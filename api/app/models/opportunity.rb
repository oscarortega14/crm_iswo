# frozen_string_literal: true

# ============================================================================
# Opportunity — tabla central del dominio comercial
# ============================================================================
# Ciclo de vida (status):
#   new_lead → contacted → qualified → proposal → won | lost
#
# `last_activity_at` se toca desde:
#   - creación de notas / logs
#   - cambios de etapa
#   - mensajes WhatsApp
#   - recordatorios marcados como done
# ============================================================================
class Opportunity < ApplicationRecord
  include TenantScoped
  include Discard::Model
  include DataClassifiable
  include ExportRansackable

  EXPORT_RANSACKABLE_ATTRIBUTES = %w[
    pipeline_id pipeline_stage_id owner_user_id lead_source_id
    status temperature updated_at last_activity_at title
  ].freeze
  EXPORT_RANSACKABLE_ASSOCIATIONS = %w[contact].freeze

  TEMPERATURES = %w[cold warm hot].freeze
  enum :temperature, TEMPERATURES.zip(TEMPERATURES).to_h, prefix: :temp, default: "cold"

  STATUSES = {
    "new_lead"  => "new_lead",
    "contacted" => "contacted",
    "qualified" => "qualified",
    "proposal"  => "proposal",
    "won"       => "won",
    "lost"      => "lost",
    "merged"    => "merged"   # estado terminal: fusionada via DuplicateFlag → se descarta automáticamente
  }.freeze
  enum :status, STATUSES, prefix: true, default: "new_lead"

  # ---- Asociaciones ---------------------------------------------------------
  belongs_to :tenant
  belongs_to :contact
  belongs_to :pipeline
  belongs_to :pipeline_stage
  belongs_to :owner_user,  class_name: "User"
  belongs_to :lead_source, optional: true

  has_many :opportunity_logs, dependent: :destroy
  has_many :reminders,        dependent: :destroy
  has_many :whatsapp_messages, dependent: :nullify
  has_many :duplicate_flags,  dependent: :destroy
  has_many :landing_form_submissions, dependent: :nullify
  has_many :appointments, dependent: :nullify

  # Duplicados donde ESTA oportunidad es la "ganadora"
  has_many :duplicate_flags_as_original,
           class_name: "DuplicateFlag",
           foreign_key: :duplicate_of_opportunity_id,
           dependent: :destroy

  # API/SPA usan `notes` y `expected_close_date`; en BD son description / expected_close_on.
  alias_attribute :notes, :description
  alias_attribute :expected_close_date, :expected_close_on
  alias_attribute :lost_reason, :close_reason

  # ---- Validaciones ---------------------------------------------------------
  validates :title, presence: true
  validates :estimated_value,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :bant_score,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :currency, length: { is: 3 }
  validate  :stage_belongs_to_pipeline

  # Flags de control para recálculo BANT (controller / factories / jobs internos).
  attr_accessor :preserve_temperature_on_bant_recalc, :skip_bant_recalc

  # ---- Callbacks ------------------------------------------------------------
  before_validation :set_last_activity_at, on: :create
  before_save       :track_close_transition
  after_create      :recalculate_bant_after_create
  after_update      :recalculate_bant_after_update
  after_commit      :enqueue_google_conversion_upload, on: %i[create update]

  # ---- Scopes ---------------------------------------------------------------
  scope :open,        -> { where.not(status: %w[won lost merged]) }
  scope :won,         -> { where(status: "won") }
  scope :lost,        -> { where(status: "lost") }
  scope :by_owner,    ->(user_id) { where(owner_user_id: user_id) }
  scope :stale,       ->(days = 7) { where(last_activity_at: ..days.days.ago) }
  scope :hot,         -> { where(temperature: "hot") }
  scope :warm,        -> { where(temperature: "warm") }
  scope :cold,        -> { where(temperature: "cold") }

  # ---- Helpers --------------------------------------------------------------
  def terminal?
    status_won? || status_lost? || status_merged?
  end

  def touch_activity!(recalc_temperature: true)
    update_column(:last_activity_at, Time.current)
    sync_temperature_from_signals! if recalc_temperature
  end

  # Recalcula frío/tibio/caliente según BANT y días sin actividad (sin llamar a IA).
  def sync_temperature_from_signals!
    return unless defined?(Opportunities::TemperatureCalculator)

    reload
    Opportunities::TemperatureCalculator.new(self).apply!
  end

  # Recalcula bant_score (y opcionalmente temperatura) vía BantScorer.
  def recalculate_bant!(sync_temperature: nil)
    return unless defined?(Opportunities::BantScorer)

    sync = if sync_temperature.nil?
             !preserve_temperature_on_bant_recalc
           else
             sync_temperature
           end

    previous_skip = skip_bant_recalc
    self.skip_bant_recalc = true
    Opportunities::BantScorer.new(self).call_and_persist!(sync_temperature: sync)
    reload
  ensure
    self.skip_bant_recalc = previous_skip
  end

  # BANT detallado vive en custom_fields["bant_data"] (no hay columna dedicada).
  def bant_data
    (custom_fields || {})["bant_data"] || {}
  end

  def bant_data=(value)
    return if value.nil?

    incoming =
      if value.is_a?(Hash)
        value.deep_stringify_keys
      else
        {}
      end
    return if incoming.blank?

    existing = (bant_data || {}).deep_stringify_keys
    merged   = existing.deep_merge(incoming)
    cf       = (custom_fields || {}).dup
    cf["bant_data"] = merged
    self.custom_fields = cf
  end

  private

  def recalculate_bant_after_create
    return if skip_bant_recalc

    recalculate_bant!
  end

  def recalculate_bant_after_update
    return if skip_bant_recalc
    return unless saved_change_to_estimated_value? || bant_custom_fields_changed_on_save?

    recalculate_bant!
  end

  def bant_custom_fields_changed_on_save?
    return false unless saved_change_to_custom_fields?

    before_cf, after_cf = saved_change_to_custom_fields
    (before_cf || {})["bant_data"] != (after_cf || {})["bant_data"]
  end

  def set_last_activity_at
    self.last_activity_at ||= Time.current
  end

  def stage_belongs_to_pipeline
    return if pipeline_stage.blank? || pipeline.blank?

    errors.add(:pipeline_stage, "no pertenece al pipeline indicado") if pipeline_stage.pipeline_id != pipeline_id
  end

  def track_close_transition
    if status_changed? && terminal?
      self.closed_at ||= Time.current
    elsif status_changed? && !terminal?
      self.closed_at = nil
      self.close_reason = nil
    end
  end

  def enqueue_google_conversion_upload
    return unless saved_change_to_status?(to: "won")

    UploadGoogleConversionJob.perform_later(id)
  end
end
