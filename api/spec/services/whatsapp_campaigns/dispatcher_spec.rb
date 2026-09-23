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

  it "omite al contacto (sin encolar envío) si una variable queda vacía — evita el 131008 de Meta" do
    contact.update!(first_name: "")
    recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                        status: "pending")

    described_class.call(campaign: campaign)

    expect(recipient.reload.status).to eq("skipped_missing_variable")
    expect(recipient.skip_reason).to eq("variable {{1}} vacía para este contacto")
    expect(recipient.whatsapp_message).to be_nil
    expect(WhatsappDeliveryJob).not_to have_received(:perform_later)
    expect(campaign.reload.sent_count).to eq(0)
  end

  it "sigue enviando al resto del lote cuando un contacto tiene una variable vacía" do
    empty_contact = create(:contact, tenant: tenant, first_name: " ", phone_e164: "+573004445566",
                                     whatsapp_opt_in_at: Time.current)
    skipped = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign,
                                                   contact: empty_contact, status: "pending")
    sent = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                                                status: "pending")

    described_class.call(campaign: campaign)

    expect(skipped.reload.status).to eq("skipped_missing_variable")
    expect(sent.reload.status).to eq("sent")
    expect(campaign.reload.status).to eq("completed")
  end

  it "envía texto fijo del variable_field_map tal cual (p. ej. el nombre de la empresa que escribe)" do
    positional = create(:whatsapp_template, tenant: tenant, meta_template_name: "confirmacion_contacto_whatsapp",
                                           language: "es_CO", variable_labels: %w[Nombre Empresa], variable_names: [])
    fixed_text = create(:whatsapp_campaign, tenant: tenant, whatsapp_template: positional, status: "running",
                                            variable_field_map: ["contact.first_name", "SIG ISWO Software + IA"])
    recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: fixed_text,
                                                     contact: contact, status: "pending")

    described_class.call(campaign: fixed_text)

    expect(recipient.reload.whatsapp_message.template_params).to eq(["Victoria", "SIG ISWO Software + IA"])
  end

  it "omite al contacto si el texto fijo del variable_field_map quedó vacío" do
    recipient = create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: campaign, contact: contact,
                        status: "pending")
    campaign.update!(variable_field_map: [""])

    described_class.call(campaign: campaign)

    expect(recipient.reload.status).to eq("skipped_missing_variable")
    expect(recipient.whatsapp_message).to be_nil
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
