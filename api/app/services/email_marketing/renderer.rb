# frozen_string_literal: true

module EmailMarketing
  # ==========================================================================
  # EmailMarketing::Renderer — arma el correo final de un destinatario
  # ==========================================================================
  # - Variables: {{nombre}}, {{apellido}}, {{nombre_completo}}, {{empresa}},
  #   {{asesor}}; con valor por defecto: {{nombre|cliente}}.
  # - Agrega el texto de vista previa (preheader) oculto y el pie obligatorio
  #   con la dirección del remitente y el enlace «Darme de baja».
  # - Devuelve también la versión en texto plano.
  # ==========================================================================
  class Renderer
    VARIABLE = /\{\{\s*([a-z_]+)\s*(?:\|([^}]*))?\}\}/i
    VARIABLES = %w[nombre apellido nombre_completo empresa asesor].freeze

    Result = Struct.new(:subject, :html, :text, keyword_init: true)

    def self.call(...) = new(...).call

    # recipient: EmailCampaignRecipient (o nil para el envío de prueba).
    def initialize(campaign:, contact:, opportunity: nil, unsubscribe_url: "#")
      @campaign        = campaign
      @contact         = contact
      @opportunity     = opportunity
      @unsubscribe_url = unsubscribe_url
      @sender          = campaign.tenant.email_sender
    end

    def call
      subject = interpolate(@campaign.subject.to_s, html: false)
      body    = interpolate(@campaign.body_html.to_s, html: true)
      Result.new(subject: subject, html: document(body, subject), text: text_version(body))
    end

    def values
      @values ||= {
        "nombre"          => @contact&.kind_company? ? @contact.company_name : @contact&.first_name,
        "apellido"        => @contact&.last_name,
        "nombre_completo" => @contact&.display_name,
        "empresa"         => @contact&.company_name,
        "asesor"          => (@opportunity&.owner_user || @contact&.owner_user)&.name
      }
    end

    private

    def interpolate(template, html:)
      template.gsub(VARIABLE) do
        key, fallback = Regexp.last_match(1).downcase, Regexp.last_match(2)
        next Regexp.last_match(0) unless VARIABLES.include?(key)

        value = values[key].presence || fallback.to_s.strip
        html ? ERB::Util.html_escape(value) : value
      end
    end

    def document(body, subject)
      <<~HTML
        <!DOCTYPE html>
        <html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{ERB::Util.html_escape(subject)}</title></head>
        <body style="margin:0;padding:0;background:#f4f4f5;">
        #{preheader}#{body}#{footer}
        </body></html>
      HTML
    end

    def preheader
      return "" if @campaign.preheader.blank?

      %(<div style="display:none;max-height:0;overflow:hidden;opacity:0;">#{ERB::Util.html_escape(@campaign.preheader)}</div>)
    end

    def footer
      lines = [ ERB::Util.html_escape(@sender.from_name) ]
      lines << ERB::Util.html_escape(@sender.address) if @sender.address
      <<~HTML
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
        <td align="center" style="padding:24px 16px;font-family:Arial,sans-serif;font-size:12px;line-height:18px;color:#71717a;">
        #{lines.join('<br>')}<br>
        Recibes este correo porque estás en contacto con nosotros.
        <a href="#{ERB::Util.html_escape(@unsubscribe_url)}" style="color:#71717a;text-decoration:underline;">Darme de baja</a>
        </td></tr></table>
      HTML
    end

    def text_version(body)
      text = Nokogiri::HTML5.fragment(body.gsub(%r{<br[^>]*>|</p>|</tr>|</h\d>}i, "\n")).text
      text = text.gsub(/[ \t]+/, " ").gsub(/\n\s*\n+/, "\n\n").strip
      [ text, "—", @sender.from_name, @sender.address, "Darme de baja: #{@unsubscribe_url}" ].compact.join("\n")
    end
  end
end
