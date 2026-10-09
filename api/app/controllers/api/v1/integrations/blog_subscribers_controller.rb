# frozen_string_literal: true

module Api
  module V1
    module Integrations
      # ========================================================================
      # Integrations::BlogSubscribersController — sincroniza registros del blog
      # ========================================================================
      # Cuando alguien se registra y confirma su email en el sitio del blog
      # (iswo-website), crea/actualiza un Contact pasivo (sin Opportunity, sin
      # entrar al pipeline) en el tenant resuelto por X-Tenant-Slug.
      #
      # Sin sesión de usuario (skip_before_action :authenticate_user!). En su
      # lugar, autenticación por secreto compartido estático — no hay JWT de
      # usuario real del otro lado, es una integración servidor-a-servidor.
      # ========================================================================
      class BlogSubscribersController < BaseController
        skip_before_action :authenticate_user!, raise: false

        auditable_resource :contact

        # prepend: debe correr antes que resolve_tenant! (registrado por TenantResolver
        # al incluirse en BaseController), si no un caller sin secreto podría distinguir
        # 400 tenant_not_found de 401 unauthorized y enumerar slugs de tenant válidos
        # sin nunca dar el secreto correcto.
        prepend_before_action :verify_integration_secret!

        # POST /api/v1/integrations/blog_subscribers
        def create
          email = params[:email].to_s.downcase.strip
          return render json: { error: "email_required" }, status: :unprocessable_entity if email.blank?

          @contact = current_tenant.contacts.find_by(email: email)

          if @contact
            # Solo completa el nombre si el contact no tenía ninguno — nunca pisa datos
            # ya cargados (ej. por ventas o un formulario de landing previo) con lo que
            # venga del registro del blog, que puede ser más corto/incompleto.
            no_existing_name = @contact.first_name.blank? && @contact.last_name.blank? && @contact.company_name.blank?
            @contact.update(name_attributes) if no_existing_name
            @contact.record_origin!("blog", "Blog ISWO")
            return render_resource(@contact, with: ContactSerializer, status: :ok)
          end

          @contact = current_tenant.contacts.new(
            kind: "person",
            email: email,
            source_kind: "blog",
            source_label: "Blog ISWO",
            **name_attributes
          )

          if @contact.save
            render_created(@contact, with: ContactSerializer)
          else
            render_unprocessable(@contact)
          end
        end

        private

        def verify_integration_secret!
          secret = ENV["BLOG_INTEGRATION_SECRET"].to_s
          return head :unauthorized if secret.blank?

          provided = request.headers["X-Integration-Secret"].to_s
          head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, secret)
        end

        def name_attributes
          full_name = params[:name].to_s.strip
          parts = full_name.split
          {
            first_name: parts.first.presence || "Suscriptor",
            last_name: parts[1..].presence&.join(" ")
          }
        end
      end
    end
  end
end
