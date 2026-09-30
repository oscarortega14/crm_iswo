# frozen_string_literal: true

module WhatsApp
  # ==========================================================================
  # WhatsApp::ConversationEraser — borra mensajes de WhatsApp del CRM (no del
  # celular del cliente). Lo usan «Eliminar conversación» de la bandeja y el
  # borrado desde la ficha de la oportunidad.
  # ==========================================================================
  # Los mensajes de campañas están enlazados a su destinatario
  # (whatsapp_campaign_recipients.whatsapp_message_id, FK): antes de borrarlos
  # se guarda el fallo en el destinatario (para que el resultado de la campaña
  # siga contando como fallido) y se suelta el enlace; si no, el borrado
  # rompía por la FK. Igual con el «mensaje al autorizar» (confirm_reply_message_id).
  # ==========================================================================
  class ConversationEraser
    def self.call(messages)
      new(messages).call
    end

    def initialize(messages)
      @messages = messages
    end

    # @return [Integer] mensajes borrados
    def call
      ids = @messages.pluck(:id)
      return 0 if ids.empty?

      ActiveRecord::Base.transaction do
        failed = WhatsappMessage.where(id: ids, status: "failed").pluck(:id, :error_message).to_h
        WhatsappCampaignRecipient.where(whatsapp_message_id: failed.keys).find_each do |recipient|
          recipient.update_columns(status: "failed", skip_reason: failed[recipient.whatsapp_message_id].to_s.truncate(300).presence)
        end
        WhatsappCampaignRecipient.where(whatsapp_message_id: ids).update_all(whatsapp_message_id: nil)
        WhatsappCampaignRecipient.where(confirm_reply_message_id: ids).update_all(confirm_reply_message_id: nil)
        WhatsappMessage.where(id: ids).delete_all
      end
    end
  end
end
