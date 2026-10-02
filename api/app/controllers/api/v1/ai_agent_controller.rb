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
    #   POST  /api/v1/ai_agent/calendar_test            probar la agenda de Google (admin)
    #   GET   /api/v1/ai_agent/appointments             próximas citas (admin/manager)
    #   POST  /api/v1/ai_agent/appointments/:id/cancel  cancelar una cita (admin/manager)
    #   POST  /api/v1/ai_agent/appointments/:id/outcome { outcome: attended|no_show } (admin/manager)
    # ========================================================================
    class AiAgentController < BaseController
      def show
        authorize :ai_agent, :show?
        render json: { data: agent_config.as_json }
      end

      def update
        authorize :ai_agent, :update?
        attrs = params.require(:ai_agent).permit(
          :enabled, *AiAgent::Config::TEXT_FIELDS,
          calendar: [ :calendar_id, :duration_minutes, :start_time, :end_time, :min_notice_hours, :max_days_ahead,
                      :location, { work_days: [] } ],
          reminders: [ :whatsapp_template_id, :no_show_template_id, :email_enabled, :staff_offset_minutes,
                       :daily_summary, :no_show_followup, { client_offsets: [] } ]
        )
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

      def calendar_test
        authorize :ai_agent, :test?
        scheduler = AiAgent::Scheduler.new(current_tenant)
        slots = scheduler.available_slots(limit: 5)
        render json: { data: { ok: true, slots: slots.map { |s| { starts_at: s.iso8601, label: scheduler.label(s) } } } }
      rescue AiAgent::GoogleCalendar::Error => e
        render json: { error: "calendar_error", message: e.message }, status: :unprocessable_content
      end

      def appointments
        authorize :ai_agent, :appointments?
        scheduler = AiAgent::Scheduler.new(current_tenant)
        upcoming = current_tenant.appointments.upcoming.includes(:contact, :owner_user).limit(50)
        pending  = current_tenant.appointments.awaiting_outcome.where(starts_at: 14.days.ago..)
                                 .includes(:contact, :owner_user).limit(50)
        render json: {
          data: upcoming.map { |a| appointment_json(a, scheduler) },
          meta: { awaiting_outcome: pending.map { |a| appointment_json(a, scheduler) } }
        }
      end

      def cancel_appointment
        authorize :ai_agent, :cancel_appointment?
        appointment = current_tenant.appointments.find(params[:id])
        AiAgent::Scheduler.new(current_tenant).cancel!(appointment)
        AuditLogger.record!(tenant: current_tenant, user: current_user, action: "appointment.cancel",
                            entity_type: "Appointment", entity_id: appointment.id,
                            ip_address: request.remote_ip, user_agent: request.user_agent)
        head :no_content
      rescue AiAgent::GoogleCalendar::Error => e
        render json: { error: "calendar_error", message: e.message }, status: :unprocessable_content
      end

      # Después de la cita: asistió (completed) o no asistió (no_show → mensaje para reagendar).
      def appointment_outcome
        authorize :ai_agent, :cancel_appointment?
        appointment = current_tenant.appointments.status_scheduled.find(params[:id])
        outcome = params.require(:outcome).to_s
        unless %w[attended no_show].include?(outcome)
          return render json: { error: "invalid", message: "Resultado inválido." }, status: :unprocessable_content
        end

        appointment.update!(status: outcome == "attended" ? "completed" : "no_show", outcome_at: Time.current)
        AiAgent::AppointmentReminders.new(current_tenant).send_no_show_followup!(appointment) if outcome == "no_show"
        AuditLogger.record!(tenant: current_tenant, user: current_user, action: "appointment.#{outcome}",
                            entity_type: "Appointment", entity_id: appointment.id,
                            ip_address: request.remote_ip, user_agent: request.user_agent)
        render json: { data: { status: appointment.status, no_show_followup_at: appointment.reload.no_show_followup_at } }
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

      def appointment_json(appointment, scheduler)
        {
          id: appointment.id.to_s, starts_at: appointment.starts_at, ends_at: appointment.ends_at,
          label: scheduler.label(appointment.starts_at), contact_id: appointment.contact_id.to_s,
          contact_name: appointment.contact&.display_name, owner_name: appointment.owner_user&.name,
          notes: appointment.notes, source: appointment.source, confirmed_at: appointment.confirmed_at,
          reminders_sent: appointment.client_reminders.reject { |_, v| v["skipped"] }.keys.map(&:to_i).sort.reverse
        }
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
