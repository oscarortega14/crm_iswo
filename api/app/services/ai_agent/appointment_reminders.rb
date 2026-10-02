# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::AppointmentReminders — recordatorios de citas al cliente
  # ==========================================================================
  # Fase 3 del asistente IA. Lo corre AppointmentReminderJob cada 5 minutos.
  #
  # Para cada cita próxima y cada anticipación configurada (p. ej. 24 h y 1 h):
  #   - Si la cita se agendó con menos anticipación que ese recordatorio, se
  #     omite (no tiene sentido «mañana es tu cita» si se agendó hace 2 h).
  #   - WhatsApp: si el cliente escribió en las últimas 24 h → texto libre (sin
  #     costo de plantilla); si no → plantilla aprobada de «recordatorio»
  #     (variables en orden: nombre, fecha y hora, lugar). Sin plantilla y con
  #     la ventana cerrada, no se envía WhatsApp.
  #   - Correo: si está activado y el contacto tiene correo.
  # También envía el mensaje para reagendar cuando se marca «No asistió».
  # ==========================================================================
  class AppointmentReminders
    SERVICE_WINDOW = 23.hours
    LOOKAHEAD      = 49.hours

    def self.dispatch_due!(tenant) = new(tenant).dispatch_due!

    def initialize(tenant)
      @tenant    = tenant
      @config    = tenant.ai_agent_config
      @settings  = @config.reminders
      @scheduler = Scheduler.new(tenant)
    end

    # @return [Integer] recordatorios enviados
    def dispatch_due!
      offsets = Array(@settings["client_offsets"]).map(&:to_i)
      return 0 if offsets.empty?

      sent = 0
      @tenant.appointments.status_scheduled.where(starts_at: Time.current..LOOKAHEAD.from_now)
             .includes(:contact, opportunity: :owner_user).find_each do |appointment|
        offsets.each do |hours|
          key = hours.to_s
          next if appointment.client_reminders[key].present?
          next if Time.current < appointment.starts_at - hours.hours

          if appointment.created_at > appointment.starts_at - hours.hours
            record!(appointment, key, "skipped" => "agendada con menos anticipación")
          else
            record!(appointment, key, deliver_reminder(appointment, hours))
            sent += 1
          end
        end
      end
      sent
    end

    # Mensaje para reagendar a quien no asistió.
    def send_no_show_followup!(appointment)
      return unless @settings["no_show_followup"]
      return if appointment.no_show_followup_at.present?

      contact = appointment.contact
      name = first_name(contact)
      text = "Hola #{name}, te esperábamos en la reunión con #{@tenant.name} y no pudimos conectarnos. " \
             "¿Quieres que agendemos otro horario? Responde este mensaje y te ayudamos."
      whatsapp = send_whatsapp(appointment, text, @config.reminder_template("no_show_template_id"),
                               [ name, @scheduler.label(appointment.starts_at), @tenant.name ])
      email = send_email(appointment, :no_show)
      appointment.update!(no_show_followup_at: Time.current) if whatsapp || email
    end

    private

    def deliver_reminder(appointment, hours)
      contact = appointment.contact
      when_text = @scheduler.label(appointment.starts_at)
      location = @config.calendar["location"].presence
      text = [
        Scheduler.sentence("Hola #{first_name(contact)}, te recordamos tu reunión con #{@tenant.name} " \
                           "#{hours <= 2 ? "hoy, #{when_text}" : "el #{when_text}"}"),
        ("Lugar / enlace: #{location}" if location),
        ("¿Nos confirmas tu asistencia? Responde *CONFIRMO* o *REPROGRAMAR*." unless appointment.confirmed_at)
      ].compact.join("\n")

      message = send_whatsapp(appointment, text, @config.reminder_template,
                              [ first_name(contact), when_text, location || @tenant.name ])
      emailed = send_email(appointment, :reminder)
      { "at" => Time.current.iso8601, "whatsapp_message_id" => message&.id, "email" => emailed }.compact
    end

    # Texto libre si la ventana de 24 h está abierta; si no, la plantilla.
    def send_whatsapp(appointment, text, template, values)
      contact = appointment.contact
      phone = contact.phone_e164_safe.presence || contact.phone_normalized_legacy
      return nil if phone.blank? || contact.whatsapp_opted_out?

      if window_open?(contact)
        result = WhatsApp::OutboundSender.call(tenant: @tenant, contact: contact, opportunity: appointment.opportunity,
                                               to_number: phone, body: text, provider: last_provider(contact),
                                               automated: true)
      elsif template && approved?(template)
        params = values.first(template.variable_count).map { |v| v.to_s.presence || "-" }
        result = WhatsApp::OutboundSender.call(tenant: @tenant, contact: contact, opportunity: appointment.opportunity,
                                               to_number: phone, body: nil, whatsapp_template_id: template.id,
                                               template_params: params, provider: "whatsapp_cloud", automated: true)
      else
        return nil
      end
      result.success? ? result.message : nil
    end

    def send_email(appointment, kind)
      return false unless @settings["email_enabled"]
      return false if appointment.contact.email.blank?

      AppointmentMailer.with(appointment: appointment, tenant: @tenant).public_send(kind).deliver_later
      true
    end

    def window_open?(contact)
      contact.whatsapp_messages.direction_in.where(created_at: SERVICE_WINDOW.ago..).exists?
    end

    def last_provider(contact)
      contact.whatsapp_messages.direction_in.order(created_at: :desc).pick(:provider)
    end

    def approved?(template)
      status = template.meta_status.to_s.upcase
      status.blank? || status == "APPROVED"
    end

    def first_name(contact)
      name = contact.kind_company? ? contact.company_name : contact.first_name
      name = nil if name == Contacts::Merger::WHATSAPP_PLACEHOLDER
      name.presence || "cliente"
    end

    def record!(appointment, key, data)
      appointment.update_columns(client_reminders: appointment.client_reminders.merge(key => data),
                                 updated_at: Time.current)
    end
  end
end
