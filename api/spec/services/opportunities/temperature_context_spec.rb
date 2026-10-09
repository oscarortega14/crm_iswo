# frozen_string_literal: true

require "rails_helper"

RSpec.describe Opportunities::TemperatureContext do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:user) { create(:user, :consultant, tenant: tenant) }
  let(:pipeline) { create(:pipeline, tenant: tenant) }
  let(:stage) { create(:pipeline_stage, pipeline: pipeline, tenant: tenant, name: "Propuesta", probability: 60) }
  let(:contact) do
    create(:contact, tenant: tenant, first_name: "Ana", last_name: "Pérez",
           email: "ana@empresa.com", company_name: "ACME", city: "Bogotá",
           custom_fields: { "empleador" => "GovCo" })
  end
  let(:opp) do
    create(:opportunity, tenant: tenant, contact: contact, pipeline: pipeline,
           pipeline_stage: stage, owner_user: user,
           title: "Crédito libranza", notes: "Interesada en 50M",
           estimated_value: 50_000_000, temperature: "warm",
           custom_fields: {
             "bant_data" => { "budget" => { "score" => 70 } },
             "tipo_credito" => "Libranza",
             "landing_slug" => "promo-verano"
           },
           last_activity_at: 3.days.ago)
  end

  before do
    create(:tenant_field_definition, tenant: tenant, entity: "opportunity",
           key: "tipo_credito", label: "Tipo de crédito", field_type: "text")
    create(:tenant_field_definition, tenant: tenant, entity: "contact",
           key: "empleador", label: "Empleador", field_type: "text")
  end

  it "incluye contacto, oportunidad, BANT y campos personalizados" do
    ctx = described_class.new(opp)
    labels = ctx.signals.map(&:label)

    expect(labels).to include("Nombre", "Empresa", "Ciudad")
    expect(labels).to include("Etapa", "Valor estimado", "Notas")
    expect(labels).to include("Tipo de crédito", "Empleador")
    expect(labels).to include("Puntuación total")
  end

  it "expone data_considered para la UI" do
    ctx = described_class.new(opp)
    expect(ctx.data_considered).to all(include(:group, :label, :value))
    expect(ctx.prompt_text).to include("Dossier del lead")
    expect(ctx.prompt_text).to include("Ana")
  end

  it "no envía correo, teléfono ni documento a la IA (tampoco desde landing o campos custom)" do
    contact.update!(phone_e164: "+573001234567", document_id: "1020304050",
                    custom_fields: { "empleador" => "GovCo", "telefono_alterno" => "3109998877" })
    opp.update_columns(custom_fields: opp.custom_fields.merge(
      "landing_submission" => { "payload" => { "email" => "otra@correo.com", "celular" => "3112223344",
                                               "cedula" => "99887766", "ciudad" => "Cali" } }
    ))
    ctx = described_class.new(opp.reload)

    text = ctx.prompt_text
    %w[ana@empresa.com otra@correo.com 3001234567 3109998877 3112223344 1020304050 99887766].each do |pii|
      expect(text).not_to include(pii)
    end
    expect(text).to include("Cali", "GovCo")
  end

  it "tolera campos vacíos sin nil en signals" do
    sparse = create(:opportunity, tenant: tenant, contact: contact, pipeline: pipeline,
                    pipeline_stage: stage, owner_user: user, title: "Mínima", notes: nil)
    ctx = described_class.new(sparse)
    expect { ctx.signals.size }.not_to raise_error
    expect(ctx.signals).to all(be_a(described_class::Signal))
  end
end
