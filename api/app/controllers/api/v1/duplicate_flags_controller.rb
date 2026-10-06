# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # DuplicateFlagsController — gestión y resolución de colisiones
    # ========================================================================
    # Los flags se crean automáticamente por el servicio DuplicateDetector al
    # registrar una oportunidad. Aquí se listan, se ven y se resuelven
    # (reasignar, fusionar, ignorar).
    # ========================================================================
    class DuplicateFlagsController < BaseController
      include DuplicateFlagAuditable

      before_action :set_flag, only: %i[show reassign merge ignore]

      # GET /api/v1/duplicate_flags/stats
      def stats
        authorize DuplicateFlag, :index?
        payload = DuplicateFlags::Stats.new(user: current_user).call
        render json: { data: payload }, status: :ok
      end

      # GET /api/v1/duplicate_flags
      def index
        scope = policy_scope(DuplicateFlag).includes(
          :detected_by_user,
          :resolved_by_user,
          opportunity:              %i[contact owner_user],
          duplicate_of_opportunity: %i[contact owner_user]
        )
        if params[:resolution] == "pending"
          scope = scope.actionable # sin alertas cuyas oportunidades ya no existen o se cerraron
        elsif params[:resolution].present?
          scope = scope.where(resolution: params[:resolution])
        end
        render_collection(scope.order(created_at: :desc), with: DuplicateFlagSerializer)
      end

      def show
        authorize @flag
        render_resource(@flag, with: DuplicateFlagSerializer)
      end

      # POST /api/v1/duplicate_flags/:id/reassign  { new_owner_user_id }
      def reassign
        authorize @flag, :update?
        new_owner = current_tenant.users.find(params.require(:new_owner_user_id))
        ActiveRecord::Base.transaction do
          @flag.duplicate_of_opportunity.update!(owner_user_id: new_owner.id)
          @flag.resolve!(as: "reassigned", by: current_user, note: params[:note])
        end
        audit_duplicate_flag!("duplicate.reassign", @flag, new_owner_user_id: new_owner.id)
        render_no_content
      end

      # POST /api/v1/duplicate_flags/:id/merge  — consolida en la ganadora
      # Fusiona la oportunidad duplicada en la existente y, si son de contactos
      # distintos, también los contactos: queda uno solo con todos sus orígenes.
      def merge
        authorize @flag, :update?
        DuplicateFlags::Merge.call(flag: @flag, by: current_user, note: params[:note])
        audit_duplicate_flag!("duplicate.merge", @flag)
        render_no_content
      end

      BULK_LIMIT = 500

      # POST /api/v1/duplicate_flags/bulk_merge — { ids: [...] } o { all: true }
      # Fusión masiva: misma lógica que #merge, una alerta a la vez (cada una en
      # su transacción). Las que ya no aplican (una oportunidad se cerró o se
      # fusionó en una alerta anterior del mismo lote) se omiten con su motivo.
      def bulk_merge
        authorize DuplicateFlag, :merge?
        scope = policy_scope(DuplicateFlag).resolution_pending
        unless ActiveModel::Type::Boolean.new.cast(params[:all])
          ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
          return render json: { error: "bad_request", message: "ids requeridos" }, status: :bad_request if ids.empty?

          scope = scope.where(id: ids)
        end

        merged = 0
        skipped = []
        scope.order(:created_at).limit(BULK_LIMIT).pluck(:id).each do |id|
          flag = DuplicateFlag.actionable.find_by(id: id)
          next skipped << { id: id.to_s, reason: "ya no aplica (oportunidad cerrada o ya fusionada)" } unless flag

          DuplicateFlags::Merge.call(flag: flag, by: current_user, note: "Fusión masiva")
          audit_duplicate_flag!("duplicate.merge", flag, bulk: true)
          merged += 1
        rescue ActiveRecord::RecordInvalid, ArgumentError => e
          skipped << { id: id.to_s, reason: e.message.truncate(160) }
        end

        render json: { data: { merged: merged, skipped: skipped } }, status: :ok
      end

      # POST /api/v1/duplicate_flags/:id/ignore
      def ignore
        authorize @flag, :update?
        @flag.resolve!(as: "ignored", by: current_user, note: params[:note])
        audit_duplicate_flag!("duplicate.ignore", @flag)
        render_no_content
      end

      # POST /api/v1/duplicate_flags/scan
      # Escanea todas las oportunidades abiertas del tenant y crea flags para
      # pares que compartan el mismo contacto y aún no tengan un flag existente.
      # POST /api/v1/duplicate_flags/scan — busca duplicados en todo el tenant:
      # mismo contacto con varias oportunidades abiertas, y contactos distintos
      # con el mismo celular o correo (ver DuplicateFlags::Scanner).
      def scan
        authorize DuplicateFlag, :create?
        result = DuplicateFlags::Scanner.call(tenant: current_tenant, actor: current_user)

        audit_duplicate_scan!(scanned: result.scanned, created: result.created) if result.created.positive?

        render json: { scanned: result.scanned, created: result.created }, status: :ok
      end

      private

      def set_flag
        @flag = policy_scope(DuplicateFlag).includes(
          :detected_by_user,
          :resolved_by_user,
          opportunity:              %i[contact owner_user],
          duplicate_of_opportunity: %i[contact owner_user]
        ).find(params[:id])
      end
    end
  end
end
