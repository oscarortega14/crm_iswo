# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappDeliveryJob, type: :job do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:contact) { create(:contact, tenant: tenant) }
  let(:message) do
    create(:whatsapp_message, :outbound, tenant: tenant, contact: contact, status: "queued")
  end

  describe "#perform" do
    it "encola en la cola :integrations" do
      expect(described_class.new.queue_name).to eq("integrations")
    end

    it "delega a WhatsApp::MessageSender" do
      sender = instance_double(WhatsApp::MessageSender, deliver: true)
      expect(WhatsApp::MessageSender).to receive(:new).with(message).and_return(sender)

      described_class.new.perform(message.id)
    end

    it "ejecuta dentro del scope del tenant del mensaje" do
      # Forzar la materialización del mensaje ANTES de limpiar el tenant,
      # ya que `let` es lazy y el create necesita el tenant context.
      msg_id = message.id
      ActsAsTenant.current_tenant = nil
      expect(WhatsApp::MessageSender).to receive(:new) do |msg|
        expect(ActsAsTenant.current_tenant).to eq(msg.tenant)
        instance_double(WhatsApp::MessageSender, deliver: true)
      end

      described_class.new.perform(msg_id)
    end

    it "no hace nada si el mensaje no existe" do
      expect(WhatsApp::MessageSender).not_to receive(:new)
      expect { described_class.new.perform(0) }.not_to raise_error
    end

    %w[sent delivered read].each do |terminal_status|
      it "es idempotente cuando el mensaje ya está '#{terminal_status}'" do
        message.update_column(:status, terminal_status)
        expect(WhatsApp::MessageSender).not_to receive(:new)
        described_class.new.perform(message.id)
      end
    end

    it "configura retry_on Faraday::Error hasta 5 intentos" do
      handler = described_class.rescue_handlers.find { |(klass, _)| klass == "Faraday::Error" }
      expect(handler).to be_present
    end

    context "con reminder_id (recordatorio WhatsApp)" do
      let(:reminder) do
        opp = create(:opportunity, tenant: tenant)
        create(:reminder, :whatsapp, tenant: tenant, opportunity: opp)
      end

      # El flujo real (Reminders::DueDispatcher) reclama el reminder antes de
      # encolar el job, dejándolo en "processing". Reproducimos ese estado en
      # vez de "pending" para no enmascarar el bug de re-despacho.
      before { reminder.claim_for_dispatch! }

      it "marca el reminder como sent cuando el mensaje se entrega" do
        sender = instance_double(WhatsApp::MessageSender)
        allow(WhatsApp::MessageSender).to receive(:new).with(message).and_return(sender)
        allow(sender).to receive(:deliver) do
          message.update!(status: "sent", sent_at: Time.current)
          true
        end

        described_class.new.perform(message.id, reminder.id)
        expect(reminder.reload.status).to eq("sent")
      end

      it "marca el reminder como failed cuando el mensaje falla" do
        sender = instance_double(WhatsApp::MessageSender)
        allow(WhatsApp::MessageSender).to receive(:new).with(message).and_return(sender)
        allow(sender).to receive(:deliver) do
          message.update_columns(status: "failed", error_message: "provider down")
          false
        end

        described_class.new.perform(message.id, reminder.id)
        expect(reminder.reload.status).to eq("failed")
        expect(reminder.last_error).to include("provider down")
      end

      it "también finaliza un reminder aún en 'pending' (invocación sin claim previo)" do
        pending_reminder = create(:reminder, :whatsapp, tenant: tenant,
                                                        opportunity: create(:opportunity, tenant: tenant))
        sender = instance_double(WhatsApp::MessageSender)
        allow(WhatsApp::MessageSender).to receive(:new).with(message).and_return(sender)
        allow(sender).to receive(:deliver) do
          message.update!(status: "sent", sent_at: Time.current)
          true
        end

        described_class.new.perform(message.id, pending_reminder.id)
        expect(pending_reminder.reload.status).to eq("sent")
      end

      it "no re-marca un reminder ya en estado terminal" do
        reminder.mark_sent!
        sender = instance_double(WhatsApp::MessageSender, deliver: true)
        allow(WhatsApp::MessageSender).to receive(:new).with(message).and_return(sender)

        expect { described_class.new.perform(message.id, reminder.id) }
          .not_to(change { reminder.reload.sent_at })
      end
    end
  end
end
