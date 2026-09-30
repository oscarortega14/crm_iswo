# frozen_string_literal: true

module EmailMarketing
  # ==========================================================================
  # EmailMarketing::EventProcessor — aplica un evento de SES a un destinatario
  # ==========================================================================
  # Llega por SNS (Webhooks::SesController → SesEventJob). Ubica al
  # destinatario por la etiqueta `recipient_id` (o por el MessageId) y:
  #   Delivery  → delivered
  #   Bounce    → bounced; si es permanente, baja del contacto (source bounce)
  #   Complaint → complained + baja del contacto (source complaint)
  #   Open/Click → fecha de primera apertura / primer clic
  # Idempotente: SNS puede reenviar el mismo aviso.
  # ==========================================================================
  class EventProcessor
    def self.call(event) = new(event).call

    def initialize(event)
      @event = event.is_a?(String) ? JSON.parse(event) : event.to_h
    end

    def call
      recipient = find_recipient
      return :unknown_recipient unless recipient

      ActsAsTenant.with_tenant(recipient.tenant) { apply!(recipient) }
      :ok
    end

    private

    def type = (@event["eventType"] || @event["notificationType"]).to_s

    def mail = @event["mail"] || {}

    def find_recipient
      ActsAsTenant.without_tenant do
        id = Array(mail.dig("tags", "recipient_id")).first
        (id && EmailCampaignRecipient.find_by(id: id)) ||
          (mail["messageId"].present? && EmailCampaignRecipient.find_by(ses_message_id: mail["messageId"])) ||
          nil
      end
    end

    def apply!(recipient)
      at = timestamp
      case type
      when "Delivery"
        recipient.update!(status: "delivered", delivered_at: at) if recipient.status_sent?
      when "Bounce"
        permanent = @event.dig("bounce", "bounceType") == "Permanent"
        recipient.update!(status: "bounced", bounced_at: at,
                          skip_reason: bounce_reason.presence || recipient.skip_reason)
        recipient.contact&.mark_email_opt_out!(source: "bounce") if permanent
      when "Complaint"
        recipient.update!(status: "complained", complained_at: at)
        recipient.contact&.mark_email_opt_out!(source: "complaint")
      when "Open"
        recipient.update!(opened_at: at) if recipient.opened_at.nil?
      when "Click"
        recipient.update!(clicked_at: at, opened_at: recipient.opened_at || at) if recipient.clicked_at.nil?
      when "Reject", "RenderingFailure"
        recipient.update!(status: "failed", skip_reason: "SES rechazó el envío (#{type})")
      end
    end

    def timestamp
      raw = @event.dig(type.downcase, "timestamp") || mail["timestamp"]
      Time.zone.parse(raw.to_s) || Time.current
    rescue ArgumentError
      Time.current
    end

    def bounce_reason
      bounced = Array(@event.dig("bounce", "bouncedRecipients")).first || {}
      [ @event.dig("bounce", "bounceType"), bounced["diagnosticCode"] ].compact.join(": ").truncate(300)
    end
  end
end
