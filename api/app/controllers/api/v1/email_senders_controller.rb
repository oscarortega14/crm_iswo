# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # EmailSendersController — remitente de campañas de correo del tenant
    # ========================================================================
    # Dominio propio verificado en AWS SES (ver EmailMarketing::Sender).
    # admin/manager lo consultan; solo admin lo cambia y lo verifica.
    # ========================================================================
    class EmailSendersController < BaseController
      # GET /api/v1/email_sender
      def show
        authorize EmailCampaign, :index?
        render_sender
      end

      # PATCH /api/v1/email_sender { email_sender: { domain, from_local, from_name, reply_to, address } }
      def update
        authorize EmailCampaign, :manage_sender?
        attrs = params.require(:email_sender).permit(*EmailMarketing::Sender::EDITABLE)
        sender.update!(attrs)
        audit!("email_sender.update", attrs.to_h)
        render_sender
      rescue ArgumentError => e
        render json: { error: "invalid", message: e.message }, status: :unprocessable_content
      end

      # POST /api/v1/email_sender/verify — registra el dominio en SES y trae los registros DNS.
      def verify
        authorize EmailCampaign, :manage_sender?
        sender.start_verification!
        audit!("email_sender.verify", { domain: sender.domain, status: sender.status })
        render_sender
      rescue ArgumentError, Aws::SESV2::Errors::ServiceError => e
        render json: { error: "ses_error", message: e.message }, status: :unprocessable_content
      end

      # POST /api/v1/email_sender/refresh — vuelve a consultar si ya está verificado.
      def refresh
        authorize EmailCampaign, :manage_sender?
        sender.refresh!
        render_sender
      rescue ArgumentError, Aws::SESV2::Errors::ServiceError => e
        render json: { error: "ses_error", message: e.message }, status: :unprocessable_content
      end

      private

      def sender
        @sender ||= current_tenant.email_sender
      end

      def render_sender
        render json: { data: sender.as_json }
      end

      def audit!(action, metadata)
        AuditLogger.record!(tenant: current_tenant, user: current_user, action: action,
                            entity_type: "Tenant", entity_id: current_tenant.id, metadata: metadata,
                            ip_address: request.remote_ip, user_agent: request.user_agent)
      end
    end
  end
end
