# frozen_string_literal: true

module Tenants
  # ==========================================================================
  # Tenants::Onboarder — crea un tenant nuevo con datos iniciales.
  # ==========================================================================
  # Uso:
  #   result = Tenants::Onboarder.new(
  #     slug:       "micasita",
  #     name:       "Mi Casita",
  #     admin_email: "admin@micasita.co",
  #     admin_name:  "Administrador",
  #     admin_password: SecureRandom.hex(12),
  #     currency:   "COP",
  #     timezone:   "America/Bogota",
  #   ).call
  #
  # Retorna un Struct con :tenant, :admin_user, :pipeline.
  # Atómico — rollback completo si algo falla.
  # Slugs F5 conocidos (iswo, micasita, libranzas) reciben pipeline/BANT/fuentes del RFC.
  # ==========================================================================
  class Onboarder
    DEFAULT_PIPELINE = {
      name:        "Pipeline Comercial",
      description: nil
    }.freeze

    DEFAULT_PIPELINE_STAGES = [
      { name: "Nueva",      position: 0, probability: 10,  color: "#94A3B8" },
      { name: "Contactada", position: 1, probability: 25,  color: "#60A5FA",
        auto_rule: { "trigger" => "whatsapp_outbound" } },
      { name: "Calificada", position: 2, probability: 50,  color: "#22C55E",
        auto_rule: { "trigger" => "bant_qualified" } },
      { name: "Propuesta",  position: 3, probability: 75,  color: "#F59E0B" },
      { name: "Ganada",     position: 4, probability: 100, color: "#16A34A", closed_won:  true },
      { name: "Perdida",    position: 5, probability: 0,   color: "#DC2626", closed_lost: true }
    ].freeze

    # RFC F2: profundidad del árbol en /network (default 3). Pipeline: solo opps propias por consultor.
    DEFAULT_TENANT_SETTINGS = {
      "network_depth" => ConsultantNetworkAccess::DEFAULT_NETWORK_DEPTH,
      "modules"       => %w[opportunities contacts pipeline reminders network exports landings],
      "show_bant"     => true
    }.freeze

    DEFAULT_LEAD_SOURCES = [
      { kind: "web",      name: "Web / Orgánico"      },
      { kind: "whatsapp", name: "WhatsApp"             },
      { kind: "meta",     name: "Meta Ads"             },
      { kind: "google",   name: "Google Ads"           },
      { kind: "referral", name: "Referido"             },
      { kind: "manual",   name: "Manual / Presencial"  }
    ].freeze

    # Campos extra para la vertical ISWO (consultoría en sistemas de gestión ISO)
    ISWO_FIELDS = [
      { key: "norma_iso",            label: "Norma ISO",                  field_type: "select",   position: 0,
        options: ["ISO 9001", "ISO 14001", "ISO 45001", "ISO 27001", "ISO 22000", "ISO 50001", "Varias normas"] },
      { key: "sector_empresa",       label: "Sector de la empresa",       field_type: "select",   position: 1,
        options: ["Manufactura", "Salud", "Construcción", "Educación", "Servicios", "Gobierno", "Alimentos", "Tecnología", "Otro"] },
      { key: "num_sedes",            label: "Número de sedes",            field_type: "number",   position: 2 },
      { key: "estado_certificacion", label: "Estado de certificación",    field_type: "select",   position: 3,
        options: ["Sin certificar", "En proceso", "Certificado", "Recertificación"] },
      { key: "organismo_certificador", label: "Organismo certificador",   field_type: "text",     position: 4 }
    ].freeze

    # Campos extra para la vertical Libranzas (crédito por descuento de nómina)
    LIBRANZAS_FIELDS = [
      { key: "empleador_nombre", label: "Empleador",            field_type: "text",     position: 0 },
      { key: "empleador_nit",    label: "NIT del empleador",    field_type: "text",     position: 1 },
      { key: "tipo_libranza",    label: "Tipo de libranza",     field_type: "select",   position: 2,
        options: ["Sector público", "Sector privado", "Pensionado"] },
      { key: "salario_base",     label: "Salario base",         field_type: "currency", position: 3 },
      { key: "plazo_meses",      label: "Plazo (meses)",        field_type: "number",   position: 4 },
      { key: "cuota_mensual",    label: "Cuota mensual est.",   field_type: "currency", position: 5 },
      { key: "descuento_ley",    label: "% Descuento de ley",   field_type: "number",   position: 6 },
      { key: "entidad_financiera", label: "Entidad financiera", field_type: "text",     position: 7 }
    ].freeze

    # Campos extra para la vertical Mi Casita (inmobiliaria / crédito hipotecario)
    MICASITA_FIELDS = [
      { key: "tipo_inmueble",    label: "Tipo de inmueble",     field_type: "select",   position: 0,
        options: ["Apartamento", "Casa", "Local comercial", "Lote", "Bodega"] },
      { key: "estrato",          label: "Estrato",              field_type: "select",   position: 1,
        options: ["1", "2", "3", "4", "5", "6"] },
      { key: "ciudad",           label: "Ciudad",               field_type: "text",     position: 2 },
      { key: "barrio",           label: "Barrio / Sector",      field_type: "text",     position: 3 },
      { key: "valor_comercial",  label: "Valor comercial",      field_type: "currency", position: 4 },
      { key: "credito_hipotecario", label: "¿Requiere crédito hipotecario?",
        field_type: "boolean", position: 5 },
      { key: "area_m2",          label: "Área (m²)",            field_type: "number",   position: 6 }
    ].freeze

    VERTICAL_FIELDS = {
      "iswo"      => ISWO_FIELDS,
      "libranzas" => LIBRANZAS_FIELDS,
      "micasita"  => MICASITA_FIELDS,
      "mi_casita" => MICASITA_FIELDS
    }.freeze

    Result = Struct.new(:tenant, :admin_user, :pipeline, keyword_init: true)

    def initialize(slug:, name:, admin_email:, admin_name:, admin_password:,
                   currency: "COP", timezone: "America/Bogota", locale: "es-CO",
                   logo_url: nil, primary_color: nil,
                   field_definitions: nil, vertical: nil)
      @slug              = slug
      vertical_key       = vertical.to_s.strip.downcase
      @vertical          = if vertical_key == "generic"
                            nil
                          else
                            VerticalCatalog.fetch(vertical.presence || slug)
                          end
      @resolved_slug     = if vertical_key == "generic"
                             VerticalCatalog.resolve_slug(slug)
                           else
                             VerticalCatalog.resolve_slug(vertical.presence || slug)
                           end
      @name              = name
      @admin_email       = admin_email
      @admin_name        = admin_name
      @admin_password    = admin_password
      @currency          = currency
      @timezone          = timezone
      @locale            = locale
      @logo_url          = logo_url
      @primary_color     = primary_color.presence || @vertical&.primary_color || "#0F172A"
      @field_definitions = if field_definitions
                             field_definitions
                           elsif vertical_key == "generic"
                             []
                           else
                             VERTICAL_FIELDS[@resolved_slug] || []
                           end
    end

    def call
      tenant   = nil
      user     = nil
      pipeline = nil

      ActiveRecord::Base.transaction do
        tenant = Tenant.create!(
          slug:          @slug,
          name:          @name,
          currency:      @currency,
          timezone:      @timezone,
          locale:        @locale,
          logo_url:      @logo_url,
          primary_color:   @primary_color,
          active:        true,
          settings:      tenant_settings
        )

        ActsAsTenant.with_tenant(tenant) do
          user = User.create!(
            tenant:       tenant,
            email:        @admin_email,
            name:         @admin_name,
            password:     @admin_password,
            role:         "admin",
            active:       true,
            confirmed_at: Time.current
          )

          create_bant_criterion!(tenant)
          pipeline = create_pipeline!(tenant)
          create_lead_sources!(tenant)

          @field_definitions.each do |attrs|
            TenantFieldDefinition.create!(attrs.merge(tenant: tenant))
          end

          Landings::TenantSetup.apply!(tenant) if defined?(Landings::TenantSetup)
        end
      end

      Result.new(tenant: tenant, admin_user: user, pipeline: pipeline)
    end

    private

    def tenant_settings
      return DEFAULT_TENANT_SETTINGS.deep_dup unless @vertical

      @vertical.tenant_settings.deep_dup
    end

    def create_bant_criterion!(tenant)
      return unless defined?(BantCriterion)

      attrs = @vertical ? @vertical.bant : {}
      BantCriterion.create!(attrs.merge(tenant: tenant))
    end

    def create_pipeline!(tenant)
      config = @vertical ? @vertical.pipeline : DEFAULT_PIPELINE
      stages = @vertical ? @vertical.stages : DEFAULT_PIPELINE_STAGES

      pipeline = Pipeline.create!(
        tenant:      tenant,
        name:        config[:name],
        description: config[:description],
        is_default:  true,
        active:      true
      )

      stages.each do |attrs|
        pipeline.pipeline_stages.create!(with_default_auto_rule(attrs).merge(tenant: tenant))
      end

      pipeline
    end

    # Las verticales no declaran reglas: "Calificada" recibe el auto-avance BANT
    # (mismo comportamiento que antes de StageAutomation).
    def with_default_auto_rule(attrs)
      return attrs if attrs.key?(:auto_rule)
      return attrs unless attrs[:name].to_s.casecmp?("calificada")

      attrs.merge(auto_rule: { "trigger" => "bant_qualified" })
    end

    def create_lead_sources!(tenant)
      sources = @vertical ? @vertical.lead_sources : DEFAULT_LEAD_SOURCES
      sources.each do |attrs|
        LeadSource.create!(attrs.merge(tenant: tenant, active: true))
      end
    end
  end
end
