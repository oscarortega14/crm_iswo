# frozen_string_literal: true

class AddIndexesForWhatsappInbox < ActiveRecord::Migration[8.1]
  def change
    add_index :whatsapp_messages, %i[tenant_id contact_id created_at],
              name: "index_whatsapp_messages_on_tenant_contact_created"
    add_index :whatsapp_messages, %i[contact_id direction read_at],
              name: "index_whatsapp_messages_on_contact_direction_read"
  end
end
