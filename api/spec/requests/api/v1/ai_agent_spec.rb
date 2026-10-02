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

  describe "activación y pausas en bloque" do
    let(:human)  { create(:contact, tenant: tenant) }
    let(:auto)   { create(:contact, tenant: tenant) }
    let(:quiet)  { create(:contact, tenant: tenant) }

    before do
      tenant.ai_agent_config.update!(business_info: "ISO 9001")
      create(:whatsapp_message, tenant: tenant, contact: human, direction: "in", body: "hola")
      create(:whatsapp_message, tenant: tenant, contact: auto, direction: "out", automated: true, body: "campaña")
      create(:whatsapp_message, tenant: tenant, contact: quiet, direction: "in", body: "info")
      # la respuesta del asesor pausa ese chat al crearse; se reanuda para simular chats de antes del asistente
      create(:whatsapp_message, tenant: tenant, contact: human, direction: "out", body: "Hola, soy Paula")
      human.update_columns(whatsapp_automation_paused_at: nil)
    end

    it "al encender con pause_human_chats pausa solo los chats que lleva un asesor" do
      patch "/api/v1/ai_agent", headers: auth_headers(admin),
            params: { ai_agent: { enabled: true }, pause_human_chats: true }.to_json
      expect(json.dig("meta", "paused_now")).to eq(1)
      expect(human.reload.whatsapp_automation_paused?).to be(true)
      expect([ auto, quiet ].map { |c| c.reload.whatsapp_automation_paused? }).to all(be(false))
      expect(json.dig("data", "paused_chats")).to eq(1)
    end

    it "pausar todos y reanudar todos (admin); manager no" do
      post "/api/v1/ai_agent/chats", headers: auth_headers(admin), params: { paused: true }.to_json
      expect(json.dig("meta", "changed")).to eq(3)
      expect(json.dig("data", "paused_chats")).to eq(3)

      post "/api/v1/ai_agent/chats", headers: auth_headers(admin), params: { paused: false }.to_json
      expect(json.dig("data", "paused_chats")).to eq(0)

      post "/api/v1/ai_agent/chats", headers: auth_headers(manager), params: { paused: true }.to_json
      expect(response).to have_http_status(:forbidden)
    end

    it "la bandeja informa si el asistente está respondiendo" do
      get "/api/v1/whatsapp_conversations", headers: auth_headers(consultant)
      expect(json.dig("meta", "assistant_active")).to be(false)

      tenant.ai_agent_config.update!(enabled: true)
      get "/api/v1/whatsapp_conversations", headers: auth_headers(consultant)
      expect(json.dig("meta", "assistant_active")).to be(true)
    end
  end

  describe "agenda" do
    let(:calendar) { FakeGoogleCalendar.new }

    before do
      allow(AiAgent::GoogleCalendar).to receive(:configured?).and_return(true)
      allow(AiAgent::GoogleCalendar).to receive(:service_account_email).and_return("crm@iswo.iam.gserviceaccount.com")
      allow(AiAgent::GoogleCalendar).to receive(:new).and_return(calendar)
    end

    it "admin guarda la agenda (validada) y la config expone el correo a compartir" do
      patch "/api/v1/ai_agent", headers: auth_headers(admin), params: { ai_agent: { calendar: {
        calendar_id: "agenda@iswo.com.co", duration_minutes: 45, work_days: [ 1, 3, 5 ], start_time: "08:00",
        end_time: "17:00"
      } } }.to_json
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "calendar")).to include("calendar_id" => "agenda@iswo.com.co", "duration_minutes" => 45,
                                                      "work_days" => [ 1, 3, 5 ])
      expect(json["data"]).to include("calendar_active" => true,
                                      "service_account_email" => "crm@iswo.iam.gserviceaccount.com")

      patch "/api/v1/ai_agent", headers: auth_headers(admin),
            params: { ai_agent: { calendar: { start_time: "18:00", end_time: "08:00" } } }.to_json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "probar conexión devuelve horarios libres; error de Google se muestra claro" do
      tenant.ai_agent_config.update!(calendar: { calendar_id: "agenda@iswo.com.co" })
      post "/api/v1/ai_agent/calendar_test", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "slots")).to be_present

      allow(calendar).to receive(:busy).and_raise(AiAgent::GoogleCalendar::Error, "No se encontró el calendario")
      post "/api/v1/ai_agent/calendar_test", headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["message"]).to match(/No se encontró/)
    end

    it "próximas citas y cancelar (manager); consultor no" do
      tenant.ai_agent_config.update!(calendar: { calendar_id: "agenda@iswo.com.co" })
      appointment = create(:appointment, tenant: tenant, google_event_id: "evt_9")

      get "/api/v1/ai_agent/appointments", headers: auth_headers(manager)
      expect(json["data"].map { |a| a["id"] }).to eq([ appointment.id.to_s ])

      post "/api/v1/ai_agent/appointments/#{appointment.id}/cancel", headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/ai_agent/appointments/#{appointment.id}/cancel", headers: auth_headers(manager)
      expect(response).to have_http_status(:no_content)
      expect(appointment.reload.status).to eq("canceled")
      expect(calendar.deleted).to eq([ "evt_9" ])
    end
  end

  describe "recordatorios y resultado de la cita" do
    let!(:template) { create(:whatsapp_template, tenant: tenant, variable_labels: %w[Nombre Fecha]) }

    it "guarda la configuración de recordatorios validada" do
      patch "/api/v1/ai_agent", headers: auth_headers(admin), params: { ai_agent: { reminders: {
        client_offsets: [ 1, 24, 7 ], whatsapp_template_id: template.id, email_enabled: false, staff_offset_minutes: 30
      } } }.to_json
      expect(json.dig("data", "reminders")).to include("client_offsets" => [ 24, 1 ], "email_enabled" => false,
                                                       "whatsapp_template_id" => template.id.to_s,
                                                       "staff_offset_minutes" => 30, "daily_summary" => true)

      patch "/api/v1/ai_agent", headers: auth_headers(admin),
            params: { ai_agent: { reminders: { whatsapp_template_id: 999_999 } } }.to_json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lista las citas pendientes de marcar y registra asistió / no asistió" do
      contact = create(:contact, tenant: tenant, email: "c@example.com", phone_e164: nil)
      past = create(:appointment, tenant: tenant, contact: contact, starts_at: 3.hours.ago, ends_at: 2.hours.ago)
      other = create(:appointment, tenant: tenant, contact: contact, starts_at: 5.hours.ago, ends_at: 4.hours.ago)

      get "/api/v1/ai_agent/appointments", headers: auth_headers(manager)
      expect(json.dig("meta", "awaiting_outcome").map { |a| a["id"] }).to contain_exactly(past.id.to_s, other.id.to_s)

      post "/api/v1/ai_agent/appointments/#{past.id}/outcome", headers: auth_headers(manager),
           params: { outcome: "attended" }.to_json
      expect(past.reload.status).to eq("completed")

      expect {
        post "/api/v1/ai_agent/appointments/#{other.id}/outcome", headers: auth_headers(manager),
             params: { outcome: "no_show" }.to_json
      }.to have_enqueued_mail(AppointmentMailer, :no_show)
      expect(other.reload).to have_attributes(status: "no_show")
      expect(json.dig("data", "no_show_followup_at")).to be_present
    end
  end
end
