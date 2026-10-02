# frozen_string_literal: true

module Reminders
  # Entrega un recordatorio vencido (correo, WhatsApp o campana).
  class DueDispatcher
    def self.call(reminder:)
      new(reminder: reminder).call
    end

    def initialize(reminder:)
      @reminder = reminder
    end

    def call
      # Reclamo atómico: si otro proceso (batch cada minuto vs. job puntual
      # al vencer) ya lo está despachando, no hacemos nada (RFC §6.4 — evita
      # duplicar el envío al consultor).
      return false unless @reminder.claim_for_dispatch!

      unless StaffRecipient.eligible?(@reminder.user)
        @reminder.mark_failed!("staff_recipient_required")
        return false
      end

      case @reminder.channel
      when "email"
        deliver_email!
      when "whatsapp"
        enqueue_whatsapp!
      when "in_app"
        deliver_in_app!
      else
        @reminder.mark_failed!("channel_unknown:#{@reminder.channel}")
        false
      end
    rescue StandardError => e
      Rails.logger.error("[Reminders::DueDispatcher] reminder=#{@reminder.id} #{e.class}: #{e.message}")
      @reminder.mark_failed!(e.message.truncate(500))
      false
    end

    private

    def deliver_email!
      unless defined?(ReminderMailer)
        @reminder.mark_failed!("reminder_mailer_unavailable")
        return false
      end

      if @reminder.user&.email.blank?
        @reminder.mark_failed!("missing_user_email")
        return false
      end

      return mark_failed_missing_opportunity if @reminder.opportunity.nil?

      ReminderMailer.with(reminder: @reminder).due_notification.deliver_now
      # Best-effort: la campana in-app no debe revertir un correo que ya se
      # entregó (antes, si notify_in_app! fallaba aquí, el reminder quedaba
      # "failed" pese al deliver_now exitoso, arriesgando un reenvío duplicado).
      notify_in_app!

      @reminder.mark_sent!
      true
    end

    def deliver_in_app!
      return mark_failed_missing_opportunity unless notify_in_app!

      @reminder.mark_sent!
      true
    end

    def enqueue_whatsapp!
      user = @reminder.user
      to   = StaffRecipient.phone_e164(user)
      if to.blank?
        @reminder.mark_failed!("missing_user_phone")
        return false
      end

      return mark_failed_missing_opportunity if @reminder.opportunity.nil?

      tenant   = @reminder.tenant
      provider = tenant.whatsapp_outbound_provider
      from     = tenant.whatsapp_outbound_from_number_for(provider)

      msg = tenant.whatsapp_messages.create!(
        contact:     nil,
        opportunity: @reminder.opportunity,
        direction:   "out",
        provider:    provider,
        from_number: from,
        to_number:   to,
        body:        StaffWhatsappBody.for(@reminder),
        status:      "queued",
        automated:   true
      )
      # Best-effort: la campana in-app no debe bloquear el encolado real del
      # mensaje (antes, si notify_in_app! fallaba, el mensaje quedaba
      # "queued" para siempre porque WhatsappDeliveryJob nunca se encolaba).
      notify_in_app!

      WhatsappDeliveryJob.perform_later(msg.id, @reminder.id)
      true
    end

    def notify_in_app!
      Notifications::ReminderDueNotifier.call(reminder: @reminder)
    end

    def mark_failed_missing_opportunity
      @reminder.mark_failed!("missing_opportunity")
      false
    end
  end
end
