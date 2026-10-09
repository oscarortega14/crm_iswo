# frozen_string_literal: true

# SES en modo stub para todo lo de email marketing; `ses_requests` devuelve
# las llamadas hechas (operation_name + params).
module EmailMarketingHelpers
  def ses_client
    EmailMarketing::Ses.client
  end

  def ses_requests(operation = nil)
    reqs = ses_client.api_requests
    operation ? reqs.select { |r| r[:operation_name] == operation } : reqs
  end

  def verify_email_sender!(tenant, **attrs)
    config = { "domain" => "iswo.com.co", "from_local" => "info", "from_name" => "ISWO",
               "status" => "verified", "dkim_tokens" => %w[abc] }.merge(attrs.stringify_keys)
    tenant.update!(settings: (tenant.settings || {}).merge("email_marketing" => config))
  end
end

RSpec.configure do |config|
  config.include EmailMarketingHelpers

  config.before do
    EmailMarketing::Ses.client = Aws::SESV2::Client.new(stub_responses: true, region: "us-east-1")
  end

  config.after do
    EmailMarketing::Ses.client = nil
  end
end
