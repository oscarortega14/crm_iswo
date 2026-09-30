# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::WhatsappCampaigns", type: :request do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:admin)      { create(:user, :admin,      tenant: tenant) }
  let(:manager)    { create(:user, :manager,    tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
  let(:template) do
    create(:whatsapp_template, tenant: tenant, meta_template_name: "congresosst", language: "es_CO",
           variable_labels: ["Nombre"], variable_names: ["primer_nombre"])
  end
  let!(:campaign) do
    create(:whatsapp_campaign, tenant: tenant, whatsapp_template: template, variable_field_map: ["contact.first_name"])
  end

  describe "GET /api/v1/whatsapp_campaigns" do
    it "200 con lista para manager" do
      get "/api/v1/whatsapp_campaigns", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(campaign.id)
    end

    it "403 para consultant" do
      get "/api/v1/whatsapp_campaigns", headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/whatsapp_campaigns/audience_preview" do
    it "devuelve total y opted_in" do
      pipeline = create(:pipeline_with_stages, tenant: tenant)
      opted_in = create(:contact, tenant: tenant, phone_e164: "+573001112233", whatsapp_opt_in_at: Time.current)
      create(:opportunity, tenant: tenant, contact: opted_in, pipeline: pipeline,
             pipeline_stage: pipeline.pipeline_stages.first)

      get "/api/v1/whatsapp_campaigns/audience_preview", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json["total"]).to eq(1)
      expect(json["opted_in"]).to eq(1)
      expect(json["skipped_no_opt_in"]).to eq(0)
    end
  end

  describe "POST /api/v1/whatsapp_campaigns" do
    it "admin crea campaña referenciando una plantilla del catálogo" do
      post "/api/v1/whatsapp_campaigns",
           headers: auth_headers(admin),
           params: { whatsapp_campaign: {
             name: "Congreso SST", whatsapp_template_id: template.id, variable_field_map: ["contact.first_name"]
           } }.to_json
      expect(response).to have_http_status(:created)
      expect(json.dig("data", "attributes", "whatsapp_template_name")).to eq(template.name)
    end

    it "422 si variable_field_map no coincide con las variables de la plantilla" do
      post "/api/v1/whatsapp_campaigns",
           headers: auth_headers(admin),
           params: { whatsapp_campaign: {
             name: "Congreso SST", whatsapp_template_id: template.id, variable_field_map: []
           } }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "consultant no puede crear" do
      post "/api/v1/whatsapp_campaigns",
           headers: auth_headers(consultant),
           params: { whatsapp_campaign: { name: "X", whatsapp_template_id: template.id } }.to_json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/whatsapp_campaigns/:id" do
    it "manager edita un borrador y guarda texto fijo en variable_field_map" do
      patch "/api/v1/whatsapp_campaigns/#{campaign.id}",
            headers: auth_headers(manager),
            params: { whatsapp_campaign: { variable_field_map: ["SIG ISWO Software + IA"] } }.to_json
      expect(response).to have_http_status(:ok)
      expect(campaign.reload.variable_field_map).to eq(["SIG ISWO Software + IA"])
    end

    it "409 si la campaña ya no está en borrador" do
      campaign.update!(status: "running")
      patch "/api/v1/whatsapp_campaigns/#{campaign.id}",
            headers: auth_headers(admin),
            params: { whatsapp_campaign: { name: "Nuevo nombre" } }.to_json
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "POST /api/v1/whatsapp_campaigns/:id/launch" do
    it "lanza la campaña cuando hay WhatsApp Cloud configurado" do
      create(:ad_integration, :cloud, tenant: tenant, account_identifier: "123456")

      post "/api/v1/whatsapp_campaigns/#{campaign.id}/launch", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "attributes", "status")).to eq("running")
    end

    it "409 si falta configurar WhatsApp Cloud" do
      post "/api/v1/whatsapp_campaigns/#{campaign.id}/launch", headers: auth_headers(admin)

      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("invalid_state")
    end
  end

  describe "POST /api/v1/whatsapp_campaigns/:id/pause y /resume" do
    it "pausa y reanuda" do
      create(:ad_integration, :cloud, tenant: tenant, account_identifier: "123456")
      campaign.update!(status: "running")

      post "/api/v1/whatsapp_campaigns/#{campaign.id}/pause", headers: auth_headers(manager)
      expect(json.dig("data", "attributes", "status")).to eq("paused")

      post "/api/v1/whatsapp_campaigns/#{campaign.id}/resume", headers: auth_headers(manager)
      expect(json.dig("data", "attributes", "status")).to eq("running")
    end
  end

  describe "POST /api/v1/whatsapp_campaigns/:id/cancel" do
    it "cancela la campaña" do
      campaign.update!(status: "running")
      post "/api/v1/whatsapp_campaigns/#{campaign.id}/cancel", headers: auth_headers(admin)
      expect(json.dig("data", "attributes", "status")).to eq("canceled")
    end
  end

  describe "POST /api/v1/whatsapp_campaigns/:id/launch con plantilla no aprobada" do
    it "409 con el motivo y la campaña sigue en borrador" do
      create(:ad_integration, :cloud, tenant: tenant, account_identifier: "123456")
      template.update!(meta_status: "PENDING")

      post "/api/v1/whatsapp_campaigns/#{campaign.id}/launch", headers: auth_headers(admin)

      expect(response).to have_http_status(:conflict)
      expect(json["message"]).to match(/PENDING en Meta/)
      expect(campaign.reload).to be_status_draft
    end
  end

  describe "POST /api/v1/whatsapp_campaigns/:id/duplicate" do
    it "crea un borrador editable (manager)" do
      campaign.update!(status: "completed")

      expect do
        post "/api/v1/whatsapp_campaigns/#{campaign.id}/duplicate", headers: auth_headers(manager)
      end.to change(WhatsappCampaign, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(json.dig("data", "attributes", "status")).to eq("draft")
      expect(json.dig("data", "attributes", "name")).to eq("#{campaign.name} (copia)")
    end

    it "consultant no puede: las campañas no son visibles para su rol (404) y no se crea nada" do
      expect do
        post "/api/v1/whatsapp_campaigns/#{campaign.id}/duplicate", headers: auth_headers(consultant)
      end.not_to change(WhatsappCampaign, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/whatsapp_campaigns/:id/recipients" do
    it "lista cada destinatario con su resultado real y el motivo del fallo" do
      contact = create(:contact, tenant: tenant, first_name: "Ana", last_name: "Ruiz")
      msg = create(:whatsapp_message, :outbound, :cloud, tenant: tenant, contact: contact, status: "failed",
                                                         to_number: "+573001112233",
                                                         error_message: "Cloud API: (#132001) Template name does not exist")
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                                           status: "sent", whatsapp_message: msg)

      get "/api/v1/whatsapp_campaigns/#{campaign.id}/recipients", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      row = json["data"].first["attributes"]
      expect(row).to include("result" => "failed", "contact_name" => "Ana Ruiz", "to_number" => "+573001112233")
      expect(row["reason"]).to match(/132001/)
    end

    it "incluye delivery_stats en la campaña lanzada" do
      campaign.update!(status: "completed")
      get "/api/v1/whatsapp_campaigns/#{campaign.id}", headers: auth_headers(admin)
      expect(json.dig("data", "attributes", "delivery_stats")).to include("total" => 0, "failed" => 0)
    end
  end

  describe "filtro por origen del contacto (archivo importado)" do
    let(:file) { "Excel: 2026-07-08 Expo Calidad Ecuador.xlsx" }

    before do
      pipeline = create(:pipeline_with_stages, tenant: tenant)
      stage = pipeline.pipeline_stages.first
      [
        [ "+593991234567", file ], [ "+573001112233", file ], [ "+573004445566", "Landing ISO 9001" ]
      ].each do |phone, origin|
        c = create(:contact, tenant: tenant, phone_e164: phone, source_kind: "import", source_label: origin)
        create(:opportunity, tenant: tenant, contact: c, pipeline: pipeline, pipeline_stage: stage)
      end
    end

    it "audience_preview cuenta solo los de ese archivo y muestra el país de los celulares" do
      get "/api/v1/whatsapp_campaigns/audience_preview", params: { contact_origin: file }, headers: auth_headers(admin)
      expect(json["total"]).to eq(2)
      expect(json["countries"]).to eq("EC" => 1, "CO" => 1)
    end

    it "la campaña lanzada solo incluye a los contactos de ese origen" do
      template.update!(opt_in_request: true, meta_status: "APPROVED")
      campaign.update!(audience_filters: { "contact_origin" => file })
      create(:ad_integration, :cloud, tenant: tenant, account_identifier: "123456")

      campaign.launch!
      expect(campaign.whatsapp_campaign_recipients.map { |r| r.contact.source_label }.uniq).to eq([ file ])
      expect(campaign.total_recipients).to eq(2)
    end
  end

  describe "mensaje al autorizar" do
    it "se guarda en la campaña, se copia al duplicar y muestra cuántos autorizaron" do
      patch "/api/v1/whatsapp_campaigns/#{campaign.id}", headers: auth_headers(admin),
            params: { whatsapp_campaign: { confirm_reply_body: "¡Gracias {{nombre}}!" } }.to_json
      expect(json.dig("data", "attributes", "confirm_reply_body")).to eq("¡Gracias {{nombre}}!")

      post "/api/v1/whatsapp_campaigns/#{campaign.id}/duplicate", headers: auth_headers(admin)
      expect(json.dig("data", "attributes", "confirm_reply_body")).to eq("¡Gracias {{nombre}}!")

      campaign.update_columns(status: "completed")
      create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, status: "sent",
                                           confirmed_at: Time.current)
      get "/api/v1/whatsapp_campaigns/#{campaign.id}", headers: auth_headers(admin)
      expect(json.dig("data", "attributes", "confirmation_stats")).to eq("confirmed" => 1, "replied" => 0)
    end
  end
end
