# frozen_string_literal: true

# Fase 3 del asistente IA: recordatorios de la cita al cliente (WhatsApp y
# correo), confirmación, resultado (asistió / no asistió) y recordatorio al asesor.
class AddRemindersToAppointments < ActiveRecord::Migration[8.1]
  def change
    add_column :appointments, :confirmed_at, :datetime, comment: "el cliente confirmó asistencia"
    add_column :appointments, :client_reminders, :jsonb, null: false, default: {},
               comment: "{ \"24\" => { at, whatsapp_message_id, email, skipped } } por horas de anticipación"
    add_column :appointments, :outcome_at, :datetime, comment: "cuándo se marcó asistió / no asistió"
    add_column :appointments, :no_show_followup_at, :datetime, comment: "mensaje para reagendar enviado"
    add_reference :appointments, :staff_reminder, foreign_key: { to_table: :reminders, on_delete: :nullify }
  end
end
