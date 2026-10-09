# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebhookProcessorJob, type: :job do
  describe "whatsapp_cloud" do
    let(:tenant) { ActsAsTenant.current_tenant }
    let(:contact) { create(:contact, tenant: tenant) }

    it "actualiza estado saliente con statuses[] de Meta" do
      ActsAsTenant.with_tenant(tenant) do
        create(
          :ad_integration,
          :cloud,
          tenant: tenant,
          account_identifier: "109876543210"
        )
      end

      msg = create(
        :whatsapp_message,
        :cloud,
        tenant: tenant,
        contact: contact,
        direction: :out,
        provider_message_id: "wamid.STATUS123",
        status: "sent"
      )

      payload = {
        "entry" => [
          {
            "changes" => [
              {
                "value" => {
                  "metadata" => { "phone_number_id" => "109876543210" },
                  "statuses" => [
                    { "id" => "wamid.STATUS123", "status" => "delivered", "timestamp" => "1234567890" }
                  ]
                }
              }
            ]
          }
        ]
      }

      described_class.new.perform("whatsapp_cloud", payload)

      expect(msg.reload.status).to eq("delivered")
      expect(msg.delivered_at).to be_present
    end

    context "mensaje entrante", :without_tenant do
      it "persiste payload estilo Meta (text, contacts.profile, display_phone_number)" do
        t = create(:tenant)
        ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :cloud, tenant: t, account_identifier: "7794189252778687")
        end

        wamid = "wamid.HBgLMTc4NjM1NTk5NjYVAGISEE"
        payload = {
          "object" => "whatsapp_business_account",
          "entry" => [
            {
              "id" => "215589313241560883",
              "changes" => [
                {
                  "field" => "messages",
                  "value" => {
                    "messaging_product" => "whatsapp",
                    "metadata" => {
                      "display_phone_number" => "15551797781",
                      "phone_number_id" => "7794189252778687"
                    },
                    "contacts" => [
                      {
                        "profile" => { "name" => "Jessica Laverdetman" },
                        "wa_id" => "17863559966"
                      }
                    ],
                    "messages" => [
                      {
                        "from" => "17863559966",
                        "id" => wamid,
                        "timestamp" => "1758254144",
                        "text" => { "body" => "Hi!" },
                        "type" => "text"
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }

        described_class.new.perform("whatsapp_cloud", payload)

        ActsAsTenant.with_tenant(t) do
          inbound = WhatsappMessage.find_by(provider_message_id: wamid)
          expect(inbound).to be_present
          expect(inbound.body).to eq("Hi!")
          expect(inbound.direction).to eq("in")
          expect(inbound.to_number).to eq("+15551797781")
          expect(inbound.contact.first_name).to eq("Jessica")
          expect(inbound.contact.last_name).to eq("Laverdetman")
        end
      end

      it "notifica al dueño del contacto si ya existe con owner_user" do
        t = create(:tenant)
        owner = ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :cloud, tenant: t, account_identifier: "7794189252778687")
          u = create(:user, :consultant, tenant: t)
          create(:contact, tenant: t, owner_user: u, phone_e164: "+17863559966")
          u
        end

        payload = {
          "entry" => [ {
            "changes" => [ {
              "value" => {
                "metadata" => { "display_phone_number" => "15551797781", "phone_number_id" => "7794189252778687" },
                "contacts" => [ { "profile" => { "name" => "Jessica" }, "wa_id" => "17863559966" } ],
                "messages" => [ { "from" => "17863559966", "id" => "wamid.notif1",
                                  "timestamp" => "1758254144", "text" => { "body" => "Hola" }, "type" => "text" } ]
              }
            } ]
          } ]
        }

        described_class.new.perform("whatsapp_cloud", payload)

        notif = ActsAsTenant.with_tenant(t) { Notification.find_by(kind: "whatsapp_message_received") }
        expect(notif).to be_present
        expect(notif.user_id).to eq(owner.id)
      end

      it "si el contacto de ese número estaba eliminado, lo restaura y le cuelga el mensaje" do
        t = create(:tenant)
        deleted = ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :cloud, tenant: t, account_identifier: "7794189252778687")
          c = create(:contact, tenant: t, first_name: "Lucio", phone_e164: "+17863559966")
          c.discard
          c
        end

        payload = {
          "entry" => [ {
            "changes" => [ {
              "value" => {
                "metadata" => { "display_phone_number" => "15551797781", "phone_number_id" => "7794189252778687" },
                "contacts" => [ { "profile" => { "name" => "Lucio P" }, "wa_id" => "17863559966" } ],
                "messages" => [ { "from" => "17863559966", "id" => "wamid.volvio1",
                                  "timestamp" => "1758254144", "text" => { "body" => "Hola otra vez" }, "type" => "text" } ]
              }
            } ]
          } ]
        }

        expect { described_class.new.perform("whatsapp_cloud", payload) }
          .not_to(change { ActsAsTenant.with_tenant(t) { Contact.with_discarded.count } })

        ActsAsTenant.with_tenant(t) do
          inbound = WhatsappMessage.find_by(provider_message_id: "wamid.volvio1")
          expect(inbound.contact_id).to eq(deleted.id)
          expect(deleted.reload).to be_kept
        end
      end
    end
  end

  describe "whatsapp_openwa" do
    let(:tenant) { ActsAsTenant.current_tenant }
    let(:contact) { create(:contact, tenant: tenant) }

    def openwa_payload(event:, msg_id: "OWID001", from: "573001234567@c.us",
                       to: "573009999999@c.us", body: "Hola OpenWA")
      {
        "event"     => event,
        "sessionId" => "test-session",
        "data" => {
          "id"   => { "_serialized" => msg_id },
          "from" => from,
          "to"   => to,
          "body" => body
        }
      }
    end

    context "message.received — mensaje entrante", :without_tenant do
      it "persiste inbound, crea contacto y asigna tenant por AdIntegration" do
        t = create(:tenant)
        ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :openwa, tenant: t, account_identifier: "test-session")
        end

        described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.received"))

        ActsAsTenant.with_tenant(t) do
          inbound = WhatsappMessage.find_by(provider_message_id: "OWID001")
          expect(inbound).to be_present
          expect(inbound.direction).to eq("in")
          expect(inbound.provider).to eq("openwa")
          expect(inbound.status).to eq("delivered")
          expect(inbound.body).to eq("Hola OpenWA")
          expect(inbound.contact).to be_present
        end
      end

      it "convierte chatId @c.us a E.164 en from/to_number" do
        t = create(:tenant)
        ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :openwa, tenant: t, account_identifier: "test-session")
        end

        described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.received",
                                                                       from: "573001234567@c.us",
                                                                       to:   "573009999999@c.us"))

        inbound = ActsAsTenant.with_tenant(t) { WhatsappMessage.find_by(provider_message_id: "OWID001") }
        expect(inbound.from_number).to eq("+573001234567")
        expect(inbound.to_number).to eq("+573009999999")
      end

      it "es idempotente — no duplica si ya existe el provider_message_id" do
        t = create(:tenant)
        ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :openwa, tenant: t, account_identifier: "test-session")
        end

        2.times do
          described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.received"))
        end

        count = ActsAsTenant.with_tenant(t) { WhatsappMessage.where(provider_message_id: "OWID001").count }
        expect(count).to eq(1)
      end

      it "ignora el payload si no hay tenant para el sessionId" do
        expect {
          described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.received",
                                                                         from: "99999@c.us",
                                                                         to:   "88888@c.us"))
        }.not_to change { ActsAsTenant.without_tenant { WhatsappMessage.count } }
      end

      it "dispara Notifications::WhatsappMessageNotifier tras crear el mensaje" do
        t = create(:tenant)
        manager = ActsAsTenant.with_tenant(t) do
          create(:ad_integration, :openwa, tenant: t, account_identifier: "test-session")
          create(:user, :manager, tenant: t)
        end

        described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.received", msg_id: "OWID_NOTIF"))

        notif = ActsAsTenant.with_tenant(t) { Notification.find_by(kind: "whatsapp_message_received") }
        expect(notif).to be_present
        expect(notif.user_id).to eq(manager.id)
      end
    end

    context "message.delivered" do
      it "actualiza el estado del mensaje saliente a delivered con timestamp" do
        msg = create(:whatsapp_message, :openwa, :outbound,
                     tenant: tenant, contact: contact,
                     provider_message_id: "OWID_DEL", status: "sent", delivered_at: nil)

        described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.delivered",
                                                                       msg_id: "OWID_DEL"))

        msg.reload
        expect(msg.status).to eq("delivered")
        expect(msg.delivered_at).to be_present
      end
    end

    context "message.read" do
      it "actualiza el estado del mensaje saliente a read con timestamp" do
        msg = create(:whatsapp_message, :openwa, :outbound,
                     tenant: tenant, contact: contact,
                     provider_message_id: "OWID_READ", status: "delivered", read_at: nil)

        described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.read",
                                                                       msg_id: "OWID_READ"))

        msg.reload
        expect(msg.status).to eq("read")
        expect(msg.read_at).to be_present
      end
    end

    context "message.failed" do
      it "actualiza el estado del mensaje saliente a failed" do
        msg = create(:whatsapp_message, :openwa, :outbound,
                     tenant: tenant, contact: contact,
                     provider_message_id: "OWID_FAIL", status: "sent")

        described_class.new.perform("whatsapp_openwa", openwa_payload(event: "message.failed",
                                                                       msg_id: "OWID_FAIL"))

        expect(msg.reload.status).to eq("failed")
      end
    end

    context "evento desconocido" do
      it "no crea ni modifica mensajes" do
        expect {
          described_class.new.perform("whatsapp_openwa", openwa_payload(event: "group.joined"))
        }.not_to change(WhatsappMessage, :count)
      end
    end
  end
end
