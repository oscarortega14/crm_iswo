# frozen_string_literal: true

module Api
  module V1
    class WhatsappTemplatesController < BaseController
      before_action :set_whatsapp_template, only: %i[show update destroy]

      def index
        scope = policy_scope(WhatsappTemplate).order(:name)
        scope = scope.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params[:active].present?
        render_collection(scope, with: WhatsappTemplateSerializer)
      end

      def show
        authorize @whatsapp_template
        render_resource(@whatsapp_template, with: WhatsappTemplateSerializer)
      end

      def create
        authorize WhatsappTemplate
        @whatsapp_template = current_tenant.whatsapp_templates.new(permitted)
        if @whatsapp_template.save
          render_created(@whatsapp_template, with: WhatsappTemplateSerializer)
        else
          render_unprocessable(@whatsapp_template)
        end
      end

      def update
        authorize @whatsapp_template
        if @whatsapp_template.update(permitted)
          render_resource(@whatsapp_template, with: WhatsappTemplateSerializer)
        else
          render_unprocessable(@whatsapp_template)
        end
      end

      def destroy
        authorize @whatsapp_template
        @whatsapp_template.destroy
        render_no_content
      end

      # POST /api/v1/whatsapp_templates/sync — trae category/status/id reales
      # desde Meta y actualiza las plantillas que ya existen en el catálogo.
      def sync
        authorize WhatsappTemplate, :sync?
        result = WhatsApp::TemplateSync.call(tenant: current_tenant)

        if result.success?
          AuditLogger.record!(
            tenant:      current_tenant,
            user:        current_user,
            action:      "whatsapp_template_sync",
            entity_type: "WhatsappTemplate",
            metadata:    {
              updated_count:         result.updated.size,
              new_in_meta_count:     result.new_in_meta.size,
              missing_in_meta_count: result.missing_in_meta.size
            },
            ip_address:  request.remote_ip,
            user_agent:  request.user_agent
          )
          render json: {
            data: {
              updated:         result.updated,
              new_in_meta:     result.new_in_meta,
              missing_in_meta: result.missing_in_meta
            }
          }, status: :ok
        else
          render json: { error: "sync_failed", message: result.message }, status: :unprocessable_entity
        end
      end

      private

      def set_whatsapp_template
        @whatsapp_template = current_tenant.whatsapp_templates.find(params[:id])
      end

      def permitted
        params.require(:whatsapp_template)
              .permit(:name, :meta_template_name, :language, :active, :opt_in_request,
                      variable_labels: [], variable_names: [])
      end
    end
  end
end
