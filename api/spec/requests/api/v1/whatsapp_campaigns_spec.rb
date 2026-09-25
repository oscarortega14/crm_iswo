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
end
