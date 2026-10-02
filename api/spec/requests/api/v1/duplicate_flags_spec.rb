# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::DuplicateFlags", type: :request do
  let(:tenant)    { ActsAsTenant.current_tenant }
  let(:admin)     { create(:user, :admin,   tenant: tenant) }
  let(:manager)   { create(:user, :manager, tenant: tenant) }
  let(:consultant){ create(:user, :consultant, tenant: tenant) }
  let(:pipeline)  { create(:pipeline_with_stages, tenant: tenant) }
  let(:contact)   { create(:contact, tenant: tenant) }
  let(:opp_a)     { create(:opportunity, tenant: tenant, contact: contact, pipeline: pipeline, pipeline_stage: pipeline.pipeline_stages.first) }
  let(:opp_b)     { create(:opportunity, tenant: tenant, contact: contact, pipeline: pipeline, pipeline_stage: pipeline.pipeline_stages.first) }
  let!(:flag)     { create(:duplicate_flag, tenant: tenant, opportunity: opp_a, duplicate_of_opportunity: opp_b) }

  describe "GET /api/v1/duplicate_flags/stats" do
    let!(:pending_flag) { create(:duplicate_flag, tenant: tenant, resolution: "pending") }
    let!(:resolved_flag) { create(:duplicate_flag, tenant: tenant, resolution: "merged") }

    it "devuelve conteos pending y total" do
      get "/api/v1/duplicate_flags/stats", headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "pending")).to be >= 1
      expect(json.dig("data", "total")).to be >= 2
    end
  end

  describe "GET /api/v1/duplicate_flags" do
    it "200 con lista de flags" do
      get "/api/v1/duplicate_flags", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(flag.id)
    end

    it "filtra por resolution=pending" do
      get "/api/v1/duplicate_flags?resolution=pending", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(flag.id)
    end

    it "consultant solo ve flags donde participa" do
      flag.update!(detected_by_user: consultant)
      foreign_flag = create(:duplicate_flag, tenant: tenant, detected_by_user: manager)

      get "/api/v1/duplicate_flags", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(flag.id)
      expect(ids).not_to include(foreign_flag.id)
    end
  end

  describe "GET /api/v1/duplicate_flags/:id" do
    it "200 con detalle" do
      get "/api/v1/duplicate_flags/#{flag.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "id").to_i).to eq(flag.id)
    end

    it "incluye resumen RFC (owner y fechas) en attributes" do
      opp_a.update!(owner_user: consultant)
      opp_b.update!(owner_user: manager)
      get "/api/v1/duplicate_flags/#{flag.id}", headers: auth_headers(admin)
      attrs = json.dig("data", "attributes")
      expect(attrs["opportunity_a"]["owner_name"]).to eq(consultant.name)
      expect(attrs["opportunity_b"]["owner_name"]).to eq(manager.name)
      expect(attrs["opportunity_a"]["created_at"]).to be_present
    end

    it "consultant puede ver un flag donde participa" do
      flag.update!(detected_by_user: consultant)
      get "/api/v1/duplicate_flags/#{flag.id}", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
    end

    it "consultant recibe 404 en flag ajeno" do
      get "/api/v1/duplicate_flags/#{flag.id}", headers: auth_headers(consultant)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/duplicate_flags/:id/ignore" do
    it "manager puede ignorar un flag" do
      post "/api/v1/duplicate_flags/#{flag.id}/ignore", headers: auth_headers(manager)
      expect(response).to have_http_status(:no_content)
      expect(flag.reload.resolution).to eq("ignored")
    end
  end

  describe "POST /api/v1/duplicate_flags/scan" do
    it "admin puede lanzar el scan" do
      post "/api/v1/duplicate_flags/scan", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(json).to include("scanned", "created")
    end

    it "consultant no puede lanzar el scan" do
      post "/api/v1/duplicate_flags/scan", headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "alertas que ya no aplican" do
    it "no aparecen como pendientes ni cuentan en stats si una oportunidad se eliminó o se cerró" do
      pipeline = create(:pipeline_with_stages, tenant: tenant)
      mk = lambda do |**attrs|
        create(:opportunity, :skip_bant_recalc, tenant: tenant, pipeline: pipeline,
                                                pipeline_stage: pipeline.pipeline_stages.first, **attrs)
      end
      live  = create(:duplicate_flag, tenant: tenant, opportunity: mk.call, duplicate_of_opportunity: mk.call)
      gone  = mk.call
      stale_deleted = create(:duplicate_flag, tenant: tenant, opportunity: gone, duplicate_of_opportunity: mk.call)
      gone.discard
      stale_closed = create(:duplicate_flag, tenant: tenant, opportunity: mk.call(status: "won"),
                                             duplicate_of_opportunity: mk.call)

      get "/api/v1/duplicate_flags", params: { resolution: "pending" }, headers: auth_headers(admin)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(live.id, flag.id) # `flag`: alerta vigente del setup del archivo
      expect(ids).not_to include(stale_deleted.id, stale_closed.id)

      get "/api/v1/duplicate_flags/stats", headers: auth_headers(admin)
      expect(json.dig("data", "pending")).to eq(2)
    end
  end

  describe "POST /api/v1/duplicate_flags/scan (contactos distintos)" do
    it "encuentra dos contactos con el mismo celular y devuelve cuántas alertas creó" do
      pipeline = create(:pipeline_with_stages, tenant: tenant)
      2.times do
        c = create(:contact, tenant: tenant, phone_e164: "+573005556677")
        create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: c, pipeline: pipeline,
                                                pipeline_stage: pipeline.pipeline_stages.first)
      end

      post "/api/v1/duplicate_flags/scan", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json["created"]).to eq(1)
    end
  end

  describe "POST /api/v1/duplicate_flags/:id/merge con contactos distintos" do
    it "fusiona oportunidades y deja un solo contacto con los orígenes de ambos" do
      existing_contact = create(:contact, tenant: tenant, first_name: "Ana", phone_e164: "+573003334455", email: nil,
                                          source_kind: "import", source_label: "Excel: base.xlsx")
      new_contact = create(:contact, tenant: tenant, first_name: "Ana R", phone_e164: "+573003334455",
                                     email: "ana@correo.co", source_kind: "web", source_label: "Landing")
      existing = create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: existing_contact, pipeline: pipeline,
                                                         pipeline_stage: pipeline.pipeline_stages.first)
      duplicate = create(:opportunity, :skip_bant_recalc, tenant: tenant, contact: new_contact, pipeline: pipeline,
                                                          pipeline_stage: pipeline.pipeline_stages.first)
      f = create(:duplicate_flag, tenant: tenant, opportunity: duplicate, duplicate_of_opportunity: existing)

      post "/api/v1/duplicate_flags/#{f.id}/merge", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(new_contact.reload).to be_discarded
      expect(existing_contact.reload.email).to eq("ana@correo.co")
      expect(existing_contact.origins.map { |o| o["kind"] }).to contain_exactly("import", "web")
      expect(duplicate.reload.contact_id).to eq(existing_contact.id)
      expect(f.reload.resolution).to eq("merged")
    end
  end
end
