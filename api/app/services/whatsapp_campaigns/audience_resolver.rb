# frozen_string_literal: true

module WhatsappCampaigns
  # ============================================================================
  # WhatsappCampaigns::AudienceResolver — misma sintaxis de filtros que
  # Api::V1::OpportunitiesController#index (pipeline_id, pipeline_stage_id /
  # stage_id, owner_id, temperature, status), para reusar el filtro que el
  # consultor ya tiene armado en el tablero como audiencia de campaña.
  # ============================================================================
  # Deliberadamente duplica el where-chain del controller en vez de
  # refactorizarlo a un servicio compartido: OpportunitiesController#index es
  # una ruta caliente y no queremos arriesgar su comportamiento actual.
  # ============================================================================
  module AudienceResolver
    module_function

    def call(tenant:, filters:)
      filters = (filters || {}).stringify_keys
      scope   = tenant.opportunities.kept

      scope = scope.where(status: filters["status"]) if filters["status"].present?
      scope = scope.where(pipeline_id: filters["pipeline_id"]) if filters["pipeline_id"].present?

      stage_id = filters["pipeline_stage_id"] || filters["stage_id"]
      scope = scope.where(pipeline_stage_id: stage_id) if stage_id.present?

      scope = scope.where(owner_user_id: filters["owner_id"]) if filters["owner_id"].present?

      if filters["temperature"].present? && Opportunity::TEMPERATURES.include?(filters["temperature"].to_s)
        scope = scope.where(temperature: filters["temperature"])
      end

      tenant.contacts.with_phone.where(id: scope.select(:contact_id)).distinct
    end
  end
end
