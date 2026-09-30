# frozen_string_literal: true

FactoryBot.define do
  factory :email_campaign do
    tenant           { Tenant.first || create(:tenant) }
    sequence(:name)  { |n| "Boletín #{n}" }
    subject          { "Hola {{nombre|cliente}}" }
    body_html        { "<p>Hola {{nombre}}, tenemos novedades.</p>" }
    audience_filters { {} }
  end

  factory :email_campaign_recipient do
    tenant         { Tenant.first || create(:tenant) }
    email_campaign { association :email_campaign, tenant: tenant }
    contact        { association :contact, tenant: tenant }
    email          { contact.email.presence || "persona#{SecureRandom.hex(3)}@example.com" }
    status         { "pending" }
  end
end
