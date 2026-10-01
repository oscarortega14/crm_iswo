# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiAgent::Scheduler do
  let(:tenant)   { ActsAsTenant.current_tenant }
  let(:owner)    { create(:user, :consultant, tenant: tenant) }
  let(:contact)  { create(:contact, tenant: tenant, first_name: "María", last_name: "Andrade", owner_user: owner) }
  let(:calendar) { FakeGoogleCalendar.new }
  let(:zone)     { ActiveSupport::TimeZone["America/Bogota"] }
  subject(:scheduler) { described_class.new(tenant, calendar_client: calendar) }

  before do
    tenant.update!(timezone: "America/Bogota")
    tenant.ai_agent_config.update!(calendar: { calendar_id: "agenda@iswo.com.co", duration_minutes: 60,
                                               work_days: [ 1, 2, 3, 4, 5 ], start_time: "09:00", end_time: "12:00",
                                               min_notice_hours: 2, max_days_ahead: 7 })
  end

  # Lunes 5 de octubre de 2026, 7:00 a. m. en Bogotá
  around { |ex| travel_to(ActiveSupport::TimeZone["America/Bogota"].parse("2026-10-05 07:00")) { ex.run } }

  it "ofrece horarios en los días y horas de atención, con anticipación mínima y sin lo ocupado" do
    calendar.busy_ranges = [ [ zone.parse("2026-10-05 10:00"), zone.parse("2026-10-05 11:00") ] ]
    slots = scheduler.available_slots(limit: 4).map { |t| t.in_time_zone(zone).strftime("%a %H:%M") }

    # 07:00 + 2 h de anticipación → desde las 9:00; 9:30 choca con 10:00-11:00 (reunión de 60 min).
    expect(slots).to eq([ "Mon 09:00", "Mon 11:00", "Tue 09:00", "Tue 09:30" ])
  end

  it "no ofrece fines de semana y respeta las citas del CRM" do
    create(:appointment, tenant: tenant, contact: contact, starts_at: zone.parse("2026-10-06 09:00"),
                         ends_at: zone.parse("2026-10-06 12:00"))
    slots = scheduler.available_slots(from: zone.parse("2026-10-06 00:00"), limit: 50)
    expect(slots.map { |t| t.in_time_zone(zone).to_date }.uniq.map(&:wday)).to all(be_between(1, 5))
    expect(slots.map { |t| t.in_time_zone(zone).to_date }).not_to include(Date.new(2026, 10, 6))
  end

  it "agenda: crea el evento y la cita, avisa al asesor y mueve la etapa con el disparador" do
    pipeline = create(:pipeline_with_stages, tenant: tenant)
    stages = pipeline.pipeline_stages.order(:position)
    stages.second.update!(auto_rule: { "trigger" => "appointment_scheduled" })
    opp = create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: contact, owner_user: owner,
                                                  pipeline: pipeline, pipeline_stage: stages.first)

    appointment = scheduler.book!(contact: contact, opportunity: opp, starts_at: "2026-10-06T09:00:00-05:00",
                                  reason: "Diagnóstico ISO 9001")

    expect(appointment).to have_attributes(google_event_id: "evt_1", owner_user_id: owner.id, status: "scheduled",
                                           ends_at: zone.parse("2026-10-06 10:00"))
    expect(calendar.created.first).to include(summary: /María Andrade/, time_zone: "America/Bogota")
    expect(calendar.created.first[:description]).to include("Diagnóstico ISO 9001")
    expect(opp.reload.pipeline_stage).to eq(stages.second)
    expect(Notification.where(user: owner, kind: "appointment").last.title).to eq("Nueva cita: María Andrade")
    expect(scheduler.label(appointment.starts_at)).to eq("martes 6 de octubre, 9:00 a. m.")
  end

  it "no agenda un horario ocupado, fuera de horario o sin anticipación" do
    calendar.busy_ranges = [ [ zone.parse("2026-10-06 09:00"), zone.parse("2026-10-06 10:00") ] ]
    expect { scheduler.book!(contact: contact, opportunity: nil, starts_at: "2026-10-06T09:00:00-05:00") }
      .to raise_error(described_class::Unavailable)
    expect { scheduler.book!(contact: contact, opportunity: nil, starts_at: "2026-10-06T15:00:00-05:00") }
      .to raise_error(described_class::Unavailable)
    expect { scheduler.book!(contact: contact, opportunity: nil, starts_at: "2026-10-05T08:00:00-05:00") }
      .to raise_error(described_class::Unavailable)
  end

  it "reprograma y cancela sobre el mismo evento de Google" do
    appointment = scheduler.book!(contact: contact, opportunity: nil, starts_at: "2026-10-06T09:00:00-05:00")
    scheduler.reschedule!(appointment, "2026-10-07T10:00:00-05:00")
    expect(appointment.reload.starts_at).to eq(zone.parse("2026-10-07 10:00"))
    expect(calendar.moved.first[:event_id]).to eq("evt_1")

    scheduler.cancel!(appointment)
    expect(appointment.reload).to have_attributes(status: "canceled")
    expect(calendar.deleted).to eq([ "evt_1" ])
  end
end
