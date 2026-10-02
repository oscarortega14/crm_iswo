# frozen_string_literal: true

# ============================================================================
# prod:security_dry_run — RFC §7 → prod sin desplegar
# ============================================================================
# Valida las variables de entorno que Dokku (config:set) inyectará y simula
# security:infra en modo producción (sin exigir conexión real a BD prod).
#
# Uso: bundle exec rails prod:security_dry_run
# En el servidor / dentro del contenedor Dokku ya desplegado, las variables
# están puestas de verdad: `dokku run crm-iswo-api bin/rails prod:security_dry_run`.
# ============================================================================

namespace :prod do
  REQUIRED_SECRETS = %w[
    RAILS_MASTER_KEY
    CRM_ISWO_DATABASE_PASSWORD
    DEVISE_JWT_SECRET_KEY
    LOCKBOX_MASTER_KEY
    BLIND_INDEX_MASTER_KEY
    POSTMARK_API_TOKEN
  ].freeze

  # DB_SSLMODE: "require" es el ideal (tránsito cifrado), pero el Postgres que
  # provisiona el plugin dokku-postgres corre en el mismo EC2, en la red docker
  # privada del host (nunca sale a internet) y no trae TLS activado por defecto.
  # "disable" ahí es una desviación aceptada — documentada en SECURITY_FASE1.md.
  REQUIRED_CLEAR = {
    "APP_HOST" => ->(v) { v.present? },
    "ASSUME_SSL" => ->(v) { v.to_s == "true" },
    "DB_SSLMODE" => ->(v) { %w[require disable].include?(v.to_s) },
    "DB_RLS_ENABLED" => ->(v) { v.to_s == "true" },
    "SOLID_QUEUE_IN_PUMA" => ->(v) { v.to_s == "true" },
    "CORS_ALLOWED_ORIGINS" => lambda { |v|
      v.present? && !v.include?("localhost") && v.split(",").all? { |o| o.strip.start_with?("https://") }
    }
  }.freeze

  RECOMMENDED_CLEAR = {
    "AWS_S3_BUCKET" => "exports async en S3+SSE (RFC §6.7 / A.7.10)",
    "AWS_REGION" => "región S3"
  }.freeze

  desc "RFC §7 — dry-run producción (variables Dokku + security:infra simulado)"
  task security_dry_run: :environment do
    reporter = SecurityTaskReport.new

    puts "CRM ISWO — prod:security_dry_run (RFC §7 → Dokku)\n"

    missing_secrets = REQUIRED_SECRETS.reject { |k| ENV[k].present? }
    reporter.report(
      "Secretos requeridos (ENV)",
      missing_secrets.empty?,
      missing_secrets.empty? ? REQUIRED_SECRETS.join(", ") : "faltan: #{missing_secrets.join(', ')}"
    )

    REQUIRED_CLEAR.each do |key, validator|
      value = ENV[key]
      reporter.report("ENV #{key}", validator.call(value), value.to_s.truncate(80))
    end

    if ENV["DB_SSLMODE"].to_s == "disable"
      puts "ℹ️  DB_SSLMODE=disable — OK si Postgres corre en el mismo host Dokku (red docker privada)."
    end

    RECOMMENDED_CLEAR.each do |key, reason|
      value = ENV[key]
      if value.present?
        reporter.report("ENV #{key}", true, value.to_s)
      else
        reporter.warn_item(key, "no configurada en Dokku — #{reason}")
      end
    end

    puts "\n--- Simulación security:infra (subprocess RAILS_ENV=production) ---\n"

    infra_env = {
      "RAILS_ENV" => "production",
      "DEVISE_JWT_SECRET_KEY" => ENV["DEVISE_JWT_SECRET_KEY"].presence || "dry-run-jwt-secret-min-32-chars-long",
      "LOCKBOX_MASTER_KEY" => ENV["LOCKBOX_MASTER_KEY"].presence || ("a" * 64),
      "APP_HOST" => ENV["APP_HOST"].presence || "iswocrm.com",
      "ASSUME_SSL" => ENV["ASSUME_SSL"].presence || "true",
      "DB_SSLMODE" => ENV["DB_SSLMODE"].presence || "disable",
      "CORS_ALLOWED_ORIGINS" => ENV["CORS_ALLOWED_ORIGINS"].presence || "https://iswocrm.com,https://app.iswocrm.com"
    }
    infra_ok = system(infra_env, "bundle", "exec", "rails", "security:infra", chdir: Rails.root.to_s)
    reporter.fail! unless infra_ok
    puts "(Nota: puede fallar PostgreSQL si no existe crm_iswo_production local — normal en dry-run.)" unless infra_ok

    puts "\n--- Pasos manuales post-deploy ---"
    puts "• Setup inicial Dokku (una sola vez): docs/DEPLOY_DOKKU.md"
    puts "• SQL rol app: docs/sql/create_crm_iswo_app_role.sql (vía dokku postgres:connect)"
    puts "• Migraciones nuevas (owner, no crm_iswo): ver 'Migraciones' en docs/DEPLOY_DOKKU.md"
    puts "• RLS: bundle exec rails security:rls:install && security:rls"
    puts "• PII prod: security:encrypt_contacts (si hay legado) && security:pii"
    puts "• Checklist: bundle exec rails staging:preflight (en el contenedor Dokku)"

    puts "\n--- Resumen dry-run ---"
    if reporter.failures.positive?
      puts "#{reporter.failures} fallo(s) — corrige las variables antes de hacer push a main."
      exit 1
    end

    puts "Dry-run OK#{reporter.warnings.positive? ? " (#{reporter.warnings} advertencia(s))" : ''}."
    puts "Siguiente: push a main → GitHub Actions build+push GHCR → dokku git:from-image"
  end
end
