# frozen_string_literal: true

module EmailCampaigns
  # ============================================================================
  # EmailCampaigns::Dispatcher — envía un lote de una campaña "running"
  # ============================================================================
  # Invocado cada minuto por EmailCampaignBatchJob. Envía `batch_size` correos
  # por SES (SendEmail v2) con:
  #   - From del dominio verificado del tenant y Reply-To opcional.
  #   - List-Unsubscribe + List-Unsubscribe-Post (baja en un clic, exigido por
  #     Gmail/Yahoo a remitentes masivos).
  #   - Configuration set de marketing (SES_MARKETING_CONFIGURATION_SET) para
  #     recibir entregas, rebotes, quejas, aperturas y clics por SNS.
  # Re-chequea la baja al despachar (pudo darse de baja en otra campaña).
  # ============================================================================
  class Dispatcher
    def self.call(campaign:) = new(campaign: campaign).call

    def initialize(campaign:)
      @campaign = campaign
      @sender   = campaign.tenant.email_sender
    end

    def call
      return false unless @campaign.status_running?

      unless @sender.verified?
        @campaign.pause!
        Rails.logger.warn("[EmailCampaigns] campaña #{@campaign.id} pausada: dominio sin verificar")
        return false
      end

      @campaign.email_campaign_recipients.status_pending.includes(:contact, opportunity: :owner_user)
               .order(:id).limit(@campaign.batch_size).each { |recipient| deliver!(recipient) }

      @campaign.update!(last_batch_at: Time.current)
      complete_if_done!
      true
    end

    # Envío de prueba (sin destinatario real): mismo render con datos de ejemplo.
    def self.send_test!(campaign:, to:, contact: nil)
      sender = campaign.tenant.email_sender
      raise ArgumentError, "Falta verificar el dominio de envío." unless sender.verified?

      contact ||= campaign.tenant.contacts.new(first_name: "Laura", last_name: "Gómez", company_name: "Empresa Demo")
      rendered = EmailMarketing::Renderer.call(campaign: campaign, contact: contact)
      new(campaign: campaign).send_email(to: to, rendered: rendered, subject_prefix: "[Prueba] ",
                                         unsubscribe_url: nil, tags: {})
    end

    # Envía un correo ya renderizado por SES; devuelve el MessageId.
    def send_email(to:, rendered:, unsubscribe_url:, tags:, subject_prefix: "")
      headers = []
      if unsubscribe_url
        headers << { name: "List-Unsubscribe", value: "<#{unsubscribe_url}>" }
        headers << { name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click" }
      end

      params = {
        from_email_address: @sender.from_header,
        destination:        { to_addresses: [ to ] },
        reply_to_addresses: Array(@sender.reply_to),
        content:            {
          simple: {
            subject: { data: "#{subject_prefix}#{rendered.subject}", charset: "UTF-8" },
            body:    { html: { data: rendered.html, charset: "UTF-8" }, text: { data: rendered.text, charset: "UTF-8" } },
            headers: headers.presence
          }.compact
        },
        email_tags:         tags.map { |name, value| { name: name, value: value.to_s } }.presence
      }
      params[:configuration_set_name] = EmailMarketing::Ses.configuration_set if EmailMarketing::Ses.configuration_set
      EmailMarketing::Ses.client.send_email(params.compact).message_id
    end

    private

    def deliver!(recipient)
      contact = recipient.contact
      if contact.nil? || contact.discarded? || contact.email_opted_out?
        return skip!(recipient, contact&.email_opted_out? ? "se dio de baja de los correos" : "contacto eliminado")
      end

      url      = EmailMarketing::UnsubscribeToken.url(recipient)
      rendered = EmailMarketing::Renderer.call(campaign: @campaign, contact: contact,
                                               opportunity: recipient.opportunity, unsubscribe_url: url)
      message_id = send_email(to: recipient.email, rendered: rendered, unsubscribe_url: url,
                              tags: { "tenant_id" => @campaign.tenant_id, "recipient_id" => recipient.id })

      recipient.update!(status: "sent", ses_message_id: message_id, sent_at: Time.current)
      @campaign.increment!(:sent_count)
    rescue Aws::SESV2::Errors::ServiceError, ArgumentError => e
      recipient.update!(status: "failed", skip_reason: e.message.truncate(300))
      @campaign.increment!(:failed_count)
    end

    def skip!(recipient, reason)
      recipient.update!(status: "skipped", skip_reason: reason)
      @campaign.increment!(:skipped_count)
    end

    def complete_if_done!
      return if @campaign.email_campaign_recipients.status_pending.exists?

      @campaign.update!(status: "completed", completed_at: Time.current)
    end
  end
end
