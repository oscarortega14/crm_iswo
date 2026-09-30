# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Public::EmailUnsubscribes", type: :request do
  let(:tenant)    { ActsAsTenant.current_tenant }
  let(:contact)   { create(:contact, tenant: tenant, email: "ana@example.com") }
  let(:recipient) { create(:email_campaign_recipient, tenant: tenant, contact: contact, status: "delivered") }
  let(:token)     { EmailMarketing::UnsubscribeToken.generate(recipient) }

  it "GET muestra la confirmación sin dar de baja (los antispam abren enlaces)" do
    get "/api/v1/public/email/unsubscribe", params: { t: token }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("Confirmar baja", "ana@example.com")
    expect(contact.reload.email_opted_out?).to be(false)
  end

  it "POST (botón o baja en un clic de Gmail) da de baja y audita una sola vez" do
    expect {
      2.times { post "/api/v1/public/email/unsubscribe?t=#{token}", params: "List-Unsubscribe=One-Click" }
    }.to change(AuditEvent.where(action: "contact.email_unsubscribe"), :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(contact.reload).to have_attributes(email_opt_out_source: "unsubscribe")
    expect(recipient.reload.unsubscribed_at).to be_present
  end

  it "token alterado → 404" do
    post "/api/v1/public/email/unsubscribe?t=#{token}x"
    expect(response).to have_http_status(:not_found)
  end
end
