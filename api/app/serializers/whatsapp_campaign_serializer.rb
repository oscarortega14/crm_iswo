# frozen_string_literal: true

class WhatsappCampaignSerializer < ApplicationSerializer
  set_type :whatsapp_campaign

  attributes :name, :variable_field_map, :audience_filters, :status,
             :batch_size, :batch_interval_minutes,
             :total_recipients, :sent_count, :failed_count, :skipped_no_opt_in_count,
             :started_at, :completed_at, :last_batch_at,
             :created_at, :updated_at

  attribute :whatsapp_template_id do |c|
    c.whatsapp_template_id.to_s
  end

  attribute :whatsapp_template_name do |c|
    c.whatsapp_template.name
  end
end
