# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappCampaigns::Dispatcher do
  let(:tenant) { ActsAsTenant.current_tenant }
  let!(:integration) { create(:ad_integration, :cloud, tenant: tenant, account_identifier: "123456") }
  let(:template) do
    create(:whatsapp_template, tenant: tenant, meta_template_name: "congresosst", language: "es_CO",
           variable_labels: ["Nombre"], variable_names: ["primer_nombre"])
  end
  let(:campaign) do
    create(:whatsapp_campaign, tenant: tenant, whatsapp_template: template, variable_field_map: ["contact.first_name"],
           status: "running", batch_size: 10)
  end
  let(:contact) { create(:contact, tenant: tenant, first_name: "Victoria", phone_e164: "+573001112233",
                          whatsapp_opt_in_at: Time.current) }

  before { allow(WhatsappDeliveryJob).to receive(:perform_later) }

  it "no hace nada si la campaña no está running" do
    campaign.update!(status: "paused")
    expect(described_class.call(campaign: campaign)).to be(false)
  end

  it "respeta batch_interval_minutes (no despacha si el último lote fue muy reciente)" do
    campaign.update!(last_batch_at: 1.minute.ago, batch_interval_minutes: 15)
    expect(described_class.call(campaign: campaign)).to be(false)
  end

  it "envía un mensaje de plantilla con message_type y variable_names correctos, tomando el valor del contacto" do
    recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                        status: "pending")

    described_class.call(campaign: campaign)

    msg = recipient.reload.whatsapp_message
    expect(msg).to be_present
    expect(msg.message_type).to eq("template")
    expect(msg.template_name).to eq("congresosst")
    expect(msg.template_language).to eq("es_CO")
    expect(msg.template_params).to eq(["Victoria"])
    expect(msg.template_variable_names).to eq(["primer_nombre"])
    expect(recipient.status).to eq("sent")
    expect(WhatsappDeliveryJob).to have_received(:perform_later).with(msg.id)
    expect(campaign.reload.sent_count).to eq(1)
  end

  it "salta contactos sin opt-in aunque el recipient exista como pending" do
    contact.update!(whatsapp_opt_in_at: nil)
    recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                        status: "pending")

    described_class.call(campaign: campaign)

    expect(recipient.reload.status).to eq("skipped_no_opt_in")
    expect(recipient.whatsapp_message).to be_nil
  end

  it "salta contactos sin teléfono" do
    no_phone_contact = create(:contact, :without_phone, tenant: tenant, whatsapp_opt_in_at: Time.current)
    recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign,
                        contact: no_phone_contact, status: "pending")

    described_class.call(campaign: campaign)

    expect(recipient.reload.status).to eq("skipped_no_phone")
  end

  it "marca la campaña completed cuando ya no quedan recipients pending" do
    create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
           status: "pending")

    described_class.call(campaign: campaign)

    expect(campaign.reload.status).to eq("completed")
    expect(campaign.completed_at).to be_present
  end

  it "marca failed y no interrumpe el resto del lote si un envío individual explota" do
    bad_recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign,
                            contact: contact, status: "pending")
    allow_any_instance_of(described_class).to receive(:resolve_params).and_raise(StandardError, "boom")

    described_class.call(campaign: campaign)

    expect(bad_recipient.reload.status).to eq("failed")
    expect(campaign.reload.failed_count).to eq(1)
  end
end
