# frozen_string_literal: true

class PipelineSerializer < ApplicationSerializer
  set_type :pipeline

  attributes :name, :description, :position, :is_default

  attribute :stages_count do |p|
    p.pipeline_stages.size
  end

  # Embebido para el SPA (Kanban / formulario rápido) sin `include` JSON:API.
  attribute :stages do |p|
    p.pipeline_stages.order(:position).map do |s|
      {
        id:              s.id.to_s,
        pipeline_id:     p.id.to_s,
        name:            s.name,
        position:        s.position,
        probability:     s.probability,
        is_closed_won:   s.closed_won,
        is_closed_lost:  s.closed_lost,
        color:           s.color,
        auto_trigger:    s.auto_trigger
      }
    end
  end

  # No usar `has_many :pipeline_stages` aquí: PipelineStageSerializer tiene `belongs_to :pipeline`
  # y provoca recursión infinita → stack overflow y 500 en GET /pipelines.
  # Las etapas van en `attribute :stages` arriba (hashes planos).
end
