# frozen_string_literal: true

# ============================================================================
# whatsapp_campaigns — envío masivo con plantilla del catálogo + ritmo seguro
# ----------------------------------------------------------------------------
# La plantilla se referencia por `whatsapp_template_id` (catálogo existente,
# ver WhatsappTemplate) en vez de guardar el nombre exacto suelto — evita que
# una campaña de cientos de contactos falle por un typo. `variable_field_map`
# es un array paralelo a `whatsapp_template.variable_names`/`variable_labels`:
# cada posición dice de qué campo (contact.first_name, opportunity.title, …)
# sacar el valor real para cada destinatario.
#
# La audiencia se resuelve una sola vez al lanzar (snapshot en
# whatsapp_campaign_recipients), no en vivo — así el conteo/estado no se
# mueve bajo los pies si un lead cambia de etapa a mitad de envío.
# ============================================================================
class CreateWhatsappCampaigns < ActiveRecord::Migration[8.1]
  def change
    create_table :whatsapp_campaigns do |t|
      t.references :tenant,           null: false, foreign_key: true, index: true
      t.references :created_by_user,  foreign_key: { to_table: :users }
      t.references :whatsapp_template, null: false, foreign_key: true

      t.string   :name,               null: false
      t.jsonb    :variable_field_map, null: false, default: [],
                                      comment: "paralelo a whatsapp_template.variable_names — de qué campo sacar cada variable"
      t.jsonb    :audience_filters,   null: false, default: {},
                                      comment: "snapshot de los mismos filtros de /opportunities (pipeline_id, stage_id, owner_id, temperature, status)"
      t.string   :status,             null: false, default: "draft",
                                      comment: "draft | scheduled | running | paused | completed | canceled"
      t.integer  :batch_size,             null: false, default: 40
      t.integer  :batch_interval_minutes, null: false, default: 15

      t.integer  :total_recipients,        null: false, default: 0
      t.integer  :sent_count,              null: false, default: 0
      t.integer  :failed_count,            null: false, default: 0
      t.integer  :skipped_no_opt_in_count, null: false, default: 0

      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :last_batch_at

      t.timestamps
    end

    add_index :whatsapp_campaigns, %i[tenant_id status]
  end
end
