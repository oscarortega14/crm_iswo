# frozen_string_literal: true

module Api
  module V1
    module Public
      # ========================================================================
      # Public::EmailUnsubscribesController — «Darme de baja» de campañas
      # ========================================================================
      # Sin sesión: el token firmado (EmailMarketing::UnsubscribeToken)
      # identifica al destinatario y su tenant.
      #   GET  → página de confirmación con un botón (los filtros antispam
      #          abren los enlaces, así que visitar no da de baja).
      #   POST → da de baja. También lo usan Gmail/Yahoo con el encabezado
      #          List-Unsubscribe-Post (baja en un clic).
      # Responde HTML simple (se abre desde el correo, no desde la SPA).
      # ========================================================================
      class EmailUnsubscribesController < BaseController
        skip_before_action :authenticate_user!,            raise: false
        skip_before_action :verify_user_belongs_to_tenant, raise: false
        skip_before_action :resolve_tenant!,               raise: false
        skip_around_action :scope_to_tenant,               raise: false

        before_action :set_recipient

        # GET /api/v1/public/email/unsubscribe?t=TOKEN
        def show
          name = ERB::Util.html_escape(@recipient.tenant.email_sender.from_name)
          render_page("¿Dejar de recibir correos de #{name}?", <<~HTML)
            <p>Ya no te enviaremos correos de campañas a <strong>#{ERB::Util.html_escape(@recipient.email)}</strong>.</p>
            <form method="post" action="?t=#{ERB::Util.url_encode(params[:t])}">
              <button type="submit">Confirmar baja</button>
            </form>
          HTML
        end

        # POST /api/v1/public/email/unsubscribe?t=TOKEN
        def create
          ActsAsTenant.with_tenant(@recipient.tenant) do
            first_time = @recipient.unsubscribed_at.nil?
            @recipient.update!(unsubscribed_at: Time.current) if first_time
            @recipient.contact&.mark_email_opt_out!(source: "unsubscribe")
            audit! if first_time
          end

          name = ERB::Util.html_escape(@recipient.tenant.email_sender.from_name)
          render_page("Listo, te diste de baja", "<p>No volverás a recibir correos de campañas de #{name}.</p>")
        end

        private

        def set_recipient
          @recipient = EmailMarketing::UnsubscribeToken.recipient_for(params[:t])
          render_page("Enlace no válido", "<p>Este enlace de baja no es válido o ya no existe.</p>", status: :not_found) unless @recipient
        end

        def audit!
          AuditLogger.record!(
            tenant: @recipient.tenant, user: nil, action: "contact.email_unsubscribe",
            entity_type: "Contact", entity_id: @recipient.contact_id,
            metadata: { email_campaign_id: @recipient.email_campaign_id }
          )
        end

        def render_page(title, body, status: :ok)
          render status: status, html: <<~HTML.html_safe
            <!DOCTYPE html><html lang="es"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">
            <title>#{title}</title>
            <style>
              body{margin:0;font-family:system-ui,Arial,sans-serif;background:#f4f4f5;color:#18181b}
              main{max-width:440px;margin:12vh auto;padding:32px 24px;background:#fff;border-radius:12px;
                   box-shadow:0 1px 3px rgba(0,0,0,.08);text-align:center}
              h1{font-size:20px;margin:0 0 12px} p{line-height:1.5;color:#52525b}
              button{margin-top:12px;padding:12px 20px;border:0;border-radius:8px;background:#18181b;color:#fff;
                     font-size:15px;cursor:pointer;width:100%}
            </style></head>
            <body><main><h1>#{title}</h1>#{body}</main></body></html>
          HTML
        end
      end
    end
  end
end
