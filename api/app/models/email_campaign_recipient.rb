# frozen_string_literal: true

# ============================================================================
# EmailCampaignRecipient — un destinatario de una campaña de correo
# ============================================================================
# status lo mueve el despacho (pending → sent/failed/skipped) y luego los
# avisos de SES (delivered, bounced, complained). Aperturas, clics y bajas
# quedan como fechas aparte.
# ============================================================================
class EmailCampaignRecipient < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending sent delivered bounced complained failed skipped].freeze

  belongs_to :tenant
  belongs_to :email_campaign
  belongs_to :contact
  belongs_to :opportunity, optional: true

  enum :status, STATUSES.zip(STATUSES).to_h, prefix: :status, default: "pending"

  validates :email, presence: true
  validates :contact_id, uniqueness: { scope: :email_campaign_id }

  # Resultado más relevante para mostrar: una baja o un rebote pesan más que
  # una apertura; un clic implica apertura.
  def self.result_for(status, opened_at, clicked_at, unsubscribed_at)
    return "unsubscribed" if unsubscribed_at.present?
    return status if %w[pending bounced complained failed skipped].include?(status)
    return "clicked" if clicked_at.present?
    return "opened" if opened_at.present?

    status
  end

  def result
    self.class.result_for(status, opened_at, clicked_at, unsubscribed_at)
  end
end
