# frozen_string_literal: true

module Exports
  # ==========================================================================
  # Exports::Columns — columnas legibles de las exportaciones (CSV/XLSX).
  # ==========================================================================
  # Antes se volcaban los atributos crudos de la tabla en orden alfabético:
  # salían el celular y la cédula cifrados (`*_ciphertext`), índices ciegos,
  # ids internos y sin el origen del lead. Ahora cada recurso tiene columnas en
  # español, con los mismos datos de la plantilla de importación (Nombres,
  # Apellidos, Cédula o NIT, Celular, Correo, Origen del lead) + contexto.
  # ==========================================================================
  module Columns
    ORIGIN_KIND_LABELS = {
      "manual" => "Creado en el CRM", "import" => "Importación", "web" => "Landing", "meta" => "Meta Ads",
      "google" => "Google Ads", "whatsapp" => "WhatsApp", "blog" => "Blog", "referral" => "Referido"
    }.freeze

    STATUS_LABELS = {
      "new_lead" => "Nuevo", "contacted" => "Contactado", "qualified" => "Calificado", "proposal" => "Propuesta",
      "negotiation" => "Negociación", "won" => "Ganada", "lost" => "Perdida", "merged" => "Fusionada"
    }.freeze

    TEMPERATURE_LABELS = { "cold" => "Frío", "warm" => "Tibio", "hot" => "Caliente" }.freeze

    module_function

    # @return [Array<[String, Proc]>] [encabezado, ->(record) { valor }]
    def for(resource)
      case resource.to_s
      when "contacts"      then contact_columns
      when "opportunities" then opportunity_columns
      else raise ArgumentError, "Recurso no soportado: #{resource}"
      end
    end

    # Asociaciones a precargar para no hacer N+1 al recorrer el scope.
    def preload(resource)
      case resource.to_s
      when "contacts"      then { opportunities: :lead_source }
      when "opportunities" then [ :lead_source, :pipeline, :pipeline_stage, :owner_user, :contact ]
      else []
      end
    end

    def contact_columns
      person_columns(->(c) { c }) + [
        [ "Historial de orígenes", ->(c) { origins_text(c) } ],
        [ "Ciudad",                ->(c) { c.city } ],
        [ "Creado",                ->(c) { fmt_time(c.created_at) } ]
      ]
    end

    def opportunity_columns
      [ [ "Oportunidad", ->(o) { o.title } ] ] +
        person_columns(->(o) { o.contact }, origin: ->(o) { o.lead_source&.name.presence || contact_origin(o.contact) }) + [
          [ "Pipeline",       ->(o) { o.pipeline&.name } ],
          [ "Etapa",          ->(o) { o.pipeline_stage&.name } ],
          [ "Estado",         ->(o) { STATUS_LABELS.fetch(o.status.to_s, o.status) } ],
          [ "Valor estimado", ->(o) { o.estimated_value&.to_f } ],
          [ "Moneda",         ->(o) { o.currency } ],
          [ "Temperatura",    ->(o) { TEMPERATURE_LABELS.fetch(o.temperature.to_s, o.temperature) } ],
          [ "Puntaje BANT",   ->(o) { o.bant_score } ],
          [ "Asesor",         ->(o) { o.owner_user&.name } ],
          [ "Creada",         ->(o) { fmt_time(o.created_at) } ],
          [ "Última actividad", ->(o) { fmt_time(o.last_activity_at) } ]
        ]
    end

    # Las 6 columnas de la plantilla de importación (+ Tipo): una exportación de
    # contactos se puede volver a importar tal cual.
    def person_columns(contact_of, origin: ->(r) { contact_origin(contact_of.call(r)) })
      [
        [ "Nombres",         ->(r) { first_names(contact_of.call(r)) } ],
        [ "Apellidos",       ->(r) { contact_of.call(r)&.then { |c| c.kind_company? ? nil : c.last_name } } ],
        [ "Tipo",            ->(r) { contact_of.call(r)&.then { |c| c.kind_company? ? "Empresa" : "Persona natural" } } ],
        [ "Cédula o NIT",    ->(r) { contact_of.call(r)&.document_id_safe } ],
        [ "Celular",         ->(r) { contact_of.call(r)&.phone_e164_safe } ],
        [ "Correo",          ->(r) { contact_of.call(r)&.email } ],
        [ "Origen del lead", origin ]
      ]
    end

    def first_names(contact)
      return nil unless contact

      contact.kind_company? ? (contact.company_name.presence || contact.first_name) : contact.first_name
    end

    # Fuente del lead del contacto: la de su oportunidad más reciente; si no
    # tiene, el primer origen registrado («Importación · Excel: base.xlsx»).
    def contact_origin(contact)
      return nil unless contact

      latest = contact.opportunities.max_by { |o| o.created_at || Time.zone.at(0) }
      latest&.lead_source&.name.presence || origin_label(Array(contact.origins).first) || contact.source_label
    end

    def origins_text(contact)
      Array(contact.origins).filter_map { |o| origin_label(o) }.uniq.join(" | ").presence
    end

    def origin_label(origin)
      return nil if origin.blank?

      kind  = ORIGIN_KIND_LABELS.fetch(origin["kind"].to_s, origin["kind"].to_s)
      label = origin["label"].to_s
      label.blank? || label == "inbound" ? kind : "#{kind} · #{label}"
    end

    def fmt_time(time)
      time&.in_time_zone&.strftime("%Y-%m-%d %H:%M")
    end
  end
end
