# frozen_string_literal: true

module WhatsApp
  module Adapters
    # ==========================================================================
    # WhatsApp::Adapters::Cloud — envío vía WhatsApp Cloud API (Meta).
    # ==========================================================================
    # Endpoint:  https://graph.facebook.com/{version}/{phone_number_id}/messages
    # Auth:      Bearer token (System User access token)
    # Body:      JSON
    #
    # Credenciales (ordenadas por prioridad):
    #   1. tenant.settings["whatsapp"]["cloud_access_token"] / ..._phone_number_id /
    #      ..._api_version
    #   2. integración AdIntegration (provider whatsapp_cloud) — access_token,
    #      account_identifier = phone_number_id
    #   3. ENV: WHATSAPP_CLOUD_ACCESS_TOKEN, WHATSAPP_CLOUD_PHONE_NUMBER_ID,
    #           WHATSAPP_CLOUD_API_VERSION (default v18.0)
    #
    # Para mensajes con media: Meta requiere subir el media primero (/media)
    # o pasar un link público vía `image.link`. Aquí usamos `link` cuando hay
    # `media_url`; subir media binaria queda fuera de este MVP.
    #
    # Respuesta exitosa (200):
    #   {
    #     "messaging_product": "whatsapp",
    #     "messages": [{ "id": "wamid.HBgM..." }]
    #   }
    # ==========================================================================
    class Cloud < Base
      DEFAULT_API_VERSION = "v18.0"
      BASE_URL            = "https://graph.facebook.com"

      def deliver(message)
        token, phone_number_id, api_version = cloud_credentials_and_version

        raise_delivery!("Credenciales WhatsApp Cloud incompletas para tenant #{@tenant.id}") if
          token.blank? || phone_number_id.blank?

        body = build_payload(message)

        conn = Faraday.new(url: BASE_URL) do |f|
          f.request  :json
          f.response :json, content_type: /\bjson$/
          f.options.timeout      = DEFAULT_TIMEOUT
          f.options.open_timeout = DEFAULT_TIMEOUT
        end

        path = "/#{api_version}/#{phone_number_id}/messages"
        res  = conn.post(path) do |req|
          req.headers["Authorization"] = "Bearer #{token}"
          req.headers["Content-Type"]  = "application/json"
          req.body = body
        end

        unless res.success?
          err = extract_error(res.body)
          raise_delivery!("Cloud API: #{err}")
        end

        msg = (res.body["messages"] || []).first || {}
        {
          provider_message_id: msg["id"],
          # Cloud API responde "accepted" en sincrónico; el estado real
          # llega por webhook. Reportamos "sent" para reflejar que el envío
          # fue aceptado por Meta.
          status:              "sent"
        }
      end

      private

      def cloud_credentials_and_version
        token           = scrub_meta_access_token(tenant_setting(:cloud_access_token, "WHATSAPP_CLOUD_ACCESS_TOKEN"))
        phone_number_id = scrub_cloud_phone_number_id(tenant_setting(:cloud_phone_number_id,
                                                                      "WHATSAPP_CLOUD_PHONE_NUMBER_ID"))
        api_version =
          scrub_api_version(tenant_setting(:cloud_api_version, "WHATSAPP_CLOUD_API_VERSION")) || DEFAULT_API_VERSION

        if token.blank? || phone_number_id.blank?
          integ = @tenant.preferred_whatsapp_cloud_integration
          if integ
            creds = (integ.credentials || {}).stringify_keys
            token ||= scrub_meta_access_token(creds["access_token"])
            phone_number_id ||= scrub_cloud_phone_number_id(integ.account_identifier.presence ||
                                                               creds["phone_number_id"])
          end
        end

        [token, phone_number_id, api_version]
      end

      # Evita 190 "Cannot parse access token" por espacios, comillas al pegar desde .env
      # o prefijo "Bearer " duplicado en el header.
      def scrub_meta_access_token(value)
        s = value.to_s.gsub(/[\r\n]/, "").strip
        s = s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        s = s.sub(/\Abearer\s+/i, "").strip if s.match?(/\Abearer\s+/i)
        s.presence
      end

      def scrub_cloud_phone_number_id(value)
        s = value.to_s.gsub(/[\r\n]/, "").strip
        s = s.delete_prefix('"').delete_suffix('"')
        s.gsub(/\s+/, "").presence
      end

      def scrub_api_version(value)
        v = value.to_s.strip
        return if v.blank?

        v.start_with?("v") ? v : "v#{v.delete_prefix('v')}"
      end

      def build_payload(message)
        to = normalize_e164(message.to_number).sub(/\A\+/, "")

        if message.message_type_template?
          {
            messaging_product: "whatsapp",
            recipient_type:    "individual",
            to:                to,
            type:              "template",
            template:          {
              name:       message.template_name,
              language:   { code: message.template_language },
              components: template_components(message.template_params, message.template_variable_names)
            }.compact
          }
        elsif message.media_url.present?
          {
            messaging_product: "whatsapp",
            recipient_type:    "individual",
            to:                to,
            type:              media_type_for(message.media_url),
            media_type_for(message.media_url) => {
              link:    message.media_url,
              caption: message.body.presence
            }.compact
          }
        else
          {
            messaging_product: "whatsapp",
            recipient_type:    "individual",
            to:                to,
            type:              "text",
            text:              { body: message.body.to_s, preview_url: false }
          }
        end
      end

      # Meta migró las plantillas nuevas a variables con nombre
      # (`{{primer_nombre}}`) en vez del formato posicional clásico
      # (`{{1}}`). Si `names[i]` viene presente para un valor, se envía
      # `parameter_name` en ese parámetro; si no, se manda posicional
      # (compatibilidad con plantillas aprobadas antes de este cambio).
      def template_components(params, names = [])
        values = Array(params)
        return nil if values.empty?

        names = Array(names)
        parameters = values.each_with_index.map do |v, i|
          { type: "text", parameter_name: names[i].presence, text: v.to_s }.compact
        end

        [{ type: "body", parameters: parameters }]
      end

      # Heurística mínima por extensión. Para producción conviene apoyarse
      # en el Content-Type real del media.
      def media_type_for(url)
        ext = File.extname(URI(url).path.to_s).downcase.delete(".")
        case ext
        when "jpg", "jpeg", "png", "webp"        then "image"
        when "mp4", "3gp"                        then "video"
        when "mp3", "ogg", "amr", "aac"          then "audio"
        when "pdf", "doc", "docx", "xls", "xlsx" then "document"
        else "document"
        end
      rescue URI::InvalidURIError
        "document"
      end

      def extract_error(body)
        return "HTTP error" unless body.is_a?(Hash)

        err = body["error"] || {}
        msg = err["message"] || err["error_user_msg"] || body["message"]
        code = err["code"] || err["error_subcode"]
        base = [msg, ("(code #{code})" if code)].compact.join(" ").presence || "respuesta inválida"
        return base unless code.to_i == 190

        "#{base} — Genera un token de usuario del sistema en Meta Business Suite (permisos " \
          "whatsapp_business_messaging); no uses App Secret ni pegues «Bearer » en el campo. " \
          "En Ajustes → Integraciones usa «Probar conexión» para validar el token antes de enviar."
      end
    end
  end
end
