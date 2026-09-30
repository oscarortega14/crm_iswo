# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReminderNotificationJob, type: :job do
  let(:tenant) { ActsAsTenant.current_tenant }

  describe "#perform" do
    it "corre en cola :critical" do
      expect(described_class.new.queue_name).to eq("critical")
    end

    context "dispatcher" do
      let(:reminder_email)  { build_stubbed(:reminder, :email,  tenant: tenant) }
      let(:reminder_in_app) { build_stubbed(:reminder, :in_app, tenant: tenant) }
      # Canal desconocido: usar un reminder válido y stubear el canal para evitar
      # ArgumentError de Rails 8.1 que rechaza valores de enum inválidos.
      let(:reminder_unknown) do
        r = build_stubbed(:reminder, :email, tenant: tenant)
        allow(r).to receive(:channel).and_return("carrier_pigeon")
        r
      end

      before do
        # receive_message_chain devuelve Array; el job llama find_each sobre él.
        # Usamos and_yield para simular el comportamiento de find_each en un Array.
        allow(Reminder).to receive(:due) do
          rel = double("relation")
          allow(rel).to receive(:find_each).and_yield(reminder)
          rel
        end
        allow(reminder).to receive(:claim_for_dispatch!).and_return(true)
        allow(reminder).to receive(:mark_sent!)
        allow(reminder).to receive(:mark_failed!)
        allow(reminder).to receive(:tenant).and_return(tenant)
        allow(reminder).to receive(:user).and_return(build_stubbed(:user, :consultant, tenant: tenant))
      end

      context "channel=email" do
        let(:reminder) { reminder_email }

        it "entrega con deliver_now, notifica in-app y marca como sent" do
          mailer = double("ActionMailer::MessageDelivery", deliver_now: true)
          chain  = double("Mailer", due_notification: mailer)
          allow(ReminderMailer).to receive(:with).with(reminder: reminder).and_return(chain)
          allow(reminder).to receive(:user).and_return(build_stubbed(:user, email: "a@b.co"))
          allow(reminder).to receive(:opportunity).and_return(build_stubbed(:opportunity, tenant: tenant))
          expect(mailer).to receive(:deliver_now)
          expect(Notifications::ReminderDueNotifier).to receive(:call).with(reminder: reminder).and_return(true)
          expect(reminder).to receive(:mark_sent!)
          described_class.new.perform
        end

        it "marca failed si el usuario no tiene email" do
          allow(reminder).to receive(:user).and_return(build_stubbed(:user, email: ""))
          expect(reminder).to receive(:mark_failed!).with("missing_user_email")
          expect(ReminderMailer).not_to receive(:with)
          described_class.new.perform
        end
      end

      context "channel=in_app" do
        let(:reminder) { reminder_in_app }

        it "notifica in-app y marca como sent" do
          allow(reminder).to receive(:opportunity).and_return(build_stubbed(:opportunity, tenant: tenant))
          expect(Notifications::ReminderDueNotifier).to receive(:call).with(reminder: reminder).and_return(true)
          expect(reminder).to receive(:mark_sent!)
          described_class.new.perform
        end
      end

      context "channel=whatsapp" do
        let(:reminder) { build_stubbed(:reminder, :whatsapp, tenant: tenant) }
        let(:staff_user) { build_stubbed(:user, :consultant, tenant: tenant, phone: "+573001112233") }

        before do
          allow(reminder).to receive(:user).and_return(staff_user)
          allow(reminder).to receive(:opportunity).and_return(build_stubbed(:opportunity, tenant: tenant))
          allow(tenant).to receive(:whatsapp_outbound_provider).and_return("whatsapp_cloud")
          allow(tenant).to receive(:whatsapp_outbound_from_number_for).and_return("+15550001")
          allow(tenant).to receive_message_chain(:whatsapp_messages, :create!).and_return(
            instance_double(WhatsappMessage, id: 99)
          )
        end

        it "encola WhatsApp al consultor y notifica in-app" do
          expect(tenant.whatsapp_messages).to receive(:create!).with(
            hash_including(contact: nil, to_number: "+573001112233")
          ).and_return(instance_double(WhatsappMessage, id: 99))
          expect(Notifications::ReminderDueNotifier).to receive(:call).with(reminder: reminder).and_return(true)
          expect(WhatsappDeliveryJob).to receive(:perform_later).with(99, reminder.id)
          described_class.new.perform
        end

        it "marca failed si el consultor no tiene teléfono" do
          allow(staff_user).to receive(:phone).and_return(nil)
          expect(reminder).to receive(:mark_failed!).with("missing_user_phone")
          described_class.new.perform
        end
      end

      context "destinatario viewer" do
        let(:reminder) { reminder_in_app }

        it "marca failed" do
          allow(reminder).to receive(:user).and_return(build_stubbed(:user, :viewer, tenant: tenant))
          expect(reminder).to receive(:mark_failed!).with("staff_recipient_required")
          described_class.new.perform
        end
      end

      context "channel desconocido" do
        let(:reminder) { reminder_unknown }

        it "marca como failed con un mensaje descriptivo" do
          expect(reminder).to receive(:mark_failed!).with(/channel_unknown:carrier_pigeon/)
          described_class.new.perform
        end
      end
    end

    context "manejo de excepciones" do
      let(:reminder) { build_stubbed(:reminder, :email, tenant: tenant) }

      before do
        allow(Reminder).to receive(:due) do
          rel = double("relation")
          allow(rel).to receive(:find_each).and_yield(reminder)
          rel
        end
        allow(reminder).to receive(:claim_for_dispatch!).and_return(true)
        allow(reminder).to receive(:tenant).and_return(tenant)
        allow(reminder).to receive(:user).and_return(build_stubbed(:user, :consultant, tenant: tenant, email: "a@b.co"))
        allow(ReminderMailer).to receive(:with).and_raise(StandardError, "smtp down")
      end

      it "captura el error y marca el reminder como failed" do
        expect(reminder).to receive(:mark_failed!).with(include("smtp down"))
        described_class.new.perform
      end
    end
  end
end
