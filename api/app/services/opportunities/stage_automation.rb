# frozen_string_literal: true

module Opportunities
  # ==========================================================================
  # Opportunities::StageAutomation — avance automático de etapa por eventos.
  # ==========================================================================
  # Cada PipelineStage puede declarar `auto_rule = { trigger: "..." }`. Cuando
  # ocurre el evento, la oportunidad entra a la etapa con ese disparador.
  #
  # Reglas de seguridad:
  #   1. Solo hacia adelante (posición destino > posición actual).
  #   2. Nunca a etapas terminales (validado en PipelineStage) ni desde ellas.
  #   3. Solo oportunidades vivas y abiertas (kept + status no won/lost/merged).
  #   4. Lo manual manda: si el último cambio de etapa fue un retroceso hecho
  #      por un usuario, no se vuelve a avanzar sola hasta otro movimiento manual.
  #
  # Queda log `stage_change` con nota "Avance automático: …" y se notifica
  # al dueño. Nunca levanta excepción hacia el caller (webhooks, BANT).
  # ==========================================================================
  class StageAutomation
    TRIGGERS = {
      "whatsapp_outbound" => "se envió un WhatsApp al lead",
      "whatsapp_inbound"  => "el lead escribió por WhatsApp",
      "bant_qualified"    => "calificación BANT"
    }.freeze

    def self.call(opportunity:, trigger:)
      new(opportunity: opportunity, trigger: trigger).call
    end

    # Todas las oportunidades abiertas del contacto (eventos de WhatsApp que no
    # traen oportunidad, p.ej. envío desde el inbox).
    def self.call_for_contact(contact:, trigger:, opportunity: nil)
      targets = opportunity ? [opportunity] : contact.opportunities.kept.open.to_a
      targets.filter_map { |opp| call(opportunity: opp, trigger: trigger) }
    end

    def initialize(opportunity:, trigger:)
      @opportunity = opportunity
      @trigger     = trigger.to_s
    end

    # @return [PipelineStage, nil] etapa destino si hubo avance
    def call
      return nil unless TRIGGERS.key?(@trigger)
      return nil unless eligible?

      target = target_stage
      return nil unless target

      from_stage = @opportunity.pipeline_stage
      ActiveRecord::Base.transaction do
        @opportunity.update!(pipeline_stage_id: target.id, last_activity_at: Time.current)
        @opportunity.opportunity_logs.create!(
          tenant:       @opportunity.tenant,
          action:       "stage_change",
          changes_data: { from_stage_id: from_stage&.id, to_stage_id: target.id, trigger: @trigger },
          note:         "Avance automático: #{TRIGGERS[@trigger]}"
        )
      end

      Notifications::StageChangeNotifier.call(
        opportunity: @opportunity,
        from_stage:  from_stage,
        to_stage:    target,
        automatic:   true,
        reason:      TRIGGERS[@trigger]
      )

      target
    rescue StandardError => e
      Rails.logger.warn("[StageAutomation] opp=#{@opportunity&.id} trigger=#{@trigger}: #{e.class} #{e.message}")
      nil
    end

    private

    def eligible?
      @opportunity.kept? &&
        !@opportunity.status.in?(%w[won lost merged]) &&
        !@opportunity.pipeline_stage&.terminal? &&
        !manual_rollback?
    end

    def target_stage
      current_position = @opportunity.pipeline_stage&.position || -1

      PipelineStage.where(pipeline_id: @opportunity.pipeline_id, discarded_at: nil)
                   .open_stages
                   .with_auto_trigger(@trigger)
                   .where("position > ?", current_position)
                   .order(:position)
                   .first
    end

    def manual_rollback?
      last = @opportunity.opportunity_logs.where(action: "stage_change").order(:created_at, :id).last
      return false unless last&.user_id

      data = last.changes_data || {}
      positions = PipelineStage.where(id: [data["from_stage_id"], data["to_stage_id"]].compact)
                               .pluck(:id, :position).to_h
      from_pos = positions[data["from_stage_id"].to_i]
      to_pos   = positions[data["to_stage_id"].to_i]
      from_pos.present? && to_pos.present? && to_pos < from_pos
    end
  end
end
