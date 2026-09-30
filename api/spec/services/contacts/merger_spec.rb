# frozen_string_literal: true

require "rails_helper"

RSpec.describe Contacts::Merger do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:admin)    { create(:user, :admin, tenant: tenant) }
  let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }

  def opp_for(contact)
    create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: contact, pipeline: pipeline,
                                            pipeline_stage: pipeline.pipeline_stages.first)
  end

  let(:survivor) do
    create(:contact, tenant: tenant, first_name: "Laura", last_name: "Gómez", phone_e164: "+573001112233",
                     email: nil, city: nil, notes: "Cliente del congreso", source_kind: "import", source_label: "Excel: base.xlsx")
  end
  let(:absorbed) do
    create(:contact, tenant: tenant, first_name: "Laura G", last_name: nil, phone_e164: "+573001112233",
                     email: "laura@correo.co", city: "Bogotá", notes: "Pidió cotización", source_kind: "web",
                     source_label: "Landing ISO 9001")
  end

  it "deja un solo contacto: completa datos vacíos, suma notas y une los orígenes" do
    described_class.call(survivor: survivor, absorbed: absorbed, performed_by: admin)
    survivor.reload

    expect(survivor).to have_attributes(first_name: "Laura", email: "laura@correo.co", city: "Bogotá")
    expect(survivor.notes).to eq("Cliente del congreso\n\nPidió cotización")
    expect(survivor.origins.map { |o| [ o["kind"], o["label"] ] })
      .to contain_exactly([ "import", "Excel: base.xlsx" ], [ "web", "Landing ISO 9001" ])
    expect(absorbed.reload).to be_discarded
  end

  it "mueve oportunidades, mensajes, formularios, campañas y notificaciones al sobreviviente" do
    opp = opp_for(absorbed)
    msg = create(:whatsapp_message, :inbound, tenant: tenant, contact: absorbed)
    notif = Notification.create!(tenant: tenant, user: admin, kind: "whatsapp_message_received", title: "x", resource: absorbed)
    shared = create(:whatsapp_campaign, tenant: tenant)
    create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: shared, contact: survivor)
    create(:whatsapp_campaign_recipient, tenant: tenant, whatsapp_campaign: shared, contact: absorbed)
    only_absorbed = create(:whatsapp_campaign_recipient, tenant: tenant, contact: absorbed)

    described_class.call(survivor: survivor, absorbed: absorbed, performed_by: admin)

    expect(opp.reload.contact_id).to eq(survivor.id)
    expect(msg.reload.contact_id).to eq(survivor.id)
    expect(notif.reload.resource_id).to eq(survivor.id)
    expect(WhatsappCampaignRecipient.where(whatsapp_campaign: shared).pluck(:contact_id)).to eq([ survivor.id ])
    expect(only_absorbed.reload.contact_id).to eq(survivor.id)
    expect(opp.reload).to be_kept
  end

  it "reemplaza el nombre provisional de WhatsApp por el real y respeta el opt-out" do
    wa = create(:contact, tenant: tenant, first_name: "Contacto", last_name: "2233", phone_e164: "+573001112233",
                          source_kind: "whatsapp", source_label: "inbound")
    real = create(:contact, tenant: tenant, first_name: "Pedro", last_name: "Ruiz", phone_e164: "+573001112233",
                            whatsapp_opt_out_at: 1.day.ago)

    described_class.call(survivor: wa, absorbed: real)

    expect(wa.reload).to have_attributes(first_name: "Pedro", last_name: "Ruiz")
    expect(wa.whatsapp_opt_out_at).to be_present
  end

  it "no fusiona un contacto consigo mismo" do
    expect { described_class.call(survivor: survivor, absorbed: survivor) }.to raise_error(ArgumentError)
  end

  it "respeta la baja de correos del absorbido y mueve sus envíos de correo" do
    absorbed.update_columns(email_opt_out_at: Time.current, email_opt_out_source: "unsubscribe")
    shared = create(:email_campaign, tenant: tenant)
    only_absorbed = create(:email_campaign, tenant: tenant)
    create(:email_campaign_recipient, tenant: tenant, email_campaign: shared, contact: survivor, email: "x@example.com")
    create(:email_campaign_recipient, tenant: tenant, email_campaign: shared, contact: absorbed)
    moved = create(:email_campaign_recipient, tenant: tenant, email_campaign: only_absorbed, contact: absorbed)

    described_class.call(survivor: survivor, absorbed: absorbed, performed_by: admin)

    expect(survivor.reload).to have_attributes(email: "laura@correo.co", email_opt_out_source: "unsubscribe")
    expect(moved.reload.contact_id).to eq(survivor.id)
    expect(EmailCampaignRecipient.where(email_campaign: shared).pluck(:contact_id)).to eq([ survivor.id ])
  end
end
