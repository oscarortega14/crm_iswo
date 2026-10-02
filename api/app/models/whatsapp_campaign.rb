# frozen_string_literal: true

# ============================================================================
# WhatsappCampaign — envío masivo con plantilla aprobada por Meta
# ============================================================================
# Audiencia: snapshot al lanzar, tomado de los mismos filtros que
# /opportunities (pipeline_id, pipeline_stage_id, owner_id, temperature,
# status) — ver WhatsappCampaigns::AudienceResolver.
#
# Gate de opt-in: cualquier contacto sin whatsapp_opt_in_at queda
# "skipped_no_opt_in" en vez de enviarse. Única excepción: una plantilla
# marcada como WhatsappTemplate#opt_in_request — ahí el gate se salta a
# propósito, porque el mensaje mismo es el que pide la autorización.
#
# La plantilla se referencia por `whatsapp_template_id` (catálogo, ver
# WhatsappTemplate) en vez de un nombre suelto — así se hereda automático el
# formato de variables (posicional o con nombre, ver
# WhatsappTemplate#named_parameters?) sin duplicar esa lógica acá.
# ============================================================================
class WhatsappCampaign < ApplicationRecord
  include TenantScoped

  STATUSES = %w[draft scheduled running paused completed canceled].freeze

  # Resultado real por destinatario (ver #delivery_stats): se calcula desde el
  # estado del WhatsappMessage, que Meta actualiza por webhook (entregado/leído/
  # fallido). El estado del destinatario solo dice si se encoló el envío.
  DELIVERY_KEYS = %w[pending sent delivered read failed skipped].freeze

  belongs_to :tenant
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :whatsapp_template
  has_many :whatsapp_campaign_recipients, dependent: :destroy

  enum :status, STATUSES.zip(STATUSES).to_h, prefix: :status, default: "draft"

  validates :name, presence: true
  validates :batch_size, numericality: { greater_than: 0 }
  validates :batch_interval_minutes, numericality: { greater_than_or_equal_to: 1 }
  validate :variable_field_map_matches_template
  validates :confirm_reply_body, length: { maximum: 4096 }

  def launch!
    raise ArgumentError, "Solo se puede lanzar una campaña en borrador" unless status_draft?
    raise ArgumentError, template_not_launchable_reason if template_not_launchable_reason
    raise ArgumentError, "Falta configurar WhatsApp Cloud API en Ajustes → Integraciones " \
                          "(las campañas siempre envían por Meta, no por OpenWA)" unless
      tenant.whatsapp_cloud_configured?

    contacts = WhatsappCampaigns::AudienceResolver.call(tenant: tenant, filters: audience_filters)

    skip_opt_in_gate = whatsapp_template.opt_in_request?

    transaction do
      contacts.find_each do |contact|
        # Un opt-out explícito bloquea incluso las plantillas de solicitud de opt-in.
        opted_in = !contact.whatsapp_opted_out? && (skip_opt_in_gate || contact.whatsapp_opted_in?)
        whatsapp_campaign_recipients.create!(
          tenant:      tenant,
          contact:     contact,
          opportunity: contact.opportunities.order(last_activity_at: :desc).first,
          status:      opted_in ? "pending" : "skipped_no_opt_in",
          skip_reason: opted_in ? nil : skip_reason_for(contact)
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

  # Motivo por el que la plantilla no sirve para lanzar (nil = se puede).
  # Estado desconocido en Meta (nunca sincronizada) no bloquea: la UI avisa.
  def template_not_launchable_reason
    return "La plantilla «#{whatsapp_template.name}» está desactivada en el catálogo." unless whatsapp_template.active?

    meta = whatsapp_template.meta_status.to_s.upcase
    return nil if meta.blank? || meta == "APPROVED"

    "La plantilla «#{whatsapp_template.name}» está #{meta} en Meta: solo se pueden lanzar campañas con " \
      "plantillas aprobadas. Sincroniza las plantillas en WhatsApp → Plantillas o espera la aprobación."
  end

  # Copia editable (borrador) con la misma plantilla, variables, audiencia y ritmo.
  # Si la plantilla cambió de número de variables, el mapeo queda vacío para completarlo.
  def duplicate!(user)
    map = Array(variable_field_map)
    map = Array.new(whatsapp_template.variable_count, "") if map.size != whatsapp_template.variable_count

    tenant.whatsapp_campaigns.create!(
      name:                   "#{name} (copia)",
      confirm_reply_body:     confirm_reply_body,
      whatsapp_template:      whatsapp_template,
      variable_field_map:     map,
      audience_filters:       audience_filters,
      batch_size:             batch_size,
      batch_interval_minutes: batch_interval_minutes,
      created_by_user:        user
    )
  end

  # { "total", "pending", "sent", "delivered", "read", "failed", "skipped" }
  # «sent» = aceptado por Meta, aún sin confirmación de entrega. Una consulta.
  def delivery_stats
    rows = whatsapp_campaign_recipients.left_joins(:whatsapp_message)
                                       .group("whatsapp_campaign_recipients.status", "whatsapp_messages.status")
                                       .count
    stats = DELIVERY_KEYS.index_with { 0 }
    rows.each { |(recipient_status, message_status), n| stats[self.class.delivery_key(recipient_status, message_status)] += n }
    stats.merge("total" => rows.values.sum)
  end

  def self.delivery_key(recipient_status, message_status)
    case recipient_status.to_s
    when "pending" then "pending"
    when "failed"  then "failed"
    when "sent"
      case message_status.to_s
      when "failed"    then "failed"
      when "delivered" then "delivered"
      when "read"      then "read"
      else "sent"
      end
    else "skipped"
    end
  end

  # { "confirmed" => respondieron «Sí», "replied" => recibieron el mensaje automático }
  def confirmation_stats
    {
      "confirmed" => whatsapp_campaign_recipients.where.not(confirmed_at: nil).count,
      "replied"   => whatsapp_campaign_recipients.where.not(confirm_reply_message_id: nil).count
    }
  end

  def pause!  = update!(status: "paused")
  def resume! = update!(status: "running")

  def cancel!
    update!(status: "canceled")
    whatsapp_campaign_recipients.where(status: "pending")
                                 .update_all(status: "skipped_no_opt_in", skip_reason: "campaña cancelada")
  end

  private

  def skip_reason_for(contact)
    contact.whatsapp_opted_out? ? "no autorizó WhatsApp (opt-out)" : "sin opt-in registrado"
  end

  def variable_field_map_matches_template
    return unless whatsapp_template

    expected = whatsapp_template.variable_count
    return if Array(variable_field_map).size == expected

    errors.add(:variable_field_map, "debe tener #{expected} entrada(s), una por variable de la plantilla")
  end
end
