# frozen_string_literal: true

class CreateWhatsappTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :whatsapp_templates do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :name, null: false
      t.string :meta_template_name, null: false
      t.string :language, null: false
      t.jsonb :variable_labels, null: false, default: []
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :whatsapp_templates, %i[tenant_id meta_template_name language],
              unique: true, name: "index_whatsapp_templates_on_tenant_and_meta_name_and_lang"
  end
end
