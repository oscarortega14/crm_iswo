# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsApp::OutboundSender do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:contact) { create(:contact, tenant: tenant) }
  let!(:cloud_integration) do
    create(:ad_integration, :cloud,
           tenant:             tenant,
           account_identifier: "+5731999999999",
           credentials:      { "access_token" => "fake-access-token" })
  end

  around do |example|
    old_provider = ENV.delete("WHATSAPP_PROVIDER")
    example.run
  ensure
    ENV["WHATSAPP_PROVIDER"] = old_provider if old_provider
  end

  before { allow(WhatsappDeliveryJob).to receive(:perform_later) }

  it "arma y guarda el mensaje saliente con el número de la integración configurada" do
    result = described_class.call(
      tenant: tenant, contact: contact, to_number: "3001234567", body: "Hola"
    )

    expect(result.success?).to be(true)
    expect(result.message).to be_persisted
    expect(result.message.direction).to eq("out")
    expect(result.message.from_number).to eq("+5731999999999")
    expect(result.message.to_number).to eq("+573001234567")
    expect(WhatsappDeliveryJob).to have_received(:perform_later).with(result.message.id)
  end

  it "asocia la oportunidad cuando se pasa y actualiza su última actividad" do
    pipeline = create(:pipeline_with_stages, tenant: tenant)
    opportunity = create(:opportunity, tenant: tenant, contact: contact,
                          pipeline: pipeline, pipeline_stage: pipeline.pipeline_stages.first,
                          last_activity_at: 1.week.ago)

    result = described_class.call(
      tenant: tenant, contact: contact, opportunity: opportunity,
      to_number: "3001234567", body: "Hola"
    )

    expect(result.message.opportunity_id).to eq(opportunity.id)
    expect(opportunity.reload.last_activity_at).to be_within(5.seconds).of(Time.current)
  end

  it "funciona sin oportunidad (envío standalone desde el inbox)" do
    result = described_class.call(
      tenant: tenant, contact: contact, to_number: "3001234567", body: "Hola"
    )

    expect(result.success?).to be(true)
    expect(result.message.opportunity_id).to be_nil
  end

  it "arma un mensaje de plantilla cuando se pasa whatsapp_template_id" do
    template = create(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto",
                                           language: "es_CO", variable_labels: ["Nombre"])

    result = described_class.call(
      tenant: tenant, contact: contact, to_number: "3001234567",
      body: nil, whatsapp_template_id: template.id, template_params: ["Oscar"]
    )

    expect(result.success?).to be(true)
    expect(result.message.message_type).to eq("template")
    expect(result.message.template_name).to eq("primer_contacto")
    expect(result.message.template_language).to eq("es_CO")
    expect(result.message.template_params).to eq(["Oscar"])
    expect(result.message.body).to be_nil
  end

  it "copia variable_names de la plantilla al mensaje (variables con nombre de Meta)" do
    template = create(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto",
                                           language: "es_CO", variable_labels: ["Nombre"],
                                           variable_names: ["primer_nombre"])

    result = described_class.call(
      tenant: tenant, contact: contact, to_number: "3001234567",
      body: nil, whatsapp_template_id: template.id, template_params: ["Oscar"]
    )

    expect(result.message.template_variable_names).to eq(["primer_nombre"])
  end

  it "eleva RecordNotFound si el whatsapp_template_id no existe en el catálogo activo del tenant" do
    inactive = create(:whatsapp_template, tenant: tenant, active: false)

    expect do
      described_class.call(
        tenant: tenant, contact: contact, to_number: "3001234567",
        body: nil, whatsapp_template_id: inactive.id
      )
    end.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "devuelve error_code :not_configured si el tenant no tiene envío saliente" do
    cloud_integration.destroy!

    result = described_class.call(
      tenant: tenant, contact: contact, to_number: "3001234567", body: "Hola"
    )

    expect(result.success?).to be(false)
    expect(result.error_code).to eq(:not_configured)
    expect(result.message).to be_nil
  end
end
