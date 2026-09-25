# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Opportunities", type: :request do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:manager)    { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
  let(:other_consultant) { create(:user, :consultant, tenant: tenant) }

  let(:pipeline) { create(:pipeline_with_stages, tenant: tenant) }
  let(:stage)    { pipeline.pipeline_stages.first }
  let(:won_stage) { pipeline.pipeline_stages.find_by(closed_won: true) }
  let(:contact)         { create(:contact, tenant: tenant) }
  let(:foreign_contact) { create(:contact, tenant: tenant) }

  let!(:own_opp) do
    create(:opportunity, :skip_bant_recalc,
           tenant: tenant, pipeline: pipeline, pipeline_stage: stage,
           contact: contact, owner_user: consultant, title: "Propia")
  end
  let!(:foreign_opp) do
    create(:opportunity, :skip_bant_recalc,
           tenant: tenant, pipeline: pipeline, pipeline_stage: stage,
           contact: foreign_contact, owner_user: other_consultant, title: "Ajena")
  end

  describe "GET /api/v1/opportunities" do
    it "manager ve todas" do
      get "/api/v1/opportunities", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to match_array([own_opp.id, foreign_opp.id])
    end

    it "consultant solo ve las suyas" do
      get "/api/v1/opportunities", headers: auth_headers(consultant)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to eq([own_opp.id])
    end

    it "filtra por status" do
      own_opp.update!(status: "qualified")
      get "/api/v1/opportunities?status=qualified", headers: auth_headers(manager)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to eq([own_opp.id])
    end

    it "filtra por q en título o contacto" do
      own_opp.contact.update!(first_name: "Zulma", last_name: "UniqueSearch")
      get "/api/v1/opportunities?q=UniqueSearch", headers: auth_headers(manager)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(own_opp.id)
      expect(ids).not_to include(foreign_opp.id)
    end

    it "filtra por iniciales con initials=true (2 letras)" do
      own_opp.contact.update!(first_name: "Camila", last_name: "Restrepo")
      foreign_opp.contact.update!(first_name: "Pedro", last_name: "López")

      get "/api/v1/opportunities?q=CR&initials=true", headers: auth_headers(manager)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(own_opp.id)
      expect(ids).not_to include(foreign_opp.id)
    end

    it "filtra por pipeline_id" do
      other_pipeline = create(:pipeline_with_stages, tenant: tenant)
      other_opp = create(:opportunity,
                         tenant: tenant,
                         pipeline: other_pipeline,
                         pipeline_stage: other_pipeline.pipeline_stages.first,
                         owner_user: manager)

      get "/api/v1/opportunities?pipeline_id=#{other_pipeline.id}", headers: auth_headers(manager)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to eq([other_opp.id])
    end
  end

  describe "POST /api/v1/opportunities" do
    let(:payload) do
      {
        opportunity: {
          contact_id: contact.id,
          pipeline_id: pipeline.id,
          pipeline_stage_id: stage.id,
          title: "Nueva deal",
          estimated_value: 1_000_000
        }
      }.to_json
    end

    it "201, asigna owner=current_user y crea log" do
      expect {
        post "/api/v1/opportunities", params: payload, headers: auth_headers(consultant)
      }.to change(Opportunity, :count).by(1)
        .and change(OpportunityLog, :count).by(1)

      expect(response).to have_http_status(:created)
      created = Opportunity.order(:created_at).last
      expect(created.owner_user_id).to eq(consultant.id)
      expect(created.opportunity_logs.last.action).to eq("create")
      expect(created.bant_score).to be > 0
    end

    it "201 sin título genera uno automático desde el contacto" do
      bad = { opportunity: { contact_id: contact.id, pipeline_id: pipeline.id, pipeline_stage_id: stage.id } }.to_json
      post "/api/v1/opportunities", params: bad, headers: auth_headers(consultant)
      expect(response).to have_http_status(:created)
      expect(json.dig("data", "attributes", "title")).to be_present
    end

    it "422 si falta la etapa del pipeline" do
      bad = { opportunity: { contact_id: contact.id } }.to_json
      post "/api/v1/opportunities", params: bad, headers: auth_headers(consultant)
      expect(response.status).to eq(422)
      expect(json["error"]).to eq("unprocessable_entity")
    end

    it "segunda oportunidad del mismo contacto crea flag y notifica admin/manager" do
      admin_user = create(:user, :admin, tenant: tenant)

      expect {
        post "/api/v1/opportunities",
             params: {
               opportunity: {
                 contact_id: contact.id,
                 pipeline_stage_id: stage.id,
                 title: "Colisión consultor"
               }
             }.to_json,
             headers: auth_headers(other_consultant)
      }.to change(DuplicateFlag, :count).by(1)
        .and change { admin_user.notifications.kind_duplicate_found.count }.by(1)
        .and change { manager.notifications.kind_duplicate_found.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(DuplicateFlag.last.resolution).to eq("pending")
    end
  end

  describe "PATCH /api/v1/opportunities/:id" do
    it "manager actualiza cualquier oportunidad" do
      patch "/api/v1/opportunities/#{foreign_opp.id}",
            params: { opportunity: { title: "Editada" } }.to_json,
            headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      expect(foreign_opp.reload.title).to eq("Editada")
    end

    it "consultant no puede actualizar ajenas (404 fuera de policy_scope)" do
      patch "/api/v1/opportunities/#{foreign_opp.id}",
            params: { opportunity: { title: "Hack" } }.to_json,
            headers: auth_headers(consultant)
      expect(response).to have_http_status(:not_found)
    end

    it "conserva temperatura hot cuando el consultor la elige manualmente" do
      own_opp.update!(temperature: "cold", bant_score: 10, last_activity_at: 30.days.ago)

      patch "/api/v1/opportunities/#{own_opp.id}",
            params: { opportunity: { temperature: "hot" } }.to_json,
            headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "attributes", "temperature")).to eq("hot")
      expect(own_opp.reload.temperature).to eq("hot")
    end

    it "al crear con temperatura explícita no la sobrescribe el calculador automático" do
      post "/api/v1/opportunities",
           params: {
             opportunity: {
               contact_id: contact.id,
               pipeline_stage_id: stage.id,
               title: "Lead caliente manual",
               temperature: "hot",
               estimated_value: 1_000_000
             }
           }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:created)
      expect(json.dig("data", "attributes", "temperature")).to eq("hot")
      created = tenant.opportunities.order(:id).last
      expect(created.temperature).to eq("hot")
      expect(created.bant_score).to be > 0
    end

    it "recalcula BANT al cambiar estimated_value" do
      own_opp.update_columns(bant_score: 0, estimated_value: 0)

      patch "/api/v1/opportunities/#{own_opp.id}",
            params: { opportunity: { estimated_value: 15_000_000 } }.to_json,
            headers: auth_headers(consultant)

      expect(response).to have_http_status(:ok)
      expect(own_opp.reload.bant_score).to be > 0
    end
  end

  describe "POST /api/v1/opportunities/:id/move_stage" do
    it "consultant puede mover su opp a won (marca status won)" do
      post "/api/v1/opportunities/#{own_opp.id}/move_stage",
           params: { pipeline_stage_id: won_stage.id }.to_json,
           headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      expect(own_opp.reload.status).to eq("won")
    end

    it "notifica al dueño cuando un manager mueve la etapa de una opp ajena" do
      mid_stage = pipeline.pipeline_stages.order(:position)[1]

      expect do
        post "/api/v1/opportunities/#{foreign_opp.id}/move_stage",
             params: { pipeline_stage_id: mid_stage.id }.to_json,
             headers: auth_headers(manager)
      end.to change {
        other_consultant.notifications.kind_stage_change.unread.count
      }.by(1)

      expect(response).to have_http_status(:ok)
      n = other_consultant.notifications.kind_stage_change.last
      expect(n.resource_id).to eq(foreign_opp.id)
    end

    it "no notifica al dueño cuando él mismo mueve su opp" do
      mid_stage = pipeline.pipeline_stages.order(:position)[1]

      expect do
        post "/api/v1/opportunities/#{own_opp.id}/move_stage",
             params: { pipeline_stage_id: mid_stage.id }.to_json,
             headers: auth_headers(consultant)
      end.not_to change {
        consultant.notifications.kind_stage_change.count
      }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/opportunities/bulk_move_stage" do
    let(:mid_stage) { pipeline.pipeline_stages.order(:position)[1] }

    def bulk_move(user, ids, stage_id = mid_stage.id)
      post "/api/v1/opportunities/bulk_move_stage",
           params: { ids: ids.map(&:to_s), pipeline_stage_id: stage_id }.to_json,
           headers: auth_headers(user)
    end

    it "manager mueve varias y registra log manual en cada una" do
      bulk_move(manager, [own_opp.id, foreign_opp.id])

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "moved")).to eq(2)
      expect(json.dig("data", "skipped")).to eq([])
      expect([own_opp.reload, foreign_opp.reload].map(&:pipeline_stage_id)).to all(eq(mid_stage.id))
      log = own_opp.opportunity_logs.where(action: "stage_change").last
      expect(log.user_id).to eq(manager.id)
      expect(log.changes_data).to include("bulk" => true, "to_stage_id" => mid_stage.id)
    end

    it "consultant solo mueve las propias; las ajenas quedan como omitidas" do
      bulk_move(consultant, [own_opp.id, foreign_opp.id])

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "moved")).to eq(1)
      expect(json.dig("data", "skipped")).to contain_exactly(
        { "id" => foreign_opp.id.to_s, "reason" => "no encontrada" }
      )
      expect(own_opp.reload.pipeline_stage_id).to eq(mid_stage.id)
      expect(foreign_opp.reload.pipeline_stage_id).to eq(stage.id)
    end

    it "etapa de cierre ganado sincroniza status won" do
      bulk_move(manager, [own_opp.id], won_stage.id)
      expect(own_opp.reload.status).to eq("won")
    end

    it "omite las que ya estaban en esa etapa" do
      bulk_move(manager, [own_opp.id], stage.id)
      expect(json.dig("data", "moved")).to eq(0)
      expect(json.dig("data", "skipped").first["reason"]).to eq("ya estaba en esa etapa")
    end

    it "viewer no puede (403)" do
      viewer = create(:user, :viewer, tenant: tenant)
      bulk_move(viewer, [own_opp.id])
      expect(response).to have_http_status(:forbidden)
    end

    it "400 sin ids" do
      bulk_move(manager, [])
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /api/v1/opportunities/:id/assign" do
    it "solo manager/admin; responde 200 y reasigna owner" do
      post "/api/v1/opportunities/#{foreign_opp.id}/assign",
           params: { owner_user_id: consultant.id }.to_json,
           headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      expect(foreign_opp.reload.owner_user_id).to eq(consultant.id)
    end

    it "consultant es bloqueado (403)" do
      post "/api/v1/opportunities/#{own_opp.id}/assign",
           params: { owner_user_id: other_consultant.id }.to_json,
           headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "consultores pares (sin red entre ellos)" do
    let(:manager_user) { create(:user, :manager, tenant: tenant) }

    before do
      create(:referral_network, tenant: tenant, referrer_user: manager_user, referred_user: consultant)
      create(:referral_network, tenant: tenant, referrer_user: manager_user, referred_user: other_consultant)
    end

    it "cada consultor solo ve sus oportunidades en index" do
      get "/api/v1/opportunities", headers: auth_headers(consultant)
      expect(json["data"].map { |d| d["id"].to_i }).to eq([own_opp.id])

      get "/api/v1/opportunities", headers: auth_headers(other_consultant)
      expect(json["data"].map { |d| d["id"].to_i }).to eq([foreign_opp.id])
    end
  end

  describe "GET /api/v1/opportunities/kanban" do
    it "devuelve array agrupado por stage con opportunities por etapa" do
      get "/api/v1/opportunities/kanban?pipeline_id=#{pipeline.id}", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      stages = json["data"].map { |d| d.dig("stage", "id").to_i }
      expect(stages).to match_array(pipeline.pipeline_stages.pluck(:id))
    end
  end

  describe "red de referidos (RFC F2)" do
    let(:referred) { create(:user, :consultant, tenant: tenant) }

    before do
      tenant.update!(settings: tenant.settings.merge("network_depth" => 3))
      create(:referral_network, tenant: tenant, referrer_user: consultant, referred_user: referred)
    end

    let!(:network_opp) do
      create(:opportunity,
             tenant: tenant,
             pipeline: pipeline,
             pipeline_stage: stage,
             contact: foreign_contact,
             owner_user: referred,
             title: "Red referido")
    end

    it "consultant ve propias y las de referidos en index" do
      get "/api/v1/opportunities", headers: auth_headers(consultant)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to match_array([own_opp.id, network_opp.id])
    end

    it "serializa from_network y network_read_only en show de opp de referido" do
      get "/api/v1/opportunities/#{network_opp.id}", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      attrs = json.dig("data", "attributes") || {}
      expect(attrs["from_network"]).to be(true)
      expect(attrs["network_read_only"]).to be(true)
    end

    it "consultant no puede mover etapa en opp de referido (403)" do
      target = pipeline.pipeline_stages.second || stage
      post "/api/v1/opportunities/#{network_opp.id}/move_stage",
           params: { pipeline_stage_id: target.id }.to_json,
           headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end

    it "bulk_move_stage omite opps de referidos (solo lectura) por permiso" do
      target = pipeline.pipeline_stages.second || stage
      post "/api/v1/opportunities/bulk_move_stage",
           params: { ids: [network_opp.id.to_s], pipeline_stage_id: target.id }.to_json,
           headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "skipped")).to contain_exactly({ "id" => network_opp.id.to_s, "reason" => "sin permiso" })
    end

    it "consultant no puede actualizar opp de referido (403)" do
      patch "/api/v1/opportunities/#{network_opp.id}",
            params: { opportunity: { title: "Hack" } }.to_json,
            headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end

    it "consultant ve propias y referidos en kanban" do
      get "/api/v1/opportunities/kanban?pipeline_id=#{pipeline.id}", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      opp_ids = json["data"].flat_map { |col| Array(col["opportunities"]).map { |o| o["id"].to_i } }
      expect(opp_ids).to include(own_opp.id, network_opp.id)
    end

    it "consultant sigue sin ver opps fuera de su red (404)" do
      get "/api/v1/opportunities/#{foreign_opp.id}", headers: auth_headers(consultant)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/opportunities/:id" do
    it "admin soft-deleta (discard)" do
      admin = create(:user, :admin, tenant: tenant)
      delete "/api/v1/opportunities/#{own_opp.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:no_content)
      expect(own_opp.reload.discarded?).to be(true)
    end

    it "manager no puede destruir (403)" do
      delete "/api/v1/opportunities/#{own_opp.id}", headers: auth_headers(manager)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/opportunities/bulk_destroy" do
    let(:admin) { create(:user, :admin, tenant: tenant) }

    it "admin elimina varias oportunidades del tenant" do
      expect {
        delete "/api/v1/opportunities/bulk_destroy",
               params: { ids: [own_opp.id, foreign_opp.id] },
               headers: auth_headers(admin),
               as: :json
      }.to change { Opportunity.kept.count }.by(-2)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "deleted")).to eq(2)
      expect(own_opp.reload.discarded?).to be(true)
      expect(foreign_opp.reload.discarded?).to be(true)
    end

    it "consultant recibe forbidden" do
      delete "/api/v1/opportunities/bulk_destroy",
             params: { ids: [own_opp.id] },
             headers: auth_headers(consultant),
             as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
