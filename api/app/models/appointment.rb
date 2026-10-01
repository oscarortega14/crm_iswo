# frozen_string_literal: true

# ============================================================================
# Appointment — cita agendada en el Google Calendar del tenant
# ============================================================================
# La crea el asistente IA (AiAgent::Scheduler) cuando el cliente elige un
# horario libre; puede cancelarse o reprogramarse por WhatsApp o desde el CRM.
# ============================================================================
class Appointment < ApplicationRecord
  include TenantScoped

  STATUSES = %w[scheduled canceled completed no_show].freeze
  SOURCES  = %w[ai_agent user].freeze

  belongs_to :tenant
  belongs_to :contact
  belongs_to :opportunity, optional: true
  belongs_to :owner_user, class_name: "User", optional: true

  enum :status, STATUSES.zip(STATUSES).to_h, prefix: :status, default: "scheduled"

  validates :starts_at, :ends_at, presence: true
  validates :source, inclusion: { in: SOURCES }
  validate :ends_after_start

  scope :upcoming, -> { status_scheduled.where(starts_at: Time.current..).order(:starts_at) }
  scope :overlapping, ->(from, to) { status_scheduled.where("starts_at < ? AND ends_at > ?", to, from) }

  private

  def ends_after_start
    errors.add(:ends_at, "debe ser después del inicio") if starts_at && ends_at && ends_at <= starts_at
  end
end
