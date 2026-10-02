# frozen_string_literal: true

module Opportunities
  # ==========================================================================
  # Opportunities::LeadImporter — capa unificada de importación de leads.
  # ==========================================================================
  # Convierte un conjunto normalizado de atributos (nombre, email, teléfono)
  # en un Contact + Opportunity dentro del tenant dado.
  #
  # Consumidores:
  #   Ads::MetaLeadProcessor    → source_kind: "meta"
  #   Ads::GoogleLeadProcessor  → source_kind: "google"
  #   LandingSubmissionProcessor → source_kind: "web"
  #   Webhooks::WhatsappController → source_kind: "whatsapp"
  #
  # Retorna un Result con:
  #   .contact      — contacto creado o reutilizado
  #   .opportunity  — oportunidad creada
  #   .duplicate?   — true si se detectó un contacto previo
  # ==========================================================================
  class LeadImporter
    DEFAULT_DUP_THRESHOLD = 0.85

    Result = Struct.new(:contact, :opportunity, :duplicate_match, keyword_init: true) do
      def duplicate? = duplicate_match.present?
    end

    # @param tenant        [Tenant]
    # @param attrs         [Hash]  :first_name, :last_name, :full_name, :email, :phone
    # @param source_kind   [String] "meta" | "google" | "whatsapp" | "web" | "manual"
    # @param source_label  [String] etiqueta descriptiva (slug de landing, form_id, etc.)
    # @param owner_user    [User, nil] si nil se asigna por round-robin entre consultores activos
    # @param title         [String, nil] si nil se genera automáticamente
    # @param custom_fields [Hash]  metadatos del canal (ad_id, campaign_id, etc.)
    # @param dup_threshold [Float] score mínimo para considerar duplicado (0-1)
    def initialize(
      tenant:,
      attrs:,
      source_kind:,
      source_label: nil,
      owner_user: nil,
      title: nil,
      custom_fields: {},
      dup_threshold: DEFAULT_DUP_THRESHOLD
    )
      @tenant        = tenant
      @attrs         = attrs.with_indifferent_access
      @source_kind   = source_kind.to_s
      @source_label  = source_label.to_s.presence
      @owner_user    = owner_user
      @title         = title
      @custom_fields = (custom_fields || {}).with_indifferent_access
      @dup_threshold = dup_threshold
    end

    def call
      contact    = nil
      dup_match  = nil
      opportunity = nil

      ActsAsTenant.with_tenant(@tenant) do
        ActiveRecord::Base.transaction do
          contact, dup_match = upsert_contact
          opportunity        = create_opportunity(contact)
        end

        audit_new_contact!(contact) if dup_match.nil?
      end

      Result.new(contact: contact, opportunity: opportunity, duplicate_match: dup_match)
    end

    # =========================================================================

    private

    # Devuelve [contact, dup_match_or_nil].
    # Reutiliza el contacto existente si supera el umbral de duplicado.
    def upsert_contact
      phone = normalize_phone(@attrs["phone"])
      email = @attrs["email"]&.downcase&.strip

      matches = DuplicateDetector.new(
        phone:     phone,
        email:     email,
        full_name: full_name,
        threshold: @dup_threshold
      ).call

      if matches.any?
        matches.first.contact.record_origin!(@source_kind, @source_label) # volvió a entrar por otra vía
        [matches.first.contact, matches.first]
      else
        contact = @tenant.contacts.create!(
          first_name:   first_name,
          last_name:    last_name,
          email:        email,
          phone_e164:   phone,
          source_kind:  @source_kind,
          source_label: @source_label
        )
        [contact, nil]
      end
    end

    def create_opportunity(contact)
      pipeline = @tenant.pipelines.find_by(is_default: true) || @tenant.pipelines.first
      stage    = pipeline&.pipeline_stages&.order(:position)&.first
      source   = @tenant.lead_sources.find_by(kind: @source_kind) || @tenant.lead_sources.first
      owner    = @owner_user || round_robin_owner

      opp = @tenant.opportunities.create!(
        contact:          contact,
        pipeline:         pipeline,
        pipeline_stage:   stage,
        owner_user:       owner,
        lead_source:      source,
        title:            @title.presence || default_title,
        custom_fields:    @custom_fields,
        last_activity_at: Time.current
      )

      opp.opportunity_logs.create!(
        tenant:       @tenant,
        user:         owner,
        action:       "create",
        changes_data: {
          source_kind:  @source_kind,
          source_label: @source_label,
          custom_fields: @custom_fields.presence
        }.compact
      )

      Notifications::NewLeadNotifier.call(
        opportunity:  opp,
        source_kind:  @source_kind,
        source_label: @source_label
      )

      opp
    end

    def full_name
      @attrs["full_name"].presence ||
        [@attrs["first_name"], @attrs["last_name"]].compact.join(" ").presence
    end

    def first_name
      @attrs["first_name"].presence || full_name.to_s.split.first
    end

    def last_name
      @attrs["last_name"].presence || full_name.to_s.split[1..]&.join(" ")
    end

    # Normaliza a E.164. Toma el país del locale del tenant (p.ej. "es-CO" → "CO").
    # Si el número NO es normalizable, devolvemos nil en vez del valor crudo:
    # Contact valida `phone_e164` (Phonelib.valid?), así que guardar un raw
    # inválido haría fallar el create! y se perdería el lead entero; además
    # rompería la deduplicación por igualdad E.164. Se registra el raw para
    # trazabilidad.
    def normalize_phone(raw)
      return nil if raw.blank?

      country = @tenant.locale.to_s.split("-").last.presence || "CO"
      parsed  = Phonelib.parse(raw, country)
      return parsed.e164 if parsed.valid?

      Rails.logger.warn("[LeadImporter] teléfono no normalizable descartado (tenant=#{@tenant.id}): #{raw.inspect}")
      nil
    end

    def default_title
      label = @source_label.presence || @source_kind.capitalize
      name  = full_name.presence || @attrs["email"].presence || "Sin nombre"
      "Lead #{label} — #{name}"
    end

    def audit_new_contact!(contact)
      # Vía AuditLogger (regla del proyecto): aplica LogSanitizer a la metadata
      # y falla en silencio sin tumbar la importación.
      AuditLogger.record!(
        tenant:      @tenant,
        user:        nil,
        action:      "contact.create",
        entity_type: "Contact",
        entity_id:   contact.id,
        metadata:    { origin: "system", source_kind: @source_kind, source_label: @source_label }.compact
      )
    end

    def round_robin_owner
      Leads::RoundRobinOwner.call(@tenant)
    end
  end
end
