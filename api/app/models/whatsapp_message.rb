# frozen_string_literal: true

# ============================================================================
# WhatsappMessage — log bidireccional de mensajes WhatsApp
# ============================================================================
class WhatsappMessage < ApplicationRecord
  include TenantScoped
  include DataClassifiable

  DIRECTIONS    = %w[in out].freeze
  PROVIDERS     = %w[whatsapp_cloud openwa].freeze
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

  SENT_STATUSES = %w[sent delivered read].freeze

  after_create :mark_contact_whatsapp_opt_in, if: :direction_in?
  after_commit :run_stage_automation, on: %i[create update]
  after_commit :schedule_inbound_automation, on: :create, if: :direction_in?
  after_create :pause_automation_for_human_reply, if: :direction_out?

  scope :inbound,  -> { direction_in }
  scope :outbound, -> { direction_out }
  scope :recent,   -> { order(created_at: :desc) }

  # Mensajes disparados por una WhatsappCampaign van por el endpoint
  # /marketing_messages (MM Lite) en vez de /messages — ver
  # WhatsApp::Adapters::Cloud#deliver.
  def marketing?
    whatsapp_campaign_recipient.present?
  end

  private

  # Un mensaje entrante es la señal más fuerte de consentimiento que existe:
  # el contacto escribió primero. Se interpreta como opt-in para seguir la
  # conversación (no como opt-in genérico de marketing masivo, pero
  # WhatsappCampaign trata cualquier opt-in igual — ver RFC).
  #
  # Excepciones: una negativa ("No autorizo", "Stop"… ver
  # WhatsApp::ConsentReply) registra opt-out en vez de opt-in, y un contacto
  # con opt-out solo vuelve a quedar habilitado con un "Sí" explícito — no
  # con cualquier mensaje posterior.
  def mark_contact_whatsapp_opt_in
    return unless contact

    case WhatsApp::ConsentReply.classify(body)
    when :opt_out
      contact.mark_whatsapp_opt_out!(source: "reply") unless contact.whatsapp_opted_out?
    when :opt_in
      # También cuando ya tenía opt-in por import/manual: el "Sí" del propio
      # contacto es la confirmación que usa el filtro de audiencia
      # whatsapp_consent=confirmed. Un "Sí" repetido no reescribe la fecha.
      already_confirmed = contact.whatsapp_opted_in? && contact.whatsapp_opt_in_source == "reply_confirm"
      contact.mark_whatsapp_opt_in!(source: "reply_confirm") unless already_confirmed
    else
      return if contact.whatsapp_opted_in? || contact.whatsapp_opted_out?

      contact.mark_whatsapp_opt_in!(source: "reply_stop_in")
    end
  end

  # Respuestas automáticas a un mensaje entrante: «Mensaje al autorizar» de una
  # campaña o el asistente IA (WhatsappInboundAutomationJob, con espera corta
  # para contestar una sola vez a una ráfaga de mensajes).
  def schedule_inbound_automation
    return unless contact
    return unless WhatsApp::ConsentReply.classify(body) == :opt_in || tenant.ai_agent_config.enabled? ||
                  AiAgent::AppointmentReplies.pending_for(contact)

    WhatsappInboundAutomationJob.set(wait: WhatsappInboundAutomationJob::DEBOUNCE).perform_later(id)
  end

  # Una persona le escribió al contacto (bandeja, oportunidad): toma el control
  # y el asistente deja de responder en ese chat hasta que lo reanuden.
  def pause_automation_for_human_reply
    return if automated || contact.nil? || contact.whatsapp_automation_paused?

    contact.update_columns(whatsapp_automation_paused_at: Time.current, updated_at: Time.current)
  end

  # Auto-avance de etapa (Opportunities::StageAutomation). Requiere contacto:
  # los avisos de recordatorio al consultor (Reminders::DueDispatcher) van con
  # contact: nil y no son contacto con el lead.
  def run_stage_automation
    return if contact.nil?

    trigger = stage_automation_trigger
    return unless trigger

    Opportunities::StageAutomation.call_for_contact(contact: contact, opportunity: opportunity, trigger: trigger)
  end

  # Entrante: al crearse. Saliente: cuando el proveedor confirma el envío
  # (queued → sent/delivered/read), así un rechazo de Meta (131047) no avanza.
  def stage_automation_trigger
    if direction_in?
      "whatsapp_inbound" if previously_new_record?
    elsif status.in?(SENT_STATUSES)
      return "whatsapp_outbound" if previously_new_record?

      "whatsapp_outbound" if saved_change_to_status? && !status_before_last_save.to_s.in?(SENT_STATUSES)
    end
  end
end
