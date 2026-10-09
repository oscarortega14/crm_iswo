# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappReadReceiptJob, type: :job do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:contact) { create(:contact, tenant: tenant) }

  it "usa la cola :integrations (igual que el envío)" do
    expect(described_class.new.queue_name).to eq("integrations")
  end

  it "envía el visto por el adaptador del proveedor del mensaje, dentro de su tenant" do
    msg = create(:whatsapp_message, :inbound, :cloud, tenant: tenant, contact: contact,
                                                      provider_message_id: "wamid.XYZ")
    msg_id = msg.id
    ActsAsTenant.current_tenant = nil

    expect_any_instance_of(WhatsApp::Adapters::Cloud).to receive(:mark_read).with("wamid.XYZ") do
      expect(ActsAsTenant.current_tenant).to eq(tenant)
      true
    end

    described_class.new.perform(msg_id)
  end

  it "ignora mensajes salientes o sin id de Meta" do
    outbound = create(:whatsapp_message, :outbound, :cloud, tenant: tenant, contact: contact,
                                                            provider_message_id: "wamid.OUT")
    no_id = create(:whatsapp_message, :inbound, :cloud, tenant: tenant, contact: contact, provider_message_id: nil)

    expect_any_instance_of(WhatsApp::Adapters::Cloud).not_to receive(:mark_read)
    described_class.new.perform(outbound.id)
    described_class.new.perform(no_id.id)
    described_class.new.perform(0)
  end
end
