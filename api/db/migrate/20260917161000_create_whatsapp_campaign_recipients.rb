# frozen_string_literal: true

class CreateWhatsappCampaignRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :whatsapp_campaign_recipients do |t|
      t.references :whatsapp_campaign, null: false, foreign_key: true, index: true
      t.references :tenant,            null: false, foreign_key: true, index: true
      t.references :contact,           null: false, foreign_key: true, index: true
      t.references :opportunity,                    foreign_key: true
      t.references :whatsapp_message,                foreign_key: true

      t.string :status, null: false, default: "pending",
                        comment: "pending | sent | failed | skipped_no_opt_in | skipped_no_phone"
      t.text   :skip_reason

      t.timestamps
    end

    add_index :whatsapp_campaign_recipients, %i[whatsapp_campaign_id status]
    add_index :whatsapp_campaign_recipients, %i[whatsapp_campaign_id contact_id], unique: true,
              name: "index_wa_campaign_recipients_unique_contact"
  end
end
