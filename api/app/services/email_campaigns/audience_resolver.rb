# frozen_string_literal: true

module EmailCampaigns
  # ============================================================================
  # EmailCampaigns::AudienceResolver — contactos a los que se puede escribir
  # ============================================================================
  # Filtros de oportunidad (mismos que /opportunities): status, pipeline_id,
  # pipeline_stage_id, owner_id, temperature, lead_source_id. Sin ninguno de
  # ellos la audiencia son todos los contactos (tengan o no oportunidad).
  # Filtros de contacto: kind (person | company) y contact_origin (archivo
  # importado, landing…, ver Contact.with_origin).
  # Siempre excluye contactos sin correo o dados de baja (Contact.email_marketable).
  # ============================================================================
  module AudienceResolver
    OPPORTUNITY_FILTERS = %w[status pipeline_id pipeline_stage_id owner_id temperature lead_source_id].freeze

    module_function

    def call(tenant:, filters:)
      base(tenant, filters).email_marketable
    end

    # Cuántos correos distintos recibirían y cuántos quedan fuera por baja/rebote/queja.
    def preview(tenant:, filters:)
      with_email = base(tenant, filters).where.not(email: [ nil, "" ])
      {
        total:     with_email.where(email_opt_out_at: nil).distinct.count(Arel.sql("lower(contacts.email)")),
        opted_out: with_email.where.not(email_opt_out_at: nil).count
      }
    end

    def base(tenant, filters)
      filters  = (filters || {}).to_h.stringify_keys.transform_values(&:presence).compact
      contacts = tenant.contacts.kept

      if filters.slice(*OPPORTUNITY_FILTERS).any?
        contacts = contacts.where(id: opportunity_scope(tenant, filters).select(:contact_id))
      end
      contacts = contacts.where(kind: filters["kind"]) if Contact::KINDS.include?(filters["kind"])
      contacts = contacts.with_origin(filters["contact_origin"]) if filters["contact_origin"]
      contacts
    end

    def opportunity_scope(tenant, filters)
      scope = tenant.opportunities.kept
      scope = scope.where(status: filters["status"]) if filters["status"]
      scope = scope.where(pipeline_id: filters["pipeline_id"]) if filters["pipeline_id"]
      scope = scope.where(pipeline_stage_id: filters["pipeline_stage_id"]) if filters["pipeline_stage_id"]
      scope = scope.where(owner_user_id: filters["owner_id"]) if filters["owner_id"]
      scope = scope.where(lead_source_id: filters["lead_source_id"]) if filters["lead_source_id"]
      if Opportunity::TEMPERATURES.include?(filters["temperature"].to_s)
        scope = scope.where(temperature: filters["temperature"])
      end
      scope
    end
  end
end
