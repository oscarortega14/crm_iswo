# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiAgent::AppointmentReminders do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:zone)     { ActiveSupport::TimeZone["America/Bogota"] }
  let(:owner)    { create(:user, :consultant, tenant: tenant) }
  let(:contact)  do
    create(:contact, tenant: tenant, first_name: "María", phone_e164: "+593991112233", email: "maria@example.com",
                     owner_user: owner)
  end
  let(:template) do
    create(:whatsapp_template, tenant: tenant, meta_template_name: "recordatorio_cita", meta_status: "APPROVED",
                               variable_labels: [ "Nombre", "Fecha y hora" ])
  end
  let!(:cloud_integration) do
    create(:ad_integration, :cloud, tenant: tenant, account_identifier: "+5731999999999",
                                    credentials: { "access_token" => "fake-access-token" })
  end
  let(:appointment) do
    create(:appointment, tenant: tenant, contact: contact, owner_user: owner, created_at: 3.days.ago,
                         starts_at: zone.parse("2026-10-06 10:00"), ends_at: zone.parse("2026-10-06 10:30"))
  end

  around do |example|
    old_provider = ENV.delete("WHATSAPP_PROVIDER")
    travel_to(ActiveSupport::TimeZone["America/Bogota"].parse("2026-10-05 10:30")) { example.run }
  ensure
    ENV["WHATSAPP_PROVIDER"] = old_provider if old_provider
  end

  before do
    allow(WhatsappDeliveryJob).to receive(:perform_later)
    tenant.update!(timezone: "America/Bogota")
    tenant.ai_agent_config.update!(reminders: { client_offsets: [ 24, 1 ], whatsapp_template_id: template.id })
  end

  it "24 h antes con la ventana cerrada: plantilla con nombre y fecha, y correo; una sola vez" do
    appointment
    expect { described_class.dispatch_due!(tenant) }.to have_enqueued_mail(AppointmentMailer, :reminder)
    msg = WhatsappMessage.direction_out.last
    expect(msg).to have_attributes(message_type: "template", template_name: "recordatorio_cita", automated: true,
                                   template_params: [ "María", "martes 6 de octubre, 10:00 a. m." ])
    expect(appointment.reload.client_reminders["24"]).to include("whatsapp_message_id" => msg.id, "email" => true)
    expect(appointment.client_reminders).not_to have_key("1")

    expect { described_class.dispatch_due!(tenant) }.not_to change(WhatsappMessage, :count)
  end

  it "con la ventana de 24 h abierta envía texto libre (sin plantilla) pidiendo confirmación" do
    create(:whatsapp_message, :inbound, tenant: tenant, contact: contact, body: "hola", created_at: 2.hours.ago)
    appointment
    described_class.dispatch_due!(tenant)
    msg = WhatsappMessage.direction_out.last
    expect(msg).to have_attributes(message_type: "text", automated: true)
    expect(msg.body).to include("María", "martes 6 de octubre, 10:00 a. m.", "CONFIRMO")
  end

  it "sin plantilla y con la ventana cerrada no envía WhatsApp (solo correo)" do
    tenant.ai_agent_config.update!(reminders: { whatsapp_template_id: nil })
    appointment
    expect { described_class.dispatch_due!(tenant) }.to have_enqueued_mail(AppointmentMailer, :reminder)
    expect(WhatsappMessage.direction_out.count).to eq(0)
  end

  it "omite el recordatorio de 24 h si la cita se agendó con menos anticipación" do
    appointment.update_columns(created_at: 20.minutes.ago) # después de «24 h antes» (10:00 del día anterior)
    described_class.dispatch_due!(tenant)
    expect(appointment.reload.client_reminders["24"]).to eq("skipped" => "agendada con menos anticipación")
    expect(WhatsappMessage.direction_out.count).to eq(0)
  end

  it "no asistió: envía el mensaje para reagendar una vez" do
    appointment.update!(status: "no_show")
    service = described_class.new(tenant)
    expect { service.send_no_show_followup!(appointment) }.to have_enqueued_mail(AppointmentMailer, :no_show)
    expect(appointment.reload.no_show_followup_at).to be_present
    expect { service.send_no_show_followup!(appointment) }.not_to have_enqueued_mail(AppointmentMailer, :no_show)
  end
end
