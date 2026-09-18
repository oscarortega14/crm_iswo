# frozen_string_literal: true

class AddWhatsappOptInToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :whatsapp_opt_in_at, :datetime
    add_column :contacts, :whatsapp_opt_in_source, :string, comment: "manual | import | form | reply_stop_in"

    add_index :contacts, :whatsapp_opt_in_at
  end
end
