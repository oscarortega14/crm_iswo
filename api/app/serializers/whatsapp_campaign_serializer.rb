# frozen_string_literal: true

class WhatsappCampaignSerializer < ApplicationSerializer
  set_type :whatsapp_campaign

  attributes :name, :variable_field_map, :audience_filters, :status,
             :batch_size, :batch_interval_minutes,
             :total_recipients, :sent_count, :failed_count, :skipped_no_opt_in_count, :confirm_reply_body,
             :started_at, :completed_at, :last_batch_at,
             :created_at, :updated_at

  attribute :whatsapp_template_id do |c|
    c.whatsapp_template_id.to_s
  end

  attribute :whatsapp_template_name do |c|
    c.whatsapp_template.name
  end

  attribute :whatsapp_template_meta_status do |c|
    c.whatsapp_template.meta_status
  end

  # Cuántos respondieron «Sí» y cuántos recibieron el «Mensaje al autorizar».
  attribute :confirmation_stats do |c|
    c.status_draft? ? nil : c.confirmation_stats
  end

  # Resultado real (entregado/leído/fallido según Meta) — ver WhatsappCampaign#delivery_stats.
  attribute :delivery_stats do |c|
    c.status_draft? ? nil : c.delivery_stats
  end
end
