# frozen_string_literal: true

# ============================================================================
# WhatsappDeliveryJob — envía un WhatsappMessage outbound al proveedor.
# ============================================================================
# Wrapper sobre WhatsApp::MessageSender. Se encola desde:
#   - WhatsApp::OutboundSender (chat 1-a-1: inbox + oportunidad, perform_later)
#   - ReminderNotificationJob (WhatsApp al teléfono del consultor asignado)
#
# Usa cola "integrations" para no saturar la default.
# Reintenta hasta 5 veces con backoff polinomial; al fallar definitivamente
# marca el mensaje como failed (ya lo hace el sender).
# ============================================================================
class WhatsappDeliveryJob < ApplicationJob
  queue_as :integrations

  retry_on Faraday::Error, wait: :polynomially_longer, attempts: 5

  # Single-job uniqueness por message_id (evita doble envío en reintentos
  # duplicados de Sidekiq).
  def perform(message_id, reminder_id = nil)
    # without_tenant: necesario porque el job no conoce el tenant a priori.
    # Una vez cargado el mensaje, se ejecuta dentro del scope correcto.
    msg = ActsAsTenant.without_tenant { WhatsappMessage.find_by(id: message_id) }
    return unless msg
    return if msg.status.in?(%w[sent delivered read])

    ActsAsTenant.with_tenant(msg.tenant) do
      WhatsApp::MessageSender.new(msg).deliver
    end

    msg.reload
    finalize_reminder!(reminder_id, msg) if reminder_id.present?
  end

  private

  def finalize_reminder!(reminder_id, msg)
    reminder = ActsAsTenant.without_tenant { Reminder.find_by(id: reminder_id) }
    # El flujo real reclama el reminder (status "processing") antes de encolar
    # este job; también toleramos "pending" por si se invoca sin claim previo.
    # Cualquier otro estado (sent/failed/done) ya es terminal: no re-marcar.
    return unless reminder && (reminder.status_processing? || reminder.status_pending?)

    if msg.status.in?(%w[sent delivered read])
      reminder.mark_sent!
    elsif msg.status == "failed"
      reminder.mark_failed!(msg.error_message.presence || "whatsapp_delivery_failed")
    end
  end
end
