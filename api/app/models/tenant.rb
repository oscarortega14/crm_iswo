# frozen_string_literal: true

# ============================================================================
# Tenant — raíz de la jerarquía multi-tenant
# ============================================================================
# Cada negocio o vertical (ISWO, Mi Casita, Libranzas, …) es una fila aquí.
# El subdominio se resuelve por `slug`.
# ============================================================================
class Tenant < ApplicationRecord
  include Discard::Model

  # ---- Asociaciones ---------------------------------------------------------
  has_many :users,                  dependent: :destroy
  has_many :pipelines,              dependent: :destroy
  has_many :pipeline_stages,        dependent: :destroy
  has_many :lead_sources,           dependent: :destroy
  has_many :contacts,               dependent: :destroy
  has_many :opportunities,          dependent: :destroy
  has_many :opportunity_logs,       dependent: :destroy
  has_many :reminders,              dependent: :destroy
  has_many :duplicate_flags,        dependent: :destroy
  has_many :referral_networks,      dependent: :destroy
  has_many :landing_pages,          dependent: :destroy
  has_many :landing_form_submissions, dependent: :destroy
  has_many :ad_integrations,        dependent: :destroy
  has_many :whatsapp_messages,      dependent: :destroy
  has_many :whatsapp_templates,     dependent: :destroy
  has_many :whatsapp_campaigns,     dependent: :destroy
  has_many :exports,                dependent: :destroy
  has_many :audit_events,           dependent: :nullify
  has_one  :bant_criterion,         dependent: :destroy
  has_many :tenant_field_definitions, dependent: :destroy

  # Nombre de API/SPA; en base de datos la columna es `primary_color`.
  alias_attribute :brand_color, :primary_color

  # ---- Validaciones ---------------------------------------------------------
  validates :name,     presence: true
  validates :slug,     presence: true,
                       uniqueness: { case_sensitive: false },
                       format: { with: /\A[a-z0-9](?:[a-z0-9\-]{1,30}[a-z0-9])?\z/,
                                 message: "solo minúsculas, números y guiones" }
  validates :timezone, presence: true
  validates :locale,   presence: true
  validates :currency, presence: true, length: { is: 3 }

  # ---- Callbacks ------------------------------------------------------------
  before_validation :normalize_slug

  # ---- Scopes ---------------------------------------------------------------
  scope :active, -> { kept.where(active: true) }

  # Integración Twilio: preferimos `active`; si la cuenta quedó en `error` (p. ej. tras «Probar conexión»
  # fallida), seguimos usando la misma fila para remitente y credenciales hasta que el usuario corrija.
  # Usamos `AdIntegration.unscoped` + `tenant_id` para no depender de ActsAsTenant.current (jobs, consola, specs).
  def preferred_twilio_integration
    base = AdIntegration.unscoped.where(tenant_id: id, provider: :twilio)
    base.where(status: "active").order(updated_at: :desc).first ||
      base.order(updated_at: :desc).first
  end

  def preferred_whatsapp_cloud_integration
    base = AdIntegration.unscoped.where(tenant_id: id, provider: :whatsapp_cloud)
    base.where(status: "active").order(updated_at: :desc).first ||
      base.order(updated_at: :desc).first
  end

  def preferred_openwa_integration
    base = AdIntegration.unscoped.where(tenant_id: id, provider: :openwa)
    base.where(status: "active").order(updated_at: :desc).first ||
      base.order(updated_at: :desc).first
  end

  # Número/línea usado como remitente en mensajes WhatsApp salientes (Twilio API).
  # Orden: settings del tenant → ENV → integración Twilio (`account_identifier`).
  def whatsapp_outbound_from_number
    settings.dig("whatsapp", "number").presence ||
      ENV["TWILIO_WHATSAPP_NUMBER"].presence ||
      preferred_twilio_integration&.account_identifier.presence
  end

  # Etiqueta para `from_number` cuando el proveedor es Cloud API (Meta no usa el campo en el POST).
  def whatsapp_cloud_sender_label
    settings.dig("whatsapp", "number").presence ||
      preferred_whatsapp_cloud_integration&.account_identifier.presence
  end

  # Twilio vs WhatsApp Cloud API vs OpenWA para mensajes salientes.
  # Prioridad: ENV["WHATSAPP_PROVIDER"] → settings["whatsapp"]["provider"] →
  # si hay credenciales, preferimos Cloud > Twilio > OpenWA.
  def whatsapp_outbound_provider
    exp = ENV["WHATSAPP_PROVIDER"].to_s.strip
    return exp if %w[twilio whatsapp_cloud openwa].include?(exp)

    override = settings.dig("whatsapp", "provider").to_s.strip
    return override if %w[twilio whatsapp_cloud openwa].include?(override)

    cloud_i   = preferred_whatsapp_cloud_integration
    twilio_i  = preferred_twilio_integration
    openwa_i  = preferred_openwa_integration
    cloud_ok  = ad_integration_has_credentials?(cloud_i)
    twilio_ok = ad_integration_has_credentials?(twilio_i)
    openwa_ok = ad_integration_has_credentials?(openwa_i)

    return "whatsapp_cloud" if cloud_ok
    return "twilio"         if twilio_ok
    return "openwa"         if openwa_ok

    "twilio"
  end

  def whatsapp_outbound_from_number_for(provider)
    case provider.to_s
    when "whatsapp_cloud"
      whatsapp_cloud_sender_label.presence ||
        whatsapp_outbound_from_number.presence ||
        "whatsapp-cloud"
    when "openwa"
      settings.dig("whatsapp", "openwa_number").presence ||
        preferred_openwa_integration&.account_identifier.presence ||
        "openwa"
    else
      whatsapp_outbound_from_number
    end
  end

  # Usado por WhatsappCampaign#launch! para fallar rápido con un mensaje claro
  # en vez de crear cientos de recipients que van a fallar uno por uno.
  def whatsapp_cloud_configured?
    return true if ENV["WHATSAPP_CLOUD_ACCESS_TOKEN"].present? && ENV["WHATSAPP_CLOUD_PHONE_NUMBER_ID"].present?
    return true if settings.dig("whatsapp", "cloud_access_token").present? &&
                   settings.dig("whatsapp", "cloud_phone_number_id").present?

    ad_integration_has_credentials?(preferred_whatsapp_cloud_integration)
  end

  private

  def ad_integration_has_credentials?(integ)
    integ.present? &&
      integ.status == "active" &&
      integ.respond_to?(:credentials_ciphertext) &&
      integ.credentials_ciphertext.present?
  end

  def normalize_slug
    self.slug = slug&.downcase&.strip
  end
end
