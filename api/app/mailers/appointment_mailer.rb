# frozen_string_literal: true

# ============================================================================
# AppointmentMailer — correos al CLIENTE sobre su cita (fase 3 del asistente IA)
# ============================================================================
#   reminder — recordatorio antes de la cita
#   no_show  — «no pudimos conectarnos, ¿reagendamos?»
# Sale desde el dominio verificado del tenant (EmailMarketing::Sender) si existe;
# si no, desde el remitente por defecto del CRM.
#
# daily_summary — resumen de citas del día para admin / manager.
# ============================================================================
class AppointmentMailer < ApplicationMailer
  def reminder
    prepare
    mail(to: @contact.email, subject: "Recordatorio: tu reunión con #{@tenant.name} — #{@when}", **sender)
  end

  def no_show
    prepare
    mail(to: @contact.email, subject: "¿Reagendamos tu reunión con #{@tenant.name}?", **sender)
  end

  def daily_summary
    @tenant = params[:tenant]
    @user = params[:user]
    @rows = params[:rows]
    mail(to: @user.email, subject: "Citas de hoy en #{@tenant.name} (#{@rows.size})")
  end

  private

  def prepare
    @appointment = params[:appointment]
    @tenant = params[:tenant] || @appointment.tenant
    @contact = @appointment.contact
    scheduler = AiAgent::Scheduler.new(@tenant)
    @when = scheduler.label(@appointment.starts_at)
    @location = @tenant.ai_agent_config.calendar["location"].presence
    @name = @contact.kind_company? ? @contact.company_name : @contact.first_name
    @name = nil if @name == Contacts::Merger::WHATSAPP_PLACEHOLDER
  end

  def sender
    email_sender = @tenant.email_sender
    return {} unless email_sender.verified?

    { from: email_sender.from_header, reply_to: email_sender.reply_to }.compact
  end
end
