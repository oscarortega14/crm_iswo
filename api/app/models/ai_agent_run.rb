# frozen_string_literal: true

# Una respuesta del asistente IA de WhatsApp (ver AiAgent::Responder).
class AiAgentRun < ApplicationRecord
  include TenantScoped

  STATUSES = %w[replied handoff skipped error].freeze

  belongs_to :tenant
  belongs_to :contact
  belongs_to :trigger_message, class_name: "WhatsappMessage", optional: true
  belongs_to :reply_message,   class_name: "WhatsappMessage", optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
