# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappCampaigns::AudienceResolver do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }
  let(:stage) { pipeline.pipeline_stages.first }

  it "filtra por pipeline_stage_id y solo trae contactos con teléfono" do
    with_phone = create(:contact, tenant: tenant, phone_e164: "+573001112233")
    without_phone = create(:contact, :without_phone, tenant: tenant)
    create(:opportunity, tenant: tenant, contact: with_phone, pipeline: pipeline, pipeline_stage: stage)
    create(:opportunity, tenant: tenant, contact: without_phone, pipeline: pipeline, pipeline_stage: stage)

    result = described_class.call(tenant: tenant, filters: { "pipeline_stage_id" => stage.id })

    expect(result).to include(with_phone)
    expect(result).not_to include(without_phone)
  end

  it "filtra por temperature válida e ignora valores inválidos" do
    hot_contact = create(:contact, tenant: tenant, phone_e164: "+573001112233")
    create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: hot_contact, pipeline: pipeline,
           pipeline_stage: stage, temperature: "hot")

    result = described_class.call(tenant: tenant, filters: { "temperature" => "hot" })
    expect(result).to include(hot_contact)

    result_invalid = described_class.call(tenant: tenant, filters: { "temperature" => "not-a-real-value" })
    expect(result_invalid).to include(hot_contact)
  end

  it "sin filtros trae todos los contactos con teléfono asociados a oportunidades vigentes" do
    contact = create(:contact, tenant: tenant, phone_e164: "+573001112233")
    create(:opportunity, tenant: tenant, contact: contact, pipeline: pipeline, pipeline_stage: stage)

    result = described_class.call(tenant: tenant, filters: {})
    expect(result).to include(contact)
  end
end
