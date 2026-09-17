# frozen_string_literal: true

# ============================================================================
# WhatsappMessage — log bidireccional de mensajes WhatsApp
# ============================================================================
class WhatsappMessage < ApplicationRecord
  include TenantScoped
  include DataClassifiable

  DIRECTIONS    = %w[in out].freeze
  PROVIDERS     = %w[twilio whatsapp_cloud openwa].freeze
  STATUSES      = %w[pending queued sent delivered read failed].freeze
  MESSAGE_TYPES = %w[text template].freeze

  enum :direction,    DIRECTIONS.zip(DIRECTIONS).to_h,       prefix: true
  enum :provider,     PROVIDERS.zip(PROVIDERS).to_h,         prefix: true
  enum :status,       STATUSES.zip(STATUSES).to_h,           prefix: :status, default: "pending"
  enum :message_type, MESSAGE_TYPES.zip(MESSAGE_TYPES).to_h, prefix: true,    default: "text"

  belongs_to :tenant
  belongs_to :opportunity, optional: true
  belongs_to :contact, optional: true
  has_one :whatsapp_campaign_recipient, inverse_of: :whatsapp_message

  validates :direction,   inclusion: { in: DIRECTIONS }
  validates :provider,    inclusion: { in: PROVIDERS }
  validates :status,      inclusion: { in: STATUSES }
  validates :from_number, :to_number, presence: true
  validates :provider_message_id,
            uniqueness: { scope: :provider, allow_nil: true }
  validates :template_name, :template_language, presence: true, if: :message_type_template?

  scope :inbound,  -> { direction_in }
  scope :outbound, -> { direction_out }
  scope :recent,   -> { order(created_at: :desc) }

  # Mensajes disparados por una WhatsappCampaign van por el endpoint
  # /marketing_messages (MM Lite) en vez de /messages — ver
  # WhatsApp::Adapters::Cloud#deliver.
  def marketing?
    whatsapp_campaign_recipient.present?
  end
end
