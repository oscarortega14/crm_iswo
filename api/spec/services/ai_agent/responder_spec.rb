# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiAgent::Responder do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:owner)   { create(:user, :consultant, tenant: tenant) }
  let(:contact) { create(:contact, tenant: tenant, first_name: "Contacto", last_name: nil, phone_e164: "+593991112233", owner_user: owner) }
  let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }
  let!(:opportunity) do
    create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: contact, owner_user: owner, pipeline: pipeline,
                                            pipeline_stage: pipeline.pipeline_stages.first, temperature: "cold")
  end
  let!(:cloud_integration) do
    create(:ad_integration, :cloud, tenant: tenant, account_identifier: "+5731999999999",
                                    credentials: { "access_token" => "fake-access-token" })
  end

  around do |example|
    old_provider = ENV.delete("WHATSAPP_PROVIDER")
    ENV["OPENAI_API_KEY"] = "sk-test"
    example.run
  ensure
    ENV.delete("OPENAI_API_KEY")
    ENV["WHATSAPP_PROVIDER"] = old_provider if old_provider
  end

  before do
    allow(WhatsappDeliveryJob).to receive(:perform_later)
    tenant.ai_agent_config.update!(enabled: true, assistant_name: "Sofía",
                                   business_info: "ISWO asesora certificaciones ISO 9001. Diagnóstico gratis.")
  end

  def inbound(text)
    create(:whatsapp_message, :inbound, tenant: tenant, contact: contact, body: text,
                                        from_number: "+593991112233", to_number: "+5731999999999")
  end

  it "responde con la información del negocio y el historial, como mensaje automático" do
    create(:whatsapp_message, tenant: tenant, contact: contact, direction: "out", body: "Hola, soy de ISWO",
                              automated: true, created_at: 1.hour.ago)
    msg = inbound("¿Qué hacen?")
    client = FakeOpenaiClient.new({ content: "Asesoramos certificaciones ISO 9001 😊 ¿Para qué empresa sería?" })

    result = described_class.call(message: msg, client: client)

    expect(result.status).to eq("replied")
    system = client.requests.first[:messages].first[:content]
    expect(system).to include("Sofía", "ISO 9001. Diagnóstico gratis", "Etapa actual")
    expect(client.requests.first[:messages].map { |m| m[:role] }).to eq(%w[system assistant user])

    reply = result.run.reply_message
    expect(reply).to have_attributes(direction: "out", automated: true, provider: "whatsapp_cloud",
                                     to_number: "+593991112233", body: /Asesoramos/)
    expect(result.run).to have_attributes(input_tokens: 1000, output_tokens: 50, model: "gpt-4.1-mini")
    expect(contact.reload.whatsapp_automation_paused?).to be(false)
  end

  it "usa las herramientas: califica, guarda datos y avisa lead caliente" do
    msg = inbound("Soy María Andrade de Textiles SA, necesito certificarme antes de diciembre")
    client = FakeOpenaiClient.new(
      { tool_calls: [
        { name: "guardar_datos_contacto", arguments: { nombre: "María", apellido: "Andrade", empresa: "Textiles SA" } },
        { name: "calificar_lead", arguments: { temperatura: "hot", resumen: "Certificación ISO 9001 antes de diciembre" } }
      ] },
      { content: "¡Perfecto María! ¿Cuántas personas trabajan en Textiles SA?" }
    )

    result = described_class.call(message: msg, client: client)

    expect(result.status).to eq("replied")
    expect(contact.reload).to have_attributes(first_name: "María", last_name: "Andrade", company_name: "Textiles SA")
    expect(opportunity.reload.temperature).to eq("hot")
    expect(opportunity.opportunity_logs.where(action: "classify").last.changes_data["source"]).to eq("ai_agent")
    expect(Notification.where(user: owner, kind: "ai_agent_hot_lead").count).to eq(1)
    expect(result.run.tool_calls.map { |c| c["name"] }).to eq(%w[guardar_datos_contacto calificar_lead])
    # el resultado de la herramienta vuelve al modelo
    expect(client.requests.last[:messages].last).to include(role: "tool")
  end

  it "pasar_a_asesor pausa el chat, avisa y responde aunque el modelo no escriba texto" do
    msg = inbound("Quiero hablar con una persona")
    client = FakeOpenaiClient.new({ tool_calls: [ { name: "pasar_a_asesor", arguments: { motivo: "Lo pidió" } } ] },
                                  { content: "" })

    result = described_class.call(message: msg, client: client)

    expect(result.status).to eq("handoff")
    expect(result.run.reply_message.body).to eq(described_class::HANDOFF_FALLBACK)
    expect(contact.reload.whatsapp_automation_paused?).to be(true)
    expect(Notification.where(user: owner, kind: "ai_agent_handoff").count).to eq(1)

    # el siguiente mensaje ya no lo contesta el asistente
    expect(described_class.call(message: inbound("¿hola?"), client: FakeOpenaiClient.new).status).to eq("skipped")
  end

  it "no responde: asistente apagado, chat en pausa, opt-out o ráfaga (solo al último)" do
    first = inbound("Hola")
    inbound("¿están?")
    expect(described_class.call(message: first, client: FakeOpenaiClient.new).status).to eq("skipped")

    tenant.ai_agent_config.update!(enabled: false)
    expect(described_class.call(message: inbound("x"), client: FakeOpenaiClient.new).status).to eq("skipped")
    expect(AiAgentRun.count).to eq(0)
  end

  it "una persona que escribe desde el CRM pausa el asistente en ese chat" do
    create(:whatsapp_message, tenant: tenant, contact: contact, direction: "out", body: "Hola María, soy Paula")
    expect(contact.reload.whatsapp_automation_paused?).to be(true)
  end

  it "error de OpenAI queda registrado sin enviar nada" do
    msg = inbound("Hola")
    client = FakeOpenaiClient.new
    allow(client).to receive(:chat).and_raise(AiAgent::OpenaiClient::Error, "OpenAI 429: rate limit")

    result = described_class.call(message: msg, client: client)
    expect(result.run).to have_attributes(status: "error", error: /429/)
    expect(WhatsappDeliveryJob).not_to have_received(:perform_later)
  end

  it "modo prueba no toca el CRM ni envía" do
    client = FakeOpenaiClient.new(
      { tool_calls: [ { name: "calificar_lead", arguments: { temperatura: "warm", resumen: "x" } } ] },
      { content: "¡Claro! ¿Para cuándo lo necesitas?" }
    )
    result = described_class.preview(tenant: tenant, messages: [ { "role" => "user", "content" => "info" } ],
                                     client: client)
    expect(result.reply).to eq("¡Claro! ¿Para cuándo lo necesitas?")
    expect(result.tool_calls.first["result"]).to include("prueba")
    expect(WhatsappMessage.direction_out.count).to eq(0)
    expect(AiAgentRun.count).to eq(0)
  end
end
