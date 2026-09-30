# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemperatureDecayJob, type: :job do
  let(:tenant) { ActsAsTenant.current_tenant }

  # El after_create recalcula BANT y temperatura; se fijan los valores del
  # escenario después, sin callbacks.
  def opp_with(temperature:, days_ago:, bant: 0, status: "new_lead")
    create(:opportunity, tenant: tenant, status: status).tap do |o|
      o.update_columns(temperature: temperature, last_activity_at: days_ago.days.ago, bant_score: bant)
    end
  end

  it "enfría a frío un lead tibio sin actividad hace más de 14 días y BANT bajo" do
    opp = opp_with(temperature: "warm", days_ago: 20, bant: 10)

    described_class.new.perform

    expect(opp.reload.temperature).to eq("cold")
    log = opp.opportunity_logs.where(action: "classify").last
    expect(log.changes_data).to include("source" => "daily_decay", "previous_temperature" => "warm")
  end

  it "baja de caliente a tibio un lead con BANT alto pero sin actividad hace más de 7 días" do
    opp = opp_with(temperature: "hot", days_ago: 10, bant: 80)

    described_class.new.perform

    expect(opp.reload.temperature).to eq("warm")
  end

  it "no toca leads con actividad en los últimos 7 días, aunque las reglas den otra cosa" do
    opp = opp_with(temperature: "hot", days_ago: 2, bant: 0)

    described_class.new.perform

    expect(opp.reload.temperature).to eq("hot")
  end

  it "nunca sube la temperatura" do
    opp = opp_with(temperature: "warm", days_ago: 10, bant: 90)

    described_class.new.perform

    expect(opp.reload.temperature).to eq("warm")
  end

  it "ignora oportunidades cerradas" do
    opp = opp_with(temperature: "warm", days_ago: 30, bant: 0, status: "won")

    described_class.new.perform

    expect(opp.reload.temperature).to eq("warm")
  end

  it "no cambia last_activity_at" do
    opp = opp_with(temperature: "warm", days_ago: 20)
    before = opp.reload.last_activity_at

    described_class.new.perform

    expect(opp.reload.last_activity_at).to eq(before)
  end
end
