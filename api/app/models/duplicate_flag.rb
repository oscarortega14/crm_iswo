# frozen_string_literal: true

# ============================================================================
# DuplicateFlag — colisión entre dos oportunidades del mismo tenant
# ============================================================================
class DuplicateFlag < ApplicationRecord
  include TenantScoped

  MATCHED_ON  = %w[phone email both].freeze
  RESOLUTIONS = %w[pending reassigned merged ignored].freeze

  enum :matched_on, MATCHED_ON.zip(MATCHED_ON).to_h,  prefix: :matched_on
  enum :resolution, RESOLUTIONS.zip(RESOLUTIONS).to_h, prefix: :resolution, default: "pending"

  belongs_to :tenant
  belongs_to :opportunity
  belongs_to :duplicate_of_opportunity, class_name: "Opportunity"
  belongs_to :detected_by_user, class_name: "User"
  belongs_to :resolved_by_user, class_name: "User", optional: true

  validates :matched_on, inclusion: { in: MATCHED_ON }
  validates :resolution, inclusion: { in: RESOLUTIONS }
  validate  :not_same_opportunity

  scope :pending,  -> { resolution_pending }
  scope :resolved, -> { where.not(resolution: "pending") }
  # Pendientes que todavía se pueden resolver: las dos oportunidades siguen
  # activas y abiertas. Si una se eliminó, se cerró o se fusionó, la alerta ya
  # no aplica y no debe contar en la pantalla ni en el contador del menú.
  scope :actionable, lambda {
    live = Opportunity.kept.open.select(:id)
    resolution_pending.where(opportunity_id: live).where(duplicate_of_opportunity_id: live)
  }

  # Aliases usados por DuplicateFlagSerializer (oportunidad nueva vs existente).
  def opportunity_a_id = opportunity_id
  def opportunity_b_id = duplicate_of_opportunity_id

  def contact_a = opportunity&.contact
  def contact_b = duplicate_of_opportunity&.contact

  def resolve!(as:, by:, note: nil)
    update!(
      resolution:       as,
      resolved_by_user: by,
      resolution_note:  note,
      resolved_at:      Time.current
    )
  end

  private

  def not_same_opportunity
    return if opportunity_id.blank? || duplicate_of_opportunity_id.blank?

    errors.add(:duplicate_of_opportunity_id, "no puede ser la misma oportunidad") if opportunity_id == duplicate_of_opportunity_id
  end
end
