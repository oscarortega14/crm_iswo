# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Integrations::BlogSubscribers", type: :request do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:secret) { "test-integration-secret" }

  around do |example|
    original = ENV["BLOG_INTEGRATION_SECRET"]
    example.run
  ensure
    ENV["BLOG_INTEGRATION_SECRET"] = original
    ENV.delete("BLOG_INTEGRATION_SECRET") if original.nil?
  end

  def headers_with_secret(value)
    tenant_headers(tenant).merge("X-Integration-Secret" => value)
  end

  describe "POST /api/v1/integrations/blog_subscribers" do
    let(:body) { { name: "Camila Rios", email: "camila@example.com" }.to_json }

    it "401 si BLOG_INTEGRATION_SECRET no está configurado" do
      ENV.delete("BLOG_INTEGRATION_SECRET")

      post "/api/v1/integrations/blog_subscribers", params: body, headers: headers_with_secret("cualquiera")

      expect(response).to have_http_status(:unauthorized)
    end

    it "401 si el secreto no coincide" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret

      expect {
        post "/api/v1/integrations/blog_subscribers", params: body, headers: headers_with_secret("incorrecto")
      }.not_to change(Contact, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "201 con secreto correcto; crea Contact con source_kind blog" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret

      expect {
        post "/api/v1/integrations/blog_subscribers", params: body, headers: headers_with_secret(secret)
      }.to change(Contact, :count).by(1)

      expect(response).to have_http_status(:created)

      contact = Contact.order(:created_at).last
      expect(contact.first_name).to eq("Camila")
      expect(contact.last_name).to eq("Rios")
      expect(contact.email).to eq("camila@example.com")
      expect(contact.source_kind).to eq("blog")
      expect(contact.kind_person?).to be true
    end

    it "200 e idempotente si el email ya existe (no duplica)" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret
      create(:contact, tenant: tenant, email: "camila@example.com", first_name: "Cam")

      expect {
        post "/api/v1/integrations/blog_subscribers", params: body, headers: headers_with_secret(secret)
      }.not_to change(Contact, :count)

      expect(response).to have_http_status(:ok)
    end

    it "no pisa el nombre de un Contact existente que ya tenía uno cargado" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret
      create(:contact, tenant: tenant, email: "camila@example.com", first_name: "Cam", last_name: "R.")

      post "/api/v1/integrations/blog_subscribers", params: body, headers: headers_with_secret(secret)

      contact = Contact.find_by(email: "camila@example.com")
      expect(contact.first_name).to eq("Cam")
      expect(contact.last_name).to eq("R.")
    end

    it "completa el nombre si el Contact existente no tenía ninguno" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret
      # El modelo exige nombre o razón social (name_or_company_present) en el flujo normal;
      # se fuerza este estado (legado/import) para probar la rama defensiva de "sin nombre".
      contact = build(:contact, tenant: tenant, email: "camila@example.com", first_name: nil, last_name: nil,
                                 company_name: nil)
      contact.save(validate: false)

      post "/api/v1/integrations/blog_subscribers", params: body, headers: headers_with_secret(secret)

      contact.reload
      expect(contact.first_name).to eq("Camila")
      expect(contact.last_name).to eq("Rios")
    end

    it "400 si no resuelve tenant (sin X-Tenant-Slug)" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret

      post "/api/v1/integrations/blog_subscribers",
           params: body,
           headers: { "Content-Type" => "application/json", "X-Integration-Secret" => secret }

      expect(response).to have_http_status(:bad_request)
    end

    it "401 (no 400) con secreto incorrecto aunque el X-Tenant-Slug no exista — no filtra qué slugs son válidos" do
      ENV["BLOG_INTEGRATION_SECRET"] = secret

      post "/api/v1/integrations/blog_subscribers",
           params: body,
           headers: {
             "Content-Type" => "application/json",
             "X-Integration-Secret" => "incorrecto",
             "X-Tenant-Slug" => "slug-que-no-existe"
           }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
