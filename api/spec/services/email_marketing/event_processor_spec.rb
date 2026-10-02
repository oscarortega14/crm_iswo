# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailMarketing::EventProcessor do
  let(:tenant)    { ActsAsTenant.current_tenant }
  let(:contact)   { create(:contact, tenant: tenant, email: "ana@example.com") }
  let!(:recipient) do
    create(:email_campaign_recipient, tenant: tenant, contact: contact, status: "sent", ses_message_id: "m-1")
  end

  def event(type, extra = {})
    { "eventType" => type, "mail" => { "messageId" => "m-1", "tags" => { "recipient_id" => [ recipient.id.to_s ] } } }
      .merge(extra)
  end

  it "Delivery marca entregado" do
    described_class.call(event("Delivery", "delivery" => { "timestamp" => "2026-09-28T10:00:00Z" }).to_json)
    expect(recipient.reload).to have_attributes(status: "delivered", delivered_at: Time.zone.parse("2026-09-28T10:00:00Z"))
  end

  it "rebote permanente da de baja al contacto; temporal no" do
    described_class.call(event("Bounce", "bounce" => { "bounceType" => "Transient" }))
    expect(contact.reload.email_opted_out?).to be(false)

    described_class.call(event("Bounce", "bounce" => { "bounceType" => "Permanent",
                                                       "bouncedRecipients" => [ { "diagnosticCode" => "550 no existe" } ] }))
    expect(recipient.reload).to have_attributes(status: "bounced", skip_reason: /550 no existe/)
    expect(contact.reload).to have_attributes(email_opt_out_source: "bounce")
  end

  it "queja (spam) da de baja al contacto" do
    described_class.call(event("Complaint"))
    expect(recipient.reload.status).to eq("complained")
    expect(contact.reload.email_opt_out_source).to eq("complaint")
  end

  it "clic registra apertura y clic solo la primera vez; ubica por MessageId sin etiquetas" do
    evt = { "eventType" => "Click", "mail" => { "messageId" => "m-1" }, "click" => { "timestamp" => "2026-09-28T11:00:00Z" } }
    described_class.call(evt)
    described_class.call(evt.merge("click" => { "timestamp" => "2026-09-29T11:00:00Z" }))
    expect(recipient.reload.clicked_at).to eq(Time.zone.parse("2026-09-28T11:00:00Z"))
    expect(recipient.opened_at).to eq(recipient.clicked_at)
  end

  it "ignora eventos de destinatarios desconocidos" do
    expect(described_class.call({ "eventType" => "Delivery", "mail" => { "messageId" => "otro" } })).to eq(:unknown_recipient)
  end
end
