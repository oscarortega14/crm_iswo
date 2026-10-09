# frozen_string_literal: true

# Recordatorios de citas al cliente (AiAgent::AppointmentReminders), cada 5 minutos.
class AppointmentReminderJob < ApplicationJob
  queue_as :integrations

  def perform
    ActsAsTenant.without_tenant do
      tenant_ids = Appointment.status_scheduled.where(starts_at: Time.current..49.hours.from_now).distinct.pluck(:tenant_id)
      Tenant.where(id: tenant_ids).find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) { AiAgent::AppointmentReminders.dispatch_due!(tenant) }
      rescue StandardError => e
        Rails.logger.error("[AppointmentReminderJob] tenant=#{tenant.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
