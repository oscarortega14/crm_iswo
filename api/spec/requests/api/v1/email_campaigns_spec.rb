# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::EmailCampaigns", type: :request do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:admin)      { create(:user, :admin, tenant: tenant) }
  let(:manager)    { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
  let(:viewer)     { create(:user, :viewer, tenant: tenant) }
  let!(:campaign)  { create(:email_campaign, tenant: tenant) }

  describe "permisos" do
    it "admin y manager listan; consultor y visor no" do
      [ admin, manager ].each do |user|
        get "/api/v1/email_campaigns", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
        expect(json["data"].map { |d| d["id"].to_i }).to include(campaign.id)
      end
      [ consultant, viewer ].each do |user|
        get "/api/v1/email_campaigns", headers: auth_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "no ve campañas de otro tenant" do
      other = create(:tenant)
      foreign = ActsAsTenant.with_tenant(other) { create(:email_campaign, tenant: other) }
      get "/api/v1/email_campaigns/#{foreign.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "crea, edita el borrador (con diseño del editor) y lo elimina" do
    post "/api/v1/email_campaigns", headers: auth_headers(manager), params: {
      email_campaign: { name: "Boletín ISO", subject: "Novedades", body_html: "<p>Hola</p>",
                        audience_filters: { temperature: "hot" }, body_design: { pages: [ { id: "p1" } ] } }
    }.to_json
    expect(response).to have_http_status(:created)
    id = json.dig("data", "id")
    expect(json.dig("data", "attributes", "body_design")).to eq("pages" => [ { "id" => "p1" } ])
    expect(json.dig("data", "attributes", "audience_filters")).to eq("temperature" => "hot")

    patch "/api/v1/email_campaigns/#{id}", headers: auth_headers(manager),
                                           params: { email_campaign: { subject: "Nuevo asunto" } }.to_json
    expect(json.dig("data", "attributes", "subject")).to eq("Nuevo asunto")

    delete "/api/v1/email_campaigns/#{id}", headers: auth_headers(manager)
    expect(response).to have_http_status(:no_content)
  end

  it "audience_preview cuenta correos únicos y dados de baja" do
    create(:contact, tenant: tenant, email: "a@example.com")
    create(:contact, tenant: tenant, email: "A@example.com")
    create(:contact, tenant: tenant, email: "b@example.com", email_opt_out_at: Time.current)
    get "/api/v1/email_campaigns/audience_preview", headers: auth_headers(admin)
    expect(json).to eq("total" => 1, "opted_out" => 1)
  end

  describe "lanzar" do
    it "409 con mensaje claro si el dominio no está verificado" do
      post "/api/v1/email_campaigns/#{campaign.id}/launch", headers: auth_headers(admin)
      expect(response).to have_http_status(:conflict)
      expect(json["message"]).to match(/verificar el dominio/)
    end

    it "lanza y luego no permite editar" do
      verify_email_sender!(tenant)
      create(:contact, tenant: tenant, email: "a@example.com")
      post "/api/v1/email_campaigns/#{campaign.id}/launch", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "attributes", "status")).to eq("running")

      patch "/api/v1/email_campaigns/#{campaign.id}", headers: auth_headers(admin),
                                                       params: { email_campaign: { subject: "x" } }.to_json
      expect(response).to have_http_status(:conflict)
    end
  end

  it "envío de prueba al correo indicado con prefijo [Prueba]" do
    verify_email_sender!(tenant)
    ses_client.stub_responses(:send_email, { message_id: "t-1" })
    post "/api/v1/email_campaigns/#{campaign.id}/send_test", headers: auth_headers(manager),
                                                             params: { email: "yo@iswo.com.co" }.to_json
    expect(response).to have_http_status(:ok)
    params = ses_requests(:send_email).first[:params]
    expect(params[:destination][:to_addresses]).to eq([ "yo@iswo.com.co" ])
    expect(params.dig(:content, :simple, :subject, :data)).to start_with("[Prueba] ")
  end

  it "recipients filtra por problemas" do
    campaign.update!(status: "completed")
    ok  = create(:email_campaign_recipient, email_campaign: campaign, status: "delivered")
    bad = create(:email_campaign_recipient, email_campaign: campaign, status: "bounced", skip_reason: "550")
    get "/api/v1/email_campaigns/#{campaign.id}/recipients?result=problems", headers: auth_headers(admin)
    ids = json["data"].map { |d| d["id"].to_i }
    expect(ids).to eq([ bad.id ])
    expect(ids).not_to include(ok.id)
    expect(json["data"].first.dig("attributes", "reason")).to eq("550")
  end
end
