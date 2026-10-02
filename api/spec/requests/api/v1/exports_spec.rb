# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Exports", type: :request do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:manager) { create(:user, :manager, tenant: tenant) }

  describe "POST /api/v1/exports" do
    it "202 y normaliza export_format inválido a xlsx (evita ArgumentError del enum)" do
      expect(ExportGenerationJob).to receive(:perform_later)

      post "/api/v1/exports",
           params: { resource: "contacts", export_format: "json", filters: {} }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:accepted)
      expect(json.dig("data", "attributes", "format")).to eq("xlsx")
    end

    it "acepta filters como Hash JSON sin permit!" do
      expect(ExportGenerationJob).to receive(:perform_later)

      post "/api/v1/exports",
           params: {
             resource: "contacts",
             export_format: "csv",
             filters: { kind_eq: "person" }
           }.to_json,
           headers: auth_headers(manager)

      expect(response).to have_http_status(:accepted)
      expect(json.dig("data", "attributes", "format")).to eq("csv")
      expect(json.dig("data", "attributes", "filters")).to include("kind_eq" => "person")
    end
  end

  describe "GET /api/v1/exports" do
    let!(:failed_export) do
      create(:export, tenant: tenant, user: manager, resource: "contacts", format: "csv",
             status: "failed", error_message: "LOCKBOX test")
    end

    it "lista exportaciones fallidas (no expiradas)" do
      get "/api/v1/exports", headers: auth_headers(manager)
      expect(response).to have_http_status(:ok)
      ids = json["data"].map { |d| d["id"].to_i }
      expect(ids).to include(failed_export.id)
    end

    it "consultant no puede listar exportaciones (403)" do
      consultant = create(:user, :consultant, tenant: tenant)
      get "/api/v1/exports", headers: auth_headers(consultant)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/exports/:id/download" do
    let!(:ready_export) do
      create(:export, :ready, tenant: tenant, user: manager, resource: "contacts", format: "xlsx")
    end

    it "registra AuditEvent action=export_download al descargar (ISO A.7.10)" do
      expect {
        get "/api/v1/exports/#{ready_export.id}/download", headers: auth_headers(manager)
      }.to change(AuditEvent, :count).by(1)

      expect(response).to have_http_status(:found) # redirect al file_url https://

      event = AuditEvent.last
      expect(event.action).to      eq("export_download")
      expect(event.entity_type).to eq("Contact")
      expect(event.entity_id).to   eq(ready_export.id)
    end

    it "consultant no puede descargar (404 vía policy_scope) y no audita" do
      consultant = create(:user, :consultant, tenant: tenant)

      expect {
        get "/api/v1/exports/#{ready_export.id}/download", headers: auth_headers(consultant)
      }.not_to change(AuditEvent, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "422 sin auditar si el export aún no está listo" do
      pending_export = create(:export, tenant: tenant, user: manager, status: "queued")

      expect {
        get "/api/v1/exports/#{pending_export.id}/download", headers: auth_headers(manager)
      }.not_to change(AuditEvent, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
