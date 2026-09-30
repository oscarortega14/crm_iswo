# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AiAgent", type: :request do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:admin)      { create(:user, :admin, tenant: tenant) }
  let(:manager)    { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }

  around do |example|
    ENV["OPENAI_API_KEY"] = "sk-test"
    example.run
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  it "admin guarda y activa; no deja activar sin información del negocio" do
    patch "/api/v1/ai_agent", headers: auth_headers(admin), params: { ai_agent: { enabled: true } }.to_json
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["message"]).to match(/información del negocio/)

    patch "/api/v1/ai_agent", headers: auth_headers(admin),
          params: { ai_agent: { enabled: true, assistant_name: "Sofía", business_info: "ISO 9001" } }.to_json
    expect(response).to have_http_status(:ok)
    expect(json["data"]).to include("enabled" => true, "active" => true, "assistant_name" => "Sofía",
                                    "model" => "gpt-4.1-mini", "openai_configured" => true)
  end

  it "manager consulta pero no cambia; consultor no accede" do
    get "/api/v1/ai_agent", headers: auth_headers(manager)
    expect(response).to have_http_status(:ok)
    patch "/api/v1/ai_agent", headers: auth_headers(manager), params: { ai_agent: { enabled: false } }.to_json
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/ai_agent", headers: auth_headers(consultant)
    expect(response).to have_http_status(:forbidden)
  end

  it "PATCH /tenant no puede activar el asistente por la puerta de atrás" do
    patch "/api/v1/tenant", headers: auth_headers(admin),
          params: { tenant: { settings: { ai_agent: { enabled: true } } } }.to_json
    expect(tenant.reload.ai_agent_config.enabled?).to be(false)
  end

  it "probar el asistente devuelve la respuesta sin enviar nada" do
    tenant.ai_agent_config.update!(business_info: "ISO 9001")
    fake = FakeOpenaiClient.new({ content: "¡Hola! ¿En qué te ayudo?" })
    allow(AiAgent::OpenaiClient).to receive(:new).and_return(fake)

    post "/api/v1/ai_agent/test", headers: auth_headers(admin),
         params: { messages: [ { role: "user", content: "hola" } ] }.to_json
    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "reply")).to eq("¡Hola! ¿En qué te ayudo?")
    expect(WhatsappMessage.count).to eq(0)
  end

  it "actividad: últimas respuestas y consumo de 30 días" do
    contact = create(:contact, tenant: tenant)
    AiAgentRun.create!(tenant: tenant, contact: contact, status: "replied", input_tokens: 900, output_tokens: 40)
    AiAgentRun.create!(tenant: tenant, contact: contact, status: "handoff", input_tokens: 100, output_tokens: 10)

    get "/api/v1/ai_agent/activity", headers: auth_headers(manager)
    expect(json["data"].size).to eq(2)
    expect(json.dig("meta", "last_30_days")).to include("replies" => 2, "handoffs" => 1, "input_tokens" => 1000)
  end
end
