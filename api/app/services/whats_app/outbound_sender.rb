# frozen_string_literal: true

module WhatsApp
  # ============================================================================
  # WhatsApp::OutboundSender — arma y despacha un WhatsappMessage saliente.
  # ============================================================================
  # Extraído de WhatsappMessagesController#create para reutilizarse también
  # desde el envío standalone del inbox (WhatsappConversationsController), sin
  # depender de que exista una Opportunity.
  #
  # Envío síncrono (WhatsappDeliveryJob.perform_now): el caller espera el
  # resultado del proveedor (status/error_message) en la misma petición HTTP,
  # sin depender de que Solid Queue/Sidekiq estén levantados.
  # ============================================================================
  class OutboundSender
    Result = Struct.new(:message, :error_code, keyword_init: true) do
      def success?
        error_code.nil?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(tenant:, contact:, to_number:, body:, opportunity: nil, media_url: nil, whatsapp_template_id: nil,
                   template_params: [])
      @tenant                = tenant
      @contact               = contact
      @to_number             = to_number
      @body                  = body
      @opportunity           = opportunity
      @media_url             = media_url
      @whatsapp_template_id  = whatsapp_template_id
      @template_params       = template_params
    end

    def call
      provider    = @tenant.whatsapp_outbound_provider
      from_number = @tenant.whatsapp_outbound_from_number_for(provider)
      return Result.new(error_code: :not_configured) if from_number.blank?

      template = @tenant.whatsapp_templates.active.find(@whatsapp_template_id) if @whatsapp_template_id.present?

      msg = build_message(provider, from_number, template)
      return Result.new(message: msg, error_code: :invalid) unless msg.save

      WhatsappDeliveryJob.perform_now(msg.id)
      msg.reload
      @opportunity&.touch_activity!

      Result.new(message: msg)
    end

    private

    def build_message(provider, from_number, template)
      WhatsappMessage.new(
        tenant:                  @tenant,
        opportunity:             @opportunity,
        contact:                 @contact,
        direction:               "out",
        provider:                provider,
        from_number:             from_number,
        to_number:               WhatsappPhone.normalize_to_e164(@to_number),
        body:                    template ? nil : @body,
        media_url:               template ? nil : @media_url,
        message_type:            template ? "template" : "text",
        template_name:           template&.meta_template_name,
        template_language:       template&.language,
        template_params:         template ? Array(@template_params) : [],
        template_variable_names: template ? Array(template.variable_names) : [],
        status:                  "queued"
      )
    end
  end
end
