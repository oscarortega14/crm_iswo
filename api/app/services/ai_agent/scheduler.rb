# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::Scheduler — agenda del asistente IA sobre Google Calendar
  # ==========================================================================
  # - available_slots: horarios libres según los días y horas de atención,
  #   la duración de la reunión, la anticipación mínima y lo ocupado en el
  #   Google Calendar (freeBusy) y en las citas del CRM.
  # - book!: vuelve a comprobar que el horario siga libre, crea el evento en
  #   Google y la cita (Appointment), mueve la oportunidad si alguna etapa
  #   tiene el disparador «se agendó una reunión» y avisa al asesor.
  # - cancel! / reschedule!: sobre la próxima cita del contacto.
  # ==========================================================================
  class Scheduler
    class Unavailable < StandardError; end

    SLOT_STEP = 30.minutes

    def initialize(tenant, calendar_client: nil)
      @tenant = tenant
      @config = tenant.ai_agent_config.calendar
      @zone   = ActiveSupport::TimeZone[tenant.timezone.presence || "America/Bogota"] || Time.zone
      @client = calendar_client
    end

    def duration = @config["duration_minutes"].to_i.minutes

    def start_of_day(date) = @zone.parse(date.to_s)

    # @return [Array<Time>] inicios libres (hora del tenant), máx. `limit`
    def available_slots(from: nil, limit: 8)
      earliest = [ Time.current + @config["min_notice_hours"].to_i.hours, from || Time.current ].max
      latest   = (@zone.now + @config["max_days_ahead"].to_i.days).end_of_day
      return [] if earliest >= latest

      busy = busy_ranges(earliest, latest)
      slots = []
      candidate_days(earliest, latest).each do |day|
        day_slots(day).each do |start|
          next if start < earliest
          next if busy.any? { |(b_start, b_end)| start < b_end && start + duration > b_start }

          slots << start
          return slots if slots.size >= limit
        end
      end
      slots
    end

    def book!(contact:, opportunity:, starts_at:, reason: nil)
      starts_at = @zone.parse(starts_at.to_s) unless starts_at.is_a?(Time)
      raise Unavailable, "Fecha u hora inválida." unless starts_at
      raise Unavailable, "Ese horario ya no está disponible." unless free?(starts_at)

      ends_at = starts_at + duration
      owner = opportunity&.owner_user || contact.owner_user
      event_id = client.create_event(
        summary: "Reunión #{@tenant.name} – #{contact.display_name}",
        description: event_description(contact, opportunity, reason, owner),
        starts_at: starts_at, ends_at: ends_at, time_zone: @zone.tzinfo.name, location: @config["location"]
      )
      appointment = @tenant.appointments.create!(
        contact: contact, opportunity: opportunity, owner_user: owner, starts_at: starts_at, ends_at: ends_at,
        title: "Reunión #{@tenant.name}", notes: reason, google_event_id: event_id, source: "ai_agent"
      )
      after_booking(appointment)
      appointment
    end

    def reschedule!(appointment, starts_at)
      starts_at = @zone.parse(starts_at.to_s) unless starts_at.is_a?(Time)
      raise Unavailable, "Fecha u hora inválida." unless starts_at
      raise Unavailable, "Ese horario ya no está disponible." unless free?(starts_at, ignore: appointment)

      ends_at = starts_at + duration
      client.move_event(appointment.google_event_id, starts_at: starts_at, ends_at: ends_at,
                                                     time_zone: @zone.tzinfo.name) if appointment.google_event_id
      appointment.update!(starts_at: starts_at, ends_at: ends_at)
      notify(appointment, "Cita reprogramada: #{appointment.contact.display_name}")
      appointment
    end

    def cancel!(appointment)
      client.delete_event(appointment.google_event_id) if appointment.google_event_id
      appointment.update!(status: "canceled", canceled_at: Time.current)
      notify(appointment, "Cita cancelada: #{appointment.contact.display_name}")
      appointment
    end

    # «jueves 2 de octubre, 10:00 a. m.»
    def label(time)
      t = time.in_time_zone(@zone)
      hour = t.strftime("%-I:%M")
      suffix = t.hour < 12 ? "a. m." : "p. m."
      "#{Responder::DAYS[t.wday]} #{t.day} de #{Responder::MONTHS[t.month - 1]}, #{hour} #{suffix}"
    end

    private

    def client
      @client ||= GoogleCalendar.new(@config["calendar_id"])
    end

    def free?(starts_at, ignore: nil)
      return false if starts_at < Time.current + @config["min_notice_hours"].to_i.hours
      return false unless day_slots(starts_at.in_time_zone(@zone).to_date).any? { |s| s == starts_at }

      busy_ranges(starts_at, starts_at + duration, ignore: ignore).none? do |(b_start, b_end)|
        starts_at < b_end && starts_at + duration > b_start
      end
    end

    def busy_ranges(from, to, ignore: nil)
      crm = @tenant.appointments.overlapping(from, to)
      crm = crm.where.not(id: ignore.id) if ignore
      google = client.busy(from, to)
      # El propio evento de la cita que se reprograma no cuenta como ocupado.
      if ignore
        google = google.reject { |(b_start, b_end)| b_start == ignore.starts_at && b_end == ignore.ends_at }
      end
      google + crm.pluck(:starts_at, :ends_at)
    end

    def candidate_days(from, to)
      (from.in_time_zone(@zone).to_date..to.in_time_zone(@zone).to_date).select do |d|
        @config["work_days"].include?(d.wday)
      end
    end

    def day_slots(date)
      return [] unless @config["work_days"].include?(date.wday)

      open_at  = @zone.parse("#{date} #{@config['start_time']}")
      close_at = @zone.parse("#{date} #{@config['end_time']}")
      slots = []
      t = open_at
      while t + duration <= close_at
        slots << t
        t += SLOT_STEP
      end
      slots
    end

    def event_description(contact, opportunity, reason, owner)
      [
        "Agendada por el asistente IA del CRM.",
        ("Motivo: #{reason}" if reason.present?),
        "Cliente: #{contact.display_name}",
        ("Empresa: #{contact.company_name}" if contact.company_name.present?),
        ("Celular: #{contact.phone_e164_safe}" if contact.phone_e164_safe.present?),
        ("Correo: #{contact.email}" if contact.email.present?),
        ("Asesor: #{owner.name}" if owner),
        ("Etapa: #{opportunity.pipeline_stage&.name}" if opportunity)
      ].compact.join("\n")
    end

    def after_booking(appointment)
      if appointment.opportunity
        Opportunities::StageAutomation.call(opportunity: appointment.opportunity, trigger: "appointment_scheduled")
      end
      notify(appointment, "Nueva cita: #{appointment.contact.display_name}")
    end

    def notify(appointment, title)
      users = appointment.owner_user ? [ appointment.owner_user ] : @tenant.users.where(role: %w[admin manager]).to_a
      body = "#{label(appointment.starts_at)}#{" · #{appointment.notes.truncate(120)}" if appointment.notes.present?}"
      users.each do |user|
        Notification.create!(tenant: @tenant, user: user, kind: "appointment", title: title, body: body,
                             resource: appointment.contact)
      end
    end
  end
end
