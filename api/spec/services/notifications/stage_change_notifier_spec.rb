# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::StageChangeNotifier do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:owner)      { create(:user, :consultant, tenant: tenant, name: "Dueño") }
  let(:manager)    { create(:user, :manager, tenant: tenant, name: "Manager") }
  let(:pipeline)   { create(:pipeline_with_stages, tenant: tenant) }
  let(:from_stage) { pipeline.pipeline_stages.order(:position).first }
  let(:to_stage)   { pipeline.pipeline_stages.order(:position).second }
  let(:contact)    { create(:contact, tenant: tenant) }
  let(:opp) do
    create(:opportunity,
           tenant: tenant,
           pipeline: pipeline,
           pipeline_stage: from_stage,
           contact: contact,
           owner_user: owner,
           title: "Deal ACME")
  end

  it "notifica al dueño cuando otro usuario mueve la etapa" do
    expect do
      described_class.call(
        opportunity: opp,
        from_stage:  from_stage,
        to_stage:    to_stage,
        actor:       manager
      )
    end.to change { owner.notifications.kind_stage_change.count }.by(1)

    n = owner.notifications.kind_stage_change.last
    expect(n.title).to eq("Cambio de etapa")
    expect(n.body).to include("Manager")
    expect(n.body).to include(to_stage.name)
    expect(n.resource).to eq(opp)
  end

  it "no notifica si el dueño mueve su propia oportunidad" do
    expect do
      described_class.call(
        opportunity: opp,
        from_stage:  from_stage,
        to_stage:    to_stage,
        actor:       owner
      )
    end.not_to change(Notification, :count)
  end

  it "notifica al dueño en avance automático BANT aunque no haya actor" do
    expect do
      described_class.call(
        opportunity: opp,
        from_stage:  from_stage,
        to_stage:    to_stage,
        automatic:   true,
        reason:      "calificación BANT"
      )
    end.to change { owner.notifications.kind_stage_change.count }.by(1)

    expect(owner.notifications.kind_stage_change.last.body).to include("BANT")
  end

  it "no hace nada si la etapa no cambió" do
    expect do
      described_class.call(
        opportunity: opp,
        from_stage:  from_stage,
        to_stage:    from_stage,
        actor:       manager
      )
    end.not_to change(Notification, :count)
  end
end
