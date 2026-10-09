# frozen_string_literal: true

# Registro de cada respuesta del asistente IA de WhatsApp: qué mensaje la
# disparó, qué respondió, qué herramientas usó (calificar, guardar datos,
# pasar a asesor…) y cuántos tokens consumió (costo).
class CreateAiAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_agent_runs do |t|
      t.references :tenant,  null: false, foreign_key: true, index: true
      t.references :contact, null: false, foreign_key: true, index: true
      t.references :trigger_message, foreign_key: { to_table: :whatsapp_messages, on_delete: :nullify }
      t.references :reply_message,   foreign_key: { to_table: :whatsapp_messages, on_delete: :nullify }

      t.string  :status, null: false, comment: "replied | handoff | skipped | error"
      t.string  :model
      t.integer :input_tokens,  null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.jsonb   :tool_calls, null: false, default: [], comment: "[{name, arguments, result}]"
      t.text    :error

      t.timestamps
    end

    add_index :ai_agent_runs, %i[tenant_id created_at]
    add_index :ai_agent_runs, %i[contact_id created_at]
  end
end
