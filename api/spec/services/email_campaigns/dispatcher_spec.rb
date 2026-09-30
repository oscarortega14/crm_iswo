# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailCampaigns::Dispatcher do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:campaign) { create(:email_campaign, tenant: tenant, status: "running", batch_size: 2) }

  before do
    verify_email_sender!(tenant, "reply_to" => "ventas@iswo.com.co")
    ses_client.stub_responses(:send_email, { message_id: "ses-msg-1" })
  end

  def recipient(**attrs)
    contact = create(:contact, tenant: tenant, email: "c#{SecureRandom.hex(3)}@example.com", **attrs)
    create(:email_campaign_recipient, tenant: tenant, email_campaign: campaign, contact: contact, email: contact.email)
  end

  it "envía por SES desde el dominio del tenant con baja en un clic y etiquetas" do
    r = recipient(first_name: "Ana")
    described_class.call(campaign: campaign)

    params = ses_requests(:send_email).first[:params]
    expect(params[:from_email_address]).to eq('"ISWO" <info@iswo.com.co>')
    expect(params[:destination]).to eq(to_addresses: [ r.email ])
    expect(params[:reply_to_addresses]).to eq([ "ventas@iswo.com.co" ])
    expect(params.dig(:content, :simple, :subject, :data)).to eq("Hola Ana")
    headers = params.dig(:content, :simple, :headers).to_h { |h| [ h[:name], h[:value] ] }
    expect(headers["List-Unsubscribe"]).to match(%r{\A<http.+/api/v1/public/email/unsubscribe\?t=.+>\z})
    expect(headers["List-Unsubscribe-Post"]).to eq("List-Unsubscribe=One-Click")
    expect(params[:email_tags]).to include({ name: "recipient_id", value: r.id.to_s })

    expect(r.reload).to have_attributes(status: "sent", ses_message_id: "ses-msg-1")
    expect(campaign.reload).to have_attributes(sent_count: 1, status: "completed")
  end

  it "respeta el tamaño del lote y omite a quien se dio de baja" do
    opted_out = recipient(email_opt_out_at: Time.current, email_opt_out_source: "unsubscribe")
    3.times { recipient }
    described_class.call(campaign: campaign)

    expect(opted_out.reload).to have_attributes(status: "skipped", skip_reason: /baja/)
    expect(campaign.reload.email_campaign_recipients.status_pending.count).to eq(2)
    expect(campaign).to be_status_running
  end

  it "registra el fallo de SES sin detener el lote" do
    ses_client.stub_responses(:send_email, "MessageRejected")
    r = recipient
    described_class.call(campaign: campaign)
    expect(r.reload.status).to eq("failed")
    expect(campaign.reload.failed_count).to eq(1)
  end

  it "pausa la campaña si el dominio dejó de estar verificado" do
    verify_email_sender!(tenant, "status" => "failed")
    recipient
    expect(described_class.call(campaign: campaign)).to be(false)
    expect(campaign.reload).to be_status_paused
    expect(ses_requests(:send_email)).to be_empty
  end
end
