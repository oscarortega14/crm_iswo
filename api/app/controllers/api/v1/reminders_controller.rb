# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # RemindersController — recordatorios standalone y anidados a oportunidad
    # ========================================================================
    class RemindersController < BaseController
      before_action :set_opportunity, only: %i[create]
      before_action :set_reminder,    only: %i[show update destroy complete snooze]

      # GET /api/v1/reminders/stats
      def stats
        authorize Reminder, :index?
        payload = Reminders::Stats.new(user: current_user).call
        render json: { data: payload }, status: :ok
      end

      # GET /api/v1/reminders
      # GET /api/v1/opportunities/:opportunity_id/reminders
      def index
        authorize Reminder, :index?

        scope = if params[:opportunity_id].present?
                  opp = policy_scope(Opportunity).kept.find(params[:opportunity_id])
                  authorize opp, :show?
                  opp.reminders
                else
                  policy_scope(Reminder)
                end
        scope = scope.where(status: params[:status]) if params[:status].present?
        if params[:overdue] == "true"
          scope = scope.merge(Reminder.status_pending.where(remind_at: ..Time.current))
        end
        scope = scope.upcoming if params[:upcoming] == "true"

        render_collection(
          scope.includes(:user, :opportunity).order(:remind_at),
          with:     ReminderSerializer,
          include:  %i[opportunity]
        )
      end

      def show
        authorize @reminder
        render_resource(@reminder, with: ReminderSerializer)
      end

      def create
        authorize @opportunity, :update?
        # admin/manager pueden asignar el recordatorio a otro consultor via user_id
        # (permitido en reminder_params); si no lo mandan, o si el rol no puede
        # mandarlo, el creador queda como responsable por defecto.
        attrs = reminder_params.merge(tenant: current_tenant)
        attrs[:user_id] = current_user.id if attrs[:user_id].blank?
        reminder = @opportunity.reminders.new(attrs)
        if reminder.save
          @reminder = reminder
          ReminderCreatedNotificationJob.perform_later(reminder.id)
          Reminders::DueSchedule.enqueue!(reminder)
          render_created(reminder, with: ReminderSerializer)
        else
          render_unprocessable(reminder)
        end
      end

      def update
        authorize @reminder
        if @reminder.update(reminder_params)
          Reminders::DueSchedule.enqueue!(@reminder) if @reminder.status_pending?
          render_resource(@reminder, with: ReminderSerializer)
        else
          render_unprocessable(@reminder)
        end
      end

      def destroy
        authorize @reminder
        @reminder.destroy
        render_no_content
      end

      # POST /api/v1/reminders/:id/complete
      def complete
        authorize @reminder, :update?
        @reminder.update!(status: "done")
        @reminder.opportunity&.touch_activity!
        render_no_content
      end

      # POST /api/v1/reminders/:id/snooze  { minutes: 30 }
      def snooze
        authorize @reminder, :update?
        minutes = params.fetch(:minutes, 30).to_i
        if minutes <= 0
          return render json: { error: "minutes debe ser un número positivo" },
                        status: :unprocessable_entity
        end
        @reminder.update!(remind_at: Time.current + minutes.minutes)
        Reminders::DueSchedule.enqueue!(@reminder)
        render_no_content
      end

      private

      def set_opportunity
        @opportunity = policy_scope(Opportunity).kept.find(params[:opportunity_id])
      end

      def set_reminder
        @reminder = policy_scope(Reminder).find(params[:id])
      end

      def reminder_params
        permitted = params.require(:reminder).permit(:remind_at, :channel, :subject, :message, :user_id, :status)
        unless current_user.role_admin? || current_user.role_manager?
          permitted = permitted.except(:user_id)
        end
        permitted
      end
    end
  end
end
