# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # WhatsappCampaignsController — mensajería masiva con plantilla + opt-in
    # ========================================================================
    # Todo admin/manager (igual gobernanza que /exports) — el radio de acción
    # de una campaña (cientos de contactos) es demasiado sensible para dejarlo
    # en manos de cada consultor sin supervisión.
    # ========================================================================
    class WhatsappCampaignsController < BaseController
      before_action :set_campaign, only: %i[show update launch pause resume cancel]

      def index
        authorize WhatsappCampaign
        scope = policy_scope(WhatsappCampaign).order(created_at: :desc)
        render_collection(scope, with: WhatsappCampaignSerializer)
      end

      def show
        authorize @campaign
        render_resource(@campaign, with: WhatsappCampaignSerializer)
      end

      # GET /api/v1/whatsapp_campaigns/audience_preview?<mismos params que /opportunities>
      def audience_preview
        authorize WhatsappCampaign, :create?

        contacts = WhatsappCampaigns::AudienceResolver.call(tenant: current_tenant, filters: audience_filter_params)
        total    = contacts.count
        opted_in = contacts.opted_in_for_whatsapp.count

        render json: { total: total, opted_in: opted_in, skipped_no_opt_in: total - opted_in }
      end

      def create
        authorize WhatsappCampaign

        @campaign = current_tenant.whatsapp_campaigns.new(campaign_params.merge(created_by_user: current_user))

        if @campaign.save
          render_created(@campaign, with: WhatsappCampaignSerializer)
        else
          render_unprocessable(@campaign)
        end
      end

      def update
        authorize @campaign
        unless @campaign.status_draft?
          return render json: { error: "not_draft", message: "Solo se puede editar un borrador." },
                        status: :conflict
        end

        if @campaign.update(campaign_params)
          render_resource(@campaign, with: WhatsappCampaignSerializer)
        else
          render_unprocessable(@campaign)
        end
      end

      def launch
        authorize @campaign, :update?
        @campaign.launch!
        render_resource(@campaign, with: WhatsappCampaignSerializer)
      rescue ArgumentError => e
        render json: { error: "invalid_state", message: e.message }, status: :conflict
      end

      def pause
        authorize @campaign, :update?
        @campaign.pause!
        render_resource(@campaign, with: WhatsappCampaignSerializer)
      end

      def resume
        authorize @campaign, :update?
        @campaign.resume!
        render_resource(@campaign, with: WhatsappCampaignSerializer)
      end

      def cancel
        authorize @campaign, :update?
        @campaign.cancel!
        render_resource(@campaign, with: WhatsappCampaignSerializer)
      end

      private

      def set_campaign
        @campaign = policy_scope(WhatsappCampaign).find(params[:id])
      end

      def campaign_params
        params.require(:whatsapp_campaign).permit(
          :name, :whatsapp_template_id, :batch_size, :batch_interval_minutes,
          variable_field_map: [], audience_filters: {}
        )
      end

      def audience_filter_params
        params.permit(:status, :pipeline_id, :pipeline_stage_id, :stage_id, :owner_id, :temperature)
      end
    end
  end
end
