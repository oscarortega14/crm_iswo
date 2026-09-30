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

    attr_reader :handoff

    def initialize(contact:, opportunity:, dry_run: false)
      @contact     = contact
      @opportunity = opportunity
      @dry_run     = dry_run
      @handoff     = false
    end

    def definitions = DEFINITIONS

    # @return [String] resultado para el modelo (texto corto)
    def call(name, args)
      case name
      when "calificar_lead"         then qualify(args)
      when "guardar_datos_contacto" then save_contact(args)
      when "pasar_a_asesor"         then hand_off(args)
      else "Herramienta desconocida: #{name}"
      end
    rescue StandardError => e
      Rails.logger.warn("[AiAgent::Tools] #{name}: #{e.class}: #{e.message}")
      "No se pudo completar: #{e.message.truncate(120)}"
    end

    private

    def qualify(args)
      temperature = args["temperatura"].to_s
      return "Temperatura inválida" unless TEMPERATURES.include?(temperature)
      return "Calificado como #{temperature} (prueba)" if @dry_run
      return "Sin oportunidad abierta para calificar" unless @opportunity

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
