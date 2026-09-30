# frozen_string_literal: true

# ============================================================================
# TemperatureDecayJob — enfría a diario los leads abiertos sin actividad.
# ============================================================================
# La temperatura solo se recalcula cuando algo toca la oportunidad (BANT,
# actividad, edición del dossier); sin este job un lead abandonado se queda
# "tibio" o "caliente" indefinidamente.
#
# Aplica las reglas de TemperatureCalculator (sin IA) y solo BAJA la
# temperatura: nunca la sube, para no pisar una clasificación de la IA con
# reglas. Solo revisa oportunidades abiertas sin actividad hace más de
# HOT_DAYS_MAX días, que es cuando el paso del tiempo cambia el resultado.
# No toca last_activity_at.
# ============================================================================
class TemperatureDecayJob < ApplicationJob
  queue_as :low

  RANK = { "cold" => 0, "warm" => 1, "hot" => 2 }.freeze
  INACTIVE_AFTER = Opportunities::TemperatureCalculator::THRESHOLDS[:hot_days_max].days

  def perform
    ActsAsTenant.without_tenant do
      Tenant.active.find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) { decay_tenant(tenant) }
      end
    end
  end

  private

  def decay_tenant(tenant)
    candidates = tenant.opportunities.kept.open
                       .where(temperature: %w[hot warm])
                       .where(last_activity_at: ...INACTIVE_AFTER.ago)

    candidates.find_each do |opp|
      decay!(opp)
    rescue StandardError => e
      Rails.logger.warn("[TemperatureDecayJob] opp=#{opp.id}: #{e.class} — #{e.message}")
    end
  end

  def decay!(opp)
    result = Opportunities::TemperatureCalculator.new(opp).call
    return unless RANK.fetch(result.temperature) < RANK.fetch(opp.temperature)

    previous = opp.temperature
    opp.update!(temperature: result.temperature)
    opp.opportunity_logs.create!(
      tenant:       opp.tenant,
      user:         nil,
      action:       "classify",
      changes_data: {
        temperature:          result.temperature,
        previous_temperature: previous,
        ai_used:              false,
        source:               "daily_decay",
        days_since_activity:  result.days_since
      }
    )
  end
end
