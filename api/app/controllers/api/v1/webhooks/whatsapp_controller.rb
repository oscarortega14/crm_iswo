# frozen_string_literal: true

module Api
  module V1
    module Webhooks
      # ========================================================================
      # Webhooks::WhatsappController — Meta Cloud API
      # ========================================================================
      #   - Cloud: GET verify + POST JSON (X-Hub-Signature-256)
      #
      # Cada mensaje entrante se encola en WebhookProcessorJob, que:
      #   1. resuelve el tenant por el número destino (to_number)
      #   2. busca/crea Contact
      #   3. persiste el WhatsappMessage con direction="in"
      #   4. dispara notificaciones (reminders, asignación automática, etc.)
      # ========================================================================
      class WhatsappController < BaseController
        include WebhookEnqueue
        include WebhookJsonPayload

        skip_before_action :authenticate_user!,            raise: false
        skip_before_action :verify_user_belongs_to_tenant, raise: false
        skip_before_action :resolve_tenant!,               raise: false
        skip_around_action :scope_to_tenant,               raise: false

        before_action :verify_cloud_signature!, only: :cloud

        # GET /api/v1/webhooks/whatsapp/cloud (verify)
        def verify_cloud
          if ActiveSupport::SecurityUtils.secure_compare(params["hub.verify_token"].to_s, ENV["WHATSAPP_CLOUD_VERIFY_TOKEN"].to_s)
            render plain: params["hub.challenge"], status: :ok
          else
            head :forbidden
          end
        end

        # POST /api/v1/webhooks/whatsapp/cloud
        def cloud
          payload = parsed_webhook_payload
          return head :bad_request if payload == WebhookJsonPayload::INVALID_JSON_BODY

          enqueue_webhook_processor(
            "whatsapp_cloud",
            payload.merge("received_at" => Time.current.iso8601),
            inline: true
          )
          head :ok
        end

        private

        def verify_cloud_signature!
          secret = ENV["META_APP_SECRET"].to_s
          return head :forbidden if secret.blank? && Rails.env.production?
          return if secret.blank?

          signature = request.headers["X-Hub-Signature-256"].to_s
          expected  = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)
          head :forbidden unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        end
      end
    end
  end
end
