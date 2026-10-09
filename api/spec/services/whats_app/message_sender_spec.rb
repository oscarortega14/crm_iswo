# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsApp::MessageSender do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:contact) { create(:contact, tenant: tenant) }
  let(:message) do
    create(:whatsapp_message, :outbound, :cloud,
           tenant: tenant, contact: contact, status: "queued", to_number: "+573001112233")
  end

  describe "#deliver" do
    let(:adapter) { instance_double("WhatsApp::Adapters::Cloud") }

    before do
      allow(WhatsApp::Adapters::Cloud).to receive(:new).with(tenant: tenant).and_return(adapter)
    end

    context "cuando el adapter responde OK" do
      before do
        allow(adapter).to receive(:deliver)
          .with(message)
          .and_return(provider_message_id: "wamid.abc123", status: "sent")
      end

      it "persiste provider_message_id, status y sent_at" do
        expect(described_class.new(message).deliver).to be(true)
        message.reload
        expect(message.provider_message_id).to eq("wamid.abc123")
        expect(message.status).to eq("sent")
        expect(message.sent_at).to be_present
      end
    end

    context "cuando el adapter eleva DeliveryError" do
      before do
        allow(adapter).to receive(:deliver).and_raise(
          described_class::DeliveryError, "token inválido"
        )
      end

      it "marca el mensaje como failed y guarda el error truncado" do
        expect(described_class.new(message).deliver).to be(false)
        message.reload
        expect(message.status).to eq("failed")
        expect(message.error_message).to include("token inválido")
      end
    end

    context "cuando el adapter eleva Faraday::Error" do
      before do
        allow(adapter).to receive(:deliver).and_raise(Faraday::ConnectionFailed, "ECONNREFUSED")
      end

      it "también marca failed y no propaga la excepción" do
        expect(described_class.new(message).deliver).to be(false)
        expect(message.reload.status).to eq("failed")
      end
    end
  end

  describe "selección de adapter" do
    it "eleva DeliveryError si el provider no está mapeado" do
      # update_column: evita validación del enum para forzar un valor inválido.
      # El sender usa update_columns en el rescue (saltea validaciones también).
      message.update_column(:provider, "unknown")
      expect(described_class.new(message).deliver).to be(false)
      expect(message.reload.error_message).to match(/Provider no soportado/)
    end

    it "acepta 'whatsapp_cloud' y carga el adapter Cloud" do
      message.update_column(:provider, "whatsapp_cloud")
      adapter = instance_double("WhatsApp::Adapters::Cloud")
      allow(WhatsApp::Adapters::Cloud).to receive(:new).and_return(adapter)
      allow(adapter).to receive(:deliver).and_return(provider_message_id: "wamid.X", status: "sent")

      expect(described_class.new(message).deliver).to be(true)
    end
  end
end
