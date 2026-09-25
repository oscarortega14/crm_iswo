# frozen_string_literal: true

require "rails_helper"

RSpec.describe Opportunities::StageAutomation do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:pipeline) { create(:pipeline, tenant: tenant) }
  let(:owner)    { create(:user, tenant: tenant) }
  let(:actor)    { create(:user, tenant: tenant) }

  let!(:nueva)      { create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Nueva", position: 0) }
  let!(:contactada) do
    create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Contactada", position: 1,
           auto_rule: { "trigger" => "whatsapp_outbound" })
  end
  let!(:interesada) do
    create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Interesada", position: 2,
           auto_rule: { "trigger" => "whatsapp_inbound" })
  end
  let!(:ganada) { create(:pipeline_stage, :won, pipeline: pipeline, tenant: tenant, name: "Ganada", position: 3) }

  let(:contact) { create(:contact, tenant: tenant) }
  let(:opp) do
    create(:opportunity, :skip_bant_recalc, tenant: tenant, pipeline: pipeline, pipeline_stage: nueva,
                                            contact: contact, owner_user: owner)
  end

  def run(trigger, opportunity = opp)
    described_class.call(opportunity: opportunity, trigger: trigger)
  end

  it "avanza a la etapa con el disparador y registra log + notificación" do
    expect(run("whatsapp_outbound")).to eq(contactada)

    expect(opp.reload.pipeline_stage).to eq(contactada)
    log = opp.opportunity_logs.where(action: "stage_change").last
    expect(log.note).to eq("Avance automático: se envió un WhatsApp al lead")
    expect(log.user_id).to be_nil
    expect(log.changes_data).to include("from_stage_id" => nueva.id, "to_stage_id" => contactada.id,
                                        "trigger" => "whatsapp_outbound")
    expect(Notification.where(user: owner, kind: "stage_change").last.body).to include("automático")
  end

  it "puede saltar etapas intermedias hacia adelante" do
    expect(run("whatsapp_inbound")).to eq(interesada)
  end

  it "nunca retrocede" do
    opp.update!(pipeline_stage: interesada)
    expect(run("whatsapp_outbound")).to be_nil
    expect(opp.reload.pipeline_stage).to eq(interesada)
  end

  it "no mueve oportunidades cerradas ni descartadas" do
    opp.update!(pipeline_stage: ganada, status: "won")
    expect(run("whatsapp_inbound")).to be_nil

    other = create(:opportunity, :skip_bant_recalc, tenant: tenant, pipeline: pipeline, pipeline_stage: nueva)
    other.discard
    expect(run("whatsapp_inbound", other)).to be_nil
  end

  it "ignora disparadores sin etapa configurada o desconocidos" do
    contactada.update!(auto_rule: {})
    expect(run("whatsapp_outbound")).to be_nil
    expect(run("inventado")).to be_nil
  end

  it "respeta un retroceso manual (lo manual manda)" do
    opp.update!(pipeline_stage: nueva)
    opp.opportunity_logs.create!(tenant: tenant, user: actor, action: "stage_change",
                                 changes_data: { from_stage_id: interesada.id, to_stage_id: nueva.id })

    expect(run("whatsapp_inbound")).to be_nil
    expect(opp.reload.pipeline_stage).to eq(nueva)
  end

  it "vuelve a automatizar tras un avance manual posterior" do
    opp.opportunity_logs.create!(tenant: tenant, user: actor, action: "stage_change",
                                 changes_data: { from_stage_id: interesada.id, to_stage_id: nueva.id })
    opp.opportunity_logs.create!(tenant: tenant, user: actor, action: "stage_change",
                                 changes_data: { from_stage_id: nueva.id, to_stage_id: contactada.id })
    opp.update!(pipeline_stage: contactada)

    expect(run("whatsapp_inbound")).to eq(interesada)
  end

  describe ".call_for_contact" do
    it "sin oportunidad explícita avanza todas las abiertas del contacto" do
      second = create(:opportunity, :skip_bant_recalc, tenant: tenant, pipeline: pipeline,
                                                       pipeline_stage: nueva, contact: contact)
      opp

      described_class.call_for_contact(contact: contact, trigger: "whatsapp_outbound")

      expect([opp.reload, second.reload].map(&:pipeline_stage)).to all(eq(contactada))
    end
  end
end
