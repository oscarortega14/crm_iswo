# frozen_string_literal: true

# ============================================================================
# WhatsappReadReceiptJob — envía el «visto» a WhatsApp cuando alguien del CRM
# abre la conversación (ver WhatsappConversationsController#mark_read).
# ============================================================================
# Se manda solo para el mensaje entrante más reciente: Meta marca como leídos
# también los anteriores. Best effort: si Meta rechaza (p. ej. mensaje de hace
# más de 30 días) solo se registra en el log; nunca afecta la bandeja.
# ============================================================================
class WhatsappReadReceiptJob < ApplicationJob
  queue_as :integrations

  retry_on Faraday::Error, wait: :polynomially_longer, attempts: 3

  def perform(message_id)
    # without_tenant: el job no conoce el tenant a priori (RLS, igual que
    # WhatsappDeliveryJob); el envío corre dentro del tenant del mensaje.
    msg = ActsAsTenant.without_tenant { WhatsappMessage.find_by(id: message_id) }
    return unless msg&.direction_in? && msg.provider_message_id.present?

    klass = WhatsApp::MessageSender::ADAPTERS[msg.provider]&.safe_constantize
    return unless klass

    ActsAsTenant.with_tenant(msg.tenant) do
      klass.new(tenant: msg.tenant).mark_read(msg.provider_message_id)
    end
  end
end
