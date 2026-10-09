# frozen_string_literal: true

module Ads
  # ==========================================================================
  # Ads::ConnectionTester — valida que las credenciales de una AdIntegration
  # funcionan contra el proveedor correspondiente.
  # ==========================================================================
  # Hace un request mínimo (listar cuentas o `me`) al API de cada proveedor:
  #   - meta_ads:  GET graph.facebook.com/v18.0/me?access_token=…
  #   - google_ads: requiere refresh_token válido → POST oauth2/token (refresh)
  #   - whatsapp_cloud: GET graph.facebook.com/{v}/me?access_token=… (detecta OAuth 190)
  #
  # `test` devuelve Result con mensaje seguro para UI (sin secretos).
  # `call` se mantiene por compatibilidad (solo true/false).
  # ==========================================================================
  class ConnectionTester
    TIMEOUT_SECONDS = 10

    Result = Struct.new(:ok, :message, keyword_init: true) do
      def success?
        ok
      end
    end

    def initialize(integration)
      @integration = integration
      @creds       = integration.credentials || {}
    end

    def call
      test.success?
    end

    def test
      case @integration.provider
      when "meta"            then test_meta
      when "google"          then test_google
      when "whatsapp_cloud"
        test_whatsapp_cloud
      when "openwa"
        test_openwa
      else
        Rails.logger.warn("ConnectionTester: provider '#{@integration.provider}' sin implementar, stub OK")
        Result.new(ok: true, message: nil)
      end
    rescue StandardError => e
      Rails.logger.warn("ConnectionTester failed [#{@integration.provider}]: #{e.class} #{e.message}")
      Result.new(ok: false, message: "Error inesperado al probar la conexión. Revisa los logs del servidor.")
    end

    # =========================================================================

    private

    def test_meta
      token = @creds["access_token"] || @creds[:access_token]
      return fail_result("Falta access_token en las credenciales de Meta.") if token.blank?

      conn = Faraday.new(url: "https://graph.facebook.com") do |f|
        f.request  :url_encoded
        f.response :json
        f.options.timeout      = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      res = conn.get("/v18.0/me", { access_token: token })
      if res.success? && res.body.is_a?(Hash) && res.body["id"].present?
        Result.new(ok: true, message: nil)
      else
        detail = res.body.is_a?(Hash) ? res.body.dig("error", "message") : res.body.to_s
        Rails.logger.warn("ConnectionTester meta: #{res.status} #{detail}")
        fail_result("Meta rechazó el token (Graph API). Renueva el access token en la app de Meta.")
      end
    end

    def scrub(val)
      s = val.to_s.strip
      s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'").presence
    end

    def scrub_whatsapp_cloud_token(val)
      s = val.to_s.gsub(/[\r\n]/, "").strip
      s = s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
      s = s.sub(/\Abearer\s+/i, "").strip if s.match?(/\Abearer\s+/i)
      s.presence
    end

    # Valida que el access_token sea OAuth parseable (evita 190 al enviar mensajes).
    def test_whatsapp_cloud
      creds = @creds.stringify_keys
      token = scrub_whatsapp_cloud_token(creds["access_token"])
      return fail_result("Falta access_token en las credenciales de WhatsApp Cloud.") if token.blank?

      api_version = ENV["WHATSAPP_CLOUD_API_VERSION"].to_s.strip
      api_version =
        if api_version.blank?
          "v18.0"
        else
          api_version.start_with?("v") ? api_version : "v#{api_version.delete_prefix('v')}"
        end

      conn = Faraday.new(url: "https://graph.facebook.com") do |f|
        f.request  :url_encoded
        f.response :json
        f.options.timeout      = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      res = conn.get("/#{api_version}/me", { access_token: token })
      if res.success? && res.body.is_a?(Hash) && res.body["id"].present?
        Result.new(ok: true, message: nil)
      else
        err    = res.body.is_a?(Hash) ? res.body["error"] : {}
        detail = err["message"] || res.body.to_s
        code   = err["code"]
        hint =
          if code.to_i == 190
            "Token OAuth inválido (190): en Meta Business Suite → Configuración → Usuarios → Usuarios del sistema " \
              "genera un token para esta app con permisos whatsapp_business_messaging (no uses App Secret ni el texto «Bearer » dentro del campo)."
          else
            "Meta rechazó el token en Graph API /me: #{detail}#{" (code #{code})" if code}"
          end
        Rails.logger.warn("ConnectionTester whatsapp_cloud: #{res.status} #{detail}")
        fail_result(hint)
      end
    end

    def test_google
      refresh = @creds["refresh_token"] || @creds[:refresh_token]
      return fail_result("Falta refresh_token en las credenciales de Google Ads.") if refresh.blank?

      client_id     = ENV["GOOGLE_ADS_CLIENT_ID"].to_s.strip
      client_secret = ENV["GOOGLE_ADS_CLIENT_SECRET"].to_s.strip
      if client_id.blank? || client_secret.blank?
        return fail_result(
          "En el servidor del API deben estar definidas las variables GOOGLE_ADS_CLIENT_ID y " \
          "GOOGLE_ADS_CLIENT_SECRET (OAuth de la consola Google Cloud). Copia .env.example y reinicia el proceso."
        )
      end

      conn = Faraday.new(url: "https://oauth2.googleapis.com") do |f|
        f.request  :url_encoded
        f.response :json
        f.options.timeout      = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      res = conn.post("/token", {
        client_id:     client_id,
        client_secret: client_secret,
        refresh_token: refresh,
        grant_type:    "refresh_token"
      })

      if res.success? && res.body.is_a?(Hash) && res.body["access_token"].present?
        Result.new(ok: true, message: nil)
      else
        err = res.body.is_a?(Hash) ? res.body["error"] : nil
        desc = res.body.is_a?(Hash) ? res.body["error_description"] : res.body.to_s
        Rails.logger.warn("ConnectionTester google: #{res.status} #{err} #{desc}")
        hint =
          case err
          when "invalid_grant"
            "Google rechazó el refresh_token (revocado o expirado). Vuelve a autorizar la cuenta OAuth."
          when "invalid_client"
            "GOOGLE_ADS_CLIENT_ID o GOOGLE_ADS_CLIENT_SECRET no coinciden con el proyecto OAuth."
          else
            "No se pudo obtener access_token de Google (#{err.presence || res.status}). Revisa OAuth y el refresh token."
          end
        fail_result(hint)
      end
    end

    # GET {url}/api/sessions/{session_id} — verifica URL, API key y que la sesión existe.
    # OpenWA devuelve 200 + JSON con el estado de la sesión cuando las credenciales son válidas.
    # Test en dos pasos:
    #   1. GET /api/sessions  → valida URL + API key y detecta la sesión en la lista
    #   2. Si ese endpoint no existe (404), intenta GET / como health-check mínimo
    # Ambos pasos se hacen con el header X-API-Key.
    def test_openwa
      creds      = @creds.stringify_keys
      url        = creds["url"].to_s.strip.chomp("/")
      api_key    = creds["api_key"].to_s.strip
      session_id = (@integration.account_identifier.to_s.strip.presence ||
                    creds["session_id"].to_s.strip).presence

      return fail_result("Falta la URL del servidor OpenWA en las credenciales.") if url.blank?
      return fail_result("Falta la API Key de OpenWA en las credenciales.")       if api_key.blank?
      return fail_result("Falta el Session ID de OpenWA. Escríbelo en el campo «Session ID» de la integración.") if session_id.blank?

      conn = Faraday.new(url: url) do |f|
        f.response :json, content_type: /\bjson$/
        f.options.timeout      = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      res = conn.get("/api/sessions") { |req| req.headers["X-API-Key"] = api_key }

      case res.status
      when 200
        openwa_check_session_in_list(res.body, session_id)
      when 401, 403
        fail_result("OpenWA rechazó la API Key. Verifica la clave en el panel de OpenWA.")
      when 404
        # El endpoint /api/sessions no existe en esta versión; intentamos un health-check mínimo.
        openwa_fallback_health(conn, api_key, url)
      else
        detail = openwa_error_detail(res.body)
        Rails.logger.warn("ConnectionTester openwa: GET /api/sessions → HTTP #{res.status} — #{detail}")
        fail_result("OpenWA respondió HTTP #{res.status}. Comprueba la URL y que el servidor esté en línea.")
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      Rails.logger.warn("ConnectionTester openwa: #{e.class} #{e.message}")
      fail_result("No se pudo conectar al servidor OpenWA (#{url}). Verifica que el servidor esté en línea y la URL sea correcta.")
    end

    # Busca session_id en la lista que devuelve GET /api/sessions.
    # Acepta Array de strings, Array de hashes con campo id/sessionId/name, o Hash indexado.
    def openwa_check_session_in_list(body, session_id)
      ids =
        case body
        when Array
          body.filter_map do |item|
            case item
            when String then item
            when Hash   then item["id"] || item["sessionId"] || item["name"] || item["session"]
            end
          end
        when Hash
          # Algunas versiones devuelven { sessions: [...] } o { data: [...] }
          inner = body["sessions"] || body["data"] || body.values.first
          return openwa_check_session_in_list(inner, session_id) if inner.is_a?(Array)
          body.keys
        else
          []
        end

      if ids.map(&:to_s).include?(session_id.to_s)
        Result.new(ok: true, message: nil)
      else
        Rails.logger.info("ConnectionTester openwa: sesiones disponibles: #{ids.inspect}")
        if ids.empty?
          fail_result(
            "El servidor OpenWA no tiene sesiones activas. " \
            "Inicia la sesión «#{session_id}» escaneando el código QR en el panel de OpenWA."
          )
        else
          fail_result(
            "Session «#{session_id}» no encontrada. " \
            "Sesiones disponibles: #{ids.map(&:to_s).join(', ')}. " \
            "Verifica el Session ID en la integración."
          )
        end
      end
    end

    # Health-check mínimo cuando /api/sessions devuelve 404 (versión de OpenWA sin ese endpoint).
    # Si el servidor responde cualquier HTTP (incluso 404 en /) con la API key correcta, damos OK.
    def openwa_fallback_health(conn, api_key, url)
      res = conn.get("/") { |req| req.headers["X-API-Key"] = api_key }
      case res.status
      when 401, 403
        fail_result("OpenWA rechazó la API Key. Verifica la clave en el panel de OpenWA.")
      else
        # El servidor responde → URL y API key parecen correctas.
        # No podemos verificar la sesión con esta versión de OpenWA.
        Rails.logger.info("ConnectionTester openwa: fallback health OK (HTTP #{res.status}) — #{url}")
        Result.new(ok: true, message: nil)
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError
      fail_result("No se pudo conectar al servidor OpenWA (#{url}).")
    end

    def openwa_error_detail(body)
      return "respuesta no JSON" unless body.is_a?(Hash)

      (body["message"] || body["error"] || body.to_s).to_s.truncate(200)
    end

    def fail_result(message)
      Result.new(ok: false, message: message)
    end
  end
end
