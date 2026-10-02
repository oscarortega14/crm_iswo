# frozen_string_literal: true

module Opportunities
  # ============================================================================
  # TemperatureContext — dossier completo del lead para clasificación de temperatura.
  # Alimenta el prompt de Claude y la UI («datos analizados»).
  # ============================================================================
  class TemperatureContext
    Signal = Struct.new(:group, :label, :value, keyword_init: true)

    SKIP_OPP_CUSTOM_KEYS = %w[bant_data landing_submission].freeze
    UTM_KEYS = %w[utm_source utm_medium utm_campaign utm_term utm_content].freeze
    # Datos de contacto e identificación: no aportan a la temperatura y no deben
    # salir hacia la API de Anthropic (ISO A.8.11). Se filtran también en el
    # formulario de landing y en campos personalizados, por clave.
    PII_KEY_PATTERN = /e-?mail|correo|phone|tel[eé]fono|celular|m[oó]vil|whatsapp|document|c[eé]dula|\bdni\b/i

    def initialize(opportunity)
      @opp = opportunity
      @contact = opportunity.contact
      @tenant = opportunity.tenant
    end

    def signals
      @signals ||= build_signals.compact.reject { |s| s.value.blank? }
    end

    def prompt_text
      lines = build_prompt_lines
      lines << "Señales estructuradas (#{signals.size} campos con valor):"
      signals.each { |s| lines << "- [#{s.group}] #{s.label}: #{s.value}" }
      lines.join("\n")
    end

    def data_considered
      signals.map { |s| { group: s.group, label: s.label, value: s.value } }
    end

    private

    def build_signals
      out = []
      out.concat(contact_signals)
      out.concat(opportunity_signals)
      out.concat(bant_signals)
      out.concat(custom_field_signals(:opportunity, @opp.custom_fields, SKIP_OPP_CUSTOM_KEYS))
      out.concat(custom_field_signals(:contact, @contact&.custom_fields))
      out.concat(landing_signals)
      out.concat(activity_signals)
      out
    end

    def contact_signals
      return [] unless @contact

      c = @contact
      [
        signal("Contacto", "Nombre", c.display_name),
        signal("Contacto", "Tipo", c.kind),
        signal("Contacto", "Empresa", c.company_name),
        signal("Contacto", "Cargo", c.job_title),
        signal("Contacto", "Ciudad", c.city),
        signal("Contacto", "País", c.country),
        signal("Contacto", "Origen contacto", c.has_attribute?(:source_label) ? c[:source_label] : nil),
        signal("Contacto", "Notas", c.notes&.truncate(300)),
        signal("Contacto", "Propietario", c.owner_user&.name)
      ]
    end

    def opportunity_signals
      [
        signal("Oportunidad", "Título", @opp.title),
        signal("Oportunidad", "Estado CRM", @opp.status),
        signal("Oportunidad", "Etapa", @opp.pipeline_stage&.name),
        signal("Oportunidad", "Probabilidad etapa", @opp.pipeline_stage&.probability&.then { |p| "#{p}%" }),
        signal("Oportunidad", "Calificada BANT", @opp.qualified? ? "Sí" : "No"),
        signal("Oportunidad", "Valor estimado", format_money(@opp.estimated_value, @opp.currency)),
        signal("Oportunidad", "Origen lead", @opp.lead_source&.name),
        signal("Oportunidad", "Consultor asignado", @opp.owner_user&.name),
        signal("Oportunidad", "Temperatura actual", @opp.temperature),
        signal("Oportunidad", "Notas", @opp.notes&.truncate(400)),
        signal("Oportunidad", "Cierre estimado", @opp.expected_close_date&.strftime("%d/%m/%Y")),
        signal("Oportunidad", "Antigüedad", age_days_label),
        signal("Oportunidad", "Recordatorios pendientes", pending_reminders_label)
      ]
    end

    def bant_signals
      bant = (@opp.bant_data || {}).with_indifferent_access
      out = [signal("BANT", "Puntuación total", "#{@opp.bant_score}/100")]

      %i[budget authority need timeline].each do |dim|
        section = bant[dim]
        next unless section.is_a?(Hash)

        section = section.with_indifferent_access
        score = section[:score].to_i
        parts = []
        parts << "score #{score}/100" if score.positive?
        %w[amount role intent days answer].each do |k|
          v = section[k]
          parts << "#{k}=#{v}" if v.present?
        end
        label = dim.to_s.capitalize
        out << signal("BANT", label, parts.join(", ").presence || (score.positive? ? "#{score}/100" : nil))
      end

      out
    end

    def custom_field_signals(entity, fields, skip_keys = [])
      return [] if fields.blank?

      labels = field_labels_for(entity)
      fields.stringify_keys.except(*skip_keys).filter_map do |key, raw|
        next if raw.nil? || raw.to_s.strip.blank?
        next if pii_key?(key) || pii_key?(labels[key])

        signal("Campos", labels[key] || key.humanize, format_custom_value(raw))
      end
    end

    def landing_signals
      cf = (@opp.custom_fields || {}).with_indifferent_access
      out = []
      %w[landing_title landing_slug landing_page_id].each do |k|
        v = cf[k]
        out << signal("Landing", k.humanize, v) if v.present?
      end

      submission = cf[:landing_submission]
      if submission.is_a?(Hash)
        payload = submission["payload"] || submission[:payload]
        if payload.is_a?(Hash)
          payload.each do |k, v|
            next if UTM_KEYS.include?(k.to_s) || pii_key?(k)
            next if v.nil? || v.to_s.strip.blank?

            out << signal("Formulario landing", k.humanize, v.to_s.truncate(200))
          end
        end
      end

      out
    end

    def activity_signals
      days =
        if @opp.last_activity_at
          ((Time.current - @opp.last_activity_at) / 86_400).round
        end

      logs = @opp.opportunity_logs.order(created_at: :desc).limit(8).map do |log|
        "#{log.action} (#{log.created_at&.strftime('%d/%m')})"
      end

      [
        signal("Actividad", "Días sin actividad", days.nil? ? "sin registro" : days.to_s),
        signal("Actividad", "Última actividad", @opp.last_activity_at&.strftime("%d/%m/%Y %H:%M")),
        signal("Actividad", "Historial reciente", logs.join(" · ").presence)
      ]
    end

    def build_prompt_lines
      [
        "Dossier del lead — usa TODOS los campos con valor para clasificar temperatura.",
        "Prioriza campos del negocio, formulario landing y BANT sobre suposiciones.",
        ""
      ]
    end

    def field_labels_for(entity)
      @field_labels ||= {}
      @field_labels[entity] ||= TenantFieldDefinition
                                .where(tenant_id: @tenant.id, entity: entity, active: true)
                                .pluck(:key, :label)
                                .to_h
    end

    def pending_reminders_label
      n = @opp.reminders.where(status: "pending").count
      n.positive? ? n.to_s : nil
    end

    def age_days_label
      days = ((Time.current - @opp.created_at) / 86_400).floor
      "#{days} días"
    end

    def format_money(amount, currency)
      return nil if amount.blank? || amount.to_f.zero?

      "#{amount.to_f.round} #{currency}"
    end

    def format_custom_value(raw)
      case raw
      when true  then "Sí"
      when false then "No"
      when Hash, Array then raw.to_json.truncate(200)
      else raw.to_s.truncate(200)
      end
    end

    def pii_key?(key)
      key.to_s.match?(PII_KEY_PATTERN)
    end

    def signal(group, label, value)
      text = value.to_s.strip
      return nil if text.blank?

      Signal.new(group: group, label: label, value: text)
    end
  end
end
