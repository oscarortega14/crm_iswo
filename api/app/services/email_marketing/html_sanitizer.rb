# frozen_string_literal: true

module EmailMarketing
  # Limpia el HTML del editor antes de guardarlo: solo etiquetas y atributos
  # de correo (tablas, estilos en línea, imágenes, enlaces). Quita scripts,
  # formularios, iframes y manejadores de eventos.
  module HtmlSanitizer
    TAGS = %w[
      a b big blockquote br center div em font h1 h2 h3 h4 h5 h6 hr i img li ol p pre s small span
      strike strong sub sup table tbody td tfoot th thead tr u ul style
    ].freeze

    ATTRIBUTES = %w[
      align alt bgcolor border cellpadding cellspacing class color colspan dir face height href
      id lang role rowspan size src style target title valign width
    ].freeze

    module_function

    def call(html)
      return html if html.blank?

      Rails::HTML5::SafeListSanitizer.new.sanitize(html.to_s, tags: TAGS, attributes: ATTRIBUTES)
    end
  end
end
