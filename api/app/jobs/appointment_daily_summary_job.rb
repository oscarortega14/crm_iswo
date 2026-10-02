# frozen_string_literal: true

# ============================================================================
# AppointmentDailySummaryJob — resumen de las citas del día para admin/manager
# ============================================================================
# Corre cada hora; a partir de las 7:00 (hora del tenant) envía una sola vez
# al día un aviso en la campana y un correo con las citas de hoy.
# ============================================================================
class AppointmentDailySummaryJob < ApplicationJob
  queue_as :low

  SEND_HOUR = 7

  def perform
    ActsAsTenant.without_tenant do
      Tenant.kept.where(active: true).find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) { summarize(tenant) }
      rescue StandardError => e
        Rails.logger.error("[AppointmentDailySummaryJob] tenant=#{tenant.id}: #{e.class}: #{e.message}")
      end
    end
  end

  private

  def summarize(tenant)
    config = tenant.ai_agent_config
    return unless config.reminders["daily_summary"]

    zone = ActiveSupport::TimeZone[tenant.timezone.presence || "America/Bogota"] || Time.zone
    now = zone.now
    return if now.hour < SEND_HOUR
    return if config.raw["daily_summary_sent_on"] == now.to_date.iso8601

    appointments = tenant.appointments.status_scheduled.where(starts_at: now.beginning_of_day..now.end_of_day)
                         .includes(:contact, :owner_user).order(:starts_at).to_a
    mark_sent!(tenant, now.to_date)
    return if appointments.empty?

    rows = appointments.map do |a|
      { time: a.starts_at.in_time_zone(zone).strftime("%-I:%M %p").sub("AM", "a. m.").sub("PM", "p. m."),
        contact: a.contact&.display_name, owner: a.owner_user&.name, confirmed: a.confirmed_at.present? }
    end
    body = rows.map { |r| "#{r[:time]} #{r[:contact]} (#{r[:confirmed] ? 'confirmó' : 'sin confirmar'})" }.join(" · ")

    tenant.users.kept.where(role: %w[admin manager], active: true).find_each do |user|
      Notification.create!(tenant: tenant, user: user, kind: "appointment",
                           title: "Hoy hay #{rows.size} cita(s)", body: body.truncate(500))
      AppointmentMailer.with(tenant: tenant, user: user, rows: rows).daily_summary.deliver_later if user.email.present?
    end
  end

  def mark_sent!(tenant, date)
    settings = tenant.settings || {}
    agent = (settings["ai_agent"] || {}).merge("daily_summary_sent_on" => date.iso8601)
    tenant.update_columns(settings: settings.merge("ai_agent" => agent), updated_at: Time.current)
  end
end
