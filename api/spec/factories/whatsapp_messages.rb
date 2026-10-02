# frozen_string_literal: true

FactoryBot.define do
  factory :whatsapp_message do
    tenant      { Tenant.first || create(:tenant) }
    contact     { association :contact, tenant: tenant }
    opportunity { nil }
    direction   { "out" }
    provider    { "whatsapp_cloud" }
    from_number { "+573000000000" }
    to_number   { "+573001112233" }
    body        { "Hola, soy de ISWO" }
    status      { "queued" }

    trait :inbound  do direction { "in"  } end
    trait :outbound do direction { "out" } end

    trait :cloud    do provider { "whatsapp_cloud" } end
    trait :openwa   do provider { "openwa"         } end

    trait :sent      do status { "sent"      }; sent_at      { Time.current } end
    trait :delivered do status { "delivered" }; delivered_at { Time.current } end
    trait :read      do status { "read"      }; read_at      { Time.current } end
    trait :failed    do status { "failed"    }; error_message { "boom"     } end
  end
end
