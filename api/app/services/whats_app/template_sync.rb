# frozen_string_literal: true

module WhatsApp
  # ============================================================================
  # WhatsApp::TemplateSync — trae el estado real de las plantillas desde Meta
  # (Template Management API) y lo refleja en el catálogo local.
  # ============================================================================
  # Motivo: el catálogo (WhatsappTemplate) se registra a mano y no tiene forma
  # de enterarse si algo cambió directo en Meta Business Suite — pasó en
  # producción con una plantilla rechazada como Utility y reaprobada como
  # Marketing sin que el CRM se enterara.
  #
  # Solo LEE de Meta — nunca crea plantillas nuevas ni toca variable_labels/
  # variable_names (esos son elegidos a mano para el mapeo de campañas/chat;
  # sobreescribirlos automáticamente podría romper variable_field_map de
  # campañas ya armadas). Actualiza category/meta_status/meta_template_id de
  # las que ya existen localmente, y reporta (sin persistir) las plantillas
  # que Meta tiene y el CRM no, o que el CRM tiene y Meta ya no.
  #
  # Requiere que el tenant tenga configurado:
  #   - Access token con permiso whatsapp_business_management (además del
  #     whatsapp_business_messaging que ya usa el envío).
  #   - WABA ID en AdIntegration(provider: whatsapp_cloud).metadata["waba_id"].
  # ============================================================================
  class TemplateSync
    BASE_URL        = "https://graph.facebook.com"
    DEFAULT_API_VERSION = "v18.0"
    TIMEOUT_SECONDS  = 15
    MAX_PAGES        = 5

    Result = Struct.new(:ok, :message, :updated, :new_in_meta, :missing_in_meta, keyword_init: true) do
      def success?
        ok
      end
    end

    def self.call(tenant:)
      new(tenant: tenant).call
    end

    def initialize(tenant:)
      @tenant = tenant
    end

    def call
      waba_id, token, api_version = credentials
      return fail_result("Falta el WABA ID — configúralo en Ajustes → Integraciones → WhatsApp Cloud API.") if
        waba_id.blank?
      return fail_result("Falta el access token de WhatsApp Cloud API.") if token.blank?

      remote_templates, error = fetch_all(waba_id, token, api_version)
      return fail_result(error) if error

      reconcile(remote_templates)
    end

    private

    def credentials
      integ = @tenant.preferred_whatsapp_cloud_integration
      token = integ && (integ.credentials || {}).stringify_keys["access_token"]
      waba_id = integ && (integ.metadata || {}).stringify_keys["waba_id"]
      api_version = ENV["WHATSAPP_CLOUD_API_VERSION"].presence || DEFAULT_API_VERSION
      api_version = "v#{api_version.delete_prefix('v')}"
      [waba_id.presence, scrub_token(token), api_version]
    end

    def scrub_token(value)
      s = value.to_s.gsub(/[\r\n]/, "").strip
      s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'").presence
    end

    def fetch_all(waba_id, token, api_version)
      conn = Faraday.new(url: BASE_URL) do |f|
        f.response :json, content_type: /\bjson$/
        f.options.timeout      = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      templates = []
      path = "/#{api_version}/#{waba_id}/message_templates"
      params = { fields: "name,language,status,category,id", limit: 100 }

      MAX_PAGES.times do
        res = conn.get(path) do |req|
          req.headers["Authorization"] = "Bearer #{token}"
          req.params = params if params
        end

        unless res.success?
          return [nil, extract_error(res.body)]
        end

        body = res.body.is_a?(Hash) ? res.body : {}
        templates.concat(Array(body["data"]))

        next_url = body.dig("paging", "next")
        break if next_url.blank?

        # `next_url` ya viene absoluta con todos los query params (incluido
        # access_token si Meta lo agrega) — seguimos a mano en vez de con
        # Faraday#get(path, params) para no duplicar/perder query params.
        uri = URI(next_url)
        path = uri.path
        params = URI.decode_www_form(uri.query.to_s).to_h
      end

      [templates, nil]
    end

    def extract_error(body)
      return "HTTP error consultando Meta" unless body.is_a?(Hash)

      err = body["error"] || {}
      msg = err["message"] || body["message"]
      code = err["code"]
      base = [msg, ("(code #{code})" if code)].compact.join(" ").presence || "respuesta inválida de Meta"
      return base unless code.to_i == 190 || code.to_i == 200

      "#{base} — el token necesita el permiso whatsapp_business_management " \
        "(no solo whatsapp_business_messaging). Genera uno nuevo en Meta Business Suite → " \
        "Usuarios del sistema, y actualízalo en Ajustes → Integraciones."
    end

    def reconcile(remote_templates)
      by_key = @tenant.whatsapp_templates.index_by { |t| [t.meta_template_name, t.language] }
      matched_keys = []
      updated = []

      remote_templates.each do |rt|
        name     = rt["name"]
        language = rt["language"]
        next if name.blank? || language.blank?

        key = [name, language]
        local = by_key[key]
        next unless local

        matched_keys << key
        local.update!(
          category:         rt["category"],
          meta_status:      rt["status"],
          meta_template_id: rt["id"],
          meta_synced_at:   Time.current
        )
        updated << { name: name, language: language, status: rt["status"], category: rt["category"] }
      end

      new_in_meta = remote_templates
                    .reject { |rt| matched_keys.include?([rt["name"], rt["language"]]) }
                    .map { |rt| { name: rt["name"], language: rt["language"], status: rt["status"] } }

      missing_in_meta = (by_key.keys - matched_keys).map { |name, language| { name: name, language: language } }

      Result.new(ok: true, message: nil, updated: updated, new_in_meta: new_in_meta, missing_in_meta: missing_in_meta)
    end

    def fail_result(message)
      Result.new(ok: false, message: message, updated: [], new_in_meta: [], missing_in_meta: [])
    end
  end
end
