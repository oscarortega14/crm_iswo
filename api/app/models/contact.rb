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
  has_many :email_campaign_recipients, dependent: :destroy
  has_many :ai_agent_runs, dependent: :delete_all

  # ---- Validaciones ---------------------------------------------------------
  validates :kind, inclusion: { in: KINDS }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate  :name_or_company_present
  validate  :valid_phone_format

  # ---- Callbacks ------------------------------------------------------------
  before_validation :normalize_email_and_phone
  before_create :seed_origins
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
  # Respondió "Sí" por WhatsApp (ver WhatsApp::ConsentReply); no basta el
  # opt-in por import/manual.
  scope :whatsapp_confirmed, lambda {
    where(whatsapp_opt_in_source: "reply_confirm", whatsapp_opt_out_at: nil).where.not(whatsapp_opt_in_at: nil)
  }
  scope :whatsapp_opted_out, -> { where.not(whatsapp_opt_out_at: nil) }
  # Dijo «Sí» por WhatsApp y ninguna persona le ha escrito después (los
  # mensajes automáticos no cuentan): está esperando que un asesor le responda.
  scope :whatsapp_awaiting_reply, lambda {
    whatsapp_confirmed.where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM whatsapp_messages m
        WHERE m.contact_id = contacts.id AND m.direction = 'out' AND m.automated = FALSE
          AND m.created_at > contacts.whatsapp_opt_in_at
      )
    SQL
  }

  # Con correo y sin baja de correos de marketing (baja, rebote o queja).
  scope :email_marketable, lambda {
    where.not(email: [ nil, "" ]).where(email_opt_out_at: nil)
  }

  # Por dónde llegó (landing, «Excel: base.xlsx», WhatsApp…): el origen
  # principal o cualquiera de los acumulados (incluye contactos fusionados).
  scope :with_origin, lambda { |label|
    where(source_label: label).or(where("contacts.origins @> ?", [ { label: label } ].to_json))
  }

  # [{ label:, kind:, count: }] de los orígenes principales, más frecuentes primero.
  def self.origin_options(limit: 100)
    kept.where.not(source_label: [ nil, "" ])
        .group(:source_label, :source_kind).order(Arel.sql("COUNT(*) DESC")).limit(limit).count
        .map { |(label, kind), count| { label: label, kind: kind, count: count } }
  end

  WHATSAPP_CONSENT_FILTERS = %w[confirmed opted_out unconfirmed none].freeze

  # Filtro de /contacts por consentimiento de WhatsApp:
  #   confirmed   → respondió "Sí"
  #   opted_out   → respondió "No" (o se marcó "No autoriza")
  #   unconfirmed → tiene opt-in (import/manual/mensaje) pero no confirmó "Sí"
  #   none        → sin opt-in ni opt-out
  def self.filter_by_whatsapp_consent(value)
    case value.to_s
    when "confirmed"   then whatsapp_confirmed
    when "opted_out"   then whatsapp_opted_out
    when "unconfirmed"
      opted_in_for_whatsapp.where(whatsapp_opt_out_at: nil)
                           .where("contacts.whatsapp_opt_in_source IS DISTINCT FROM ?", "reply_confirm")
    when "none" then where(whatsapp_opt_in_at: nil, whatsapp_opt_out_at: nil)
    else all
    end
  end

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
  # Registra una vía de entrada (landing, importación, WhatsApp…) si no estaba ya
  # (mismo kind + label). No toca updated_at ni dispara callbacks.
  def record_origin!(kind, label = nil, at: Time.current)
    return if kind.blank? || new_record?

    list = Array(origins)
    return if list.any? { |o| o["kind"] == kind.to_s && o["label"].to_s == label.to_s }

    update_column(:origins, list + [ { "kind" => kind.to_s, "label" => label.presence, "at" => at.utc.iso8601 }.compact ])
  end

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

  # El contacto dijo explícitamente que NO quiere WhatsApp. Bloquea toda
  # campaña, incluidas las de solicitud de opt-in.
  def whatsapp_opted_out?
    whatsapp_opt_out_at.present?
  end

  # Opt-in explícito (manual, "Sí autorizo", import…): limpia un opt-out previo.
  def mark_whatsapp_opt_in!(source:)
    update!(whatsapp_opt_in_at: Time.current, whatsapp_opt_in_source: source,
            whatsapp_opt_out_at: nil, whatsapp_opt_out_source: nil)
  end

  def mark_whatsapp_opt_out!(source:)
    update!(whatsapp_opt_in_at: nil, whatsapp_opt_out_at: Time.current, whatsapp_opt_out_source: source)
  end

  def revoke_whatsapp_opt_in!
    update!(whatsapp_opt_in_at: nil)
  end

  # Un asesor tomó el control del chat: no se envían respuestas automáticas.
  def whatsapp_automation_paused?
    whatsapp_automation_paused_at.present?
  end

  EMAIL_OPT_OUT_SOURCES = %w[unsubscribe bounce complaint manual].freeze

  # Se dio de baja de las campañas de correo, rebotó de forma permanente o lo
  # marcó como spam. No afecta los correos del sistema ni WhatsApp.
  def email_opted_out?
    email_opt_out_at.present?
  end

  # Idempotente: conserva la primera fecha y motivo.
  def mark_email_opt_out!(source:)
    return if email_opted_out?

    update_columns(email_opt_out_at: Time.current, email_opt_out_source: source.to_s, updated_at: Time.current)
  end

  def clear_email_opt_out!
    update_columns(email_opt_out_at: nil, email_opt_out_source: nil, updated_at: Time.current)
  end

  private

  def discard_opportunities
    opportunities.kept.discard_all
  end

  def seed_origins
    return if Array(origins).any? || source_kind.blank?

    self.origins = [ { "kind" => source_kind, "label" => source_label.presence, "at" => Time.current.utc.iso8601 }.compact ]
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
