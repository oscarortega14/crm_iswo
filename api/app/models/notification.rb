# frozen_string_literal: true

# ============================================================================
# Notification — registro de notificación in-app por usuario
# ============================================================================
# Se crea desde:
#   - ReminderNotificationJob (todos los canales → campana in-app)
#   - Notifications::NewLeadNotifier (LeadImporter, landing, alta manual por otro usuario)
#   - Notifications::StageChangeNotifier
#   - Notifications::WhatsappMessageNotifier (WebhookProcessorJob, mensaje entrante)
#   - detección de duplicados en OpportunitiesController
# Se consume desde:
#   - GET /api/v1/notifications
# ============================================================================
class Notification < ApplicationRecord
  include TenantScoped

  KINDS = %w[
    reminder_due reminder_created reminder_upcoming
    new_lead stage_change duplicate_found
    whatsapp_message_received
    ai_agent_hot_lead ai_agent_handoff
  ].freeze
  enum :kind, KINDS.zip(KINDS).to_h, prefix: true, default: "reminder_due"

  belongs_to :tenant
  belongs_to :user
  belongs_to :resource, polymorphic: true, optional: true

  validates :title, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :unread,  -> { where(read_at: nil) }
  scope :recent,  -> { order(created_at: :desc) }

  def read?
    read_at.present?
  end

  def mark_read!
    update!(read_at: Time.current) unless read?
  end
end
