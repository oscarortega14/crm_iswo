# frozen_string_literal: true

module Opportunities
  # ==========================================================================
  # Opportunities::StageMover — movimiento manual de etapa (individual o lote).
  # ==========================================================================
  # Misma lógica para POST /opportunities/:id/move_stage y
  # POST /opportunities/bulk_move_stage: sincroniza status con etapas de
  # cierre (won/lost), toca actividad, registra `stage_change` con el usuario
  # (StageAutomation lo lee para respetar retrocesos manuales) y notifica.
  # ==========================================================================
  class StageMover
    def self.call(...)
      new(...).call
    end

    # @param request_meta [Hash] :ip_address, :user_agent para el log
    def initialize(opportunity:, stage:, actor:, request_meta: {}, bulk: false)
      @opportunity  = opportunity
      @stage        = stage
      @actor        = actor
      @request_meta = request_meta
      @bulk         = bulk
    end

    # @return [Boolean] true si cambió de etapa
    def call
      from_stage = @opportunity.pipeline_stage
      from_id    = @opportunity.pipeline_stage_id

      ActiveRecord::Base.transaction do
        @opportunity.update!(
          pipeline_stage_id: @stage.id,
          pipeline_id:       @stage.pipeline_id,
          status:            new_status
        )
        @opportunity.touch_activity!(recalc_temperature: false)
        @opportunity.opportunity_logs.create!(
          tenant:       @opportunity.tenant,
          user:         @actor,
          action:       "stage_change",
          changes_data: LogSanitizer.redact(
            { from_stage_id: from_id, to_stage_id: @stage.id, bulk: (true if @bulk) }.compact
          ),
          ip_address:   @request_meta[:ip_address],
          user_agent:   @request_meta[:user_agent]
        )
      end

      return false if from_id == @stage.id

      Notifications::StageChangeNotifier.call(
        opportunity: @opportunity.reload,
        from_stage:  from_stage,
        to_stage:    @stage,
        actor:       @actor
      )
      true
    end

    private

    def new_status
      return "won"  if @stage.closed_won
      return "lost" if @stage.closed_lost

      @opportunity.status
    end
  end
end
