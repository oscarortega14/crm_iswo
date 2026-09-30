# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsApp::ConfirmationFollowup do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:owner)    { create(:user, :consultant, tenant: tenant, name: "Paula Ríos") }
  let(:contact)  { create(:contact, tenant: tenant, first_name: "María", phone_e164: "+593991112233", owner_user: owner) }
  let(:template) { create(:whatsapp_template, :opt_in_request, tenant: tenant) }
  let(:campaign) do
    create(:whatsapp_campaign, tenant: tenant, whatsapp_template: template,
                               confirm_reply_body: "¡Gracias {{nombre}}! Soy {{asesor|el equipo}}, te comparto la info.")
  end
  let!(:cloud_integration) do
    create(:ad_integration, :cloud, tenant: tenant, account_identifier: "+5731999999999",
                                    credentials: { "access_token" => "fake-access-token" })
  end

  around do |example|
    old_provider = ENV.delete("WHATSAPP_PROVIDER")
    example.run
  ensure
    ENV["WHATSAPP_PROVIDER"] = old_provider if old_provider
  end

  before { allow(WhatsappDeliveryJob).to receive(:perform_later) }

  def sent_campaign_to(contact, at: 2.days.ago, campaign: self.campaign)
    msg = create(:whatsapp_message, :sent, tenant: tenant, contact: contact, message_type: "template", automated: true,
                                           template_name: "optin", template_language: "es", created_at: at)
    create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                                         status: "sent", whatsapp_message: msg)
  end

  def reply(text, at: Time.current)
    create(:whatsapp_message, :inbound, tenant: tenant, contact: contact, body: text,
                                        from_number: "+593991112233", to_number: "+5731999999999", created_at: at)
  end

  it "al «Sí» (aunque sea días después) envía el mensaje automático, personalizado y una sola vez" do
    recipient = sent_campaign_to(contact, at: 3.days.ago)

    expect(described_class.call(message: reply("Sí"))).to eq(:sent)
    expect(described_class.call(message: reply("si"))).to eq(:already_confirmed)

    recipient.reload
    auto = recipient.confirm_reply_message
    expect(recipient.confirmed_at).to be_present
    expect(auto).to have_attributes(direction: "out", automated: true, provider: "whatsapp_cloud",
                                    to_number: "+593991112233",
                                    body: "¡Gracias María! Soy Paula Ríos, te comparto la info.")
    expect(WhatsappDeliveryJob).to have_received(:perform_later).with(auto.id).once
  end

  it "registra el «Sí» pero no envía si un asesor pausó el automático" do
    recipient = sent_campaign_to(contact)
    contact.update_columns(whatsapp_automation_paused_at: Time.current)

    expect(described_class.call(message: reply("Sí"))).to eq(:paused)
    expect(recipient.reload).to have_attributes(confirm_reply_message_id: nil)
    expect(recipient.confirmed_at).to be_present
  end

  it "no hace nada sin campaña reciente o si la campaña no tiene mensaje al autorizar" do
    expect(described_class.call(message: reply("Sí"))).to eq(:no_campaign)

    sent_campaign_to(contact, at: 40.days.ago)
    expect(described_class.call(message: reply("Sí"))).to eq(:no_campaign)

    without_reply = create(:whatsapp_campaign, tenant: tenant, whatsapp_template: template, confirm_reply_body: nil)
    sent_campaign_to(contact, at: 1.day.ago, campaign: without_reply)
    expect(described_class.call(message: reply("Sí"))).to eq(:no_campaign)
    expect(WhatsappDeliveryJob).not_to have_received(:perform_later)
  end

  it "el mensaje entrante «Sí» dispara el job; otras respuestas no" do
    ActiveJob::Base.queue_adapter = :test
    expect { reply("Sí, autorizo") }.to have_enqueued_job(WhatsappInboundAutomationJob)
    expect { reply("¿cuánto cuesta?") }.not_to have_enqueued_job(WhatsappInboundAutomationJob)
  end
end
