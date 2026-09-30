# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::EmailSenders", type: :request do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:admin)      { create(:user, :admin, tenant: tenant) }
  let(:manager)    { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }

  it "admin configura el dominio y lo verifica en SES" do
    patch "/api/v1/email_sender", headers: auth_headers(admin),
                                  params: { email_sender: { domain: "iswo.com.co", from_name: "ISWO" } }.to_json
    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "from_email")).to eq("info@iswo.com.co")

    ses_client.stub_responses(:create_email_identity, {
      identity_type: "DOMAIN", verified_for_sending_status: false, dkim_attributes: { status: "PENDING", tokens: %w[t1] }
    })
    post "/api/v1/email_sender/verify", headers: auth_headers(admin)
    expect(json.dig("data", "status")).to eq("pending")
    expect(json.dig("data", "dns_records").map { |r| r["name"] }).to include("t1._domainkey.iswo.com.co")
  end

  it "422 con mensaje si el dominio no es válido" do
    patch "/api/v1/email_sender", headers: auth_headers(admin), params: { email_sender: { domain: "x" } }.to_json
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["message"]).to match(/dominio/)
  end

  it "manager consulta pero no cambia; consultor no accede" do
    get "/api/v1/email_sender", headers: auth_headers(manager)
    expect(response).to have_http_status(:ok)
    patch "/api/v1/email_sender", headers: auth_headers(manager), params: { email_sender: { domain: "a.com" } }.to_json
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/email_sender", headers: auth_headers(consultant)
    expect(response).to have_http_status(:forbidden)
  end

  it "PATCH /tenant no puede pisar el estado de verificación" do
    verify_email_sender!(tenant)
    patch "/api/v1/tenant", headers: auth_headers(admin),
                            params: { tenant: { settings: { stale_days: 9, email_marketing: { status: "hacked" } } } }.to_json
    expect(response).to have_http_status(:ok)
    expect(tenant.reload.settings.dig("email_marketing", "status")).to eq("verified")
  end
end
