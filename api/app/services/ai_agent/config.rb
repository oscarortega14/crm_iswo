# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::Config — configuración del asistente IA de WhatsApp por tenant
  # ==========================================================================
  # Vive en tenant.settings["ai_agent"] y la edita el admin en
  # Ajustes → Asistente IA:
  #   enabled          — responde automáticamente por WhatsApp
  #   assistant_name   — cómo se presenta («Sofía, asistente de ISWO»)
  #   business_info    — servicios, precios, proceso, horarios, ubicación…
  #   faq              — preguntas frecuentes con su respuesta
  #   tone             — cómo debe escribir
  #   qualification    — qué debe averiguar para calificar al lead
  #   handoff_rules    — cuándo pasarle la conversación a una persona
  # ==========================================================================
  class Config
    TEXT_FIELDS = %w[assistant_name business_info faq tone qualification handoff_rules].freeze
    MAX_LENGTH  = 12_000

    DEFAULTS = {
      "tone"          => "Cercano y profesional, en español, con frases cortas como en WhatsApp. " \
                         "Máximo un emoji por mensaje.",
      "qualification" => "Qué necesita, para cuándo lo necesita, tamaño de la empresa, si ya tiene " \
                         "presupuesto y si es quien toma la decisión.",
      "handoff_rules" => "Pasa la conversación a un asesor si el cliente lo pide, si está molesto, si " \
                         "pide una cotización formal o un descuento, o si pregunta algo que no está en " \
                         "la información del negocio."
    }.freeze

    attr_reader :tenant

    def initialize(tenant)
      @tenant = tenant
    end

    def raw = (tenant.settings || {})["ai_agent"] || {}

    def enabled? = ActiveModel::Type::Boolean.new.cast(raw["enabled"]) == true

    # Puede responder de verdad: activado, con información del negocio y clave de OpenAI.
    def active? = enabled? && business_info.present? && OpenaiClient.configured?

    def assistant_name = raw["assistant_name"].presence || "Asistente de #{tenant.name}"
    def business_info  = raw["business_info"].to_s.strip
    def faq            = raw["faq"].to_s.strip
    def tone           = raw["tone"].presence || DEFAULTS["tone"]
    def qualification  = raw["qualification"].presence || DEFAULTS["qualification"]
    def handoff_rules  = raw["handoff_rules"].presence || DEFAULTS["handoff_rules"]

    def update!(attrs)
      attrs = attrs.to_h.stringify_keys
      next_config = raw.dup
      next_config["enabled"] = ActiveModel::Type::Boolean.new.cast(attrs["enabled"]) == true if attrs.key?("enabled")
      TEXT_FIELDS.each do |field|
        next unless attrs.key?(field)

        value = attrs[field].to_s.strip
        raise ArgumentError, "El campo «#{field}» es demasiado largo." if value.length > MAX_LENGTH

        next_config[field] = value
      end
      if next_config["enabled"] && next_config["business_info"].to_s.strip.blank?
        raise ArgumentError, "Para activar el asistente primero escribe la información del negocio."
      end

      tenant.update!(settings: (tenant.settings || {}).merge("ai_agent" => next_config))
    end

    HUMAN_CHAT_WINDOW = 7.days

    # Chats con WhatsApp donde el asistente no responde porque un asesor los atiende.
    def paused_chats
      chat_contacts.where.not(whatsapp_automation_paused_at: nil)
    end

    # Chats donde una persona del equipo escribió en los últimos días.
    def human_chats(since: HUMAN_CHAT_WINDOW.ago)
      tenant.contacts.kept.where(
        id: tenant.whatsapp_messages.direction_out.where(automated: false, created_at: since..).select(:contact_id)
      )
    end

    # Pausa (paused: true) o reanuda el asistente en bloque. Devuelve cuántos chats cambió.
    def set_paused!(scope, paused:)
      target = paused ? scope.where(whatsapp_automation_paused_at: nil) : scope.where.not(whatsapp_automation_paused_at: nil)
      target.update_all(whatsapp_automation_paused_at: paused ? Time.current : nil, updated_at: Time.current)
    end

    def chat_contacts
      tenant.contacts.kept.where(id: tenant.whatsapp_messages.select(:contact_id))
    end

    def as_json(*)
      {
        "enabled" => enabled?, "active" => active?, "assistant_name" => assistant_name,
        "business_info" => business_info, "faq" => faq, "tone" => tone, "qualification" => qualification,
        "handoff_rules" => handoff_rules, "openai_configured" => OpenaiClient.configured?,
        "model" => OpenaiClient.model_name, "defaults" => DEFAULTS,
        "paused_chats" => paused_chats.count, "human_chats" => human_chats.count
      }
    end
  end
end
