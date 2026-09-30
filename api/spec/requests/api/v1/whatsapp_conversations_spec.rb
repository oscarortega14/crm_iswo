# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::WhatsappConversations (inbox)", type: :request do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:admin)      { create(:user, :admin,      tenant: tenant) }
  let(:manager)    { create(:user, :manager,    tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
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

  describe "GET /api/v1/whatsapp_conversations" do
    it "agrupa por contacto, trae el último mensaje y el conteo de no leídos" do
      own_contact = create(:contact, tenant: tenant, owner_user: consultant)
      create(:whatsapp_message, tenant: tenant, contact: own_contact, direction: "in",
             body: "primero", created_at: 2.hours.ago, read_at: 1.hour.ago)
      latest = create(:whatsapp_message, tenant: tenant, contact: own_contact, direction: "in",
                       body: "segundo", created_at: 1.minute.ago)

      get "/api/v1/whatsapp_conversations", headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      row = json["data"].find { |d| d.dig("attributes", "contact_id") == own_contact.id.to_s }
      expect(row).not_to be_nil
      expect(row.dig("attributes", "last_message_body")).to eq(latest.body)
      expect(row.dig("attributes", "unread_count")).to eq(1)
      expect(row.dig("attributes", "bucket")).to eq("mine")
    end

    it "cuando el último mensaje es una plantilla sin body, arma el preview con el nombre y los parámetros" do
      contact = create(:contact, tenant: tenant, owner_user: consultant)
      create(:whatsapp_message, tenant: tenant, contact: contact, direction: "out", body: nil,
             message_type: "template", template_name: "confirmacion_contacto_whatsapp",
             template_language: "es_CO", template_params: %w[Victoria], created_at: 1.minute.ago)

      get "/api/v1/whatsapp_conversations", headers: auth_headers(consultant)

      row = json["data"].find { |d| d.dig("attributes", "contact_id") == contact.id.to_s }
      expect(row.dig("attributes", "last_message_body")).to eq("Plantilla: confirmacion_contacto_whatsapp (Victoria)")
    end

    it "consultant ve la bandeja 'sin asignar' compartida (mensaje sin oportunidad ni dueño)" do
      unowned_contact = create(:contact, tenant: tenant)
      create(:whatsapp_message, tenant: tenant, contact: unowned_contact, direction: "in")

      get "/api/v1/whatsapp_conversations", params: { scope: "unassigned" }, headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d.dig("attributes", "contact_id") }
      expect(ids).to include(unowned_contact.id.to_s)
    end

    it "?scope=mine solo devuelve las conversaciones del consultor" do
      mine = create(:contact, tenant: tenant, owner_user: consultant)
      other_owner = create(:user, :consultant, tenant: tenant)
      other = create(:contact, tenant: tenant, owner_user: other_owner)
      create(:whatsapp_message, tenant: tenant, contact: mine, direction: "in")
      create(:whatsapp_message, tenant: tenant, contact: other, direction: "in")

      get "/api/v1/whatsapp_conversations", params: { scope: "mine" }, headers: auth_headers(consultant)

      ids = json["data"].map { |d| d.dig("attributes", "contact_id") }
      expect(ids).to include(mine.id.to_s)
      expect(ids).not_to include(other.id.to_s)
    end
  end

  describe "contactos eliminados" do
    it "no muestra en la bandeja ni cuenta como no leída la conversación de un contacto eliminado" do
      kept = create(:contact, tenant: tenant, owner_user: admin)
      gone = create(:contact, tenant: tenant, owner_user: admin)
      create(:whatsapp_message, tenant: tenant, contact: kept, direction: "in", read_at: nil)
      create(:whatsapp_message, tenant: tenant, contact: gone, direction: "in", read_at: nil)
      gone.discard

      get "/api/v1/whatsapp_conversations", headers: auth_headers(admin)
      ids = json["data"].map { |d| d.dig("attributes", "contact_id") }
      expect(ids).to eq([ kept.id.to_s ])

      get "/api/v1/whatsapp_conversations/stats", headers: auth_headers(admin)
      expect(json.dig("data", "unread")).to eq(1)
    end
  end

  describe "GET /api/v1/whatsapp_conversations/stats" do
    it "cuenta conversaciones con mensajes entrantes sin leer" do
      c1 = create(:contact, tenant: tenant, owner_user: admin)
      c2 = create(:contact, tenant: tenant, owner_user: admin)
      create(:whatsapp_message, tenant: tenant, contact: c1, direction: "in", read_at: nil)
      create(:whatsapp_message, tenant: tenant, contact: c2, direction: "in", read_at: Time.current)

      get "/api/v1/whatsapp_conversations/stats", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "unread")).to eq(1)
    end

    it "expone latest_inbound_id (sube con cada mensaje entrante; lo usa el sonido global)" do
      contact = create(:contact, tenant: tenant, owner_user: admin)
      create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in")
      latest = create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in")
      create(:whatsapp_message, :outbound, tenant: tenant, contact: contact)

      get "/api/v1/whatsapp_conversations/stats", headers: auth_headers(admin)

      expect(json.dig("data", "latest_inbound_id")).to eq(latest.id)
    end
  end

  describe "PATCH /api/v1/whatsapp_conversations/:contact_id/mark_read" do
    it "marca como leídos los mensajes entrantes del contacto y limpia la notificación" do
      contact = create(:contact, tenant: tenant, owner_user: admin)
      msg = create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in", read_at: nil)
      notif = Notification.create!(tenant: tenant, user: admin, kind: "whatsapp_message_received",
                                    title: "Nuevo mensaje de WhatsApp", resource: contact)

      patch "/api/v1/whatsapp_conversations/#{contact.id}/mark_read", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(msg.reload.read_at).not_to be_nil
      expect(notif.reload.read_at).not_to be_nil
    end

    it "encola el «visto» de WhatsApp para el último mensaje entrante no leído" do
      contact = create(:contact, tenant: tenant, owner_user: admin)
      create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in", read_at: nil)
      latest = create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in", read_at: nil)

      expect do
        patch "/api/v1/whatsapp_conversations/#{contact.id}/mark_read", headers: auth_headers(admin)
      end.to have_enqueued_job(WhatsappReadReceiptJob).with(latest.id)
    end

    it "no encola nada si no había mensajes sin leer" do
      contact = create(:contact, tenant: tenant, owner_user: admin)
      create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in", read_at: Time.current)

      expect do
        patch "/api/v1/whatsapp_conversations/#{contact.id}/mark_read", headers: auth_headers(admin)
      end.not_to have_enqueued_job(WhatsappReadReceiptJob)
    end
  end

  describe "POST /api/v1/whatsapp_conversations/:contact_id/send_message" do
    before { allow(WhatsappDeliveryJob).to receive(:perform_later) }

    it "responde desde el inbox sin necesidad de una oportunidad abierta" do
      contact = create(:contact, tenant: tenant, owner_user: admin, phone_e164: "+573001234567")

      post "/api/v1/whatsapp_conversations/#{contact.id}/send_message",
           params:  { to_number: "3001234567", body: "Hola desde el inbox" }.to_json,
           headers: auth_headers(admin)

      expect(response).to have_http_status(:accepted)
      attrs = json["data"]["attributes"]
      expect(attrs["direction"]).to eq("out")
      expect(attrs["from_number"]).to eq("+5731999999999")
    end

    it "un consultor puede responder un contacto sin asignar (para reclamarlo)" do
      unowned_contact = create(:contact, tenant: tenant, phone_e164: "+573001234567")

      post "/api/v1/whatsapp_conversations/#{unowned_contact.id}/send_message",
           params:  { to_number: "3001234567", body: "Hola" }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:accepted)
    end

    it "acepta whatsapp_template_id para iniciar conversación fuera de la ventana de 24h" do
      contact = create(:contact, tenant: tenant, owner_user: admin, phone_e164: "+573001234567")
      template = create(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto",
                                             language: "es_CO", variable_labels: ["Nombre"])

      post "/api/v1/whatsapp_conversations/#{contact.id}/send_message",
           params:  { to_number: "3001234567", whatsapp_template_id: template.id, template_params: ["Oscar"] }.to_json,
           headers: auth_headers(admin)

      expect(response).to have_http_status(:accepted)
      attrs = json["data"]["attributes"]
      expect(attrs["message_type"]).to eq("template")
      expect(attrs["template_name"]).to eq("primer_contacto")
    end

    it "un consultor NO puede responder por el contacto de otro consultor" do
      other_owner = create(:user, :consultant, tenant: tenant)
      foreign = create(:contact, tenant: tenant, owner_user: other_owner, phone_e164: "+573001234567")

      post "/api/v1/whatsapp_conversations/#{foreign.id}/send_message",
           params:  { to_number: "3001234567", body: "Hola" }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/whatsapp_conversations/:contact_id/messages (eliminar conversación)" do
    let(:contact) { create(:contact, tenant: tenant, owner_user: consultant) }

    it "borra del CRM los mensajes del contacto y deja registro en auditoría" do
      create_list(:whatsapp_message, 2, tenant: tenant, contact: contact, direction: "in")
      other = create(:whatsapp_message, tenant: tenant, contact: create(:contact, tenant: tenant), direction: "in")

      expect do
        delete "/api/v1/whatsapp_conversations/#{contact.id}/messages", headers: auth_headers(admin)
      end.to change(WhatsappMessage, :count).by(-2)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "deleted")).to eq(2)
      expect(other.reload).to be_present
      expect(AuditEvent.where(action: "whatsapp_conversation_deleted", entity_id: contact.id)).to exist
    end

    it "conserva el resultado de campaña (fallido) al borrar un mensaje de campaña" do
      msg = create(:whatsapp_message, :outbound, :cloud, tenant: tenant, contact: contact, status: "failed",
                                                         error_message: "Cloud API: (#132001)")
      recipient = create(:whatsapp_campaign_recipient, tenant: tenant, contact: contact, status: "sent", whatsapp_message: msg)

      delete "/api/v1/whatsapp_conversations/#{contact.id}/messages", headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      expect(recipient.reload).to have_attributes(status: "failed", whatsapp_message_id: nil)
      expect(recipient.skip_reason).to match(/132001/)
    end

    it "el consultor dueño puede; otro consultor no" do
      create(:whatsapp_message, tenant: tenant, contact: contact, direction: "in")
      intruder = create(:user, :consultant, tenant: tenant)

      delete "/api/v1/whatsapp_conversations/#{contact.id}/messages", headers: auth_headers(intruder)
      expect(response.status).to be_in([ 403, 404 ])

      delete "/api/v1/whatsapp_conversations/#{contact.id}/messages", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "autorizaron y esperan respuesta" do
    let(:waiting) { create(:contact, tenant: tenant, owner_user: consultant) }
    let(:answered) { create(:contact, tenant: tenant, owner_user: consultant) }

    before do
      [ waiting, answered ].each do |c|
        c.mark_whatsapp_opt_in!(source: "reply_confirm")
        create(:whatsapp_message, tenant: tenant, contact: c, direction: "in", body: "Sí")
      end
      # El automático no cuenta como respuesta; la del asesor sí.
      create(:whatsapp_message, tenant: tenant, contact: waiting, direction: "out", automated: true, body: "¡Gracias!")
      create(:whatsapp_message, tenant: tenant, contact: answered, direction: "out", body: "Hola, soy Paula")
    end

    it "marca awaiting_reply, filtra con ?awaiting=true y lo cuenta en stats" do
      get "/api/v1/whatsapp_conversations", headers: auth_headers(consultant)
      flags = json["data"].to_h { |d| [ d.dig("attributes", "contact_id"), d.dig("attributes", "awaiting_reply") ] }
      expect(flags).to include(waiting.id.to_s => true, answered.id.to_s => false)

      get "/api/v1/whatsapp_conversations?awaiting=true", headers: auth_headers(consultant)
      expect(json["data"].map { |d| d.dig("attributes", "contact_id") }).to eq([ waiting.id.to_s ])

      get "/api/v1/whatsapp_conversations/stats", headers: auth_headers(consultant)
      expect(json.dig("data", "awaiting")).to eq(1)
    end

    it "pausar y reanudar el automático del chat" do
      patch "/api/v1/whatsapp_conversations/#{waiting.id}/automation", params: { paused: true }.to_json,
                                                                        headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      expect(waiting.reload.whatsapp_automation_paused?).to be(true)

      get "/api/v1/whatsapp_conversations", headers: auth_headers(consultant)
      row = json["data"].find { |d| d.dig("attributes", "contact_id") == waiting.id.to_s }
      expect(row.dig("attributes", "automation_paused")).to be(true)

      patch "/api/v1/whatsapp_conversations/#{waiting.id}/automation", params: { paused: false }.to_json,
                                                                        headers: auth_headers(consultant)
      expect(waiting.reload.whatsapp_automation_paused?).to be(false)
    end
  end
end
