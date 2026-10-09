# frozen_string_literal: true

# Citas agendadas (por el asistente IA o por el equipo) en el Google Calendar
# del tenant. Base de los recordatorios al cliente (fase 3).
class CreateAppointments < ActiveRecord::Migration[8.1]
  def change
    create_table :appointments do |t|
      t.references :tenant,      null: false, foreign_key: true, index: true
      t.references :contact,     null: false, foreign_key: true, index: true
      t.references :opportunity, foreign_key: true
      t.references :owner_user,  foreign_key: { to_table: :users }

      t.datetime :starts_at, null: false
      t.datetime :ends_at,   null: false
      t.string   :status, null: false, default: "scheduled", comment: "scheduled | canceled | completed | no_show"
      t.string   :source, null: false, default: "ai_agent",  comment: "ai_agent | user"
      t.string   :title
      t.text     :notes
      t.string   :google_event_id
      t.datetime :canceled_at

      t.timestamps
    end

    add_index :appointments, %i[tenant_id starts_at]
    add_index :appointments, %i[contact_id status]
  end
end
