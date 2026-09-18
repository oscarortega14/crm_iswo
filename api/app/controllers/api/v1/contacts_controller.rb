# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # ContactsController — CRUD + chequeo de duplicados + export async
    # ========================================================================
    class ContactsController < BaseController
      include ExportAuditable
      include ExportDownloadable

      before_action :set_contact, only: %i[show update destroy claim]

      # GET /api/v1/contacts/stats
      def stats
        authorize Contact, :index?
        payload = Contacts::Stats.new(user: current_user, tenant: current_tenant).call
        render json: { data: payload }, status: :ok
      end

      # GET /api/v1/contacts
      # ?segment=clients|prospects|hot_leads|stale — filtro por métrica rápida
      def index
        scope = policy_scope(Contact).kept

        if params[:segment].present?
          scope = Contacts::Stats.apply_segment(
            scope,
            segment: params[:segment],
            user:    current_user,
            tenant:  current_tenant
          )
        end

        scope = scope.where(kind: params[:kind])               if params[:kind].present?
        scope = scope.where(owner_user_id: params[:owner_id])  if params[:owner_id].present?
        scope = scope.with_phone if params[:has_phone] == "true"

        if (q = params[:q]).present?
          scope = Contacts::EncryptedSearch.apply(scope, q)
        end

        render_collection(
          scope.includes(:opportunities, :owner_user).order(updated_at: :desc),
          with:   ContactSerializer,
          params: { current_user: current_user }
        )
      end

      def show
        authorize @contact
        contact = policy_scope(Contact).kept
                  .includes(landing_form_submissions: :landing_page)
                  .find(@contact.id)
        render_resource(
          contact,
          with:   ContactSerializer,
          params: { current_user: current_user, include_landing_origins: true }
        )
      end

      def create
        authorize Contact
        @contact = current_tenant.contacts.new(contact_params.merge(owner_user: current_user))
        if @contact.save
          audit_contact!("contact.create", @contact)
          Contacts::ProspectOpportunityCreator.call(contact: @contact, actor: current_user)
          render_created(@contact, with: ContactSerializer, params: { current_user: current_user })
        else
          render_unprocessable(@contact)
        end
      end

      def update
        authorize @contact
        if @contact.update(contact_params)
          changed_keys = @contact.previous_changes.except("updated_at").keys
          audit_contact!("contact.update", @contact, changed_fields: changed_keys)
          opp_ids = Opportunities::TemperatureAutoClassifier.enqueue_for_contact!(
            contact:      @contact,
            source:       "auto_contact",
            user:         current_user,
            changed_keys: changed_keys,
            ip_address:   request.remote_ip,
            user_agent:   request.user_agent
          )
          payload = ContactSerializer.new(
            @contact,
            params: { current_user: current_user }
          ).serializable_hash
          if opp_ids.any?
            payload[:meta] = {
              temperature_classification: { queued: true, auto: true, opportunity_ids: opp_ids.map(&:to_s) }
            }
          end
          render json: payload, status: :ok
        else
          render_unprocessable(@contact)
        end
      end

      # POST /api/v1/contacts/:id/claim — "Tomar lead" desde la bandeja "sin asignar".
      def claim
        authorize @contact, :claim?
        @contact.update!(owner_user_id: current_user.id)
        audit_contact!("contact.claim", @contact)
        render_resource(@contact, with: ContactSerializer, params: { current_user: current_user })
      end

      def destroy
        authorize @contact
        audit_contact!("contact.destroy", @contact)
        @contact.discard
        render_no_content
      end

      # DELETE /api/v1/contacts/bulk_destroy  — { ids: ["1","2",...] }
      def bulk_destroy
        authorize Contact, :destroy?
        ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
        return render json: { error: "bad_request", message: "ids requeridos" }, status: :bad_request if ids.blank?

        contacts = policy_scope(Contact).kept.where(id: ids)
        deleted  = contacts.count
        contacts.each { |c| audit_contact!("contact.destroy", c) }
        contacts.discard_all
        render json: { data: { deleted: deleted } }, status: :ok
      end

      # POST /api/v1/contacts/backfill_whatsapp_opt_in?dry_run=true
      # Marca opt-in a contactos que ya escribieron por WhatsApp antes de que
      # existiera el gate de opt-in (WhatsappMessage#mark_contact_whatsapp_opt_in
      # ya lo hace automático para mensajes nuevos desde ahora en adelante).
      # dry_run=true solo cuenta, no persiste — para previsualizar el impacto.
      def backfill_whatsapp_opt_in
        authorize Contact, :destroy?

        scope = policy_scope(Contact).kept
                                      .where(whatsapp_opt_in_at: nil)
                                      .where(id: current_tenant.whatsapp_messages.inbound.select(:contact_id))

        count = scope.count
        unless ActiveModel::Type::Boolean.new.cast(params[:dry_run])
          scope.find_each { |c| c.mark_whatsapp_opt_in!(source: "reply_stop_in") }
        end

        render json: { data: { count: count, dry_run: ActiveModel::Type::Boolean.new.cast(params[:dry_run]) } },
               status: :ok
      end

      # POST /api/v1/contacts/bulk_whatsapp_opt_in — { ids: ["1","2",...] }
      # Opt-in manual: el admin/manager confirma que tiene consentimiento
      # verificado fuera del sistema (cliente existente, permiso presencial,
      # etc). Nunca se marca en bloque sin esta confirmación explícita.
      def bulk_whatsapp_opt_in
        authorize Contact, :bulk_whatsapp_opt_in?
        ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
        return render json: { error: "bad_request", message: "ids requeridos" }, status: :bad_request if ids.blank?

        contacts = policy_scope(Contact).kept.where(id: ids).where(whatsapp_opt_in_at: nil)
        marked = contacts.count
        contacts.find_each do |c|
          c.mark_whatsapp_opt_in!(source: "manual")
          audit_contact!("contact.whatsapp_opt_in", c)
        end
        render json: { data: { marked: marked } }, status: :ok
      end

      # GET /api/v1/contacts/check_duplicates?phone=...&email=...&full_name=...
      # Llamado desde el form del SPA mientras el consultor escribe.
      # Devuelve { data: { exists: bool, opportunity?: { id, contact_name, owner_name, created_at } } }
      def check_duplicates
        authorize Contact, :check_duplicates?

        matches = Opportunities::DuplicateDetector.new(
          phone:     params[:phone],
          email:     params[:email],
          full_name: params[:full_name]
        ).call

        if current_user.role_consultant?
          allowed_ids = policy_scope(Contact).pluck(:id).to_set
          matches = matches.select { |m| allowed_ids.include?(m.contact.id) }
        end

        if matches.empty?
          return render json: { data: { exists: false } }, status: :ok
        end

        contact = matches.first.contact
        opp     = contact.opportunities.kept.order(created_at: :desc).first

        payload = { exists: true }
        if opp
          payload[:opportunity] = {
            id:           opp.id,
            contact_name: opp.contact&.display_name || opp.title,
            owner_name:   opp.owner_user&.name || "Sin asignar",
            created_at:   opp.created_at
          }
        end

        render json: { data: payload }, status: :ok
      rescue ArgumentError => e
        render json: { error: "bad_request", message: e.message }, status: :bad_request
      end

      # GET /api/v1/contacts/import_template — plantilla Excel (.xlsx)
      def import_template
        authorize Contact, :create?

        require "caxlsx"

        package = Axlsx::Package.new
        package.workbook.add_worksheet(name: "Contactos") do |sheet|
          sheet.add_row %w[first_name last_name email phone company position city country kind notes]
        end

        tmp = Tempfile.new(["plantilla_contactos", ".xlsx"], binmode: true)
        begin
          package.serialize(tmp.path)
          send_data File.binread(tmp.path),
                    filename: "plantilla_contactos.xlsx",
                    type:     "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    disposition: "attachment"
        ensure
          tmp.close!
        end
      end

      # POST /api/v1/contacts/import — multipart (Excel .xlsx/.xls o CSV)
      def import
        authorize Contact, :create?

        file = params[:file]
        unless file.respond_to?(:tempfile)
          return render json: {
            error: "no_file", message: "Adjunta un archivo Excel (.xlsx)"
          }, status: :bad_request
        end

        result = Contacts::SpreadsheetImporter.new(
          tenant:   current_tenant,
          user:     current_user,
          io:       file.tempfile,
          filename: file.original_filename
        ).call

        audit_contact_import!(result, file.original_filename) if result.created_count.positive?

        render json: {
          data: {
            created_count: result.created_count,
            skipped_count: result.skipped_count,
            errors:        result.errors
          }
        }, status: :ok
      end

      # GET /api/v1/contacts/export.csv | export.xlsx — RFC §6.7 (descarga directa)
      def export_download
        export_download_for("contacts")
      end

      # POST /api/v1/contacts/export — exportación asíncrona (grandes volúmenes)
      def export
        authorize Contact, :export?
        file_format = resolve_export_file_format
        filters     = normalize_export_filters_param
        export = current_tenant.exports.create!(
          user:     current_user,
          resource: "contacts",
          format:   file_format,
          filters:  filters
        )
        safe_enqueue_export_generation_job(export.id)
        record_export_audit!(resource: "contacts", format: file_format, filters: filters, sync: false)
        render_resource(export, with: ExportSerializer, status: :accepted)
      end

      private

      def set_contact
        @contact = policy_scope(Contact).kept.find(params[:id])
      end

      def audit_contact!(action, contact, extra = {})
        AuditLogger.record_entity!(
          tenant:       current_tenant,
          user:         current_user,
          action:       action,
          entity:       contact,
          metadata:     { name: contact.display_name }.merge(extra),
          ip_address:   request.remote_ip,
          user_agent:   request.user_agent
        )
      end

      def audit_contact_import!(result, filename)
        AuditLogger.record!(
          tenant:       current_tenant,
          user:         current_user,
          action:       "contact.import",
          entity_type:  "Contact",
          metadata:     {
            filename:      filename,
            created_count: result.created_count,
            skipped_count: result.skipped_count,
            error_count:   result.errors.size
          },
          ip_address:   request.remote_ip,
          user_agent:   request.user_agent
        )
      end

      def contact_params
        permitted = params.require(:contact).permit(
          :kind, :first_name, :last_name, :company, :position,
          :email, :phone_e164, :city, :country, :notes, :document_id,
          :owner_user_id, :source_kind, :source_label,
          custom_fields: {}
        )
        unless current_user.role_admin? || current_user.role_manager?
          permitted = permitted.except(:owner_user_id)
        end
        permitted[:company_name] = permitted.delete(:company) if permitted.key?(:company)
        permitted[:job_title] = permitted.delete(:position) if permitted.key?(:position)
        permitted
      end
    end
  end
end
