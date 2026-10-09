# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiAgent::AppointmentReplies do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:owner)   { create(:user, :consultant, tenant: tenant) }
  let(:contact) do
    create(:contact, tenant: tenant, first_name: "María", last_name: nil, phone_e164: "+593991112233", owner_user: owner)
  end
  let!(:appointment) do
    create(:appointment, tenant: tenant, contact: contact, owner_user: owner, starts_at: 20.hours.from_now,
                         ends_at: 20.hours.from_now + 30.minutes, client_reminders: { "24" => { "at" => Time.current.iso8601 } })
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

  def reply(text)
    create(:whatsapp_message, :inbound, tenant: tenant, contact: contact, body: text, from_number: "+593991112233")
  end

  it "«Confirmo» confirma la cita, agradece y avisa al asesor" do
    expect(described_class.call(message: reply("¡Confirmo!"))).to eq(:confirmed)
    expect(appointment.reload.confirmed_at).to be_present
    expect(WhatsappMessage.direction_out.last.body).to start_with("¡Gracias por confirmar, María!")
    expect(WhatsappMessage.direction_out.last.body).not_to end_with("..")
    expect(Notification.where(user: owner, kind: "appointment").last.title).to eq("María confirmó su cita")
  end

  it "«reprogramar» sin asistente avisa al asesor; con asistente se lo deja a él" do
    expect(described_class.call(message: reply("Reprogramar"))).to eq(:reschedule_to_staff)
    expect(Notification.where(user: owner).last.title).to include("pidió reprogramar")

    allow_any_instance_of(AiAgent::Config).to receive(:active?).and_return(true)
    expect(described_class.call(message: reply("no puedo mañana"))).to eq(:reschedule_to_agent)
  end

  it "no aplica sin recordatorio enviado, si ya confirmó o si el texto es otra cosa" do
    expect(described_class.call(message: reply("¿cuánto cuesta?"))).to be_nil
    appointment.update!(confirmed_at: Time.current)
    expect(described_class.call(message: reply("si"))).to be_nil
  end
end
