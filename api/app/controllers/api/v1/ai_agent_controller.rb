# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # AiAgentController — Ajustes → Asistente IA (WhatsApp)
    # ========================================================================
    #   GET   /api/v1/ai_agent           configuración (admin/manager)
    #   PATCH /api/v1/ai_agent           guardar / activar (admin)
    #   POST  /api/v1/ai_agent/test      probar con una conversación simulada (admin)
    #   GET   /api/v1/ai_agent/activity  últimas respuestas y consumo (admin/manager)
    #   POST  /api/v1/ai_agent/chats     pausar / reanudar el asistente en todos los chats (admin)
    # ========================================================================
    class AiAgentController < BaseController
      def show
        authorize :ai_agent, :show?
        render json: { data: agent_config.as_json }
      end

      def update
        authorize :ai_agent, :update?
        attrs = params.require(:ai_agent).permit(:enabled, *AiAgent::Config::TEXT_FIELDS)
        was_enabled = agent_config.enabled?
        agent_config.update!(attrs)
        # Al encender: no meterse en conversaciones que un asesor ya lleva a mano.
        paused = 0
        if !was_enabled && current_tenant.reload.ai_agent_config.enabled? &&
           ActiveModel::Type::Boolean.new.cast(params[:pause_human_chats])
          config = current_tenant.ai_agent_config
          paused = config.set_paused!(config.human_chats, paused: true)
        end
        @agent_config = nil
        AuditLogger.record!(tenant: current_tenant, user: current_user, action: "ai_agent.update",
                            entity_type: "Tenant", entity_id: current_tenant.id,
                            metadata: { enabled: agent_config.enabled?, fields: attrs.keys, paused_chats: paused },
                            ip_address: request.remote_ip, user_agent: request.user_agent)
        render json: { data: current_tenant.reload.ai_agent_config.as_json, meta: { paused_now: paused } }
      rescue ArgumentError => e
        render json: { error: "invalid", message: e.message }, status: :unprocessable_content
      end

      # body: { paused: true|false } — «Pausar todos» / «Reanudar todos»
      def chats
        authorize :ai_agent, :update?
        paused = ActiveModel::Type::Boolean.new.cast(params.require(:paused))
        count = agent_config.set_paused!(agent_config.chat_contacts, paused: paused)
        AuditLogger.record!(tenant: current_tenant, user: current_user,
                            action: paused ? "ai_agent.pause_all" : "ai_agent.resume_all",
                            entity_type: "Tenant", entity_id: current_tenant.id, metadata: { chats: count },
                            ip_address: request.remote_ip, user_agent: request.user_agent)
        render json: { data: agent_config.as_json, meta: { changed: count } }
      end

      # body: { messages: [{ role: "user"|"assistant", content }] }
      def test
        authorize :ai_agent, :test?
        unless AiAgent::OpenaiClient.configured?
          return render json: { error: "not_configured", message: "Falta configurar la clave de OpenAI en el servidor." },
                        status: :unprocessable_content
        end
        if agent_config.business_info.blank?
          return render json: { error: "invalid", message: "Escribe primero la información del negocio." },
                        status: :unprocessable_content
        end

        messages = Array(params[:messages]).map { |m| m.permit(:role, :content).to_h }
        result = AiAgent::Responder.preview(tenant: current_tenant, messages: messages)
        render json: { data: { reply: result.reply, status: result.status, tool_calls: result.tool_calls } }
      rescue AiAgent::OpenaiClient::Error => e
        render json: { error: "ai_error", message: e.message }, status: :bad_gateway
      end

      def activity
        authorize :ai_agent, :activity?
        runs = current_tenant.ai_agent_runs.recent.includes(:contact, :reply_message).limit(50)
        since = 30.days.ago
        totals = current_tenant.ai_agent_runs.where(created_at: since..)
        render json: {
          data: runs.map { |r| run_json(r) },
          meta: {
            last_30_days: {
              replies:       totals.where(status: %w[replied handoff]).count,
              handoffs:      totals.where(status: "handoff").count,
              errors:        totals.where(status: "error").count,
              input_tokens:  totals.sum(:input_tokens),
              output_tokens: totals.sum(:output_tokens)
            }
          }
        }
      end

      private

      def agent_config
        @agent_config ||= current_tenant.ai_agent_config
      end

      def run_json(run)
        {
          id: run.id.to_s, status: run.status, created_at: run.created_at,
          contact_id: run.contact_id.to_s, contact_name: run.contact&.display_name,
          reply: run.reply_message&.body, tool_calls: run.tool_calls, error: run.error,
          input_tokens: run.input_tokens, output_tokens: run.output_tokens
        }
      end
    end
  end
end
