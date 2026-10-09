# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::AppointmentReplies — respuesta del cliente a un recordatorio
  # ==========================================================================
  # Solo actúa si el contacto tiene una cita próxima (72 h) sin confirmar a la
  # que ya se le envió un recordatorio. Conservador como WhatsApp::ConsentReply:
  # solo respuestas cortas y completas.
  #   «Confirmo», «Sí», «Ok», «Ahí estaré»… → confirma la cita, le agradece y
  #   avisa al asesor.
  #   «Reprogramar», «No puedo», «Cancelar»… → si el asistente IA está activo,
  #   lo atiende él (tiene reprogramar_cita / cancelar_cita); si no, avisa al
  #   asesor para que lo haga.
  # ==========================================================================
  class AppointmentReplies
    CONFIRM = [
      "confirmo", "confirmado", "confirmada", "si confirmo", "si", "ok", "okey", "listo", "perfecto", "de acuerdo",
      "ahi estare", "alli estare", "nos vemos", "claro", "si claro", "confirmo asistencia", "asistire"
    ].to_set.freeze
    RESCHEDULE = [
      "reprogramar", "reagendar", "cambiar", "no puedo", "cancelar", "cancelo", "no podre", "otro horario",
      "otra hora", "otro dia", "cambiar la cita", "cambiar hora"
    ].to_set.freeze
    WINDOW = 72.hours

    def self.pending_for(contact)
      return nil if contact.nil? || contact.new_record?

      contact.appointments.upcoming.where(starts_at: ..WINDOW.from_now, confirmed_at: nil)
             .where.not(client_reminders: {}).first
    end

    def self.normalize(text)
      I18n.transliterate(text.to_s.downcase).gsub(/[^a-z\s]/, " ").squeeze(" ").strip
    end

    def self.call(message:) = new(message).call

    def initialize(message)
      @message = message
      @contact = message.contact
      @tenant  = message.tenant
    end

    # @return [Symbol, nil] :confirmed, :reschedule_to_agent, :reschedule_to_staff o nil (no aplica)
    def call
      appointment = self.class.pending_for(@contact)
      return nil unless appointment

      text = self.class.normalize(@message.body)
      if CONFIRM.include?(text)
        confirm!(appointment)
      elsif RESCHEDULE.include?(text) || RESCHEDULE.any? { |w| text.start_with?("#{w} ") }
        @tenant.ai_agent_config.active? ? :reschedule_to_agent : ask_staff!(appointment)
      end
    end

    private

    def confirm!(appointment)
      appointment.update!(confirmed_at: Time.current)
      scheduler = Scheduler.new(@tenant)
      name = @contact.kind_company? ? @contact.company_name : @contact.first_name
      name = nil if name == Contacts::Merger::WHATSAPP_PLACEHOLDER
      WhatsApp::OutboundSender.call(
        tenant: @tenant, contact: @contact, opportunity: appointment.opportunity, to_number: @message.from_number,
        body: Scheduler.sentence("¡Gracias por confirmar#{", #{name}" if name.present?}! Te esperamos el " \
                                 "#{scheduler.label(appointment.starts_at)}"),
        provider: @message.provider, automated: true
      )
      notify(appointment, "#{@contact.display_name} confirmó su cita", scheduler.label(appointment.starts_at))
      :confirmed
    end

    def ask_staff!(appointment)
      notify(appointment, "#{@contact.display_name} pidió reprogramar su cita",
             "Respondió «#{@message.body.to_s.truncate(80)}» al recordatorio. Escríbele para acordar otro horario.")
      :reschedule_to_staff
    end

    def notify(appointment, title, body)
      users = appointment.owner_user ? [ appointment.owner_user ] : @tenant.users.where(role: %w[admin manager]).to_a
      users.each do |user|
        Notification.create!(tenant: @tenant, user: user, kind: "appointment", title: title, body: body,
                             resource: @contact)
      end
    end
  end
end
