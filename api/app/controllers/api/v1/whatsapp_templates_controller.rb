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

      private

      def set_whatsapp_template
        @whatsapp_template = current_tenant.whatsapp_templates.find(params[:id])
      end

      def permitted
        params.require(:whatsapp_template)
              .permit(:name, :meta_template_name, :language, :active, variable_labels: [], variable_names: [])
      end
    end
  end
end
