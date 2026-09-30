# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # WhatsappConversationsController — bandeja de entrada (inbox) de WhatsApp
    # ========================================================================
    # Agrupa WhatsappMessage por contacto (última actividad + no leídos) en vez
    # de exigir abrir una oportunidad puntual para ver mensajes (RFC §6.6).
    #
    # `?scope=mine|unassigned` filtra el bucket mostrado; sin parámetro devuelve
    # todo lo que `policy_scope(WhatsappMessage)` ya resuelve para el rol
    # (para consultant eso es: propias + red + sin dueño — ver
    # WhatsappMessagePolicy::Scope).
    # ========================================================================
    class WhatsappConversationsController < BaseController
      before_action :set_contact, only: %i[mark_read send_message destroy_messages automation]

      # GET /api/v1/whatsapp_conversations
      def index
        # Solo contactos activos: el chat de un contacto eliminado no se puede responder.
        base = policy_scope(WhatsappMessage).where(contact_id: Contact.kept.select(:id))
        base = apply_bucket_scope(base)

        unread_counts = base.direction_in.where(read_at: nil).group(:contact_id).count

        # distinct(false): WhatsappMessagePolicy::Scope ya deja `.distinct` puesto
        # para consultores (LEFT JOIN a opportunity/contact); combinarlo con nuestro
        # "DISTINCT ON" genera SQL inválido ("SELECT DISTINCT DISTINCT ON (...)").
        latest_ids = base.distinct(false)
                          .select("DISTINCT ON (whatsapp_messages.contact_id) whatsapp_messages.id")
                          .order(:contact_id, created_at: :desc)

        conversations = WhatsappMessage
                        .where(id: latest_ids)
                        .includes(contact: :owner_user, opportunity: %i[pipeline_stage owner_user])
                        .order(created_at: :desc)

        if ActiveModel::Type::Boolean.new.cast(params[:unread])
          conversations = conversations.where(contact_id: unread_counts.keys)
        end

        awaiting_ids = awaiting_contact_ids(base)
        conversations = conversations.where(contact_id: awaiting_ids.to_a) if ActiveModel::Type::Boolean.new.cast(params[:awaiting])

        render_collection(
          conversations,
          with:   WhatsappConversationSerializer,
          params: { unread_counts: unread_counts, awaiting_ids: awaiting_ids, current_user: current_user }
        )
      end

      # GET /api/v1/whatsapp_conversations/stats
      # Liviano a propósito: el SPA lo consulta cada pocos segundos en todas las
      # pantallas. `latest_inbound_id` sube con cada mensaje entrante nuevo →
      # el SPA suena y refresca la bandeja solo cuando cambia (en vez de
      # recargar la lista completa en cada poll).
      def stats
        authorize WhatsappMessage, :index?
        inbound = policy_scope(WhatsappMessage).where(contact_id: Contact.kept.select(:id)).direction_in
        unread = inbound.where(read_at: nil).distinct.count(:contact_id)
        latest_inbound_id = inbound.reorder(nil).maximum(:id)

        render json: { data: { unread: unread, latest_inbound_id: latest_inbound_id,
                               awaiting: awaiting_contact_ids(inbound).size } }, status: :ok
      end

      # PATCH /api/v1/whatsapp_conversations/:contact_id/mark_read
      def mark_read
        authorize @contact, :show?
        unread = policy_scope(WhatsappMessage).inbound.where(contact_id: @contact.id, read_at: nil)
        latest_unread_id = unread.reorder(nil).maximum(:id)
        count = unread.update_all(read_at: Time.current)

        # «Visto» en WhatsApp (doble check azul para el lead). Async: no frena la bandeja.
        WhatsappReadReceiptJob.perform_later(latest_unread_id) if latest_unread_id

        Notification.where(
          user: current_user, resource: @contact,
          kind: "whatsapp_message_received", read_at: nil
        ).update_all(read_at: Time.current)

        AuditLogger.record!(
          tenant:      current_tenant,
          user:        current_user,
          action:      "whatsapp_conversation_read",
          entity_type: "Contact",
          entity_id:   @contact.id,
          metadata:    { count: count },
          ip_address:  request.remote_ip,
          user_agent:  request.user_agent
        )
        head :no_content
      end

      # PATCH /api/v1/whatsapp_conversations/:contact_id/automation { paused: true|false }
      # «Pausar automático»: un asesor toma el control y no se envían respuestas
      # automáticas a este contacto (hoy: «Mensaje al autorizar»; luego: agente IA).
      def automation
        authorize @contact, :reply_whatsapp?
        paused = ActiveModel::Type::Boolean.new.cast(params.require(:paused))
        @contact.update_columns(whatsapp_automation_paused_at: paused ? Time.current : nil, updated_at: Time.current)

        AuditLogger.record!(
          tenant: current_tenant, user: current_user,
          action: paused ? "whatsapp_automation_paused" : "whatsapp_automation_resumed",
          entity_type: "Contact", entity_id: @contact.id,
          ip_address: request.remote_ip, user_agent: request.user_agent
        )
        render json: { data: { paused: paused } }, status: :ok
      end

      # DELETE /api/v1/whatsapp_conversations/:contact_id/messages — «Eliminar
      # conversación»: borra del CRM los mensajes de WhatsApp de ese contacto
      # (no del celular del cliente). Admin, manager o el dueño del contacto.
      def destroy_messages
        authorize @contact, :update?
        count = WhatsApp::ConversationEraser.call(policy_scope(WhatsappMessage).where(contact_id: @contact.id))

        AuditLogger.record!(
          tenant:      current_tenant,
          user:        current_user,
          action:      "whatsapp_conversation_deleted",
          entity_type: "Contact",
          entity_id:   @contact.id,
          metadata:    { count: count },
          ip_address:  request.remote_ip,
          user_agent:  request.user_agent
        )
        render json: { data: { deleted: count } }, status: :ok
      end

      # POST /api/v1/whatsapp_conversations/:contact_id/send_message
      # body: { to_number, body, media_url? }
      def send_message
        authorize @contact, :reply_whatsapp?

        opportunity = @contact.opportunities.where.not(status: %w[won lost])
                              .order(last_activity_at: :desc).first

        result = WhatsApp::OutboundSender.call(
          tenant:               current_tenant,
          contact:              @contact,
          opportunity:          opportunity,
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
          AuditLogger.record!(
            tenant:      current_tenant,
            user:        current_user,
            action:      "whatsapp_message_sent",
            entity_type: "WhatsappMessage",
            entity_id:   result.message.id,
            metadata:    { contact_id: @contact.id, provider: result.message.provider, status: result.message.status },
            ip_address:  request.remote_ip,
            user_agent:  request.user_agent
          )
          render json: WhatsappMessageSerializer.new(result.message).serializable_hash, status: :accepted
        end
      end

      private

      def apply_bucket_scope(scope)
        case params[:scope]
        when "mine"
          scope.left_joins(:opportunity)
               .where(
                 "opportunities.owner_user_id = :uid OR whatsapp_messages.contact_id IN (:contact_ids)",
                 uid: current_user.id,
                 contact_ids: current_tenant.contacts.kept.where(owner_user_id: current_user.id).select(:id)
               )
        when "unassigned"
          scope.where(opportunity_id: nil)
               .where(contact_id: current_tenant.contacts.kept.where(owner_user_id: nil).select(:id))
        else
          scope
        end
      end

      # Contactos visibles para el usuario que dijeron «Sí» y esperan respuesta de una persona.
      def awaiting_contact_ids(messages)
        Contact.kept.whatsapp_awaiting_reply
               .where(id: messages.reorder(nil).distinct(false).select(:contact_id))
               .pluck(:id).to_set
      end

      def set_contact
        @contact = policy_scope(Contact).kept.find(params[:contact_id])
      end
    end
  end
end
