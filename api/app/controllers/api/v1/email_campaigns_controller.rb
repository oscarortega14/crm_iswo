# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # EmailCampaignsController — campañas de correo (AWS SES), admin/manager
    # ========================================================================
    class EmailCampaignsController < BaseController
      MEMBER_ACTIONS = %i[show update destroy launch pause resume cancel duplicate recipients send_test].freeze
      AUDIENCE_KEYS  = %i[status pipeline_id pipeline_stage_id owner_id temperature lead_source_id kind contact_origin].freeze

      before_action :set_email_campaign, only: MEMBER_ACTIONS

      def index
        authorize EmailCampaign
        scope = policy_scope(EmailCampaign).includes(:created_by_user).order(created_at: :desc)
        render_collection(scope, with: EmailCampaignSerializer)
      end

      def show
        authorize @email_campaign
        render_full(@email_campaign)
      end

      # GET /api/v1/email_campaigns/:id/recipients?result=bounced
      def recipients
        authorize @email_campaign, :show?
        scope = @email_campaign.email_campaign_recipients.includes(:contact).order(:id)
        scope = filter_by_result(scope, params[:result].to_s)
        render_collection(scope, with: EmailCampaignRecipientSerializer)
      end

      # GET /api/v1/email_campaigns/audience_preview?pipeline_stage_id=…
      def audience_preview
        authorize EmailCampaign, :create?
        render json: EmailCampaigns::AudienceResolver.preview(tenant: current_tenant, filters: audience_filter_params)
      end

      def create
        authorize EmailCampaign
        @email_campaign = current_tenant.email_campaigns.new(campaign_params.merge(created_by_user: current_user))
        if @email_campaign.save
          render_full(@email_campaign, status: :created)
        else
          render_unprocessable(@email_campaign)
        end
      end

      def update
        authorize @email_campaign
        return render_conflict("Solo se puede editar un borrador.") unless @email_campaign.status_draft?

        if @email_campaign.update(campaign_params)
          render_full(@email_campaign)
        else
          render_unprocessable(@email_campaign)
        end
      end

      def destroy
        authorize @email_campaign
        return render_conflict("Solo se puede eliminar un borrador.") unless @email_campaign.status_draft?

        @email_campaign.destroy!
        head :no_content
      end

      def duplicate
        authorize @email_campaign, :create?
        @email_campaign = @email_campaign.duplicate!(current_user)
        render_full(@email_campaign, status: :created)
      end

      # POST /api/v1/email_campaigns/:id/send_test { email }
      def send_test
        authorize @email_campaign, :update?
        to = params[:email].presence || current_user.email
        return render_conflict("El correo de prueba no es válido.") unless to.to_s.match?(URI::MailTo::EMAIL_REGEXP)

        EmailCampaigns::Dispatcher.send_test!(campaign: @email_campaign, to: to)
        render json: { sent_to: to }
      rescue ArgumentError, Aws::SESV2::Errors::ServiceError => e
        render_conflict(e.message)
      end

      def launch
        authorize @email_campaign, :update?
        @email_campaign.launch!
        render_full(@email_campaign)
      rescue ArgumentError => e
        render_conflict(e.message)
      end

      def pause
        authorize @email_campaign, :update?
        return render_conflict("Solo se puede pausar una campaña en curso.") unless @email_campaign.status_running?

        @email_campaign.pause!
        render_full(@email_campaign)
      end

      def resume
        authorize @email_campaign, :update?
        return render_conflict("Solo se puede reanudar una campaña pausada.") unless @email_campaign.status_paused?

        @email_campaign.resume!
        render_full(@email_campaign)
      end

      def cancel
        authorize @email_campaign, :update?
        unless @email_campaign.status_running? || @email_campaign.status_paused? || @email_campaign.status_scheduled?
          return render_conflict("Esta campaña ya terminó.")
        end

        @email_campaign.cancel!
        render_full(@email_campaign)
      end

      private

      def set_email_campaign
        @email_campaign = policy_scope(EmailCampaign).find(params[:id])
      end

      def render_full(campaign, status: :ok)
        render_resource(campaign, with: EmailCampaignSerializer, status: status, params: { full: true })
      end

      def render_conflict(message)
        render json: { error: "invalid_state", message: message }, status: :conflict
      end

      def filter_by_result(scope, result)
        case result
        when "delivered"    then scope.where(status: "delivered")
        when "opened"       then scope.where.not(opened_at: nil)
        when "clicked"      then scope.where.not(clicked_at: nil)
        when "unsubscribed" then scope.where.not(unsubscribed_at: nil)
        when "problems"     then scope.where(status: %w[bounced complained failed skipped])
        else scope
        end
      end

      # body_design es el proyecto del editor (JSON anidado libre): se toma aparte.
      def campaign_params
        permitted = params.require(:email_campaign).permit(
          :name, :subject, :preheader, :body_html, :scheduled_at, :batch_size, audience_filters: AUDIENCE_KEYS
        )
        design = params[:email_campaign][:body_design]
        permitted[:body_design] = design.to_unsafe_h if design.is_a?(ActionController::Parameters)
        permitted
      end

      def audience_filter_params
        params.permit(*AUDIENCE_KEYS).to_h
      end
    end
  end
end
