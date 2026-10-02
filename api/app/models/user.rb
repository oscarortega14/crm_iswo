# frozen_string_literal: true

# ============================================================================
# User — consultor o administrador dentro de un tenant
# ============================================================================
# Devise + JWT (devise-jwt). Email único por tenant (no global).
# Roles: admin, manager, consultant (default), viewer.
# ============================================================================
class User < ApplicationRecord
  include TenantScoped
  include Discard::Model

  # ---- Devise ---------------------------------------------------------------
  devise :database_authenticatable,
         :registerable,
         :recoverable,
         :rememberable,
         :trackable,
         :lockable,
         :confirmable,
         :jwt_authenticatable,
         jwt_revocation_strategy: JwtDenylist

  # ---- Enums ----------------------------------------------------------------
  ROLES = %w[admin manager consultant viewer].freeze
  enum :role, ROLES.zip(ROLES).to_h, prefix: true, default: "consultant"

  # ---- Asociaciones ---------------------------------------------------------
  belongs_to :tenant

  has_many :owned_contacts,       class_name: "Contact",     foreign_key: :owner_user_id, dependent: :nullify
  has_many :owned_opportunities,  class_name: "Opportunity", foreign_key: :owner_user_id, dependent: :nullify
  has_many :reminders,            dependent: :destroy
  has_many :notifications,        dependent: :destroy
  has_many :opportunity_logs,     dependent: :nullify
  has_many :exports,              dependent: :nullify
  has_many :appointments,         foreign_key: :owner_user_id, dependent: :nullify

  # Red de referidos (self-referential many-to-many)
  has_many :outgoing_referrals,
           class_name: "ReferralNetwork",
           foreign_key: :referrer_user_id,
           dependent: :destroy
  has_many :incoming_referrals,
           class_name: "ReferralNetwork",
           foreign_key: :referred_user_id,
           dependent: :destroy
  has_many :referred_users, through: :outgoing_referrals, source: :referred_user
  has_many :referrers,      through: :incoming_referrals, source: :referrer_user

  # Duplicate flags
  has_many :detected_duplicates,
           class_name: "DuplicateFlag",
           foreign_key: :detected_by_user_id,
           dependent: :nullify
  has_many :resolved_duplicates,
           class_name: "DuplicateFlag",
           foreign_key: :resolved_by_user_id,
           dependent: :nullify

  # ---- Validaciones ---------------------------------------------------------
  validates :email,
            presence: true,
            format: { with: URI::MailTo::EMAIL_REGEXP },
            uniqueness: { scope: :tenant_id, case_sensitive: false }
  validates :name, presence: true
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 8 }, allow_nil: true

  # ---- Callbacks ------------------------------------------------------------
  before_validation :normalize_email

  # ---- Scopes ---------------------------------------------------------------
  scope :active,   -> { kept.where(active: true) }
  scope :by_role,  ->(role) { where(role: role) }

  # ---- Métodos --------------------------------------------------------------
  def staff?
    role_admin? || role_manager?
  end

  def can_export?
    role_admin? || role_manager?
  end

  # devise-jwt llama este método para buscar el usuario al revocar el token.
  # Necesitamos bypasear el scope de acts_as_tenant porque el contexto de tenant
  # puede no estar disponible en ese punto del middleware de Warden.
  def self.find_for_jwt_authentication(sub)
    ActsAsTenant.without_tenant { find(sub) }
  end

  # Devuelve los IDs de usuarios en la red de referidos hasta `depth` niveles.
  # Usa WITH RECURSIVE para evitar N+1. El resultado NO incluye al usuario mismo.
  def network_user_ids(depth: 3)
    return [] unless tenant_id.present? && id.present?

    sql = <<~SQL
      WITH RECURSIVE tree AS (
        SELECT referred_user_id, 1 AS lvl
        FROM referral_networks
        WHERE tenant_id = :tenant_id AND referrer_user_id = :user_id AND active = true
        UNION ALL
        SELECT r.referred_user_id, t.lvl + 1
        FROM referral_networks r
        INNER JOIN tree t ON r.referrer_user_id = t.referred_user_id
        WHERE t.lvl < :depth AND r.tenant_id = :tenant_id AND r.active = true
      )
      SELECT DISTINCT referred_user_id FROM tree
    SQL

    rows = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql([sql, { tenant_id: tenant_id, user_id: id, depth: depth }])
    )
    rows.map { |r| r["referred_user_id"] }
  end

  private

  def normalize_email
    self.email = email&.downcase&.strip
  end
end
