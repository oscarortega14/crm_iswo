# frozen_string_literal: true

class AddTemplateFieldsToWhatsappMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :whatsapp_messages, :message_type, :string, null: false, default: "text",
               comment: "text | template"
    add_column :whatsapp_messages, :template_name, :string
    add_column :whatsapp_messages, :template_language, :string
    add_column :whatsapp_messages, :template_params, :jsonb, null: false, default: []

    add_index :whatsapp_messages, :message_type
  end
end
