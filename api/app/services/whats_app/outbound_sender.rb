# frozen_string_literal: true

module WhatsApp
  # ============================================================================
  # WhatsApp::OutboundSender — arma y despacha un WhatsappMessage saliente.
  # ============================================================================
  # Extraído de WhatsappMessagesController#create para reutilizarse también
  # desde el envío standalone del inbox (WhatsappConversationsController), sin
  # depender de que exista una Opportunity.
  #
  # Envío asíncrono (WhatsappDeliveryJob.perform_later, cola "integrations"):
  # el caller recibe el mensaje en estado "queued" de inmediato, sin esperar
  # a Meta (hasta 10s de timeout por request, ver WhatsApp::Adapters::
  # Base::DEFAULT_TIMEOUT). El frontend lo pinta al toque (optimista) y el
  # estado real (sent/delivered/failed) llega en el siguiente poll del hilo.
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

    # provider: fuerza el proveedor (p. ej. responder por el mismo canal por el
    # que escribió el contacto). automated: lo envía una automatización.
    def initialize(tenant:, contact:, to_number:, body:, opportunity: nil, media_url: nil, whatsapp_template_id: nil,
                   template_params: [], provider: nil, automated: false)
      @tenant                = tenant
      @contact               = contact
      @to_number             = to_number
      @body                  = body
      @opportunity           = opportunity
      @media_url             = media_url
      @whatsapp_template_id  = whatsapp_template_id
      @template_params       = template_params
      @provider              = provider
      @automated             = automated
    end

    def call
      provider = @provider.presence || @tenant.whatsapp_outbound_provider
      # whatsapp_outbound_from_number_for("whatsapp_cloud") siempre devuelve un label no-blank
      # ("whatsapp-cloud") aunque no haya credenciales reales — Meta no usa ese campo en el POST,
      # así que el chequeo de "no configurado" para Cloud tiene que ser explícito.
      return Result.new(error_code: :not_configured) if
        provider == "whatsapp_cloud" && !@tenant.whatsapp_cloud_configured?

      from_number = @tenant.whatsapp_outbound_from_number_for(provider)
      return Result.new(error_code: :not_configured) if from_number.blank?

      template = @tenant.whatsapp_templates.active.find(@whatsapp_template_id) if @whatsapp_template_id.present?

      msg = build_message(provider, from_number, template)
      return Result.new(message: msg, error_code: :invalid) unless msg.save

      WhatsappDeliveryJob.perform_later(msg.id)
      # Un mensaje automático no recalcula la temperatura por reglas: la del
      # asistente IA (calificar_lead) debe quedarse.
      @opportunity&.touch_activity!(recalc_temperature: !@automated)

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
        status:                  "queued",
        automated:               @automated
      )
    end
  end
end
