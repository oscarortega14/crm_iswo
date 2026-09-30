# frozen_string_literal: true

require "aws-sdk-sns"

module Api
  module V1
    module Webhooks
      # ========================================================================
      # Webhooks::SesController — avisos de AWS SES vía SNS (email marketing)
      # ========================================================================
      # El configuration set de marketing publica en un tema SNS suscrito a
      # POST /api/v1/webhooks/ses. Cada mensaje trae firma de AWS, que se
      # verifica con Aws::SNS::MessageVerifier; si SES_SNS_TOPIC_ARN está
      # definido, además solo se aceptan mensajes de ese tema.
      #   SubscriptionConfirmation → se confirma visitando SubscribeURL.
      #   Notification            → SesEventJob.
      # ========================================================================
      class SesController < BaseController
        skip_before_action :authenticate_user!,            raise: false
        skip_before_action :verify_user_belongs_to_tenant, raise: false
        skip_before_action :resolve_tenant!,               raise: false
        skip_around_action :scope_to_tenant,               raise: false

        # POST /api/v1/webhooks/ses
        def create
          raw = request.raw_post
          message = JSON.parse(raw)
          return head :forbidden unless trusted?(raw, message)

          case message["Type"]
          when "SubscriptionConfirmation" then confirm_subscription(message)
          when "Notification"             then SesEventJob.perform_later(message["Message"].to_s)
          end
          head :ok
        rescue JSON::ParserError
          head :bad_request
        end

        private

        def trusted?(raw, message)
          expected_topic = ENV["SES_SNS_TOPIC_ARN"].presence
          return false if expected_topic && message["TopicArn"] != expected_topic

          Aws::SNS::MessageVerifier.new.authentic?(raw)
        rescue StandardError => e
          Rails.logger.warn("[Webhooks::Ses] firma no verificable: #{e.class}: #{e.message}")
          false
        end

        def confirm_subscription(message)
          uri = URI.parse(message["SubscribeURL"].to_s)
          return unless uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(/\Asns\.[a-z0-9-]+\.amazonaws\.com\z/)

          Net::HTTP.get_response(uri)
          Rails.logger.info("[Webhooks::Ses] suscripción SNS confirmada: #{message['TopicArn']}")
        end
      end
    end
  end
end
