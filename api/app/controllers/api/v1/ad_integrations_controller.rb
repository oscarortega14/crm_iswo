# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # AdIntegrationsController — credenciales cifradas de canales externos
    # ========================================================================
    class AdIntegrationsController < BaseController
      before_action :set_integration, only: %i[show update destroy test_connection disable]

      def index
        authorize AdIntegration
        scope = policy_scope(AdIntegration).order(:provider)
        render_collection(scope, with: AdIntegrationSerializer, meta: integration_webhooks_meta)
      end

      def show
        authorize @integration
        render_resource(@integration, with: AdIntegrationSerializer)
      end

      def create
        authorize AdIntegration
        integration = current_tenant.ad_integrations.new(permitted)
        if integration.save
          log_integration_audit!("integration_connect", integration)
          render_created(integration, with: AdIntegrationSerializer)
        else
          render_unprocessable(integration)
        end
      end

      def update
        authorize @integration
        parameters = merge_credentials_into(permitted)
        parameters = merge_metadata_into(parameters)
        if @integration.update(parameters)
          log_integration_audit!(
            "integration_update", @integration,
            changes: @integration.previous_changes.except("updated_at").presence
          )
          render_resource(@integration, with: AdIntegrationSerializer)
        else
          render_unprocessable(@integration)
        end
      end

      def destroy
        authorize @integration
        log_integration_audit!("integration_disconnect", @integration)
        @integration.destroy
        render_no_content
      end

      # POST /api/v1/ad_integrations/:id/test_connection
      def test_connection
        authorize @integration, :test_connection?
        result = Ads::ConnectionTester.new(@integration).test

        if result.success?
          @integration.record_sync!
          render_resource(@integration, with: AdIntegrationSerializer)
        else
          @integration.record_failure!(result.message)
          payload = AdIntegrationSerializer.new(@integration).serializable_hash
          render json: payload.merge(
            error:   "connection_failed",
            message: result.message
          ),
                 status: :unprocessable_entity
        end
      end

      # POST /api/v1/ad_integrations/:id/disable
      def disable
        authorize @integration, :disable?
        previous_status = @integration.status
        @integration.update!(status: "paused")
        log_integration_audit!(
          "integration_disable", @integration,
          changes: { "status" => [ previous_status, @integration.status ] }
        )
        render_no_content
      end

      private

      def set_integration
        @integration = current_tenant.ad_integrations.find(params[:id])
      end

      def permitted
        # NOTA: `credentials` se cifra con Lockbox. El SPA manda como hash;
        # nunca se devuelve en la respuesta.
        params.require(:ad_integration).permit(
          :provider, :account_identifier, :status, metadata: {}, credentials: {}
        )
      end

      # Quita `credentials` vacío para no sobrescribir secretos con {} por error.
      def strip_blank_credentials_param!(parameters)
        return unless parameters.key?(:credentials)

        parameters.delete(:credentials) if parameters[:credentials].blank?
      end

      # Combina metadata (p. ej. form_id de Google) sin borrar claves no enviadas.
      def merge_metadata_into(parameters)
        strip_blank_metadata_param!(parameters)
        return parameters unless parameters[:metadata].present?

        existing = (@integration.metadata || {}).stringify_keys
        incoming = stringify_nested_param(parameters[:metadata])
        incoming.reject! { |_k, v| v.blank? }
        merged = existing.merge(incoming)
        if merged.blank?
          parameters.delete(:metadata)
        else
          parameters[:metadata] = merged
        end
        parameters
      end

      def strip_blank_metadata_param!(parameters)
        return unless parameters.key?(:metadata)

        parameters.delete(:metadata) if parameters[:metadata].blank?
      end

      # Combina credenciales nuevas con las ya guardadas (el SPA no puede volver a leer secretos).
      def merge_credentials_into(parameters)
        strip_blank_credentials_param!(parameters)
        return parameters unless parameters[:credentials].present?

        existing = (@integration.credentials || {}).stringify_keys
        incoming = stringify_nested_param(parameters[:credentials])
        incoming.reject! { |_k, v| v.blank? }
        merged = existing.merge(incoming)
        if merged.blank?
          parameters.delete(:credentials)
        else
          parameters[:credentials] = merged
        end
        parameters
      end

      # ActionController::Parameters → Hash; Hash plano (tests/Axios) → Hash.
      def stringify_nested_param(raw)
        h = case raw
            when ActionController::Parameters then raw.to_unsafe_h
            when Hash then raw
            else {}
            end
        h.stringify_keys
      end

      # URLs absolutas para configurar Meta/Google en sus consolas (mismo host que recibirá webhooks).
      # Opcional: ENV API_PUBLIC_ORIGIN si el API está detrás de proxy y request.base_url no es público.
      def integration_webhooks_meta
        root = public_api_origin.chomp("/")
        base = "#{root}/api/v1/webhooks"
        {
          integration_webhooks: {
            base_url:                  base,
            meta_verify_get:           "#{base}/meta",
            meta_leads_post:           "#{base}/meta",
            google_leads_post:         "#{base}/google",
            whatsapp_cloud_verify_get: "#{base}/whatsapp/cloud",
            whatsapp_cloud_post:       "#{base}/whatsapp/cloud",
            whatsapp_openwa_post:      "#{base}/whatsapp/openwa"
          }
        }
      end

      def public_api_origin
        ENV["API_PUBLIC_ORIGIN"].presence || request.base_url
      end

      def log_integration_audit!(action, integration, changes: nil)
        metadata = { provider: integration.provider }
        metadata[:changes] = changes if changes.present?

        AuditLogger.record!(
          tenant:      current_tenant,
          user:        current_user,
          action:      action,
          entity_type: "AdIntegration",
          entity_id:   integration.id,
          metadata:    metadata,
          ip_address:  request.remote_ip,
          user_agent:  request.user_agent
        )
      end
    end
  end
end
