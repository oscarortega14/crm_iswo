# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Contacts", type: :request do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:manager) { create(:user, :manager, tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }

  describe "autenticación y tenant" do
    it "401 si no hay JWT" do
      get "/api/v1/contacts", headers: tenant_headers(tenant)
      expect(response).to have_http_status(:unauthorized)
    end

    it "400 si no resuelve tenant" do
      get "/api/v1/contacts", headers: { "Authorization" => "Bearer #{jwt_for(manager)}" }
      expect(response).to have_http_status(:bad_request)
      expect(json["error"]).to eq("tenant_missing")
    end

    it "403 si el JWT corresponde a otro tenant (tenant_mismatch)", :without_tenant do
      home_tenant = create(:tenant, slug: "home")
      other_tenant = create(:tenant, slug: "other")
      user = ActsAsTenant.with_tenant(home_tenant) { create(:user, :manager, tenant: home_tenant) }

      get "/api/v1/contacts",
          headers: {
            "Authorization" => "Bearer #{jwt_for(user)}",
            "X-Tenant-Slug" => other_tenant.slug
          }
      expect(response).to have_http_status(:forbidden)
      expect(json["error"]).to eq("tenant_mismatch")
    end
  end

  describe "GET /api/v1/contacts/stats" do
    let!(:won_contact) do
      c = create(:contact, tenant: tenant, owner_user: manager, first_name: "Cliente")
      pipe = create(:pipeline_with_stages, tenant: tenant)
      won_stage = pipe.pipeline_stages.find_by(closed_won: true)
      create(:opportunity, tenant: tenant, contact: c, owner_user: manager,
             pipeline: pipe, pipeline_stage: won_stage, status: "won")
      c
    end

    let!(:prospect_contact) do
      c = create(:contact, tenant: tenant, owner_user: manager, first_name: "Prospecto")
      pipe = create(:pipeline_with_stages, tenant: tenant)
      create(:opportunity, tenant: tenant, contact: c, owner_user: manager,
             pipeline: pipe, pipeline_stage: pipe.pipeline_stages.first, status: "new_lead")
      c
    end

    it "devuelve conteos por segmento" do
      get "/api/v1/contacts/stats", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "clients")).to be >= 1
      expect(json.dig("data", "prospects")).to be >= 1
      expect(json).to include("data" => hash_including("hot_leads", "stale", "stale_days"))
    end
  end

  describe "GET /api/v1/contacts" do
    let!(:contact_a) { create(:contact, tenant: tenant, first_name: "Ana") }
    let!(:contact_b) { create(:contact, tenant: tenant, first_name: "Beto") }

    it "200 con lista paginada JSON:API" do
      get "/api/v1/contacts", headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to match_array([contact_a.id, contact_b.id])
      expect(json.dig("meta", "pagination")).to include("page", "pages", "count")
    end

    it "filtra por ?q=" do
      get "/api/v1/contacts?q=Ana", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to eq([contact_a.id])
    end

    it "filtra por kind=company" do
      company = create(:contact, :company, tenant: tenant)
      get "/api/v1/contacts?kind=company", headers: auth_headers(manager)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(company.id)
      expect(ids).not_to include(contact_a.id, contact_b.id)
    end

    it "filtra por segment=clients (contactos con opp ganada)" do
      pipe = create(:pipeline_with_stages, tenant: tenant)
      won_stage = pipe.pipeline_stages.find_by(closed_won: true)
      client = create(:contact, tenant: tenant, owner_user: manager, first_name: "SoloCliente")
      create(:opportunity, tenant: tenant, contact: client, owner_user: manager,
             pipeline: pipe, pipeline_stage: won_stage, status: "won")
      bare = create(:contact, tenant: tenant, first_name: "SinOpp")

      get "/api/v1/contacts?segment=clients", headers: auth_headers(manager)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(client.id)
      expect(ids).not_to include(bare.id)
    end

    it "consultant ve sus contactos y los sin dueño (bandeja sin asignar), no los de otro consultor" do
      own = create(:contact, tenant: tenant, owner_user: consultant)
      other_owner = create(:user, :consultant, tenant: tenant)
      foreign = create(:contact, tenant: tenant, owner_user: other_owner)

      get "/api/v1/contacts", headers: auth_headers(consultant)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(own.id, contact_a.id, contact_b.id) # contact_a/b sin owner_user (RFC §6.6, bandeja compartida)
      expect(ids).not_to include(foreign.id)
    end

    it "expone can_edit según ContactPolicy#update?" do
      pipe = create(:pipeline_with_stages, tenant: tenant)
      shared = create(:contact, tenant: tenant, owner_user: manager)
      create(:opportunity, tenant: tenant, contact: shared, owner_user: consultant,
             pipeline: pipe, pipeline_stage: pipe.pipeline_stages.first)
      other_owner = create(:user, :consultant, tenant: tenant)
      foreign = create(:contact, tenant: tenant, owner_user: other_owner)

      get "/api/v1/contacts", headers: auth_headers(consultant)
      row = json["data"].find { |d| d["id"].to_i == shared.id }
      expect(row.dig("attributes", "can_edit")).to be(true)

      # Sin dueño: visible (bandeja compartida) pero no editable hasta reclamarlo.
      unassigned_row = json["data"].find { |d| d["id"].to_i == contact_a.id }
      expect(unassigned_row.dig("attributes", "can_edit")).to be(false)

      foreign_row = json["data"].find { |d| d["id"].to_i == foreign.id }
      expect(foreign_row).to be_nil
    end
  end

  describe "POST /api/v1/contacts" do
    it "201 y crea con owner=current_user y oportunidad prospecto en pipeline" do
      pipe = create(:pipeline_with_stages, tenant: tenant, is_default: true)
      create(:lead_source, tenant: tenant, kind: "manual")
      payload = { contact: { kind: "person", first_name: "Nuevo", last_name: "Prospect", email: "np@iswo.co" } }.to_json

      expect {
        post "/api/v1/contacts", params: payload, headers: auth_headers(consultant)
      }.to change(Contact, :count).by(1)
        .and change(Opportunity, :count).by(1)

      expect(response).to have_http_status(:created)
      created = Contact.last
      expect(created.owner_user_id).to eq(consultant.id)
      expect(json.dig("data", "attributes", "first_name")).to eq("Nuevo")

      opp = Opportunity.order(:id).last
      expect(opp.contact_id).to eq(created.id)
      expect(opp.owner_user_id).to eq(consultant.id)
      expect(opp.pipeline_id).to eq(pipe.id)
      expect(opp.status).to eq("new_lead")

      get "/api/v1/opportunities", headers: auth_headers(manager)
      opp_ids = json["data"].map { |d| d["id"].to_i }
      expect(opp_ids).to include(opp.id)
    end

    it "422 con detalles de validación si falta nombre y company" do
      payload = { contact: { kind: "person" } }.to_json
      post "/api/v1/contacts", params: payload, headers: auth_headers(manager)

      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("unprocessable_entity")
      expect(json["details"]).to be_present
    end
  end

  describe "PATCH /api/v1/contacts/:id" do
    let(:other_consultant) { create(:user, :consultant, tenant: tenant) }
    let!(:contact) { create(:contact, tenant: tenant, owner_user: other_consultant) }

    it "manager puede actualizar cualquier contacto" do
      patch "/api/v1/contacts/#{contact.id}",
            params: { contact: { first_name: "Editado" } }.to_json,
            headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      expect(contact.reload.first_name).to eq("Editado")
    end

    it "consultant ajeno no encuentra el contacto (404 vía policy_scope)" do
      patch "/api/v1/contacts/#{contact.id}",
            params: { contact: { first_name: "Hackeado" } }.to_json,
            headers: auth_headers(consultant)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/contacts/:id/claim" do
    let(:admin) { create(:user, :admin, tenant: tenant) }

    it "consultant reclama un contacto sin dueño (bandeja sin asignar)" do
      unowned = create(:contact, tenant: tenant)
      post "/api/v1/contacts/#{unowned.id}/claim", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
      expect(unowned.reload.owner_user_id).to eq(consultant.id)
    end

    it "404 si el contacto ya tiene dueño (invisible vía policy_scope para otro consultor)" do
      taken = create(:contact, tenant: tenant, owner_user: manager)
      post "/api/v1/contacts/#{taken.id}/claim", headers: auth_headers(consultant)
      expect(response).to have_http_status(:not_found)
      expect(taken.reload.owner_user_id).to eq(manager.id)
    end

    it "403 si un admin intenta reclamar un contacto que ya tiene dueño" do
      taken = create(:contact, tenant: tenant, owner_user: manager)
      post "/api/v1/contacts/#{taken.id}/claim", headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)
      expect(taken.reload.owner_user_id).to eq(manager.id)
    end
  end

  describe "DELETE /api/v1/contacts/:id" do
    let!(:contact) { create(:contact, tenant: tenant) }

    it "admin hace soft-delete (discard) y responde 204" do
      admin = create(:user, :admin, tenant: tenant)
      delete "/api/v1/contacts/#{contact.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:no_content)
      expect(contact.reload.discarded?).to be(true)
    end

    it "manager no puede destruir (403)" do
      delete "/api/v1/contacts/#{contact.id}", headers: auth_headers(manager)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/contacts/import_template" do
    it "devuelve plantilla Excel .xlsx (200)" do
      get "/api/v1/contacts/import_template", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("spreadsheet")
      expect(response.headers["Content-Disposition"]).to include("plantilla_contactos.xlsx")
      expect(response.body.bytesize).to be_positive
    end

    it "consultant puede descargar plantilla (create)" do
      get "/api/v1/contacts/import_template", headers: auth_headers(consultant)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/contacts/import" do
    def csv_upload(email_local = nil)
      suffix = email_local || SecureRandom.hex(4)
      body = <<~CSV
        first_name,last_name,email,country
        Import,Test,import_test_#{suffix}@example.com,CO
      CSV
      tempfile = Tempfile.new(["contacts", ".csv"])
      tempfile.write(body)
      tempfile.rewind
      Rack::Test::UploadedFile.new(tempfile.path, "text/csv")
    end

    it "crea contactos desde CSV (200)" do
      post "/api/v1/contacts/import",
           params: { file: csv_upload },
           headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "created_count")).to eq(1)
      expect(json.dig("data", "errors")).to eq([])
    end

    it "crea contactos desde Excel .xlsx (200)" do
      require "caxlsx"

      tempfile = nil
      suffix = SecureRandom.hex(4)
      package = Axlsx::Package.new
      package.workbook.add_worksheet(name: "Contactos") do |sheet|
        sheet.add_row %w[first_name last_name email country]
        sheet.add_row ["Import", "Test", "import_xlsx_#{suffix}@example.com", "CO"]
      end
      tempfile = Tempfile.new(["contacts", ".xlsx"], binmode: true)
      package.serialize(tempfile.path)
      tempfile.rewind
      upload = Rack::Test::UploadedFile.new(
        tempfile.path,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )

      post "/api/v1/contacts/import",
           params: { file: upload },
           headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "created_count")).to eq(1)
      expect(json.dig("data", "errors")).to eq([])
    ensure
      tempfile&.close!
    end

    it "viewer no puede importar (403)" do
      viewer = create(:user, :viewer, tenant: tenant)
      post "/api/v1/contacts/import",
           params: { file: csv_upload },
           headers: auth_headers(viewer)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/contacts/export" do
    it "manager encola ExportGenerationJob y devuelve 202" do
      expect(ExportGenerationJob).to receive(:perform_later)

      post "/api/v1/contacts/export",
           params: { export_format: "xlsx" }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:accepted)
      expect(json.dig("data", "attributes", "format")).to eq("xlsx")
    end

    it "acepta filters como objeto JSON (sin error 500)" do
      expect(ExportGenerationJob).to receive(:perform_later)

      post "/api/v1/contacts/export",
           params: { export_format: "xlsx", filters: { kind_eq: "person" } }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:accepted)
      expect(json.dig("data", "attributes", "format")).to eq("xlsx")
      expect(json.dig("data", "attributes", "filters")).to include("kind_eq" => "person")
    end

    it "usa xlsx por defecto si no se envía export_format (API default format=json no rompe el enum)" do
      expect(ExportGenerationJob).to receive(:perform_later)

      post "/api/v1/contacts/export",
           params: { filters: {} }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:accepted)
      expect(json.dig("data", "attributes", "format")).to eq("xlsx")
    end

    it "consultant no puede exportar (403)" do
      post "/api/v1/contacts/export",
           params: { export_format: "xlsx" }.to_json,
           headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/contacts/export.csv (RFC §6.7)" do
    let!(:contact_row) { create(:contact, tenant: tenant) }

    it "manager descarga CSV directamente" do
      get "/api/v1/contacts/export.csv", headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.body).to include("email").or include(contact_row.email.to_s)
      expect(AuditEvent.where(action: "export", tenant: tenant).count).to be >= 1
    end

    it "consultant no puede descargar (403)" do
      get "/api/v1/contacts/export.csv", headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/contacts/backfill_whatsapp_opt_in" do
    let(:admin) { create(:user, :admin, tenant: tenant) }

    it "dry_run cuenta sin persistir" do
      wrote_first = create(:contact, tenant: tenant)
      create(:whatsapp_message, :inbound, :openwa, tenant: tenant, contact: wrote_first)
      # El create dispara el opt-in automático; lo revertimos para simular
      # contactos que escribieron ANTES de que existiera ese callback.
      wrote_first.update_column(:whatsapp_opt_in_at, nil)

      post "/api/v1/contacts/backfill_whatsapp_opt_in?dry_run=true", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "count")).to eq(1)
      expect(wrote_first.reload.whatsapp_opted_in?).to be(false)
    end

    it "marca opt-in a quien ya escribió y no toca a quien nunca escribió" do
      wrote = create(:contact, tenant: tenant)
      create(:whatsapp_message, :inbound, :openwa, tenant: tenant, contact: wrote)
      wrote.update_column(:whatsapp_opt_in_at, nil)
      never_wrote = create(:contact, tenant: tenant)

      post "/api/v1/contacts/backfill_whatsapp_opt_in", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "count")).to eq(1)
      expect(wrote.reload.whatsapp_opted_in?).to be(true)
      expect(wrote.whatsapp_opt_in_source).to eq("reply_stop_in")
      expect(never_wrote.reload.whatsapp_opted_in?).to be(false)
    end

    it "manager no puede (403, solo admin)" do
      post "/api/v1/contacts/backfill_whatsapp_opt_in", headers: auth_headers(manager)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/contacts/bulk_whatsapp_opt_in" do
    let(:admin) { create(:user, :admin, tenant: tenant) }

    it "admin marca opt-in manual a los ids dados" do
      c1 = create(:contact, tenant: tenant)
      c2 = create(:contact, tenant: tenant)
      untouched = create(:contact, tenant: tenant)

      post "/api/v1/contacts/bulk_whatsapp_opt_in",
           params: { ids: [c1.id, c2.id] }.to_json,
           headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "marked")).to eq(2)
      expect(c1.reload.whatsapp_opted_in?).to be(true)
      expect(c1.whatsapp_opt_in_source).to eq("manual")
      expect(c2.reload.whatsapp_opted_in?).to be(true)
      expect(untouched.reload.whatsapp_opted_in?).to be(false)
    end

    it "no recuenta ni sobreescribe contactos ya opt-in" do
      already = create(:contact, tenant: tenant)
      already.mark_whatsapp_opt_in!(source: "reply_stop_in")

      post "/api/v1/contacts/bulk_whatsapp_opt_in",
           params: { ids: [already.id] }.to_json,
           headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "marked")).to eq(0)
      expect(already.reload.whatsapp_opt_in_source).to eq("reply_stop_in")
    end

    it "manager sí puede (a diferencia del backfill, que es solo admin)" do
      c1 = create(:contact, tenant: tenant)

      post "/api/v1/contacts/bulk_whatsapp_opt_in",
           params: { ids: [c1.id] }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:ok)
      expect(c1.reload.whatsapp_opted_in?).to be(true)
    end

    it "consultant no puede (403)" do
      c1 = create(:contact, tenant: tenant)

      post "/api/v1/contacts/bulk_whatsapp_opt_in",
           params: { ids: [c1.id] }.to_json,
           headers: auth_headers(consultant)

      expect(response).to have_http_status(:forbidden)
    end

    it "400 si no hay ids" do
      post "/api/v1/contacts/bulk_whatsapp_opt_in",
           params: { ids: [] }.to_json,
           headers: auth_headers(admin)

      expect(response).to have_http_status(:bad_request)
    end
  end
end
