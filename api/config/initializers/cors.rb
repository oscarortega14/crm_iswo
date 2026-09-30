# frozen_string_literal: true

# ============================================================================
# CORS — permite al SPA React (TanStack) en otro origen consumir el API.
# ============================================================================
# Configurar `CORS_ALLOWED_ORIGINS` como lista separada por comas.
# Para producción, usar el dominio completo del SPA (ej.
# https://app.iswocrm.com).
#
# En desarrollo también se aceptan orígenes http://{tenant}.localhost:PORT
# para landings públicas por subdominio (RFC gap #9).
# ----------------------------------------------------------------------------

allowed = ENV.fetch("CORS_ALLOWED_ORIGINS", "http://localhost:3001,http://localhost:3000,http://localhost:5173")
             .split(",")
             .map(&:strip)

tenant_localhost_origin = %r{\Ahttp://[\w-]+\.localhost(:\d+)?\z}

# Landings públicas por subdominio en producción (RFC §6.5):
# https://{tenant}.iswocrm.com. El dominio base sale de APP_HOST
# (ya requerido por Fase 1 seguridad) para no duplicar configuración.
tenant_production_origin =
  if ENV["APP_HOST"].present?
    /\Ahttps:\/\/[\w-]+\.#{Regexp.escape(ENV["APP_HOST"].strip)}\z/
  end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins do |source, _env|
      allowed.include?(source) ||
        source.match?(tenant_localhost_origin) ||
        tenant_production_origin&.match?(source)
    end

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[Authorization Current-Page Page-Items Total-Pages Total-Count],
      credentials: true,
      max_age: 600
  end
end
