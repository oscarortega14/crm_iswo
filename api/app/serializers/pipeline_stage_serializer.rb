# frozen_string_literal: true

class PipelineStageSerializer < ApplicationSerializer
  set_type :pipeline_stage

  # La tabla no tiene columna `description` (no inventar atributos: rompe el JSON al crear/actualizar etapa).
  attributes :name, :position, :probability,
             :closed_won, :closed_lost, :color

  attribute :terminal do |s|
    s.closed_won || s.closed_lost
  end

  attribute :auto_trigger, &:auto_trigger

  belongs_to :pipeline, serializer: :pipeline
end
