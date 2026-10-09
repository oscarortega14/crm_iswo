# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppointmentMailer do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:zone)    { ActiveSupport::TimeZone["America/Bogota"] }
  let(:contact) { create(:contact, tenant: tenant, first_name: "María", email: "maria@example.com") }
  let(:appointment) do
    create(:appointment, tenant: tenant, contact: contact, starts_at: zone.parse("2026-10-06 10:00"),
                         ends_at: zone.parse("2026-10-06 10:30"))
  end

  before do
    tenant.update!(timezone: "America/Bogota")
    tenant.ai_agent_config.update!(calendar: { location: "https://meet.google.com/abc" })
  end

  it "recordatorio al cliente con fecha, lugar y pedido de confirmación" do
    mail = described_class.with(appointment: appointment, tenant: tenant).reminder
    expect(mail.to).to eq([ "maria@example.com" ])
    expect(mail.subject).to include(tenant.name, "martes 6 de octubre, 10:00 a. m.")
    expect(mail.text_part.body.to_s).to include("Hola María", "https://meet.google.com/abc", "confirmas")
  end

  it "sale desde el dominio verificado del tenant si lo hay" do
    verify_email_sender!(tenant)
    mail = described_class.with(appointment: appointment, tenant: tenant).reminder
    expect(mail.from).to eq([ "info@iswo.com.co" ])
  end

  it "no asistió y resumen diario" do
    expect(described_class.with(appointment: appointment, tenant: tenant).no_show.subject).to include("Reagendamos")
    user = create(:user, :admin, tenant: tenant)
    rows = [ { time: "10:00 a. m.", contact: "María", owner: "Paula", confirmed: true } ]
    mail = described_class.with(tenant: tenant, user: user, rows: rows).daily_summary
    expect(mail.subject).to eq("Citas de hoy en #{tenant.name} (1)")
    expect(mail.text_part.body.to_s).to include("10:00 a. m. · María · Paula · Confirmó")
  end
end
