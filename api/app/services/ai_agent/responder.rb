# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::Responder — el asistente IA contesta un chat de WhatsApp
  # ==========================================================================
  # 1. Arma el contexto: instrucciones + información del negocio (AiAgent::
  #    Config), datos del contacto y los últimos mensajes del chat.
  # 2. Llama al modelo (AiAgent::OpenaiClient) con las herramientas del CRM
  #    (AiAgent::Tools); si pide herramientas, las ejecuta y vuelve a llamar
  #    (máx. MAX_ROUNDS).
  # 3. Envía la respuesta por WhatsApp como mensaje automático (texto libre:
  #    siempre contesta a un mensaje reciente del cliente, dentro de las 24 h).
  # 4. Registra todo en AiAgentRun (tokens = costo).
  #
  # Modo prueba (#preview): mismas instrucciones y herramientas simuladas, sin
  # enviar nada ni tocar el CRM — lo usa «Probar asistente».
  # ==========================================================================
  class Responder
    MAX_ROUNDS       = 3
    HISTORY_MESSAGES = 20
    HISTORY_WINDOW   = 7.days
    DAILY_LIMIT      = 40 # respuestas por contacto por día (protege de bucles y costos)
    HANDOFF_FALLBACK = "Gracias por escribirnos. Te va a responder una persona de nuestro equipo en breve."
    # Omisiones esperables (asistente apagado, chat en pausa…) no se registran:
    # solo las que sirven para diagnosticar.
    QUIET_SKIPS = [ "asistente inactivo", "chat en pausa (lo atiende un asesor)", "hay un mensaje más reciente",
                    "sin contacto" ].freeze
    DAYS   = %w[domingo lunes martes miércoles jueves viernes sábado].freeze
    MONTHS = %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre].freeze

    Result = Struct.new(:status, :reply, :tool_calls, :run, keyword_init: true)

    def self.call(message:, client: OpenaiClient.new) = new(tenant: message.tenant, client: client).respond_to(message)

    # messages: [{ "role" => "user"|"assistant", "content" => "…" }] (pantalla de prueba)
    def self.preview(tenant:, messages:, client: OpenaiClient.new)
      new(tenant: tenant, client: client).preview(messages)
    end

    def initialize(tenant:, client:)
      @tenant = tenant
      @config = tenant.ai_agent_config
      @client = client
    end

    def respond_to(message)
      contact = message.contact
      reason = skip_reason(message, contact)
      return log_skip(contact, message, reason) if reason

      opportunity = contact.opportunities.kept.where.not(status: %w[won lost merged])
                           .order(last_activity_at: :desc).first
      tools = Tools.new(contact: contact, opportunity: opportunity)
      messages = [ system_message(contact, opportunity) ] + history(contact)

      reply, calls, usage = converse(messages, tools)
      reply = HANDOFF_FALLBACK if reply.blank? && tools.handoff
      return finish(contact, message, "skipped", calls, usage, error: "respuesta vacía") if reply.blank?

      sent = deliver(message, contact, opportunity, reply)
      finish(contact, message, tools.handoff ? "handoff" : "replied", calls, usage, reply_message: sent)
    rescue OpenaiClient::Error => e
      finish(contact, message, "error", [], {}, error: e.message)
    end

    def preview(conversation)
      contact = @tenant.contacts.new(first_name: "Cliente de prueba")
      tools = Tools.new(contact: contact, opportunity: nil, dry_run: true)
      history = Array(conversation).last(HISTORY_MESSAGES).map do |m|
        { role: m["role"] == "assistant" ? "assistant" : "user", content: m["content"].to_s.truncate(2000) }
      end
      reply, calls, = converse([ system_message(contact, nil) ] + history, tools)
      reply = HANDOFF_FALLBACK if reply.blank? && tools.handoff
      Result.new(status: tools.handoff ? "handoff" : "replied", reply: reply, tool_calls: calls)
    end

    private

    # ---- Cuándo NO responder -------------------------------------------------

    def skip_reason(message, contact)
      return "asistente inactivo" unless @config.active?
      return "sin contacto" if contact.nil? || contact.discarded?
      return "chat en pausa (lo atiende un asesor)" if contact.whatsapp_automation_paused?
      return "el contacto no autorizó WhatsApp" if contact.whatsapp_opted_out?
      return "mensaje sin texto" if message.body.to_s.strip.blank?
      return "hay un mensaje más reciente" if newer_inbound?(message)
      return "límite diario de respuestas" if contact.ai_agent_runs.where(created_at: 24.hours.ago..).count >= DAILY_LIMIT

      nil
    end

    # Ráfagas: el cliente escribe varios mensajes seguidos; se responde una vez, al último.
    def newer_inbound?(message)
      message.contact.whatsapp_messages.direction_in.where("id > ?", message.id).exists?
    end

    # ---- Conversación con el modelo -------------------------------------------

    def converse(messages, tools)
      calls = []
      usage = { input: 0, output: 0, model: nil }
      MAX_ROUNDS.times do
        response = @client.chat(messages: messages, tools: tools.definitions)
        usage[:input] += response.input_tokens
        usage[:output] += response.output_tokens
        usage[:model] = response.model
        return [ response.content.to_s.strip, calls, usage ] if response.tool_calls.empty?

        messages << response.raw_message
        response.tool_calls.each do |tc|
          result = tools.call(tc.name, tc.arguments)
          calls << { "name" => tc.name, "arguments" => tc.arguments, "result" => result }
          messages << { role: "tool", tool_call_id: tc.id, content: result }
        end
      end
      # Se agotaron las rondas pidiendo herramientas: una última sin herramientas.
      response = @client.chat(messages: messages)
      usage[:input] += response.input_tokens
      usage[:output] += response.output_tokens
      [ response.content.to_s.strip, calls, usage ]
    end

    def system_message(contact, opportunity)
      now = Time.current.in_time_zone(@tenant.timezone.presence || "America/Bogota")
      known = {
        "Nombre" => contact.kind_company? ? contact.company_name : contact.first_name,
        "Apellido" => contact.last_name, "Correo" => contact.email, "Empresa" => contact.company_name,
        "Cargo" => contact.job_title, "Ciudad" => contact.city
      }.compact_blank
      known.delete("Nombre") if known["Nombre"] == Contacts::Merger::WHATSAPP_PLACEHOLDER

      content = <<~PROMPT
        Eres #{@config.assistant_name}, y atiendes por WhatsApp a los clientes de #{@tenant.name}.
        Fecha y hora actual: #{spanish_datetime(now)} (hora de #{now.time_zone.name}).

        # Cómo escribir
        #{@config.tone}
        - Mensajes cortos (máximo 3 o 4 líneas). Una sola pregunta a la vez.
        - Nunca inventes precios, fechas, servicios ni datos que no estén en la información del negocio.
          Si no lo sabes, dilo y ofrece que un asesor le confirme (herramienta pasar_a_asesor).
        - No prometas descuentos ni condiciones especiales.
        - Si el cliente pide no recibir más mensajes, despídete amablemente y no insistas.
        - No digas que eres una inteligencia artificial salvo que te lo pregunten; si preguntan, dilo con honestidad.

        # Información del negocio
        #{@config.business_info}
        #{"\n# Preguntas frecuentes\n#{@config.faq}" if @config.faq.present?}

        # Tu objetivo
        Resolver las dudas del cliente y calificarlo. Para calificar, averigua de forma natural (sin
        interrogar): #{@config.qualification}
        Cuando aprendas algo nuevo, usa la herramienta calificar_lead. Si el cliente te da su nombre, correo o
        empresa, guárdalos con guardar_datos_contacto.

        # Cuándo pasar a un asesor
        #{@config.handoff_rules}
        Si el cliente quiere agendar una reunión o visita, pregúntale qué día y hora le queda bien y usa
        pasar_a_asesor indicando esa preferencia, para que un asesor la confirme.
        Al pasar a un asesor, avísale al cliente que una persona del equipo le responderá pronto.

        # Lo que ya sabemos del cliente
        #{known.any? ? known.map { |k, v| "- #{k}: #{v}" }.join("\n") : "- Aún no tenemos sus datos."}
        #{"- Etapa actual en el proceso comercial: #{opportunity.pipeline_stage&.name}" if opportunity}
      PROMPT
      { role: "system", content: content.squeeze("\n").strip }
    end

    def spanish_datetime(time)
      "#{DAYS[time.wday]} #{time.day} de #{MONTHS[time.month - 1]} de #{time.year}, #{time.strftime('%H:%M')}"
    end

    def history(contact)
      contact.whatsapp_messages.where(created_at: HISTORY_WINDOW.ago..).order(created_at: :desc)
             .limit(HISTORY_MESSAGES).to_a.reverse.filter_map do |m|
        text = m.body.presence || (m.message_type_template? ? "[Plantilla enviada: #{m.template_name}]" : nil)
        next if text.blank?

        { role: m.direction_in? ? "user" : "assistant", content: text.truncate(2000) }
      end
    end

    # ---- Envío y registro -----------------------------------------------------

    def deliver(message, contact, opportunity, reply)
      result = WhatsApp::OutboundSender.call(
        tenant: @tenant, contact: contact, opportunity: opportunity, to_number: message.from_number,
        body: reply, provider: message.provider, automated: true
      )
      raise OpenaiClient::Error, "No se pudo enviar por WhatsApp (#{result.error_code})" unless result.success?

      result.message
    end

    def finish(contact, message, status, calls, usage, reply_message: nil, error: nil)
      run = @tenant.ai_agent_runs.create!(
        contact: contact, trigger_message: message, reply_message: reply_message, status: status,
        model: usage[:model], input_tokens: usage[:input].to_i, output_tokens: usage[:output].to_i,
        tool_calls: calls, error: error&.truncate(500)
      )
      Result.new(status: status, reply: reply_message&.body, tool_calls: calls, run: run)
    end

    def log_skip(contact, message, reason)
      return Result.new(status: "skipped", tool_calls: []) if QUIET_SKIPS.include?(reason)

      finish(contact, message, "skipped", [], {}, error: reason)
    end
  end
end
