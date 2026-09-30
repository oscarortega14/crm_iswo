# frozen_string_literal: true

module Notifications
  # ============================================================================
  # Notifications::WhatsappMessageNotifier
  # ============================================================================
  # Notifica cuando entra un WhatsappMessage (direction: "in"):
  #   - si el contacto/oportunidad tiene dueño → solo a ese consultor.
  #   - si no tiene dueño (lead nuevo, bandeja "sin asignar") → a admin/manager
  #     del tenant, NO a todos los consultores (evita spam de campana por cada
  #     mensaje de un lead que aún nadie atiende; la bandeja compartida ya es
  #     descubrible vía el badge del inbox).
  #
  # Evita duplicar notificación si ya hay una sin leer para el mismo contacto
  # (una ráfaga de varios mensajes seguidos = 1 sola notificación).
  # ============================================================================
  class WhatsappMessageNotifier
    def self.call(message:)
      new(message).call
    end

    def initialize(message)
      @message = message
      @contact = message.contact
    end

    def call
      return unless @contact
      return unless @message.direction_in?

      owner = @message.opportunity&.owner_user || @contact.owner_user
      owner ? notify(owner, title: title_for(assigned: true)) : notify_admins_and_managers
    end

    private

    def notify_admins_and_managers
      @message.tenant.users.where(role: %w[admin manager]).find_each do |user|
        notify(user, title: title_for(assigned: false))
      end
    end

    # Un «Sí» a una campaña se avisa distinto: es un lead listo para atender.
    def confirmation?
      @confirmation = WhatsApp::ConsentReply.classify(@message.body) == :opt_in if @confirmation.nil?
      @confirmation
    end

    def title_for(assigned:)
      return "#{@contact.display_name} autorizó WhatsApp" if confirmation?

      assigned ? "Nuevo mensaje de WhatsApp" : "Mensaje de WhatsApp sin asignar"
    end

    def body_text
      return "Respondió «Sí». Está esperando respuesta: escríbele desde la bandeja." if confirmation?

      "#{@contact.display_name}: #{@message.body.to_s.truncate(120)}"
    end

    def notify(user, title:)
      # Un «Sí» siempre avisa, aunque haya otro aviso sin leer del mismo contacto.
      return if already_unread_for?(user) && !confirmation?

      Notification.create!(
        tenant:   @message.tenant,
        user:     user,
        kind:     "whatsapp_message_received",
        title:    title,
        body:     body_text,
        resource: @contact
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[Notification] whatsapp_message_received contact=#{@contact.id}: #{e.message}"
      )
    end

    def already_unread_for?(user)
      Notification.exists?(
        user: user, resource: @contact,
        kind: "whatsapp_message_received", read_at: nil
      )
    end
  end
end
