# frozen_string_literal: true

# ============================================================================
# WhatsappInboundAutomationJob — automatizaciones ante un mensaje entrante
# ============================================================================
# Se encola unos segundos después del mensaje (DEBOUNCE) para que una ráfaga
# de mensajes seguidos se conteste una sola vez (AiAgent::Responder responde
# solo al último).
#   1. «Sí» a una campaña con «Mensaje al autorizar» → ese mensaje fijo
#      (WhatsApp::ConfirmationFollowup) y nada más.
#   2. Si no, y el asistente IA está activo → responde el asistente.
# ============================================================================
class WhatsappInboundAutomationJob < ApplicationJob
  queue_as :integrations

  DEBOUNCE = 8.seconds

  def perform(message_id)
    message = ActsAsTenant.without_tenant { WhatsappMessage.find_by(id: message_id) }
    return unless message&.contact && message.direction_in?

    ActsAsTenant.with_tenant(message.tenant) do
      if WhatsApp::ConsentReply.classify(message.body) == :opt_in
        return if WhatsApp::ConfirmationFollowup.call(message: message) == :sent
      end

      AiAgent::Responder.call(message: message) if message.tenant.ai_agent_config.enabled?
    end
  end
end
