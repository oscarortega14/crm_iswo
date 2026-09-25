# frozen_string_literal: true

# ============================================================================
# Contact — persona o empresa prospecto
# ============================================================================
# Fase 2: `document_id` y `phone_e164` cifrados (Lockbox + blind_index).
# Duplicados por teléfono: coincidencia exacta E.164 (sin trigram en claro).
# ============================================================================
class Contact < ApplicationRecord
  include TenantScoped
  include Discard::Model
  include DataClassifiable
  include ExportRansackable

  # Fase 2 — PII cifrada. Modo migración one-shot: CONTACT_PII_MIGRATING=true (ver SECURITY_FASE2.md).
  if ENV["CONTACT_PII_MIGRATING"].to_s.match?(/\A(1|true|yes)\z/i)
    has_encrypted :document_id, migrating: true
    has_encrypted :phone_e164, migrating: true

    blind_index :document_id,
                migrating: true,
                expression: ->(v) { v.to_s.strip.gsub(/[.\s-]/, "").presence }

    blind_index :phone_e164,
                migrating: true,
                expression: ->(v) { Contact.normalize_phone_digits(v) }
  else
    # Columnas legado ignoradas; Lockbox descifra vía atributo virtual.
    self.ignored_columns += %w[document_id phone_e164]

    has_encrypted :document_id
    has_encrypted :phone_e164

    blind_index :document_id,
                expression: ->(v) { v.to_s.strip.gsub(/[.\s-]/, "").presence }

    blind_index :phone_e164,
                expression: ->(v) { Contact.normalize_phone_digits(v) }
  end

  EXPORT_RANSACKABLE_ATTRIBUTES = %w[
    kind owner_user_id source_kind updated_at
    first_name last_name email company_name phone_e164 phone_normalized
  ].freeze
  # `opportunities` habilita filtrar contactos por etapa del pipeline de sus
  # oportunidades (RFC §6.7: "Filtros disponibles: ... etapa del pipeline ...").
  EXPORT_RANSACKABLE_ASSOCIATIONS = %w[opportunities].freeze

  # Compatibilidad con serializers/frontend que usan company/position.
  alias_attribute :company, :company_name
  alias_attribute :position, :job_title

  KINDS = %w[person company].freeze
  enum :kind, KINDS.zip(KINDS).to_h, prefix: true

  # ---- Asociaciones ---------------------------------------------------------
  belongs_to :tenant
  belongs_to :owner_user, class_name: "User", optional: true

  has_many :opportunities, dependent: :destroy
  has_many :landing_form_submissions, dependent: :nullify
  has_many :whatsapp_messages, dependent: :nullify
  has_many :whatsapp_campaign_recipients, dependent: :destroy

  # ---- Validaciones ---------------------------------------------------------
  validates :kind, inclusion: { in: KINDS }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate  :name_or_company_present
  validate  :valid_phone_format

  # ---- Callbacks ------------------------------------------------------------
  before_validation :normalize_email_and_phone
  # Soft-delete en cascada: `dependent: :destroy` solo aplica al destroy real,
  # así que sin esto las oportunidades de un contacto descartado siguen
  # contando en /opportunities, kanban y dashboard.
  after_discard :discard_opportunities

  # ---- Scopes ---------------------------------------------------------------
  scope :persons,   -> { where(kind: "person") }
  scope :companies, -> { where(kind: "company") }
  # phone_normalized queda en claro para búsqueda parcial (ILIKE); PII principal cifrada.
  scope :with_phone, lambda {
    where(<<~SQL.squish)
      (phone_e164_bidx IS NOT NULL AND phone_e164_bidx <> '')
      OR (phone_normalized IS NOT NULL AND phone_normalized <> '')
    SQL
  }
  scope :opted_in_for_whatsapp, -> { where.not(whatsapp_opt_in_at: nil) }

  # ---- Helpers --------------------------------------------------------------
  def display_name
    return company_name if kind_company?

    [first_name, last_name].compact.join(" ").presence || email
  end

  # Dígitos E.164 para blind_index (búsqueda/duplicados exactos).
  def self.normalize_phone_digits(value)
    return nil if value.blank?

    parsed = Phonelib.parse(value)
    parsed.sanitized.presence if parsed.valid?
  end

  # Evita 500 en listados si hay ciphertext corrupto (encrypt fallido previo).
  def phone_e164_safe
    phone_e164
  rescue Lockbox::DecryptionError, Lockbox::Error
    nil
  end

  def document_id_safe
    document_id
  rescue Lockbox::DecryptionError, Lockbox::Error
    nil
  end

  # Columna legado en claro (búsqueda ILIKE); no usar Lockbox.
  def phone_normalized_legacy
    self[:phone_normalized]
  end

  def phone_display_value
    phone_e164_safe.presence || phone_normalized_legacy.presence
  end

  # Gate de campañas masivas — nil hasta que alguien lo marque explícito.
  # NUNCA asumir opt-in por default: es la defensa contra baneo de Meta.
  def whatsapp_opted_in?
    whatsapp_opt_in_at.present?
  end

  def mark_whatsapp_opt_in!(source:)
    update!(whatsapp_opt_in_at: Time.current, whatsapp_opt_in_source: source)
  end

  def revoke_whatsapp_opt_in!
    update!(whatsapp_opt_in_at: nil)
  end

  private

  def discard_opportunities
    opportunities.kept.discard_all
  end

  def normalize_email_and_phone
    self.email = email&.downcase&.strip

    if phone_e164.present?
      parsed = Phonelib.parse(phone_e164, country)
      if parsed.valid?
        self.phone_e164 = parsed.e164
        self.phone_normalized = parsed.sanitized
      end
    end
  end

  def name_or_company_present
    has_name = first_name.present? || last_name.present?
    has_company = company_name.present?
    errors.add(:base, "se requiere nombre o razón social") unless has_name || has_company
  end

  def valid_phone_format
    return if phone_e164.blank?

    errors.add(:phone_e164, "no es un teléfono válido") unless Phonelib.valid?(phone_e164)
  end

  # Limpia columnas legado SIN pasar por Lockbox#update_columns (evita borrar ciphertext).
  def self.clear_legacy_pii_columns!(scope = all)
    scope.in_batches(of: 500) do |batch|
      batch.update_all(
        document_id: nil,
        phone_e164: nil,
        phone_normalized: nil,
        updated_at: Time.current
      )
    end
  end
end
