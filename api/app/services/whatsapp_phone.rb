# frozen_string_literal: true

# Normaliza números de teléfono hacia E.164 para WhatsApp (salida Meta/OpenWA).
module WhatsappPhone
  module_function

  DEFAULT_REGION = ENV.fetch("PHONELIB_DEFAULT_REGION", "CO").freeze

  # @param raw [String] teléfono tal cual lo envía el cliente (whatsapp:, espacios, sin +, etc.)
  # @return [String] E.164 cuando Phonelib puede parsear; si no, dígitos con prefijo "+".
  def normalize_to_e164(raw)
    s = raw.to_s.strip.sub(/\Awhatsapp:/i, "").gsub(/[\s\-()]/, "")
    return s if s.blank?

    parsed = Phonelib.parse(s, DEFAULT_REGION)
    return parsed.e164 if parsed.valid?

    # Fallback LATAM típico: celular CO 10 dígitos empezando en 3
    digits = s.gsub(/\D/, "")
    if /\A3\d{9}\z/.match?(digits)
      retry_parsed = Phonelib.parse("+57#{digits}")
      return retry_parsed.e164 if retry_parsed.valid?
    end

    return "+#{digits}" if digits.present?

    s.start_with?("+") ? s : "+#{s}"
  end
end
