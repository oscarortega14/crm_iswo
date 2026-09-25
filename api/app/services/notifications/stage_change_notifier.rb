# frozen_string_literal: true

module Notifications
  # Notifica al dueño de la oportunidad cuando la etapa del pipeline cambia.
  # No notifica si quien mueve la etapa es el mismo dueño (salvo avance automático).
  class StageChangeNotifier
    def self.call(opportunity:, from_stage:, to_stage:, actor: nil, automatic: false, reason: nil)
      new(
        opportunity: opportunity,
        from_stage:  from_stage,
        to_stage:    to_stage,
        actor:       actor,
        automatic:   automatic,
        reason:      reason
      ).call
    end

    def initialize(opportunity:, from_stage:, to_stage:, actor: nil, automatic: false, reason: nil)
      @opportunity = opportunity
      @from_stage  = from_stage
      @to_stage    = to_stage
      @actor       = actor
      @automatic   = automatic
      @reason      = reason
    end

    def call
      return if @to_stage.blank?
      return if @from_stage&.id == @to_stage.id

      owner = @opportunity.owner_user
      return unless owner
      return if !@automatic && @actor&.id == owner.id

      Notification.create!(
        tenant:   @opportunity.tenant,
        user:     owner,
        kind:     "stage_change",
        title:    "Cambio de etapa",
        body:     build_body,
        resource: @opportunity
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[Notification] stage_change opp=#{@opportunity.id}: #{e.message}"
      )
    end

    private

    def build_body
      from_name = @from_stage&.name.presence || "—"
      to_name   = @to_stage.name
      label     = @opportunity.contact&.display_name.presence || @opportunity.title

      if @automatic
        "«#{label}» pasó de #{from_name} a #{to_name} (automático: #{@reason.presence || 'regla de etapa'})"
      elsif @actor
        "#{@actor.name} movió «#{label}» de #{from_name} a #{to_name}"
      else
        "«#{label}» pasó de #{from_name} a #{to_name}"
      end
    end
  end
end
