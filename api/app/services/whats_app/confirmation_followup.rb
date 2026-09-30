# frozen_string_literal: true

module WhatsApp
  # ==========================================================================
  # WhatsApp::ConfirmationFollowup — responde al «Sí» de una campaña
  # ==========================================================================
  # Cuando un contacto responde «Sí» (WhatsApp::ConsentReply) a una campaña que
  # tiene «Mensaje al autorizar» (WhatsappCampaign#confirm_reply_body), se le
  # envía ese mensaje al instante, sin importar cuánto tardó en autorizar.
  #
  # - Campaña: la más reciente que le llegó en los últimos WINDOW días.
  # - Texto libre: su propia respuesta abre la ventana de 24 h de WhatsApp, así
  #   que no necesita plantilla aprobada. Sale por el mismo canal por el que
  #   escribió.
  # - Una sola vez por destinatario (confirmed_at / confirm_reply_message_id),
  #   aunque diga «Sí» varias veces.
  # - No se envía si un asesor pausó el automático en ese chat.
  # Base del futuro agente IA: el mismo punto de entrada podrá pasarle la
  # conversación al asistente en vez de un texto fijo.
  # ==========================================================================
  class ConfirmationFollowup
    WINDOW = 30.days
    VARIABLE = /\{\{\s*(nombre|apellido|nombre_completo|empresa|asesor)\s*(?:\|([^}]*))?\}\}/i

    def self.call(message:) = new(message).call

    def initialize(message)
      @message = message
      @contact = message.contact
    end

    # @return [Symbol] :sent, :no_campaign, :already_confirmed, :paused, :not_sent
    def call
      recipient = find_recipient
      return :no_campaign unless recipient
      return :already_confirmed if recipient.confirmed_at.present?

      recipient.update!(confirmed_at: @message.created_at || Time.current)
      body = recipient.whatsapp_campaign.confirm_reply_body.to_s.strip
      return :no_campaign if body.blank?
      return :paused if @contact.whatsapp_automation_paused?

      deliver!(recipient, interpolate(body, recipient))
    end

    private

    def find_recipient
      WhatsappCampaignRecipient.joins(:whatsapp_message)
                               .where(contact_id: @contact.id, status: "sent")
                               .where(whatsapp_messages: { created_at: WINDOW.ago.. })
                               .where("whatsapp_messages.created_at <= ?", @message.created_at || Time.current)
                               .order("whatsapp_messages.created_at DESC")
                               .includes(:whatsapp_campaign, opportunity: :owner_user)
                               .first
    end

    def deliver!(recipient, body)
      result = OutboundSender.call(
        tenant:      @message.tenant,
        contact:     @contact,
        opportunity: recipient.opportunity,
        to_number:   @message.from_number,
        body:        body,
        provider:    @message.provider,
        automated:   true
      )
      return :not_sent unless result.success?

      recipient.update!(confirm_reply_message: result.message)
      :sent
    end

    def interpolate(text, recipient)
      values = {
        "nombre"          => @contact.kind_company? ? @contact.company_name : @contact.first_name,
        "apellido"        => @contact.last_name,
        "nombre_completo" => @contact.display_name,
        "empresa"         => @contact.company_name,
        "asesor"          => (recipient.opportunity&.owner_user || @contact.owner_user)&.name
      }
      text.gsub(VARIABLE) { values[Regexp.last_match(1).downcase].presence || Regexp.last_match(2).to_s.strip }
    end
  end
end
