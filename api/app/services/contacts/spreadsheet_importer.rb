# frozen_string_literal: true

require "csv"
require "roo"

module Contacts
  # ==========================================================================
  # Importación masiva desde CSV UTF-8 o Excel (.xlsx / .xls).
  # Columnas reconocidas (cabeceras case-insensitive; alias en español):
  #   first_name / nombre, last_name / apellido,
  #   full_name / nombre_y_apellido / nombre completo  → se parte en first/last
  #   email / correo / correo electronico,
  #   phone / telefono / celular / movil,
  #   company / empresa / cliente / razon_social,
  #   position / cargo, city / ciudad, country / pais,
  #   document_id / cc / cedula / nit,
  #   kind / tipo (person|company|persona|empresa),
  #   notes / notas / observaciones,
  #   stage / etapa / estado / fase → etapa del pipeline por defecto (nombre
  #     sin distinguir mayúsculas ni tildes; si no existe, primera etapa + aviso)
  # ==========================================================================
  class SpreadsheetImporter
    MAX_ROWS = 2000

    # Columnas de la plantilla oficial (ContactsController#import_template), en orden.
    TEMPLATE_HEADERS = [ "Nombres", "Apellidos", "Cédula o NIT", "Celular (con indicativo)", "Correo", "Origen del lead" ].freeze

    # «Origen del lead» → tipo de LeadSource cuando hay que crear la fuente (palabras sin tildes).
    ORIGIN_KIND_HINTS = {
      "whatsapp" => "whatsapp", "facebook" => "meta", "instagram" => "meta", "meta" => "meta",
      "google" => "google", "landing" => "web", "web" => "web", "pagina" => "web", "sitio" => "web",
      "referido" => "referral", "referencia" => "referral", "recomendado" => "referral"
    }.freeze

    # País por nombre (sin tildes, minúsculas) → ISO 3166-1 alfa-2. También se aceptan códigos de 2 letras.
    COUNTRY_CODES = {
      "colombia" => "CO", "mexico" => "MX", "peru" => "PE", "ecuador" => "EC", "venezuela" => "VE",
      "chile" => "CL", "argentina" => "AR", "panama" => "PA", "costa rica" => "CR", "guatemala" => "GT",
      "honduras" => "HN", "el salvador" => "SV", "nicaragua" => "NI", "bolivia" => "BO", "paraguay" => "PY",
      "uruguay" => "UY", "republica dominicana" => "DO", "puerto rico" => "PR", "cuba" => "CU",
      "brasil" => "BR", "espana" => "ES", "estados unidos" => "US", "eeuu" => "US", "ee.uu." => "US",
      "usa" => "US", "canada" => "CA"
    }.freeze
    DEFAULT_COUNTRY = "CO"

    # warnings: filas importadas con algún ajuste (p.ej. etapa desconocida).
    Result = Struct.new(:created_count, :skipped_count, :errors, :warnings, keyword_init: true) do
      def warnings = self[:warnings] || []
    end

    def initialize(tenant:, user:, io:, filename: nil)
      @tenant = tenant
      @user   = user
      @io     = io
      @filename = filename
    end

    def call
      rows, early = load_rows
      return early if early.is_a?(Result)

      errors = []
      warnings = []
      created_count = 0
      skipped_count = 0

      if rows.size > MAX_ROWS
        return Result.new(
          created_count: 0,
          skipped_count: 0,
          errors: [{ row: 0, message: "Máximo #{MAX_ROWS} filas de datos (excl. cabecera)" }]
        )
      end

      ActsAsTenant.with_tenant(@tenant) do
        rows.each_with_index do |row, idx|
          line_no = idx + 2 # cabecera = 1
          h = normalize_row(row)
          attrs = build_attrs(h, line_no, warnings)
          if attrs.nil?
            skipped_count += 1
            next
          end

          stage = resolve_stage(h["stage"], line_no, warnings)
          lead_source = resolve_lead_source(h["origin"])
          contact = @tenant.contacts.new(attrs.merge(owner_user: @user))
          contact.save!
          contact.record_origin!("import", h["origin"]) if h["origin"].present?
          Contacts::ProspectOpportunityCreator.call(contact: contact, actor: @user, stage: stage,
                                                    origin: "contact_import", lead_source: lead_source)
          created_count += 1
        rescue ActiveRecord::RecordInvalid => e
          errors << { row: line_no, message: e.record.errors.full_messages.join(", ") }
        rescue StandardError => e
          errors << { row: line_no, message: e.message.to_s.truncate(200) }
        end
      end

      Result.new(created_count: created_count, skipped_count: skipped_count, errors: errors, warnings: warnings)
    end

    # Etapas del pipeline por defecto (mismo que usa ProspectOpportunityCreator).
    def self.default_pipeline(tenant)
      tenant.pipelines.find_by(is_default: true) || tenant.pipelines.first
    end

    def self.normalize_stage_name(name)
      I18n.transliterate(name.to_s).downcase.squish
    end

    private

    def default_pipeline
      return @default_pipeline if defined?(@default_pipeline)

      @default_pipeline = self.class.default_pipeline(@tenant)
    end

    def stages_by_name
      @stages_by_name ||= (default_pipeline&.pipeline_stages&.where(discarded_at: nil)&.order(:position) || [])
                          .index_by { |st| self.class.normalize_stage_name(st.name) }
    end

    # nil → primera etapa (la decide ProspectOpportunityCreator).
    def resolve_stage(raw, line_no, warnings)
      return nil if raw.blank?

      stage = stages_by_name[self.class.normalize_stage_name(raw)]
      return stage if stage

      first = stages_by_name.values.first&.name || "la primera etapa"
      warnings << {
        row:     line_no,
        message: "etapa «#{raw}» no existe en «#{default_pipeline&.name}»; quedó en «#{first}»"
      }
      nil
    end

    # @return [Array, Result|nil] rows array or early Result error
    def load_rows
      ext = File.extname(@filename.to_s).downcase
      case ext
      when ".csv", ".txt"
        load_csv
      when ".xlsx", ".xls"
        load_excel
      else
        [
          [],
          Result.new(
            created_count: 0,
            skipped_count: 0,
            errors: [
              {
                row:   0,
                message: "Formato no admitido#{ext.presence ? " (#{ext})" : ""}. Usa Excel (.xlsx) o CSV (.csv)."
              }
            ]
          )
        ]
      end
    end

    def load_csv
      raw = @io.read
      raw = raw.force_encoding("UTF-8")
      raw = raw.encode("UTF-8", invalid: :replace, replace: "")
      raw.sub!(/\A\uFEFF/, "") # BOM

      table = CSV.parse(raw, headers: true)
      unless table.headers&.compact_blank&.any?
        return [
          [],
          Result.new(created_count: 0, skipped_count: 0, errors: [{ row: 1, message: "Archivo sin cabeceras válidas" }])
        ]
      end

      [table.map(&:to_h), nil]
    end

    def load_excel
      path = @io.respond_to?(:path) ? @io.path : nil
      unless path.present?
        return [
          [],
          Result.new(
            created_count: 0,
            skipped_count: 0,
            errors: [{ row: 0, message: "No se pudo leer el archivo temporal para Excel." }]
          )
        ]
      end

      book = Roo::Spreadsheet.open(path)
      sheet = book.sheet(0)
      return [[], nil] unless sheet.last_row&.positive?

      header_row_idx = detect_header_row(sheet)

      if header_row_idx
        # Archivo con cabeceras reconocidas
        headers    = sheet.row(header_row_idx).map { |c| c.nil? ? "" : c.to_s.strip }
        data_start = header_row_idx + 1
      else
        # Sin cabeceras: inferir tipos de columna por los valores
        headers    = infer_column_types(sheet)
        data_start = 1
      end

      unless headers.compact_blank.any?
        return [
          [],
          Result.new(created_count: 0, skipped_count: 0, errors: [{ row: 1, message: "Hoja Excel sin cabeceras válidas" }])
        ]
      end

      rows = []
      (data_start..sheet.last_row).each do |i|
        vals = sheet.row(i)
        row_h = {}
        headers.each_with_index do |h, j|
          row_h[h] = vals[j] if h.present?
        end
        rows << row_h
      end

      [rows, nil]
    end

    KNOWN_IMPORT_KEYS = %w[
      first_name last_name full_name email phone company position
      city country kind notes document_id stage origin
    ].freeze

    # Devuelve el índice (1-based) de la fila con más cabeceras reconocidas.
    # Retorna nil si ninguna fila alcanza score >= 1 (archivo sin cabeceras).
    def detect_header_row(sheet)
      max_check = [sheet.last_row.to_i, 10].min
      best_row  = nil
      best_score = 0

      (1..max_check).each do |i|
        score = sheet.row(i).count do |c|
          key = normalize_header_key(c.to_s)
          KNOWN_IMPORT_KEYS.include?(key)
        end
        if score > best_score
          best_score = score
          best_row   = i
        end
      end

      best_score >= 1 ? best_row : nil
    end

    # Para archivos sin cabecera, detecta el tipo de cada columna muestreando
    # las primeras filas y asigna un nombre de campo reconocido.
    def infer_column_types(sheet)
      sample_count = [sheet.last_row.to_i, 10].min
      samples_by_col = Hash.new { |h, k| h[k] = [] }

      (1..sample_count).each do |i|
        sheet.row(i).each_with_index do |val, col_idx|
          samples_by_col[col_idx] << cell_to_string(val) unless val.nil?
        end
      end

      col_count = (samples_by_col.keys.max || -1) + 1
      assigned  = Array.new(col_count)
      used      = Set.new

      col_count.times do |col_idx|
        samples = samples_by_col[col_idx].reject(&:blank?)
        next if samples.empty?

        type =
          if !used.include?("email") && samples.count { |v| v.include?("@") } > samples.size / 3
            "email"
          elsif !used.include?("full_name") &&
                samples.count { |v| v.match?(/[[:alpha:]]/) && v.include?(" ") } > samples.size / 2
            "full_name"
          elsif !used.include?("phone") &&
                samples.count { |v| v.gsub(/\D/, "").match?(/\A3\d{8,10}\z/) } > samples.size / 3
            "phone"
          elsif !used.include?("document_id") &&
                samples.count { |v| v.gsub(/\D/, "").match?(/\A\d{5,12}\z/) } > samples.size / 2
            "document_id"
          else
            "col_#{col_idx + 1}"
          end

        assigned[col_idx] = type
        used << type unless type.start_with?("col_")
      end

      assigned
    end

    def normalize_row(row)
      h = {}
      if row.is_a?(Hash)
        row.each do |header, val|
          next if header.blank?

          key = normalize_header_key(header)
          h[key] = cell_to_string(val).presence
        end
      else
        row.headers.each do |header|
          next if header.blank?

          key = normalize_header_key(header)
          h[key] = cell_to_string(row[header]).presence
        end
      end
      h.compact
    end

    # Convierte un valor de celda Excel a String, manejando tipos especiales de Roo.
    def cell_to_string(val)
      return "" if val.nil?
      # Roo::Link (hipervínculo) — usar el texto visible, no el href
      return val.text.to_s.strip if val.respond_to?(:text)
      # Float que representa un entero (evita "3164068553.0")
      return val.to_i.to_s if val.is_a?(Float) && val == val.to_i
      val.to_s.strip
    end

    def normalize_header_key(header)
      # [[:space:]] captura espacios unicode (non-breaking space, etc.) que \s no captura
      s = header.to_s.gsub(/[[:space:]]+/, " ").strip.downcase
      s = I18n.transliterate(s.sub(/\s*\(.*\)\s*\z/, "")).strip
      case s
      when "nombre", "first_name", "firstname", "nombres" then "first_name"
      when "apellido", "last_name", "lastname", "apellidos" then "last_name"
      when "nombre y apellido", "nombre_y_apellido", "nombre completo",
           "nombre_completo", "full_name", "fullname", "nombre y apellidos" then "full_name"
      when "email", "correo", "e-mail", "correo electronico",
           "correo electrónico", "correo_electronico" then "email"
      when "telefono", "teléfono", "phone", "tel", "movil",
           "móvil", "celular", "cel" then "phone"
      when "empresa", "company", "company_name", "razon_social",
           "razón_social", "cliente", "razon social", "razón social" then "company"
      when "cargo", "position", "job_title", "puesto" then "position"
      when "ciudad", "city" then "city"
      when "pais", "país", "country" then "country"
      when "tipo", "kind", "clase" then "kind"
      when "notas", "notes", "observaciones", "observacion",
           "observación" then "notes"
      when "cc", "cedula", "cédula", "nit", "documento", "cedula o nit", "cc o nit", "cc/nit",
           "cedula/nit", "numero de documento", "document_id", "identificacion", "identificación" then "document_id"
      when "origen", "origen del lead", "fuente", "fuente del lead", "origen o fuente",
           "origen o fuente del lead", "lead source", "source" then "origin"
      when "etapa", "stage", "estado", "fase", "etapa del pipeline",
           "etapa_pipeline", "pipeline_stage" then "stage"
      else
        s.gsub(/\s+/, "_")
      end
    end

    def build_attrs(h, line_no = nil, warnings = [])
      return nil if h.values.all?(&:blank?)

      # Partir "NOMBRE Y APELLIDO" en first_name + last_name si vienen juntos
      if h["full_name"].present? && h["first_name"].blank?
        parts = h["full_name"].strip.split(/\s+/, 2)
        h["first_name"] = parts[0]
        h["last_name"]  = parts[1]
      end

      document = Contacts::DocumentId.classify(h["document_id"])
      kind = infer_kind(h, document)

      src =
        if (@filename.to_s.downcase.end_with?(".xlsx", ".xls"))
          @filename.present? ? "Excel: #{File.basename(@filename)}" : "Excel import"
        else
          @filename.present? ? "CSV: #{File.basename(@filename)}" : "CSV import"
        end

      # País: nombre («Colombia») o código («CO»); si no viene, se toma del indicativo
      # del celular; si tampoco, Colombia.
      country_hint = resolve_country(h["country"])
      phone, phone_country = safe_phone(h["phone"], country_hint || DEFAULT_COUNTRY)
      country = country_hint || phone_country || DEFAULT_COUNTRY

      if h["country"].present? && country_hint.nil?
        warnings << { row: line_no, message: "país «#{h['country']}» no reconocido; se usó #{country}" }
      end
      if h["phone"].present? && phone.nil?
        warnings << { row: line_no, message: "celular «#{h['phone']}» no es válido (escríbelo con indicativo, ej. +573001234567); se importó sin celular" }
      end

      email = safe_email(h["email"])
      if h["email"].present? && email.nil?
        warnings << { row: line_no, message: "email «#{h['email']}» no es válido; se importó sin email" }
      end

      attrs = {
        email:        email,
        phone_e164:   phone,
        city:         h["city"],
        country:      country,
        notes:        h["notes"],
        document_id:  document&.number,
        source_kind:  "import",
        source_label: src
      }

      if kind == "company"
        attrs[:kind] = "company"
        # Con NIT, «Nombres» (+ «Apellidos») es la razón social.
        attrs[:company_name] = h["company"].presence || [ h["first_name"], h["last_name"] ].compact_blank.join(" ").presence
        attrs[:first_name] = nil
        attrs[:last_name] = nil
        attrs[:job_title] = h["position"].presence
      else
        attrs[:kind] = "person"
        attrs[:first_name] = h["first_name"].presence
        attrs[:last_name] = h["last_name"].presence
        attrs[:company_name] = h["company"].presence
        attrs[:job_title] = h["position"].presence
      end

      attrs.compact
    end

    # Prioridad: columna «Tipo» explícita → Cédula (persona) o NIT (empresa) →
    # solo «Empresa» sin nombre → persona.
    def infer_kind(h, document = nil)
      raw = h["kind"].to_s.downcase.strip
      return "company" if %w[company empresa organizacion organización].include?(raw)
      return "person" if %w[person persona individual contacto].include?(raw)
      return document.kind if document

      return "company" if h["first_name"].blank? && h["last_name"].blank? && h["full_name"].blank? && h["company"].present?

      "person"
    end

    # Normaliza a E.164. Acepta «+573001234567», «+57 300 123 4567» y también el
    # número sin «+» que deja Excel al guardarlo como número (573001234567).
    # @return [Array(String, String), Array(nil, nil)] [e164, país ISO del número]
    def safe_phone(raw, country = DEFAULT_COUNTRY)
      return [ nil, nil ] if raw.blank?

      cleaned = raw.to_s.gsub(/[\s\-\(\)\.]+/, "")
      candidates = [ Phonelib.parse(cleaned, country) ]
      candidates << Phonelib.parse("+#{cleaned}") if !cleaned.start_with?("+") && cleaned.gsub(/\D/, "").length >= 11
      parsed = candidates.find(&:valid?)
      parsed ? [ parsed.e164, parsed.country ] : [ nil, nil ]
    end

    # «Origen del lead» → fuente del tenant (por nombre, sin tildes ni mayúsculas).
    # Si no existe se crea, para que el origen quede en la oportunidad y en los
    # reportes/exportaciones; queda editable en Ajustes → Fuentes de lead.
    def resolve_lead_source(raw)
      name = raw.to_s.squish
      return nil if name.blank?

      @lead_sources ||= @tenant.lead_sources.to_a.index_by { |ls| self.class.normalize_stage_name(ls.name) }
      key = self.class.normalize_stage_name(name)
      @lead_sources[key] ||= @tenant.lead_sources.create!(name: name, kind: lead_source_kind_for(key))
    rescue ActiveRecord::RecordInvalid
      @tenant.lead_sources.where("LOWER(name) = ?", name.downcase).first
    end

    def lead_source_kind_for(normalized)
      ORIGIN_KIND_HINTS.each { |word, kind| return kind if normalized.include?(word) }
      "manual"
    end

    def resolve_country(raw)
      return nil if raw.blank?

      value = raw.to_s.strip
      return value.upcase if value.match?(/\A[A-Za-z]{2}\z/)

      COUNTRY_CODES[I18n.transliterate(value).downcase.squish]
    end

    # Devuelve el email si tiene formato válido; nil en caso contrario.
    def safe_email(raw)
      addr = raw.to_s.strip.downcase.presence
      return nil if addr.nil?

      addr =~ URI::MailTo::EMAIL_REGEXP ? addr : nil
    end
  end
end
