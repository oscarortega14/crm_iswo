# frozen_string_literal: true

FactoryBot.define do
  factory :appointment do
    tenant    { Tenant.first || create(:tenant) }
    contact   { association :contact, tenant: tenant }
    starts_at { 2.days.from_now.change(hour: 10) }
    ends_at   { starts_at + 30.minutes }
    status    { "scheduled" }
    source    { "ai_agent" }
  end
end
