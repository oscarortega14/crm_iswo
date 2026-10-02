# frozen_string_literal: true

# ============================================================================
# AdIntegration — credenciales cifradas de canales externos
# ============================================================================
# Lockbox cifra el campo `credentials` y persiste en `credentials_ciphertext`.
# En código uso `integration.credentials`; el ciphertext queda oculto.
# ============================================================================
class AdIntegration < ApplicationRecord
  include TenantScoped

  PROVIDERS = %w[meta google whatsapp_cloud openwa].freeze
  STATUSES  = %w[active paused error revoked].freeze

  enum :provider, PROVIDERS.zip(PROVIDERS).to_h, prefix: true
  enum :status,   STATUSES.zip(STATUSES).to_h,   prefix: :status, default: "active"

  # Campo cifrado: se usa integration.credentials (Hash); Lockbox serializa.
  has_encrypted :credentials, type: :json, migrating: false

  belongs_to :tenant

  validates :provider, inclusion: { in: PROVIDERS }
  validates :status,   inclusion: { in: STATUSES }
  validates :provider, uniqueness: { scope: :tenant_id }

  scope :healthy, -> { status_active }

  def record_sync!
    update!(last_sync_at: Time.current, last_error_at: nil, last_error_message: nil,
            status: "active", consecutive_failures: 0)
  end

  def record_failure!(message)
    update!(
      last_error_at:        Time.current,
      last_error_message:   message.to_s.truncate(500),
      status:               "error",
      consecutive_failures: (consecutive_failures || 0) + 1
    )
  end
end
