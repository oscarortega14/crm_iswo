# frozen_string_literal: true

FactoryBot.define do
  factory :whatsapp_template do
    tenant { Tenant.first || create(:tenant) }
    sequence(:name) { |n| "Plantilla #{n}" }
    sequence(:meta_template_name) { |n| "plantilla_#{n}" }
    language { "es_CO" }
    variable_labels { [] }
    active { true }

    trait :opt_in_request do
      opt_in_request { true }
    end
  end
end
