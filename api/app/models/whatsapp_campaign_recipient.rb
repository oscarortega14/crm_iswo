# frozen_string_literal: true

# ============================================================================
# WhatsappCampaignRecipient — snapshot de un destinatario de una campaña
# ============================================================================
class WhatsappCampaignRecipient < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending sent failed skipped_no_opt_in skipped_no_phone skipped_missing_variable].freeze

  belongs_to :tenant
  belongs_to :whatsapp_campaign
  belongs_to :contact
  belongs_to :opportunity, optional: true
  belongs_to :whatsapp_message, optional: true, inverse_of: :whatsapp_campaign_recipient

  enum :status, STATUSES.zip(STATUSES).to_h, prefix: :status, default: "pending"

  validates :status, inclusion: { in: STATUSES }
  validates :contact_id, uniqueness: { scope: :whatsapp_campaign_id }
end
