# frozen_string_literal: true

# ============================================================================
# Rack::Attack — rate limiting y protección de endpoints (A.6.8 ISO 27001)
# Caché: Solid Cache (prod/dev) o memory en test — sin Redis.
# ============================================================================

class Rack::Attack
  Rack::Attack.cache.store =
    if Rails.env.test?
      ActiveSupport::Cache::MemoryStore.new
    elsif Rails.env.development?
      # Evita depender de solid_cache_entries al arrancar (Rack::Attack no necesita persistencia en dev).
      ActiveSupport::Cache::MemoryStore.new
    else
      Rails.cache
    end

  safelist("allow-localhost") { |req| req.ip == "127.0.0.1" || req.ip == "::1" }

  throttle("webhooks/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/webhooks/")
  end

  throttle("auth/ip", limit: 10, period: 1.minute) do |req|
    next unless req.post?

    req.ip if req.path == "/api/v1/sessions" ||
              req.path == "/api/v1/sessions/refresh" ||
              req.path.start_with?("/api/v1/password/")
  end

  throttle("auth/email", limit: 5, period: 1.minute) do |req|
    if req.path == "/api/v1/sessions" && req.post?
      req.params["user"]&.dig("email").to_s.downcase.strip.presence
    end
  end

  throttle("public/landings", limit: 200, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/public/")
  end

  throttle("integrations/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/integrations/")
  end

  self.throttled_responder = lambda do |env|
    retry_after = (env["rack.attack.match_data"] || {})[:period]
    [
      429,
      {
        "Content-Type"  => "application/json",
        "Retry-After"   => retry_after.to_s
      },
      [{ error: "too_many_requests", message: "Demasiadas solicitudes. Intenta en #{retry_after}s." }.to_json]
    ]
  end
end
