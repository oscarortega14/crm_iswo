# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # WhatsappMessagesController — listar / ver / enviar mensajes
    # ========================================================================
    # Los mensajes entrantes no se crean acá — entran por webhook.
    # ========================================================================
    class WhatsappMessagesController < BaseController
      before_action :set_opportunity, only: %i[create destroy_all]
      before_action :set_message, only: :show

      # GET /api/v1/whatsapp_messages (standalone, anidado, o por contacto)
      def index
        scope = if params[:opportunity_id].present?
                  opp = policy_scope(Opportunity).kept.find(params[:opportunity_id])
                  authorize opp, :show?
                  opp.whatsapp_messages
                elsif params[:contact_id].present?
                  policy_scope(WhatsappMessage).where(contact_id: params[:contact_id])
                else
                  policy_scope(WhatsappMessage)
                end

        render_collection(scope.recent, with: WhatsappMessageSerializer)
      end

      def show
        authorize @message
        params_hash = { include_raw: ActiveModel::Type::Boolean.new.cast(params[:include_raw]) }
        render_resource(@message, with: WhatsappMessageSerializer, params: params_hash)
      end

      # DELETE /api/v1/opportunities/:opportunity_id/whatsapp_messages
      def destroy_all
        authorize @opportunity, :update?
        count = WhatsApp::ConversationEraser.call(@opportunity.whatsapp_messages)
        log_whatsapp_audit!("whatsapp_messages_cleared", metadata: { count: count })
        head :no_content
      end

      # POST /api/v1/opportunities/:opportunity_id/whatsapp_messages
      # body: { to_number, body, media_url? }
      def create
        authorize @opportunity, :update?

        result = WhatsApp::OutboundSender.call(
          tenant:               current_tenant,
          contact:              @opportunity.contact,
          opportunity:          @opportunity,
          to_number:            params.require(:to_number),
          body:                 params[:body],
          media_url:            params[:media_url],
          whatsapp_template_id: params[:whatsapp_template_id],
          template_params:      params[:template_params]
        )

        case result.error_code
        when :not_configured
          render json: {
            error:   "whatsapp_not_configured",
            message: "Configura el envío saliente en Ajustes → Integraciones: " \
                     "WhatsApp Cloud API (Phone number ID + access token) " \
                     "u OpenWA (URL + API Key + Session ID)."
          }, status: :unprocessable_entity
        when :invalid
          render_unprocessable(result.message)
        else
          log_whatsapp_audit!("whatsapp_message_sent", message: result.message)
          render json: WhatsappMessageSerializer.new(result.message).serializable_hash, status: :accepted
        end
      end

      private

      def log_whatsapp_audit!(action, message: nil, metadata: {})
        meta = metadata.merge(opportunity_id: @opportunity.id)
        if message
          meta[:message_id] = message.id
          meta[:provider]    = message.provider
          meta[:status]      = message.status
        end

        AuditLogger.record!(
          tenant:      current_tenant,
          user:        current_user,
          action:      action,
          entity_type: "WhatsappMessage",
          entity_id:   message&.id,
          metadata:    meta,
          ip_address:  request.remote_ip,
          user_agent:  request.user_agent
        )
      end

      def set_opportunity
        @opportunity = policy_scope(Opportunity).kept.find(params[:opportunity_id])
      end

      def set_message
        @message = policy_scope(WhatsappMessage).find(params[:id])
      end
    end
  end
end
