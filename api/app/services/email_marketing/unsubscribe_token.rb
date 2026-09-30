# frozen_string_literal: true

module EmailMarketing
  # Token firmado del enlace «Darme de baja» (sin vencimiento: un correo
  # viejo debe poder seguir dando de baja). Identifica al destinatario.
  module UnsubscribeToken
    PURPOSE = :email_unsubscribe

    module_function

    def generate(recipient)
      verifier.generate({ "r" => recipient.id }, purpose: PURPOSE)
    end

    # → EmailCampaignRecipient o nil si el token es inválido.
    def recipient_for(token)
      data = verifier.verified(token.to_s, purpose: PURPOSE)
      return nil unless data.is_a?(Hash) && data["r"]

      ActsAsTenant.without_tenant { EmailCampaignRecipient.find_by(id: data["r"]) }
    end

    def url(recipient)
      "#{api_origin}/api/v1/public/email/unsubscribe?t=#{generate(recipient)}"
    end

    def api_origin
      ENV["API_PUBLIC_ORIGIN"].presence&.chomp("/") ||
        (Rails.env.production? ? "https://#{ENV.fetch('APP_HOST', 'iswocrm.com')}" : "http://localhost:3000")
    end

    def verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(
        Rails.application.key_generator.generate_key("email_marketing/unsubscribe"),
        digest: "SHA256", serializer: JSON, url_safe: true
      )
    end
  end
end
