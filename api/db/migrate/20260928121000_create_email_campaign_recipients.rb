# frozen_string_literal: true

class CreateEmailCampaignRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :email_campaign_recipients do |t|
      t.references :email_campaign, null: false, foreign_key: true, index: true
      t.references :tenant,         null: false, foreign_key: true, index: true
      t.references :contact,        null: false, foreign_key: true, index: true
      t.references :opportunity,    foreign_key: true

      t.string :email, null: false
      t.string :status, null: false, default: "pending",
                        comment: "pending | sent | delivered | bounced | complained | failed | skipped"
      t.string :ses_message_id
      t.text   :skip_reason

      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :bounced_at
      t.datetime :complained_at
      t.datetime :opened_at
      t.datetime :clicked_at
      t.datetime :unsubscribed_at

      t.timestamps
    end

    add_index :email_campaign_recipients, %i[email_campaign_id status]
    add_index :email_campaign_recipients, %i[email_campaign_id contact_id], unique: true,
              name: "index_email_campaign_recipients_unique_contact"
    add_index :email_campaign_recipients, :ses_message_id, unique: true, where: "ses_message_id IS NOT NULL"
  end
end
