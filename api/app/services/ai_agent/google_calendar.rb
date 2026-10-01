# frozen_string_literal: true

module AiAgent
  # ==========================================================================
  # AiAgent::GoogleCalendar — Google Calendar con una cuenta de servicio
  # ==========================================================================
  # El CRM usa una sola cuenta de servicio de Google (GOOGLE_SERVICE_ACCOUNT_JSON,
  # el JSON que descarga Google Cloud). Cada empresa comparte su calendario con
  # el correo de esa cuenta («Hacer cambios en eventos») y escribe el ID del
  # calendario en Ajustes → Asistente IA. Sin pantalla de consentimiento ni
  # verificación de Google.
  #
  # Token OAuth por JWT (RS256), cacheado ~50 min. API REST v3: freeBusy y
  # events (insert / patch / delete).
  # ==========================================================================
  class GoogleCalendar
    # GOOGLE_API_BASE / GOOGLE_TOKEN_URL solo para pruebas locales con un servidor simulado.
    TOKEN_URL = ENV.fetch("GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")
    API_BASE  = ENV.fetch("GOOGLE_API_BASE", "https://www.googleapis.com/calendar/v3")
    SCOPE     = "https://www.googleapis.com/auth/calendar"

    class Error < StandardError; end

    def self.credentials
      raw = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"].to_s.strip
      return nil if raw.blank?

      raw = Base64.decode64(raw) unless raw.start_with?("{")
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def self.configured? = credentials&.dig("client_email").present? && credentials&.dig("private_key").present?

    # Correo con el que cada empresa debe compartir su calendario.
    def self.service_account_email = credentials&.dig("client_email")

    def initialize(calendar_id)
      @calendar_id = calendar_id.to_s.strip
      raise Error, "Falta el ID del calendario." if @calendar_id.blank?
      raise Error, "Falta configurar la cuenta de servicio de Google en el servidor." unless self.class.configured?
    end

    # [[inicio, fin], …] ocupados entre from y to.
    def busy(from, to)
      data = request(:post, "#{API_BASE}/freeBusy",
                     { timeMin: from.iso8601, timeMax: to.iso8601, items: [ { id: @calendar_id } ] })
      calendar = data.dig("calendars", @calendar_id) || {}
      if Array(calendar["errors"]).any?
        reason = calendar["errors"].first["reason"]
        raise Error, reason == "notFound" ? not_shared_message : "Google Calendar: #{reason}"
      end

      Array(calendar["busy"]).map { |b| [ Time.zone.parse(b["start"]), Time.zone.parse(b["end"]) ] }
    end

    # @return [String] id del evento
    def create_event(summary:, description:, starts_at:, ends_at:, time_zone:, location: nil)
      body = { summary: summary, description: description, location: location.presence,
               start: { dateTime: starts_at.iso8601, timeZone: time_zone },
               end: { dateTime: ends_at.iso8601, timeZone: time_zone } }.compact
      request(:post, "#{events_url}?sendUpdates=none", body)["id"]
    end

    def move_event(event_id, starts_at:, ends_at:, time_zone:)
      request(:patch, "#{events_url}/#{ERB::Util.url_encode(event_id)}?sendUpdates=none",
              { start: { dateTime: starts_at.iso8601, timeZone: time_zone },
                end: { dateTime: ends_at.iso8601, timeZone: time_zone } })
    end

    def delete_event(event_id)
      request(:delete, "#{events_url}/#{ERB::Util.url_encode(event_id)}?sendUpdates=none")
    rescue Error => e
      raise unless e.message.include?("404") || e.message.include?("410")
    end

    private

    def events_url = "#{API_BASE}/calendars/#{ERB::Util.url_encode(@calendar_id)}/events"

    def not_shared_message
      "No se encontró el calendario o no está compartido con #{self.class.service_account_email}."
    end

    def request(method, url, body = nil)
      response = connection.run_request(method, url, body&.to_json, nil)
      return {} if response.status == 204

      data = JSON.parse(response.body.presence || "{}")
      return data if response.success?

      message = data.dig("error", "message") || response.body.to_s.truncate(200)
      raise Error, response.status == 404 ? not_shared_message : "Google Calendar #{response.status}: #{message}"
    rescue Faraday::Error => e
      raise Error, "Google Calendar no respondió: #{e.message}"
    end

    def connection
      Faraday.new(request: { timeout: 15, open_timeout: 8 }) do |f|
        f.headers["Authorization"] = "Bearer #{access_token}"
        f.headers["Content-Type"]  = "application/json"
      end
    end

    def access_token
      creds = self.class.credentials
      Rails.cache.fetch([ "google_calendar_token", creds["client_email"] ], expires_in: 50.minutes) do
        now = Time.current.to_i
        assertion = JWT.encode(
          { iss: creds["client_email"], scope: SCOPE, aud: TOKEN_URL, iat: now, exp: now + 3600 },
          OpenSSL::PKey::RSA.new(creds["private_key"]), "RS256"
        )
        response = Faraday.post(TOKEN_URL, URI.encode_www_form(
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: assertion
        ), "Content-Type" => "application/x-www-form-urlencoded")
        data = JSON.parse(response.body.presence || "{}")
        raise Error, "Google rechazó la cuenta de servicio: #{data['error_description'] || data['error']}" unless response.success?

        data["access_token"]
      end
    end
  end
end
