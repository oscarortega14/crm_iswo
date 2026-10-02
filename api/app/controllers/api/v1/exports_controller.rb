# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # ExportsController — historial y creación de exportaciones async
    # ========================================================================
    class ExportsController < BaseController
      include ExportAuditable

      before_action :set_export, only: %i[show download]

      def index
        authorize Export, :index?
        scope = policy_scope(Export).where.not(status: "expired").order(created_at: :desc)
        render_collection(scope, with: ExportSerializer)
      end

      def show
        authorize @export
        render_resource(@export, with: ExportSerializer)
      end

      # GET /api/v1/exports/:id/download
      def download
        authorize @export, :download?

        unless @export.status == "succeeded"
          return render json: { error: "not_ready", message: "El export aún no está listo." },
                        status: :unprocessable_entity
        end

        if @export.expires_at.present? && @export.expires_at < Time.current
          return render json: { error: "expired", message: "El export ha expirado." },
                        status: :gone
        end

        record_export_audit!(
          resource:  @export.resource,
          format:    @export.format,
          filters:   @export.filters || {},
          action:    "export_download",
          export_id: @export.id
        )

        payload = Exports::Storage.download_payload(@export)

        case payload&.dig(:type)
        when :redirect
          redirect_to payload[:url], allow_other_host: true, status: :found
        when :file
          send_file payload[:path],
                    filename:    payload[:filename],
                    type:        payload[:content_type],
                    disposition: "attachment"
        when :data
          send_data payload[:data],
                    filename:    payload[:filename],
                    type:        payload[:content_type],
                    disposition: "attachment"
        else
          render json: { error: "file_not_found", message: "Archivo no encontrado." },
                 status: :not_found
        end
      end

      # POST /api/v1/exports  { resource: "contacts"|"opportunities", export_format, filters }
      def create
        authorize Export, :create?
        resource = params.require(:resource)
        unless Export::RESOURCES.include?(resource)
          return render json: { error: "invalid_resource",
                                message: "resource debe ser uno de: #{Export::RESOURCES.join(', ')}" },
                        status: :unprocessable_entity
        end

        export = current_tenant.exports.create!(
          user:     current_user,
          resource: resource,
          format:   resolve_export_file_format,
          filters:  normalize_export_filters_param
        )
        safe_enqueue_export_generation_job(export.id)
        record_export_audit!(
          resource:  export.resource,
          format:    export.format,
          filters:   export.filters || {},
          sync:      false,
          export_id: export.id
        )

        render_resource(export, with: ExportSerializer, status: :accepted)
      end

      private

      def set_export
        @export = policy_scope(Export).find(params[:id])
      end

    end
  end
end
