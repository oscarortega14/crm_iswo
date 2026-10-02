# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppointmentDailySummaryJob do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let!(:admin)  { create(:user, :admin, tenant: tenant) }
  let(:zone)    { ActiveSupport::TimeZone["America/Bogota"] }

  before { tenant.update!(timezone: "America/Bogota") }

  it "a las 7:00 avisa a admin/manager las citas de hoy, una sola vez al día" do
    contact = create(:contact, tenant: tenant, first_name: "María", last_name: "Andrade")
    travel_to(zone.parse("2026-10-06 07:10")) do
      create(:appointment, tenant: tenant, contact: contact, starts_at: zone.parse("2026-10-06 10:00"),
                           ends_at: zone.parse("2026-10-06 10:30"), confirmed_at: Time.current)

      expect { described_class.perform_now }.to have_enqueued_mail(AppointmentMailer, :daily_summary)
      n = Notification.where(user: admin, kind: "appointment").last
      expect(n.title).to eq("Hoy hay 1 cita(s)")
      expect(n.body).to include("10:00 a. m. María Andrade (confirmó)")

      expect { described_class.perform_now }.not_to change(Notification, :count)
    end
  end

  it "antes de las 7:00 o con el resumen desactivado no envía nada" do
    create(:appointment, tenant: tenant, starts_at: zone.parse("2026-10-06 10:00"), ends_at: zone.parse("2026-10-06 10:30"))
    travel_to(zone.parse("2026-10-06 06:30")) { expect { described_class.perform_now }.not_to change(Notification, :count) }

    tenant.ai_agent_config.update!(reminders: { daily_summary: false })
    travel_to(zone.parse("2026-10-06 08:00")) { expect { described_class.perform_now }.not_to change(Notification, :count) }
  end
end
