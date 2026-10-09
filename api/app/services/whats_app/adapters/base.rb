# frozen_string_literal: true

module WhatsApp
  module Adapters
    # ==========================================================================
    # WhatsApp::Adapters::Base — clase base para adapters de WhatsApp.
    # ==========================================================================
    # Cada adapter concreto debe implementar:
    #
    #   #deliver(message) -> { provider_message_id:, status: }
    #
    # Convenciones:
    #   - Lee credenciales del tenant.settings["whatsapp"] con fallback a ENV.
    #   - Normaliza números a formato E.164 (+573001234567) antes de enviar.
    #   - Ante error HTTP o transporte, eleva WhatsApp::MessageSender::DeliveryError.
    #   - NO persiste nada: el sender hace el update del WhatsappMessage.
    # ==========================================================================
    class Base
      DEFAULT_TIMEOUT = 10 # segundos

      def initialize(tenant:)
        @tenant = tenant
        @settings = tenant.respond_to?(:settings) ? (tenant.settings || {}) : {}
      end

      def deliver(_message)
        raise NotImplementedError, "#{self.class}#deliver debe ser implementado"
      end

      # Confirmación de lectura («visto», doble check azul del lado del lead).
      # Por defecto no-op: solo lo soportan los proveedores que lo implementen.
      # @return [Boolean] true si el proveedor aceptó la confirmación
      def mark_read(_provider_message_id)
        false
      end

      private

      # Lee una clave desde tenant.settings["whatsapp"][...] con fallback a ENV.
      def tenant_setting(key, env_key)
        value = @settings.dig("whatsapp", key.to_s) || @settings.dig("whatsapp", key.to_sym)
        value.presence || ENV[env_key].presence
      end

      def faraday(base_url:, headers: {})
        Faraday.new(url: base_url, headers: headers) do |f|
          f.request  :url_encoded
          f.response :json, content_type: /\bjson$/
          f.options.timeout      = DEFAULT_TIMEOUT
          f.options.open_timeout = DEFAULT_TIMEOUT
        end
      end

      # Quita prefijos "whatsapp:" / espacios / guiones y garantiza un "+".
      # No hace parsing real de E.164 — para eso usar Phonelib antes de persistir.
      def normalize_e164(number)
        s = number.to_s.strip.sub(/\Awhatsapp:/, "").gsub(/[\s\-()]/, "")
        s.start_with?("+") ? s : "+#{s.sub(/\A\+?/, "")}"
      end

      def raise_delivery!(message)
        raise WhatsApp::MessageSender::DeliveryError, message
      end
    end
  end
end
