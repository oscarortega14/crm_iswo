# frozen_string_literal: true

module Api
  module V1
    # ========================================================================
    # OpportunitiesController — CRUD + acciones de dominio + Kanban + export
    # ========================================================================
    class OpportunitiesController < BaseController
      include ExportAuditable
      include ExportDownloadable

      before_action :set_opportunity, only: %i[
        show update destroy move_stage assign merge recalculate_bant
        classify sync_temperature temperature_context
      ]

      # GET /api/v1/opportunities
      def index
        authorize Opportunity, :index?
        scope = policy_scope(Opportunity).kept.includes(:contact, :pipeline_stage, :owner_user, :reminders, :lead_source)

        scope = scope.where(status: params[:status])                       if params[:status].present?
        scope = scope.where(pipeline_id: params[:pipeline_id])             if params[:pipeline_id].present?
        if params[:pipeline_stage_id].present?
          scope = scope.where(pipeline_stage_id: params[:pipeline_stage_id])
        elsif params[:stage_id].present?
          scope = scope.where(pipeline_stage_id: params[:stage_id])
        end
        scope = scope.where(contact_id: params[:contact_id])               if params[:contact_id].present?
        if params[:landing_page_id].present?
          scope = apply_landing_page_filter(scope, params[:landing_page_id])
        end
        if params[:owner_id].present? && owner_filter_allowed?(params[:owner_id])
          scope = scope.where(owner_user_id: params[:owner_id])
        end
        if params[:q].present?
          initials = ActiveModel::Type::Boolean.new.cast(params[:initials])
          scope = apply_opportunity_search(scope, params[:q], initials_mode: initials)
        end
        scope = scope.stale(params[:stale_days].to_i)                      if params[:stale_days].present?
        if params[:temperature].present? && Opportunity::TEMPERATURES.include?(params[:temperature].to_s)
          scope = scope.where(temperature: params[:temperature])
        end


        render_collection(
          scope.order(last_activity_at: :desc),
          with:    OpportunitySerializer,
          include: [:owner_user, :lead_source, :contact],
          params:  opportunity_serializer_params
        )
      end

      def show
        authorize @opportunity
        render_resource(@opportunity, with: OpportunitySerializer, include: [:owner_user, :lead_source, :contact],
                        params: opportunity_serializer_params)
      end

      def create
        authorize Opportunity
        attrs = opportunity_create_attributes
        h     = attrs.to_h.symbolize_keys
        contact = resolve_contact_for_opportunity!(h)
        stage_id = h[:pipeline_stage_id].presence || h[:stage_id].presence
        if stage_id.blank?
          @opportunity = current_tenant.opportunities.new
          @opportunity.errors.add(:pipeline_stage_id, "no puede estar en blanco")
          return render_unprocessable(@opportunity)
        end

        # Siempre derivar el pipeline de la etapa: evita 422 cuando el SPA envía un pipeline_id
        # desfasado respecto a la etapa (p. ej. tras cambiar embudo sin actualizar etapa).
        stage = current_tenant.pipeline_stages.find_by(id: stage_id)
        unless stage
          @opportunity = current_tenant.opportunities.new
          @opportunity.errors.add(:pipeline_stage_id, "no es válida o no pertenece a este tenant")
          return render_unprocessable(@opportunity)
        end

        explicit_temp = normalized_temperature_param(h[:temperature])
        @opportunity = current_tenant.opportunities.new(
          title:             h[:title].presence || default_opportunity_title(contact, h),
          notes:             h[:notes],
          estimated_value:   h[:estimated_value],
          temperature:       explicit_temp || "cold",
          pipeline_id:       stage.pipeline_id,
          pipeline_stage_id: stage.id,
          lead_source_id:    h[:lead_source_id].presence,
          contact:           contact,
          owner_user:        current_user,
          currency:          current_tenant.currency
        )
        @opportunity.preserve_temperature_on_bant_recalc = explicit_temp.present?
        if @opportunity.save
          log_action!("create", @opportunity.attributes)
          notify_new_lead!(@opportunity)
          flag_duplicates_for!(@opportunity, contact)
          render_created(@opportunity, with: OpportunitySerializer, include: [:owner_user, :lead_source, :contact])
        else
          render_unprocessable(@opportunity)
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          error:   "unprocessable_entity",
          message: "Validación fallida",
          details: e.record.errors.as_json(full_messages: true)
        }, status: :unprocessable_entity
      end

      def update
        authorize @opportunity
        before = @opportunity.attributes.dup
        from_stage = @opportunity.pipeline_stage
        before_stage_id = @opportunity.pipeline_stage_id
        bant_in = params.dig(:opportunity, :bant_data).present?
        attrs = update_params.to_h
        stage_in_request = stage_id_in_attrs?(attrs)
        apply_stage_status!(attrs)
        @opportunity.preserve_temperature_on_bant_recalc = temperature_param_explicit?
        if @opportunity.update(attrs)
          # `before`/attributes finales en vez de saved_change_to_*?: el callback
          # after_update de BANT hace su propio update!/reload anidado sobre este
          # mismo registro, lo que resetea el dirty-tracking de ActiveRecord antes
          # de que el controller pueda leerlo. Comparar contra el snapshot previo
          # sí refleja el resultado real de todo el ciclo de guardado.
          changes = diff(before, @opportunity.attributes)
          bant_recalc = changes.key?("estimated_value") ||
                        (changes.key?("custom_fields") && bant_in)
          auto_queued = enqueue_auto_temperature_classify!(
            changed_keys: changes.keys,
            source:       "auto_save"
          )
          recalc_temp = !temperature_param_explicit? && !bant_recalc && !auto_queued
          @opportunity.touch_activity!(recalc_temperature: recalc_temp)
          log_action!("update", changes)
          if @opportunity.pipeline_stage_id != before_stage_id
            notify_stage_change!(
              from_stage: from_stage,
              to_stage:   @opportunity.pipeline_stage,
              # Si la etapa cambió y el request no la pidió explícitamente, solo
              # pudo moverla el auto-avance por calificación BANT (BantScorer);
              # nada más en esta acción cambia pipeline_stage_id sin stage_in_request.
              automatic:  !stage_in_request
            )
          end
          render_opportunity_resource(
            @opportunity,
            meta: temperature_classification_meta(auto_queued)
          )
        else
          render_unprocessable(@opportunity)
        end
      end

      def destroy
        authorize @opportunity
        log_action!("destroy", { title: @opportunity.title, contact_id: @opportunity.contact_id })
        @opportunity.discard
        render_no_content
      end

      # DELETE /api/v1/opportunities/bulk_destroy  — { ids: ["1","2",...] }
      def bulk_destroy
        authorize Opportunity, :destroy?
        ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
        if ids.blank?
          return render json: { error: "bad_request", message: "ids requeridos" },
                        status: :bad_request
        end

        opportunities = policy_scope(Opportunity).kept.where(id: ids)
        deleted = opportunities.count
        opportunities.find_each do |opp|
          opp.opportunity_logs.create!(
            tenant:       current_tenant,
            user:         current_user,
            action:       "destroy",
            changes_data: LogSanitizer.redact(
              { title: opp.title, contact_id: opp.contact_id, bulk: true }
            ),
            ip_address:   request.remote_ip,
            user_agent:   request.user_agent
          )
        end
        opportunities.discard_all
        render json: { data: { deleted: deleted } }, status: :ok
      end

      # POST /api/v1/opportunities/:id/move_stage  { pipeline_stage_id }
      def move_stage
        authorize @opportunity, :move_stage?
        new_stage = current_tenant.pipeline_stages.find(params.require(:pipeline_stage_id))

        Opportunities::StageMover.call(
          opportunity: @opportunity, stage: new_stage, actor: current_user, request_meta: request_meta
        )

        render_resource(@opportunity, with: OpportunitySerializer, include: [:owner_user, :lead_source, :contact],
                        params: opportunity_serializer_params)
      end

      BULK_MOVE_MAX = 500

      # POST /api/v1/opportunities/bulk_move_stage  { ids: [...], pipeline_stage_id }
      # Mueve solo las que el usuario puede mover (consultor: propias; nunca las
      # de la red en solo lectura) y reporta las omitidas con motivo.
      def bulk_move_stage
        authorize Opportunity, :bulk_move_stage?
        ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
        if ids.blank? || ids.size > BULK_MOVE_MAX
          return render json: { error: "bad_request", message: "ids requeridos (máximo #{BULK_MOVE_MAX})" },
                        status: :bad_request
        end

        stage   = current_tenant.pipeline_stages.find(params.require(:pipeline_stage_id))
        found   = policy_scope(Opportunity).kept.where(id: ids).includes(:pipeline_stage).index_by(&:id)
        moved   = 0
        skipped = []

        ids.each do |id|
          opp = found[id]
          reason =
            if opp.nil? then "no encontrada"
            elsif !policy(opp).move_stage? then "sin permiso"
            elsif opp.pipeline_stage_id == stage.id then "ya estaba en esa etapa"
            end
          next skipped << { id: id.to_s, reason: reason } if reason

          Opportunities::StageMover.call(
            opportunity: opp, stage: stage, actor: current_user, request_meta: request_meta, bulk: true
          )
          moved += 1
        rescue ActiveRecord::RecordInvalid => e
          skipped << { id: id.to_s, reason: e.record.errors.full_messages.to_sentence.presence || "inválida" }
        end

        render json: { data: { moved: moved, skipped: skipped, stage_name: stage.name } }, status: :ok
      end

      # POST /api/v1/opportunities/:id/assign  { owner_user_id }
      def assign
        authorize @opportunity, :assign?
        new_owner = current_tenant.users.find(params.require(:owner_user_id))
        from = @opportunity.owner_user_id
        @opportunity.update!(owner_user_id: new_owner.id)
        log_action!("assign", { from: from, to: new_owner.id })
        render_resource(@opportunity, with: OpportunitySerializer, include: [:owner_user, :lead_source, :contact],
                        params: opportunity_serializer_params)
      end

      # POST /api/v1/opportunities/:id/merge  { target_id }
      def merge
        authorize @opportunity, :merge?
        target = current_tenant.opportunities.find(params.require(:target_id))
        if defined?(Opportunities::Merger)
          Opportunities::Merger.new(source: @opportunity, target: target, performed_by: current_user).call
        end
        render_resource(target.reload, with: OpportunitySerializer, include: [:owner_user, :lead_source, :contact])
      end

      # POST /api/v1/opportunities/:id/recalculate_bant
      def recalculate_bant
        authorize @opportunity, :recalculate_bant?
        from_stage = @opportunity.pipeline_stage
        before_stage_id = @opportunity.pipeline_stage_id
        before_score = @opportunity.bant_score
        before_qualified = @opportunity.qualified
        Opportunities::BantScorer.new(@opportunity).call_and_persist! if defined?(Opportunities::BantScorer)
        @opportunity.reload
        # BantScorer solo deja opportunity_log si además avanza de etapa
        # (auto_advance_stage!); sin esto, un recalculo que cambia el score/
        # qualified sin mover la etapa no quedaba auditado en absoluto.
        if before_score != @opportunity.bant_score || before_qualified != @opportunity.qualified
          log_action!(
            "update",
            {
              bant_score: { from: before_score, to: @opportunity.bant_score },
              qualified:  { from: before_qualified, to: @opportunity.qualified }
            }
          )
        end
        if @opportunity.pipeline_stage_id != before_stage_id
          notify_stage_change!(
            from_stage: from_stage,
            to_stage:   @opportunity.pipeline_stage,
            automatic:  true
          )
        end
        payload = OpportunitySerializer.new(
          @opportunity,
          include: [:owner_user, :lead_source, :contact]
        ).serializable_hash
        ai_meta = maybe_auto_classify_with_claude!
        payload[:meta] = ai_meta if ai_meta.present?
        render json: payload, status: :ok
      end

      # GET /api/v1/opportunities/:id/temperature_context — señales del lead para la UI / IA
      def temperature_context
        authorize @opportunity, :show?
        ctx = Opportunities::TemperatureContext.new(@opportunity.reload)
        render json: {
          data: {
            signal_count:        ctx.signals.size,
            data_considered:     ctx.data_considered,
            last_classification: Opportunities::TemperatureAutoClassifier.read_cached_result(@opportunity.id)
          }
        }, status: :ok
      end

      # POST /api/v1/opportunities/:id/sync_temperature — reglas BANT + actividad (sin IA)
      def sync_temperature
        authorize @opportunity, :update?
        calc = Opportunities::TemperatureCalculator.new(@opportunity).apply!
        log_action!("classify", { temperature: calc.temperature, ai_used: false, source: "rules" })

        ctx = Opportunities::TemperatureContext.new(@opportunity)
        render json: {
          data:      OpportunitySerializer.new(@opportunity.reload, include: [:owner_user, :lead_source, :contact]).serializable_hash[:data],
          ai_result: {
            temperature:     calc.temperature,
            reasoning:       calc.reasoning,
            next_action:     calc.next_action,
            ai_used:         false,
            data_considered: ctx.data_considered
          }
        }, status: :ok
      end

      # POST /api/v1/opportunities/:id/classify — Claude (Anthropic) o reglas si no hay API key
      def classify
        authorize @opportunity, :update?
        classifier = Opportunities::AiClassifier.new(@opportunity.reload)
        result = classifier.call
        @opportunity.update!(temperature: result.temperature, last_activity_at: Time.current)
        log_action!(
          "classify",
          {
            temperature:     result.temperature,
            ai_used:         result.ai_used?,
            model:           result.ai_used? ? Opportunities::AiClassifier.model_name : nil,
            fallback_reason: result.fallback_reason,
            anthropic_error: classifier.last_error
          }.compact
        )

        Opportunities::TemperatureAutoClassifier.store_result!(
          @opportunity.id,
          {
            temperature:     result.temperature,
            reasoning:       result.reasoning,
            next_action:     result.next_action,
            ai_used:         result.ai_used?,
            fallback_reason: result.fallback_reason,
            data_considered: result.data_considered,
            source:          "manual",
            classified_at:   Time.current.iso8601
          }
        )

        render json: classify_response_payload(result, classifier), status: :ok
      end

      # GET /api/v1/opportunities/kanban?pipeline_id=...
      def kanban
        authorize Opportunity, :kanban?
        pipeline = current_tenant.pipelines.find(params.require(:pipeline_id))
        stages   = pipeline.pipeline_stages.order(:position)

        scope = policy_scope(Opportunity).kept.where(pipeline: pipeline).includes(:contact, :owner_user)
        grouped = scope.group_by(&:pipeline_stage_id)

        ser_params = opportunity_serializer_params
        render json: {
          data: stages.map do |stage|
            opps = grouped[stage.id] || []
            {
              stage:         PipelineStageSerializer.new(stage).serializable_hash[:data],
              opportunities: OpportunitySerializer.new(opps, params: ser_params).serializable_hash[:data] || []
            }
          end
        }, status: :ok
      end

      # POST /api/v1/opportunities/export
      # GET /api/v1/opportunities/export.csv | export.xlsx — RFC §6.7
      def export_download
        export_download_for("opportunities")
      end

      def export
        authorize Opportunity, :export?
        file_format = resolve_export_file_format
        filters     = normalize_export_filters_param
        export = current_tenant.exports.create!(
          user:     current_user,
          resource: "opportunities",
          format:   file_format,
          filters:  filters
        )
        safe_enqueue_export_generation_job(export.id)
        record_export_audit!(resource: "opportunities", format: file_format, filters: filters, sync: false)
        render_resource(export, with: ExportSerializer, status: :accepted)
      end

      private

      def set_opportunity
        @opportunity = policy_scope(Opportunity).kept
                                               .includes(
                                                 :lead_source, :owner_user, :contact, :pipeline_stage, :pipeline,
                                                 :opportunity_logs, :reminders
                                               )
                                               .find(params[:id])
      end

      def opportunity_create_attributes
        raw = params[:opportunity].presence || params[:data]
        raise ActionController::ParameterMissing, :opportunity if raw.blank?

        raw.permit(
          :contact_id, :pipeline_id, :pipeline_stage_id, :stage_id,
          :contact_name, :contact_email, :contact_phone, :company_name,
          :title, :notes, :estimated_value, :status, :temperature,
          :expected_close_date, :lead_source_id,
          custom_fields: {}, bant_data: {}
        )
      end

      def resolve_contact_for_opportunity!(attrs)
        attrs = attrs.symbolize_keys
        if attrs[:contact_id].present?
          return current_tenant.contacts.kept.find(attrs[:contact_id])
        end

        name = attrs[:contact_name].to_s.strip
        if name.blank?
          c = current_tenant.contacts.new
          c.errors.add(:contact_name, "es obligatorio")
          raise ActiveRecord::RecordInvalid.new(c)
        end

        parts  = name.split(/\s+/, 2)
        email  = attrs[:contact_email].to_s.strip.presence
        phone  = attrs[:contact_phone].to_s.strip.presence
        company = attrs[:company_name].to_s.strip.presence

        if email.present?
          hit = current_tenant.contacts.kept.where("LOWER(email) = ?", email.downcase).first
          return hit if hit
        end

        if phone.present?
          parsed = Phonelib.parse(phone, "CO")
          if parsed.valid?
            hit = current_tenant.contacts.kept.find_by(phone_e164: parsed.e164)
            return hit if hit
          end
        end

        contact = current_tenant.contacts.new(
          first_name:   parts[0],
          last_name:    parts[1],
          email:        email,
          phone_e164:   phone,
          company_name: company,
          kind:         "person",
          owner_user:   current_user
        )
        contact.save!
        contact
      end

      def default_opportunity_title(contact, h)
        base = contact.display_name
        comp = h[:company_name].to_s.strip.presence
        comp ? "#{base} — #{comp}" : base
      end

      def update_params
        params.require(:opportunity).permit(
          :title, :notes, :estimated_value, :temperature,
          :expected_close_date, :lost_reason, :lead_source_id,
          :pipeline_stage_id,
          custom_fields: {},
          bant_data: {
            budget:    [:score, :answer],
            authority: [:score, :answer],
            need:      [:score, :answer],
            timeline:  [:score, :answer]
          }
        )
      end

      def temperature_param_explicit?
        raw = params[:opportunity]
        return false unless raw.respond_to?(:key?)

        raw.key?(:temperature) || raw.key?("temperature")
      end

      def normalized_temperature_param(value)
        temp = value.to_s.strip.downcase
        return temp if Opportunity::TEMPERATURES.include?(temp)

        nil
      end

      # Misma lógica que move_stage: al cambiar etapa vía PATCH, sincronizar status.
      def apply_stage_status!(attrs)
        stage_id = attrs["pipeline_stage_id"] || attrs[:pipeline_stage_id]
        return if stage_id.blank?

        stage = current_tenant.pipeline_stages.find_by(id: stage_id)
        return unless stage

        if stage.closed_won
          attrs["status"] = "won"
        elsif stage.closed_lost
          attrs["status"] = "lost"
        end
      end

      def maybe_auto_classify_with_claude!
        return {} unless Opportunities::AiClassifier.auto_classify_enabled?

        payload = Opportunities::TemperatureAutoClassifier.new(
          @opportunity,
          source:      "auto_bant",
          user:        current_user,
          ip_address:  request.remote_ip,
          user_agent:  request.user_agent
        ).call
        return {} unless payload

        @opportunity.reload
        {
          temperature_ai: payload.merge(model: Opportunities::AiClassifier.model_name)
        }
      end

      def enqueue_auto_temperature_classify!(changed_keys:, source:)
        return false if temperature_param_explicit?

        Opportunities::TemperatureAutoClassifier.enqueue_for_opportunity!(
          opportunity:  @opportunity,
          source:       source,
          user:         current_user,
          changed_keys: changed_keys,
          ip_address:   request.remote_ip,
          user_agent:   request.user_agent
        )
      end

      def temperature_classification_meta(queued)
        return {} unless queued

        { temperature_classification: { queued: true, auto: true } }
      end

      def render_opportunity_resource(record, meta: {}, status: :ok)
        payload = OpportunitySerializer.new(
          record,
          include: [:owner_user, :lead_source, :contact],
          params:  opportunity_serializer_params
        ).serializable_hash
        payload[:meta] = meta if meta.present?
        render json: payload, status: status
      end

      def classify_response_payload(result, classifier = nil)
        {
          data:      OpportunitySerializer.new(@opportunity.reload, include: [:owner_user, :lead_source, :contact]).serializable_hash[:data],
          ai_result: {
            temperature:     result.temperature,
            reasoning:       result.reasoning,
            next_action:     result.next_action,
            ai_used:         result.ai_used?,
            fallback_reason: result.fallback_reason,
            data_considered: result.data_considered
          },
          meta:      {
            claude_configured: Opportunities::AiClassifier.configured?,
            model:             result.ai_used? ? Opportunities::AiClassifier.model_name : nil,
            ai_used:           result.ai_used?,
            anthropic_status:  classifier&.last_status,
            anthropic_error:   classifier&.last_error
          }.compact
        }
      end

      def request_meta
        { ip_address: request.remote_ip, user_agent: request.user_agent }
      end

      def log_action!(action, changes_data)
        @opportunity.opportunity_logs.create!(
          tenant:       current_tenant,
          user:         current_user,
          action:       action,
          changes_data: LogSanitizer.redact(changes_data),
          ip_address:   request.remote_ip,
          user_agent:   request.user_agent
        )
      end

      def diff(before, after)
        keys = (before.keys + after.keys).uniq - %w[updated_at]
        keys.each_with_object({}) do |k, h|
          h[k] = { from: before[k], to: after[k] } if before[k] != after[k]
        end
      end

      def flag_duplicates_for!(opportunity, contact)
        Opportunities::DuplicateFlagsCreator.new(tenant: current_tenant, actor: current_user)
                                            .call(opportunity, contact)
      end

      def notify_new_lead!(opportunity)
        source = opportunity.lead_source
        Notifications::NewLeadNotifier.call(
          opportunity:  opportunity,
          actor:        current_user,
          source_kind:  source&.kind,
          source_label: source&.name
        )
      end

      def notify_stage_change!(from_stage:, to_stage:, automatic: false)
        Notifications::StageChangeNotifier.call(
          opportunity: @opportunity.reload,
          from_stage:  from_stage,
          to_stage:    to_stage,
          actor:       current_user,
          automatic:   automatic
        )
      end

      def stage_id_in_attrs?(attrs)
        attrs.key?("pipeline_stage_id") || attrs.key?(:pipeline_stage_id)
      end

      def apply_opportunity_search(scope, q_param, initials_mode: false)
        q_raw = q_param.to_s.strip
        return scope if q_raw.blank?

        joined = scope.left_joins(:contact)
        if initials_mode && two_letter_initials_query?(q_raw)
          return apply_initials_search(joined, q_raw)
        end

        like   = "%#{ActiveRecord::Base.sanitize_sql_like(q_raw)}%"
        digits = q_raw.gsub(/\D/, "")
        phone_like = digits.length >= 2 ? "%#{ActiveRecord::Base.sanitize_sql_like(digits)}%" : like
        joined.where(
          "opportunities.title ILIKE :q OR contacts.first_name ILIKE :q OR " \
          "contacts.last_name ILIKE :q OR contacts.company_name ILIKE :q OR contacts.email ILIKE :q OR " \
          "contacts.phone_normalized ILIKE :phone",
          q: like, phone: phone_like
        )
      end

      def two_letter_initials_query?(q_raw)
        q_raw.length == 2 && q_raw.match?(/\A[\p{L}]{2}\z/ui)
      end

      # Ej. "CR" → Camila Restrepo, Carlos Mejía (inicial nombre + inicial apellido).
      def apply_initials_search(scope, q_raw)
        i1 = q_raw[0].downcase
        i2 = q_raw[1].downcase
        scope.where(
          <<~SQL.squish,
            LOWER(LEFT(TRIM(contacts.first_name), 1)) = :i1
            AND (
              LOWER(LEFT(TRIM(COALESCE(contacts.last_name, '')), 1)) = :i2
              OR (
                (contacts.last_name IS NULL OR TRIM(contacts.last_name) = '')
                AND LOWER(LEFT(SPLIT_PART(TRIM(contacts.first_name), ' ', 2), 1)) = :i2
              )
            )
          SQL
          i1: i1, i2: i2
        )
      end

      # Consultores no pueden filtrar por owner ajeno (evita confusión si la policy cambia).
      def owner_filter_allowed?(owner_id)
        return true unless current_user&.role == "consultant"

        owner_id.to_i == current_user.id
      end

      # Leads por landing: custom_fields, slug o envíos vinculados (datos legacy).
      def apply_landing_page_filter(scope, landing_page_id)
        lid = landing_page_id.to_s
        landing = current_tenant.landing_pages.find_by(id: lid)
        slug = landing&.slug.to_s

        opp_ids = LandingFormSubmission
                  .where(tenant_id: current_tenant.id, landing_page_id: lid)
                  .where.not(opportunity_id: nil)
                  .distinct
                  .pluck(:opportunity_id)

        json_parts = [
          "custom_fields->>'landing_page_id' = ?",
          "custom_fields->>'landing_page_id' = ?"
        ]
        binds = [lid, lid.to_i.to_s]
        if slug.present?
          json_parts << "custom_fields->>'landing_slug' = ?"
          binds << slug
        end
        json_sql = json_parts.join(" OR ")

        if opp_ids.any?
          scope.where("opportunities.id IN (?) OR (#{json_sql})", opp_ids, *binds)
        else
          scope.where(json_sql, *binds)
        end
      end

      def opportunity_serializer_params
        { current_user: current_user, tenant: current_tenant }
      end

    end
  end
end
