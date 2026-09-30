# frozen_string_literal: true

FactoryBot.define do
  factory :ad_integration do
    tenant   { Tenant.first || create(:tenant) }
    provider { "meta" }
    status   { "active" }
    account_identifier { "act_#{SecureRandom.hex(6)}" }
    metadata { {} }
    credentials { { "access_token" => "fake-access-token" } }

    trait :meta   do provider { "meta"           } end
    trait :google do provider { "google"         } end
    trait :cloud  do provider { "whatsapp_cloud" } end
    trait :openwa do provider { "openwa"         } end

    trait :paused do status { "paused" } end
    trait :errored do
      status            { "error" }
      last_error_at     { Time.current }
      last_error_message { "bad token" }
    end
  end
end
