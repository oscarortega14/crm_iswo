# frozen_string_literal: true

# ============================================================================
# WhatsappCampaign — envío masivo con plantilla aprobada por Meta
# ============================================================================
# Audiencia: snapshot al lanzar, tomado de los mismos filtros que
# /opportunities (pipeline_id, pipeline_stage_id, owner_id, temperature,
# status) — ver WhatsappCampaigns::AudienceResolver.
#
# Gate de opt-in: cualquier contacto sin whatsapp_opt_in_at queda
# "skipped_no_opt_in" en vez de enviarse. No hay override — es la defensa
# contra baneo de número mientras no exista una BD de consentimiento real.
#
# La plantilla se referencia por `whatsapp_template_id` (catálogo, ver
# WhatsappTemplate) en vez de un nombre suelto — así se hereda automático el
# formato de variables (posicional o con nombre, ver
# WhatsappTemplate#named_parameters?) sin duplicar esa lógica acá.
# ============================================================================
class WhatsappCampaign < ApplicationRecord
  include TenantScoped

  STATUSES = %w[draft scheduled running paused completed canceled].freeze

  belongs_to :tenant
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :whatsapp_template
  has_many :whatsapp_campaign_recipients, dependent: :destroy

  enum :status, STATUSES.zip(STATUSES).to_h, prefix: :status, default: "draft"

  validates :name, presence: true
  validates :batch_size, numericality: { greater_than: 0 }
  validates :batch_interval_minutes, numericality: { greater_than_or_equal_to: 1 }
  validate :variable_field_map_matches_template

  def launch!
    raise ArgumentError, "Solo se puede lanzar una campaña en borrador" unless status_draft?
    raise ArgumentError, "Falta configurar WhatsApp Cloud API en Ajustes → Integraciones " \
                          "(las campañas siempre envían por Meta, no por Twilio/OpenWA)" unless
      tenant.whatsapp_cloud_configured?

    contacts = WhatsappCampaigns::AudienceResolver.call(tenant: tenant, filters: audience_filters)

    transaction do
      contacts.find_each do |contact|
        opted_in = contact.whatsapp_opted_in?
        whatsapp_campaign_recipients.create!(
          tenant:      tenant,
          contact:     contact,
          opportunity: contact.opportunities.order(last_activity_at: :desc).first,
          status:      opted_in ? "pending" : "skipped_no_opt_in",
          skip_reason: opted_in ? nil : "sin opt-in registrado"
        )
      end

      update!(
        status:                  "running",
        total_recipients:        whatsapp_campaign_recipients.count,
        skipped_no_opt_in_count: whatsapp_campaign_recipients.where(status: "skipped_no_opt_in").count,
        started_at:              Time.current
      )
    end
  end

  def pause!  = update!(status: "paused")
  def resume! = update!(status: "running")

  def cancel!
    update!(status: "canceled")
    whatsapp_campaign_recipients.where(status: "pending")
                                 .update_all(status: "skipped_no_opt_in", skip_reason: "campaña cancelada")
  end

  private

  def variable_field_map_matches_template
    return unless whatsapp_template

    expected = whatsapp_template.variable_count
    return if Array(variable_field_map).size == expected

    errors.add(:variable_field_map, "debe tener #{expected} entrada(s), una por variable de la plantilla")
  end
end
