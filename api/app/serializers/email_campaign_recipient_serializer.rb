# frozen_string_literal: true

class EmailCampaignRecipientSerializer < ApplicationSerializer
  set_type :email_campaign_recipient

  attributes :email, :status, :sent_at, :delivered_at, :opened_at, :clicked_at,
             :bounced_at, :complained_at, :unsubscribed_at

  attribute :result, &:result

  attribute :contact_id do |r|
    r.contact_id.to_s
  end

  attribute :contact_name do |r|
    r.contact&.display_name
  end

  attribute :reason, &:skip_reason
end
