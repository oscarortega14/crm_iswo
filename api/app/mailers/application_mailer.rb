# frozen_string_literal: true

# ============================================================================
# ApplicationMailer — base de todos los mailers del CRM.
# ============================================================================
# - From por defecto: "CRM ISWO <no-reply@{tenant.domain}>".
# - Reply-to: configurable por tenant (settings.email.reply_to).
# - Layout "mailer" renderiza header/footer con branding del tenant si está
#   disponible en `@tenant`.
# - Delivery vía AWS SES v2 (`aws-actionmailer-ses`) en prod; letter_opener en dev.
# ============================================================================
class ApplicationMailer < ActionMailer::Base
  layout "mailer"

  default from: -> { default_from }

  before_action :set_tenant_from_params

  private

  def default_from
    tenant = params&.dig(:tenant) || @tenant
    domain = tenant&.settings&.dig("email", "from_domain").presence || ENV.fetch("APP_EMAIL_DOMAIN", "iswo.com.co")
    name   = tenant&.name.presence || "CRM ISWO"
    "#{name} <no-reply@#{domain}>"
  end

  # Los mailers reciben `params[:tenant]` (o lo derivan de params[:user].tenant)
  # para resolver branding y reply-to. Se expone @tenant a las plantillas.
  def set_tenant_from_params
    @tenant = params&.dig(:tenant) ||
              params&.dig(:briefing)&.dig(:tenant) ||
              params&.dig(:user)&.tenant ||
              params&.dig(:reminder)&.tenant ||
              params&.dig(:integration)&.tenant ||
              params&.dig(:export)&.tenant
    @reply_to = @tenant&.settings&.dig("email", "reply_to")
  end

  def tenant_email_headers
    headers["Reply-To"] = @reply_to if @reply_to.present?
  end
end
