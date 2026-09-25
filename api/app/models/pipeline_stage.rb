# frozen_string_literal: true

# ============================================================================
# PipelineStage — etapa ordenada dentro de un Pipeline
# ============================================================================
class PipelineStage < ApplicationRecord
  include TenantScoped

  # ---- Asociaciones ---------------------------------------------------------
  belongs_to :tenant
  belongs_to :pipeline
  has_many :opportunities, dependent: :restrict_with_exception

  # ---- Validaciones ---------------------------------------------------------
  validates :name, presence: true, uniqueness: { scope: :pipeline_id, case_sensitive: false }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :probability, numericality: { only_integer: true,
                                          greater_than_or_equal_to: 0,
                                          less_than_or_equal_to: 100 }
  validate :terminal_states_mutually_exclusive
  validate :auto_rule_valid

  before_validation :normalize_auto_rule

  # ---- Scopes ---------------------------------------------------------------
  scope :ordered,     -> { order(:position) }
  scope :open_stages, -> { where(closed_won: false, closed_lost: false) }
  scope :terminal,    -> { where("closed_won = TRUE OR closed_lost = TRUE") }
  scope :with_auto_trigger, ->(trigger) { where("auto_rule->>'trigger' = ?", trigger.to_s) }

  def terminal?
    closed_won? || closed_lost?
  end

  def auto_trigger
    auto_rule.is_a?(Hash) ? auto_rule["trigger"].presence : nil
  end

  private

  def terminal_states_mutually_exclusive
    errors.add(:base, "una etapa no puede ser closed_won y closed_lost a la vez") if closed_won? && closed_lost?
  end

  # {} o { "trigger" => "..." }; trigger vacío = sin regla.
  def normalize_auto_rule
    rule = auto_rule.is_a?(Hash) ? auto_rule.stringify_keys : {}
    self.auto_rule = rule["trigger"].present? ? { "trigger" => rule["trigger"].to_s } : {}
  end

  # Ganada/Perdida siempre las decide una persona; un disparador por pipeline.
  def auto_rule_valid
    trigger = auto_trigger
    return if trigger.nil?

    unless Opportunities::StageAutomation::TRIGGERS.key?(trigger)
      return errors.add(:auto_rule, "disparador no válido")
    end

    errors.add(:auto_rule, "no se permite en etapas de cierre (ganada/perdida)") if terminal?

    taken = PipelineStage.where(pipeline_id: pipeline_id, discarded_at: nil)
                         .with_auto_trigger(trigger)
                         .where.not(id: id)
                         .exists?
    errors.add(:auto_rule, "ya está asignado a otra etapa de este pipeline") if taken
  end
end
