# frozen_string_literal: true

module WhatsApp
  # ============================================================================
  # WhatsApp::ConsentReply — interpreta una respuesta entrante como sí/no
  # ============================================================================
  # Usado por WhatsappMessage al recibir un mensaje: decide si el texto (o el
  # botón de respuesta rápida, que llega como texto) es una negativa o una
  # autorización explícita. Deliberadamente conservador: solo reconoce
  # respuestas cortas y completas ("No", "No autorizo", "Stop"…), nunca
  # busca "no" dentro de una frase ("no sé, cuéntame más" → nil).
  # ============================================================================
  module ConsentReply
    module_function

    OPT_OUT = [
      "no", "no autorizo", "no lo autorizo", "no acepto", "no gracias", "no quiero",
      "no me interesa", "no me escriban", "no me escribas", "no deseo",
      "stop", "parar", "detener", "baja", "darme de baja", "cancelar", "unsubscribe"
    ].to_set.freeze

    OPT_IN = [
      "si", "si autorizo", "si lo autorizo", "autorizo", "si acepto", "acepto", "si claro", "claro que si"
    ].to_set.freeze

    # :opt_out, :opt_in o nil (respuesta que no es sobre consentimiento).
    def classify(text)
      normalized = normalize(text)
      return nil if normalized.blank?
      return :opt_out if OPT_OUT.include?(normalized)
      return :opt_in  if OPT_IN.include?(normalized)

      nil
    end

    # "¡No, autorizo!" → "no autorizo" · "Sí 👍" → "si"
    def normalize(text)
      I18n.transliterate(text.to_s.unicode_normalize(:nfkc))
          .downcase
          .gsub(/[^a-z\s]/, " ")
          .squish
    end
  end
end
