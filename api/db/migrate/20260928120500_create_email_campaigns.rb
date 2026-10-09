# frozen_string_literal: true

# ============================================================================
# email_campaigns — envío masivo de correo por AWS SES desde el dominio propio
# del tenant (settings.email_marketing). Misma mecánica que whatsapp_campaigns:
# audiencia congelada al iniciar (email_campaign_recipients) y lotes por job.
# ============================================================================
class CreateEmailCampaigns < ActiveRecord::Migration[8.1]
  def change
    create_table :email_campaigns do |t|
      t.references :tenant,          null: false, foreign_key: true, index: true
      t.references :created_by_user, foreign_key: { to_table: :users }

      t.string :name,      null: false
      t.string :subject
      t.string :preheader, comment: "texto de vista previa en la bandeja"
      t.text   :body_html, comment: "HTML final (estilos en línea) con variables {{nombre}}…"
      t.jsonb  :body_design, null: false, default: {}, comment: "proyecto del editor visual para reabrirlo"
      t.jsonb  :audience_filters, null: false, default: {}

      t.string   :status, null: false, default: "draft",
                          comment: "draft | scheduled | running | paused | completed | canceled"
      t.datetime :scheduled_at
      t.integer  :batch_size, null: false, default: 200

      t.integer :total_recipients, null: false, default: 0
      t.integer :sent_count,       null: false, default: 0
      t.integer :failed_count,     null: false, default: 0
      t.integer :skipped_count,    null: false, default: 0

      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :last_batch_at

      t.timestamps
    end

    add_index :email_campaigns, %i[tenant_id status]
  end
end
