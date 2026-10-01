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
  #
  # Agenda (fase 2, AiAgent::Scheduler) en settings["ai_agent"]["calendar"]:
  #   calendar_id, duration_minutes, work_days (0=domingo…6), start_time,
  #   end_time, min_notice_hours, max_days_ahead, location
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

    CALENDAR_DEFAULTS = {
      "calendar_id" => "", "duration_minutes" => 30, "work_days" => [ 1, 2, 3, 4, 5 ],
      "start_time" => "08:00", "end_time" => "18:00", "min_notice_hours" => 2, "max_days_ahead" => 14,
      "location" => ""
    }.freeze
    TIME_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/

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

    def calendar
      CALENDAR_DEFAULTS.merge((raw["calendar"] || {}).compact)
    end

    # La agenda funciona: hay calendario y cuenta de servicio de Google.
    def calendar_active? = calendar["calendar_id"].present? && GoogleCalendar.configured?

    def update!(attrs)
      attrs = attrs.to_h.stringify_keys
      next_config = raw.dup
      next_config["calendar"] = normalize_calendar(attrs["calendar"]) if attrs.key?("calendar")
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

    def normalize_calendar(input)
      input = (input || {}).to_h.stringify_keys.slice(*CALENDAR_DEFAULTS.keys)
      cal = calendar.merge(input)
      cal["calendar_id"] = cal["calendar_id"].to_s.strip
      cal["location"] = cal["location"].to_s.strip.truncate(300)
      cal["duration_minutes"] = cal["duration_minutes"].to_i.clamp(15, 240)
      cal["min_notice_hours"] = cal["min_notice_hours"].to_i.clamp(0, 168)
      cal["max_days_ahead"] = cal["max_days_ahead"].to_i.clamp(1, 60)
      cal["work_days"] = Array(cal["work_days"]).map(&:to_i).select { |d| d.between?(0, 6) }.uniq.sort
      raise ArgumentError, "Elige al menos un día de atención." if cal["work_days"].empty?
      %w[start_time end_time].each do |k|
        raise ArgumentError, "La hora debe tener formato HH:MM (ej. 08:00)." unless cal[k].to_s.match?(TIME_FORMAT)
      end
      raise ArgumentError, "La hora de cierre debe ser después de la de inicio." if cal["end_time"] <= cal["start_time"]

      cal
    end

    def as_json(*)
      {
        "enabled" => enabled?, "active" => active?, "assistant_name" => assistant_name,
        "business_info" => business_info, "faq" => faq, "tone" => tone, "qualification" => qualification,
        "handoff_rules" => handoff_rules, "openai_configured" => OpenaiClient.configured?,
        "model" => OpenaiClient.model_name, "defaults" => DEFAULTS,
        "paused_chats" => paused_chats.count, "human_chats" => human_chats.count,
        "calendar" => calendar, "calendar_active" => calendar_active?,
        "google_configured" => GoogleCalendar.configured?,
        "service_account_email" => GoogleCalendar.service_account_email
      }
    end
  end
end
