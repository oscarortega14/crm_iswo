# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # TenantsController — configuración del tenant actual (singular)
    # ========================================================================
    class TenantsController < BaseController
      # GET /api/v1/tenant
      def show
        authorize current_tenant
        render_resource(current_tenant, with: TenantSerializer)
      end

      # PATCH /api/v1/tenant
      def update
        authorize current_tenant
        if current_tenant.update(tenant_params)
          render_resource(current_tenant, with: TenantSerializer)
        else
          render_unprocessable(current_tenant)
        end
      end

      private

      # settings["email_marketing"] (EmailMarketing::Sender) y settings["ai_agent"]
      # (AiAgent::Config) tienen su propia pantalla y validaciones: no se pisan
      # desde este PATCH genérico.
      MANAGED_SETTINGS = %w[email_marketing ai_agent].freeze
      def tenant_params
        permitted = params.require(:tenant).permit(
          :name, :legal_name, :tax_id, :logo_url, :brand_color,
          :timezone, :locale, :currency, settings: {}
        )
        attrs = permitted.to_h
        if attrs.key?("settings")
          attrs["settings"] = attrs["settings"].except(*MANAGED_SETTINGS)
          MANAGED_SETTINGS.each do |key|
            value = current_tenant.settings&.dig(key)
            attrs["settings"][key] = value if value.present?
          end
        end
        attrs
      end
    end
  end
end
