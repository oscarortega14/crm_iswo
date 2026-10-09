# frozen_string_literal: true

# Detalle por destinatario de una campaña: resultado real según Meta y motivo
# del fallo u omisión (error de Meta o skip_reason).
class WhatsappCampaignRecipientSerializer < ApplicationSerializer
  set_type :whatsapp_campaign_recipient

  attributes :status, :created_at

  attribute :result do |r|
    WhatsappCampaign.delivery_key(r.status, r.whatsapp_message&.status)
  end

  attribute :contact_id do |r|
    r.contact_id.to_s
  end

  attribute :contact_name do |r|
    r.contact&.display_name
  end

  attribute :to_number do |r|
    r.whatsapp_message&.to_number || r.contact&.phone_e164
  end

  attribute :reason do |r|
    r.whatsapp_message&.error_message.presence || r.skip_reason.presence
  end

  attribute :sent_at do |r|
    r.whatsapp_message&.sent_at
  end

  attribute :delivered_at do |r|
    r.whatsapp_message&.delivered_at
  end

  attribute :read_at do |r|
    r.whatsapp_message&.read_at
  end

  attribute :confirmed_at, &:confirmed_at

  attribute :confirm_replied do |r|
    r.confirm_reply_message_id.present?
  end
end
