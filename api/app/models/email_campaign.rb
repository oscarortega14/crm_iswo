# frozen_string_literal: true

# ============================================================================
# EmailCampaign — envío masivo de correo por AWS SES
# ============================================================================
# Sale del dominio propio del tenant (EmailMarketing::Sender, verificado en
# SES). Misma mecánica que WhatsappCampaign: al iniciar se congela la
# audiencia en email_campaign_recipients y EmailCampaignBatchJob despacha por
# lotes. Programada (scheduled_at futuro) → queda "scheduled" y el job la
# inicia a la hora indicada.
#
# Nunca se envía a quien se dio de baja, rebotó o marcó como spam
# (Contact#email_opted_out?) ni dos veces al mismo correo en una campaña.
# ============================================================================
class EmailCampaign < ApplicationRecord
  include TenantScoped

  STATUSES = %w[draft scheduled running paused completed canceled].freeze
  RESULT_KEYS = %w[pending sent delivered opened clicked bounced complained failed skipped unsubscribed].freeze

  belongs_to :tenant
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :email_campaign_recipients, dependent: :destroy

  enum :status, STATUSES.zip(STATUSES).to_h, prefix: :status, default: "draft"

  validates :name, presence: true
  validates :batch_size, numericality: { greater_than: 0, less_than_or_equal_to: 1000 }

  before_save :sanitize_body

  # Lanza ahora o programa (si scheduled_at es futuro).
  def launch!
    raise ArgumentError, "Solo se puede lanzar una campaña en borrador" unless status_draft?
    raise ArgumentError, not_launchable_reason if not_launchable_reason

    if scheduled_at.present? && scheduled_at > Time.current
      update!(status: "scheduled")
    else
      start!
    end
  end

  # Motivo por el que no se puede lanzar (nil = se puede).
  def not_launchable_reason
    sender = tenant.email_sender
    return "Falta verificar el dominio de envío en Email marketing → Remitente." unless sender.verified?
    return "Falta el asunto del correo." if subject.blank?
    return "El correo no tiene contenido." if body_html.blank?

    nil
  end

  # Congela la audiencia y empieza a despachar. Omite duplicados por correo.
  def start!
    contacts = EmailCampaigns::AudienceResolver.call(tenant: tenant, filters: audience_filters)
    seen = Set.new

    transaction do
      contacts.includes(:opportunities).find_each do |contact|
        email = contact.email.to_s.strip.downcase
        next if email.blank? || !seen.add?(email)

        email_campaign_recipients.create!(
          tenant:      tenant,
          contact:     contact,
          email:       email,
          opportunity: contact.opportunities.max_by { |o| o.last_activity_at || o.created_at }
        )
      end

      update!(status: "running", total_recipients: email_campaign_recipients.count, started_at: Time.current)
    end
  end

  def duplicate!(user)
    tenant.email_campaigns.create!(
      name: "#{name} (copia)", subject: subject, preheader: preheader, body_html: body_html,
      body_design: body_design, audience_filters: audience_filters, batch_size: batch_size,
      created_by_user: user
    )
  end

  # Conteo por resultado (ver EmailCampaignRecipient#result). Una consulta.
  def result_stats
    stats = RESULT_KEYS.index_with { 0 }
    email_campaign_recipients.pluck(:status, :opened_at, :clicked_at, :unsubscribed_at).each do |row|
      stats[EmailCampaignRecipient.result_for(*row)] += 1
    end
    stats.merge("total" => stats.values.sum)
  end

  def pause!  = update!(status: "paused")
  def resume! = update!(status: "running")

  def cancel!
    update!(status: "canceled")
    email_campaign_recipients.status_pending.update_all(status: "skipped", skip_reason: "campaña cancelada")
  end

  private

  def sanitize_body
    self.body_html = EmailMarketing::HtmlSanitizer.call(body_html) if will_save_change_to_body_html?
  end
end
