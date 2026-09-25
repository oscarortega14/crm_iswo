# frozen_string_literal: true

module Opportunities
  # ==========================================================================
  # Opportunities::BantScorer — calcula el score BANT (0-100) de una oportunidad.
  # ==========================================================================
  # BANT = Budget, Authority, Need, Timeline. El tenant define en BantCriterion:
  #
  #   budget_weight:     Float (0-100)
  #   authority_weight:  Float (0-100)
  #   need_weight:       Float (0-100)
  #   timeline_weight:   Float (0-100)
  #
  # Suma de weights = 100 (validado en el modelo).
  #
  # Cada dimensión se puntúa 0-100 según la información capturada en la
  # oportunidad (`bant_data` jsonb) o, si falta, en el contacto y metadata
  # de la opp. El score final es el promedio ponderado:
  #
  #   score = Σ (dim_score * weight) / 100
  # ==========================================================================
  class BantScorer
    DIMENSIONS = %i[budget authority need timeline].freeze

    def initialize(opportunity)
      @opportunity = opportunity
      @tenant      = opportunity.tenant
      @criteria    = @tenant.bant_criterion || default_criteria
    end

    def call
      dimension_scores = DIMENSIONS.index_with { |dim| score_dimension(dim) }

      weighted_sum = DIMENSIONS.sum do |dim|
        dimension_scores[dim] * @criteria.public_send("#{dim}_weight").to_f
      end

      final = (weighted_sum / 100.0).round

      {
        score: final.clamp(0, 100),
        breakdown: dimension_scores,
        weights: DIMENSIONS.index_with { |d| @criteria.public_send("#{d}_weight").to_f }
      }
    end

    # Conveniencia: persiste el score en la opp y devuelve el número.
    # Si la oportunidad recién supera el umbral, la avanza a la etapa con
    # disparador `bant_qualified` (RFC §6.1 ciclo de vida; ver StageAutomation).
    def call_and_persist!(sync_temperature: true)
      result    = call
      threshold = @criteria.threshold_qualified.to_i
      newly_qualified = !@opportunity.qualified && result[:score] >= threshold

      @opportunity.update!(
        bant_score: result[:score],
        qualified:  result[:score] >= threshold,
        bant_data:  (@opportunity.bant_data || {}).merge("breakdown" => result[:breakdown])
      )

      Opportunities::StageAutomation.call(opportunity: @opportunity, trigger: "bant_qualified") if newly_qualified
      sync_temperature! if sync_temperature

      result[:score]
    end

    # =========================================================================

    private

    def sync_temperature!
      return unless defined?(Opportunities::TemperatureCalculator)

      Opportunities::TemperatureCalculator.new(@opportunity.reload).apply!
    end

    def default_criteria
      # Fallback por si el tenant aún no configuró pesos: 25/25/25/25, umbral 60.
      Struct.new(:budget_weight, :authority_weight, :need_weight, :timeline_weight, :threshold_qualified)
            .new(25, 25, 25, 25, 60)
    end

    def bant_data
      @bant_data ||= (@opportunity.bant_data || {}).with_indifferent_access
    end

    def score_dimension(dim)
      # Cada dimensión acepta un hash con `answer` (string/bool/number)
      # o una puntuación directa (`score` 0-100). Si no hay data, asume 50.
      section = bant_data[dim] || {}
      return section["score"].to_i.clamp(0, 100) if section["score"]

      case dim
      when :budget    then score_budget(section)
      when :authority then score_authority(section)
      when :need      then score_need(section)
      when :timeline  then score_timeline(section)
      end
    end

    # Budget: compara el valor estimado con rangos. Mayor ≠ mejor, pero
    # tener presupuesto declarado sí sube el score.
    def score_budget(section)
      declared = section["amount"].to_f
      return 50 if declared.zero? && @opportunity.estimated_value.to_f.zero?

      amount = declared.positive? ? declared : @opportunity.estimated_value.to_f
      case amount
      when 0...1_000_000          then 30
      when 1_000_000...10_000_000 then 60
      when 10_000_000...50_000_000 then 80
      else                              95
      end
    end

    # Authority: rol del decisor declarado en el formulario o en el contacto.
    def score_authority(section)
      role = section["role"].to_s.downcase
      return 90 if %w[owner ceo founder director gerente].include?(role)
      return 70 if %w[jefe manager lead].include?(role)
      return 40 if role.present?

      50
    end

    # Need: intensidad de la necesidad declarada.
    def score_need(section)
      intent = section["intent"].to_s.downcase
      case intent
      when "urgent", "urgente"         then 95
      when "high", "alta"              then 80
      when "exploring", "explorando"   then 40
      when "curious", "curioso"        then 20
      else                                  50
      end
    end

    # Timeline: días estimados hasta cierre. Menor = más caliente.
    def score_timeline(section)
      days = section["days"].to_i
      return 50 if days.zero?

      case days
      when 0..7    then 95
      when 8..30   then 80
      when 31..90  then 60
      when 91..180 then 35
      else              15
      end
    end
  end
end
