# frozen_string_literal: true

module WhatsappCampaigns
  # ============================================================================
  # WhatsappCampaigns::Dispatcher — despacha un lote de una campaña "running"
  # ============================================================================
  # Invocado por WhatsappCampaignBatchJob (recurring, ver config/recurring.yml).
  # Un lote por llamada, respetando `batch_interval_minutes` — es el
  # mecanismo de "pausas automáticas de seguridad" contra el rate limit /
  # calidad de número de Meta. Reusa el mismo camino de envío que
  # WhatsApp::OutboundSender (mismo adapter, mismo WhatsappDeliveryJob) — una
  # campaña es, para el adapter, una serie de envíos de plantilla 1-a-1.
  # ============================================================================
  class Dispatcher
    # Campañas siempre van por Meta Cloud API, sin importar qué proveedor usa
    # el tenant para el chat 1-a-1 (Twilio, etc.) — solo Cloud tiene soporte
    # de `type: template` en este código. Twilio requeriría Content API
    # (ContentSid), que no está implementado.
    WHATSAPP_CLOUD_PROVIDER = "whatsapp_cloud"

    def self.call(campaign:)
      new(campaign: campaign).call
    end

    def initialize(campaign:)
      @campaign = campaign
      @template = campaign.whatsapp_template
    end

    def call
      return false unless @campaign.status_running?
      return false if too_soon?

      batch.each { |recipient| dispatch_one!(recipient) }

      @campaign.update!(last_batch_at: Time.current)
      complete_if_done!
      true
    end

    private

    def too_soon?
      last = @campaign.last_batch_at
      last.present? && last > @campaign.batch_interval_minutes.minutes.ago
    end

    def batch
      @campaign.whatsapp_campaign_recipients.status_pending.limit(@campaign.batch_size)
    end

    def dispatch_one!(recipient)
      contact = recipient.contact

      unless contact.whatsapp_opted_in?
        recipient.update!(status: "skipped_no_opt_in", skip_reason: "sin opt-in registrado")
        @campaign.increment!(:skipped_no_opt_in_count)
        return
      end

      to = contact.phone_e164_safe.presence || contact.phone_normalized_legacy.presence
      unless to.present?
        recipient.update!(status: "skipped_no_phone", skip_reason: "sin teléfono")
        return
      end

      send_message!(recipient, contact, to)
    rescue StandardError => e
      recipient.update!(status: "failed", skip_reason: e.message.truncate(300))
      @campaign.increment!(:failed_count)
    end

    def send_message!(recipient, contact, to)
      tenant   = @campaign.tenant
      provider = WHATSAPP_CLOUD_PROVIDER
      from     = tenant.whatsapp_outbound_from_number_for(provider)

      msg = tenant.whatsapp_messages.create!(
        contact:                 contact,
        opportunity:             recipient.opportunity,
        direction:               "out",
        provider:                provider,
        from_number:             from,
        to_number:               to,
        message_type:            "template",
        template_name:           @template.meta_template_name,
        template_language:       @template.language,
        template_params:         resolve_params(contact, recipient.opportunity),
        template_variable_names: Array(@template.variable_names),
        status:                  "queued"
      )

      recipient.update!(whatsapp_message: msg, status: "sent")
      WhatsappDeliveryJob.perform_later(msg.id)
      @campaign.increment!(:sent_count)
    end

    def resolve_params(contact, opportunity)
      Array(@campaign.variable_field_map).map { |field| resolve_field(field, contact, opportunity) }
    end

    def resolve_field(field, contact, opportunity)
      case field.to_s
      when "contact.first_name"   then contact.first_name
      when "contact.last_name"    then contact.last_name
      when "contact.display_name" then contact.display_name
      when "contact.company_name" then contact.company_name
      when "opportunity.title"    then opportunity&.title
      else field
      end.to_s
    end

    def complete_if_done!
      return if @campaign.whatsapp_campaign_recipients.status_pending.exists?

      @campaign.update!(status: "completed", completed_at: Time.current)
    end
  end
end
