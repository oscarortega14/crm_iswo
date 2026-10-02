# frozen_string_literal: true

# ============================================================================
# WebhookEnqueue — encola WebhookProcessorJob sin tumbar la respuesta HTTP.
# ============================================================================
# Si falla al encolar, los proveedores (Meta, Google) reciben 200 OK
# para evitar reintentos infinitos; el fallo queda en log.
#
# `inline: true` usa perform_now (recomendado para WhatsApp inbound en local:
# no depende de Solid Queue para que el mensaje aparezca en el hilo).
# ============================================================================
module WebhookEnqueue
  extend ActiveSupport::Concern

  private

  def enqueue_webhook_processor(kind, payload, inline: false)
    return unless defined?(WebhookProcessorJob)

    if inline
      WebhookProcessorJob.perform_now(kind, payload)
    else
      WebhookProcessorJob.perform_later(kind, payload)
    end
  rescue StandardError => e
    Rails.logger.error(
      "[WebhookProcessorJob] Encolado fallido kind=#{kind}: #{e.class}: #{e.message}"
    )
  end
end
