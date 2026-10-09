# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::Tools — acciones que el asistente puede ejecutar en el CRM
  # ==========================================================================
  # Cada herramienta se describe para OpenAI (DEFINITIONS) y se ejecuta con
  # #call(name, args). En modo prueba (dry_run, pantalla «Probar asistente»)
  # no se toca nada: solo se describe lo que se habría hecho.
  #
  # Fase 1: calificar_lead, guardar_datos_contacto, pasar_a_asesor.
  # Fase 2 (si la agenda está activa, AiAgent::Scheduler): consultar_disponibilidad,
  # agendar_cita, reprogramar_cita, cancelar_cita.
  # ==========================================================================
  class Tools
    TEMPERATURES = %w[cold warm hot].freeze
    CONTACT_FIELDS = {
      "nombre" => :first_name, "apellido" => :last_name, "correo" => :email,
      "empresa" => :company_name, "cargo" => :job_title, "ciudad" => :city
    }.freeze

    DEFINITIONS = [
      {
        type: "function",
        function: {
          name: "calificar_lead",
          description: "Registra en el CRM qué tan interesado está el cliente y lo que se sabe de él. Úsala " \
                       "cuando aprendas algo nuevo de su necesidad, urgencia, presupuesto o poder de decisión.",
          parameters: {
            type: "object",
            properties: {
              temperatura: { type: "string", enum: TEMPERATURES,
                             description: "cold = solo curiosidad; warm = interesado sin urgencia; " \
                                          "hot = necesidad clara y quiere avanzar pronto" },
              resumen: { type: "string", description: "Una o dos frases con lo que necesita el cliente" },
              necesidad: { type: "string" },
              urgencia: { type: "string" },
              presupuesto: { type: "string" },
              decisor: { type: "string", description: "Si es quien decide o quién decide" }
            },
            required: %w[temperatura resumen]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "guardar_datos_contacto",
          description: "Guarda en el CRM datos que el cliente te dio (nombre, correo, empresa…). Solo datos " \
                       "que el cliente escribió explícitamente.",
          parameters: {
            type: "object",
            properties: CONTACT_FIELDS.keys.index_with { { type: "string" } }
          }
        }
      },
      {
        type: "function",
        function: {
          name: "pasar_a_asesor",
          description: "Pasa la conversación a una persona del equipo y deja de responder en este chat. " \
                       "Úsala según las reglas de derivación, o si el cliente quiere agendar una reunión.",
          parameters: {
            type: "object",
            properties: {
              motivo: { type: "string", description: "Por qué se pasa a un asesor, en una frase" }
            },
            required: %w[motivo]
          }
        }
      }
    ].freeze

    CALENDAR_DEFINITIONS = [
      {
        type: "function",
        function: {
          name: "consultar_disponibilidad",
          description: "Devuelve los próximos horarios libres para una reunión. Úsala antes de proponer horarios; " \
                       "nunca inventes horarios.",
          parameters: {
            type: "object",
            properties: {
              desde: { type: "string", description: "Fecha desde la que buscar (AAAA-MM-DD), si el cliente pidió un día" }
            }
          }
        }
      },
      {
        type: "function",
        function: {
          name: "agendar_cita",
          description: "Agenda la reunión cuando el cliente ya eligió un horario. El inicio debe ser uno de los que " \
                       "devolvió consultar_disponibilidad en este mismo turno: si no lo tienes, vuelve a consultarla " \
                       "primero (con «desde» = el día elegido).",
          parameters: {
            type: "object",
            properties: {
              inicio: { type: "string", description: "Inicio exacto, tal como lo devolvió consultar_disponibilidad (ISO 8601)" },
              motivo: { type: "string", description: "Tema de la reunión en una frase" }
            },
            required: %w[inicio]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "reprogramar_cita",
          description: "Mueve la próxima cita del cliente a otro horario libre (de consultar_disponibilidad).",
          parameters: {
            type: "object",
            properties: { nuevo_inicio: { type: "string", description: "Nuevo inicio exacto (ISO 8601)" } },
            required: %w[nuevo_inicio]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "cancelar_cita",
          description: "Cancela la próxima cita del cliente, solo si él lo pide explícitamente.",
          parameters: { type: "object", properties: {} }
        }
      }
    ].freeze

    attr_reader :handoff

    def initialize(contact:, opportunity:, dry_run: false, scheduler: nil)
      @contact     = contact
      @opportunity = opportunity
      @dry_run     = dry_run
      @scheduler   = scheduler
      @handoff     = false
    end

    def definitions = @scheduler ? DEFINITIONS + CALENDAR_DEFINITIONS : DEFINITIONS

    # @return [String] resultado para el modelo (texto corto)
    def call(name, args)
      case name
      when "calificar_lead"         then qualify(args)
      when "guardar_datos_contacto" then save_contact(args)
      when "pasar_a_asesor"         then hand_off(args)
      when "consultar_disponibilidad" then availability(args)
      when "agendar_cita"           then book(args)
      when "reprogramar_cita"       then reschedule(args)
      when "cancelar_cita"          then cancel
      else "Herramienta desconocida: #{name}"
      end
    rescue Scheduler::Unavailable => e
      "#{e.message} Consulta de nuevo la disponibilidad y ofrece otros horarios."
    rescue GoogleCalendar::Error => e
      Rails.logger.warn("[AiAgent::Tools] #{name}: #{e.message}")
      "La agenda no está disponible en este momento. Ofrece que un asesor confirme la reunión (pasar_a_asesor)."
    rescue StandardError => e
      Rails.logger.warn("[AiAgent::Tools] #{name}: #{e.class}: #{e.message}")
      "No se pudo completar: #{e.message.truncate(120)}"
    end

    private

    def qualify(args)
      temperature = args["temperatura"].to_s
      return "Temperatura inválida" unless TEMPERATURES.include?(temperature)
      return "Calificado como #{temperature} (prueba)" if @dry_run
      return "Sin oportunidad abierta para calificar" unless ensure_opportunity!

      previous = @opportunity.temperature
      # La calificación del asistente manda sobre el recálculo por reglas (BANT).
      @opportunity.preserve_temperature_on_bant_recalc = true
      @opportunity.update!(temperature: temperature, last_activity_at: Time.current)
      @opportunity.opportunity_logs.create!(
        tenant: @opportunity.tenant, action: "classify",
        changes_data: LogSanitizer.redact(
          { temperature: temperature, source: "ai_agent", resumen: args["resumen"],
            necesidad: args["necesidad"], urgencia: args["urgencia"], presupuesto: args["presupuesto"],
            decisor: args["decisor"] }.compact
        )
      )
      notify_hot_lead(args["resumen"]) if temperature == "hot" && previous != "hot"
      "Calificado como #{temperature}"
    end

    def save_contact(args)
      @placeholder_name = @contact.first_name == Contacts::Merger::WHATSAPP_PLACEHOLDER
      changes = CONTACT_FIELDS.each_with_object({}) do |(key, field), acc|
        value = args[key].to_s.strip
        next if value.blank?
        next if field == :email && !value.match?(URI::MailTo::EMAIL_REGEXP)
        next unless replaceable?(field)

        acc[field] = value
      end
      return "Nada nuevo que guardar" if changes.empty?
      return "Datos guardados (prueba): #{changes.keys.join(', ')}" if @dry_run

      @contact.update!(changes)
      "Datos guardados: #{changes.keys.join(', ')}"
    end

    # No se pisan datos que ya existen, salvo el nombre provisional de WhatsApp.
    def replaceable?(field)
      current = @contact.public_send(field)
      return true if current.blank?

      # Nombre provisional de WhatsApp («Contacto» + dígitos): se reemplaza completo.
      %i[first_name last_name].include?(field) && @placeholder_name
    end

    def hand_off(args)
      @handoff = true
      return "Conversación pasada a un asesor (prueba)" if @dry_run

      @contact.update_columns(whatsapp_automation_paused_at: Time.current, updated_at: Time.current)
      notify_team(
        kind: "ai_agent_handoff",
        title: "#{@contact.display_name} necesita un asesor",
        body: "El asistente IA pasó la conversación: #{args['motivo'].to_s.truncate(160)}"
      )
      "Conversación pasada a un asesor. No vuelvas a responder en este chat."
    end

    # ---- Agenda --------------------------------------------------------------

    def availability(args)
      return "La agenda no está configurada." unless @scheduler

      from = (Date.parse(args["desde"].to_s) rescue nil)
      from = @scheduler.start_of_day(from) if from
      slots = @scheduler.available_slots(from: from)
      return "No hay horarios libres en los próximos días. Ofrece que un asesor confirme la reunión." if slots.empty?

      "Horarios libres (ofrece 2 o 3, no todos):\n" +
        slots.map { |s| "- #{@scheduler.label(s)} → inicio: #{s.iso8601}" }.join("\n")
    end

    def book(args)
      return "La agenda no está configurada." unless @scheduler
      return "Ya tiene una cita el #{@scheduler.label(upcoming.starts_at)}; usa reprogramar_cita si quiere cambiarla." if upcoming
      return "Cita agendada (prueba) para #{args['inicio']}" if @dry_run

      ensure_opportunity!
      appointment = @scheduler.book!(contact: @contact, opportunity: @opportunity, starts_at: args["inicio"],
                                     reason: args["motivo"])
      "Cita agendada: #{@scheduler.label(appointment.starts_at)}. Confírmale al cliente la fecha y hora."
    end

    def reschedule(args)
      return "La agenda no está configurada." unless @scheduler
      return "El cliente no tiene citas próximas." unless upcoming
      return "Cita reprogramada (prueba) para #{args['nuevo_inicio']}" if @dry_run

      appointment = @scheduler.reschedule!(upcoming, args["nuevo_inicio"])
      "Cita reprogramada: #{@scheduler.label(appointment.starts_at)}."
    end

    def cancel
      return "La agenda no está configurada." unless @scheduler
      return "El cliente no tiene citas próximas." unless upcoming
      return "Cita cancelada (prueba)" if @dry_run

      @scheduler.cancel!(upcoming)
      "Cita cancelada. Pregúntale si quiere agendar en otro momento."
    end

    def upcoming
      return nil if @contact.new_record?

      @upcoming ||= @contact.appointments.upcoming.first
    end

    # Un contacto nuevo de WhatsApp no tiene oportunidad: al calificarlo o
    # agendarle, el asistente la abre (pipeline por defecto, fuente WhatsApp) a
    # nombre del dueño del contacto o del «asesor por defecto» del asistente.
    def ensure_opportunity!
      return @opportunity if @opportunity

      tenant = @contact.tenant
      owner = @contact.owner_user || tenant.ai_agent_config.default_owner
      return nil unless owner

      source = tenant.lead_sources.active.find_by(kind: "whatsapp")
      @opportunity = Contacts::ProspectOpportunityCreator.call(contact: @contact, actor: owner, origin: "ai_agent",
                                                               lead_source: source)
      @opportunity ||= @contact.opportunities.kept.open.order(last_activity_at: :desc).first
    end

    def notify_hot_lead(summary)
      notify_team(
        kind: "ai_agent_hot_lead",
        title: "Lead caliente: #{@contact.display_name}",
        body: summary.to_s.truncate(200).presence || "El asistente IA lo calificó como caliente."
      )
    end

    # Al dueño (oportunidad o contacto); si no hay, a admin y manager.
    def notify_team(kind:, title:, body:)
      owner = @opportunity&.owner_user || @contact.owner_user
      users = owner ? [ owner ] : @contact.tenant.users.where(role: %w[admin manager]).to_a
      users.each do |user|
        Notification.create!(tenant: @contact.tenant, user: user, kind: kind, title: title, body: body,
                             resource: @contact)
      end
    end
  end
end
