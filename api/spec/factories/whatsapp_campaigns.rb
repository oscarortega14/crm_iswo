# frozen_string_literal: true

FactoryBot.define do
  factory :whatsapp_campaign do
    tenant            { Tenant.first || create(:tenant) }
    whatsapp_template { association :whatsapp_template, tenant: tenant }
    sequence(:name)   { |n| "Campaña #{n}" }
    variable_field_map { [] }
    audience_filters   { {} }
    batch_size             { 40 }
    batch_interval_minutes { 15 }
  end

  factory :whatsapp_campaign_recipient do
    tenant            { Tenant.first || create(:tenant) }
    whatsapp_campaign { association :whatsapp_campaign, tenant: tenant }
    contact           { association :contact, tenant: tenant }
    opportunity       { nil }
    status            { "pending" }
  end
end
