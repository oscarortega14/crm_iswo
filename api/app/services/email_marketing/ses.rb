# frozen_string_literal: true

module EmailMarketing
  # Cliente SES v2 compartido (misma cuenta/credenciales que ActionMailer:
  # IAM role del servidor o AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY + AWS_REGION).
  # En tests se reemplaza con `EmailMarketing::Ses.client = Aws::SESV2::Client.new(stub_responses: true)`.
  module Ses
    module_function

    def client
      @client ||= Aws::SESV2::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
    end

    def client=(value)
      @client = value
    end

    # Configuration set de marketing: publica entregas, rebotes, quejas,
    # aperturas y clics al tema SNS que llama a /api/v1/webhooks/ses.
    def configuration_set
      ENV["SES_MARKETING_CONFIGURATION_SET"].presence
    end
  end
end
