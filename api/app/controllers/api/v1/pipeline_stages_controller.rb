# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # PipelineStagesController — anidado bajo /pipelines/:pipeline_id/stages
    # ========================================================================
    class PipelineStagesController < BaseController
      auditable_resource :stage
      before_action :set_pipeline
      before_action :set_stage, only: %i[update destroy]

      # GET /api/v1/pipelines/:pipeline_id/stages
      def index
        scope = @pipeline.pipeline_stages.order(:position)
        render json: PipelineStageSerializer.new(scope).serializable_hash, status: :ok
      end

      # POST /api/v1/pipelines/:pipeline_id/stages
      def create
        authorize @pipeline, :update?
        stage = @pipeline.pipeline_stages.new(stage_params.merge(tenant: current_tenant))
        if stage.save
          @stage = stage
          render_created(stage, with: PipelineStageSerializer)
        else
          render_unprocessable(stage)
        end
      end

      def update
        authorize @pipeline, :update?
        if @stage.update(stage_params)
          render_resource(@stage, with: PipelineStageSerializer)
        else
          render_unprocessable(@stage)
        end
      end

      def destroy
        authorize @pipeline, :update?
        @stage.destroy
        render_no_content
      end

      # PATCH /api/v1/pipelines/:pipeline_id/stages/reorder
      # body: { order: [stage_id_1, stage_id_2, ...] }
      def reorder
        authorize @pipeline, :update?
        ids = Array(params[:order]).map(&:to_i)
        ActiveRecord::Base.transaction do
          ids.each_with_index do |id, idx|
            @pipeline.pipeline_stages.where(id: id).update_all(position: idx)
          end
        end
        scope = @pipeline.pipeline_stages.order(:position)
        render json: PipelineStageSerializer.new(scope).serializable_hash, status: :ok
      end

      private

      def set_pipeline
        @pipeline = current_tenant.pipelines.find(params[:pipeline_id])
      end

      def set_stage
        @stage = @pipeline.pipeline_stages.find(params[:id])
      end

      def stage_params
        params.require(:pipeline_stage).permit(
          :name, :position, :probability,
          :closed_won, :closed_lost, :color,
          auto_rule: [:trigger]
        )
      end
    end
  end
end
