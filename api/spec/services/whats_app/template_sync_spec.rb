# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsApp::TemplateSync do
  let(:tenant) { ActsAsTenant.current_tenant }

  describe "#call" do
    it "falla con mensaje claro si no hay WABA ID configurado" do
      create(:ad_integration, :cloud, tenant: tenant, credentials: { "access_token" => "tok" }, metadata: {})

      result = described_class.call(tenant: tenant)

      expect(result.success?).to be(false)
      expect(result.message).to include("WABA ID")
    end

    it "falla con mensaje claro si no hay integración whatsapp_cloud" do
      result = described_class.call(tenant: tenant)

      expect(result.success?).to be(false)
      expect(result.message).to include("WABA ID")
    end

    context "con WABA ID y token configurados" do
      let!(:integration) do
        create(:ad_integration, :cloud, tenant: tenant,
               credentials: { "access_token" => "tok" }, metadata: { "waba_id" => "999" })
      end

      it "actualiza category/meta_status/meta_template_id de una plantilla que ya existe" do
        local = create(:whatsapp_template, tenant: tenant, meta_template_name: "confirmacion_contacto",
                        language: "es_CO")

        stub_request(:get, %r{graph\.facebook\.com/v18\.0/999/message_templates})
          .to_return(
            status: 200,
            body: {
              data: [
                { id: "abc123", name: "confirmacion_contacto", language: "es_CO",
                  status: "APPROVED", category: "MARKETING" }
              ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = described_class.call(tenant: tenant)

        expect(result.success?).to be(true)
        expect(result.updated).to eq(
          [{ name: "confirmacion_contacto", language: "es_CO", status: "APPROVED", category: "MARKETING" }]
        )
        local.reload
        expect(local.category).to eq("MARKETING")
        expect(local.meta_status).to eq("APPROVED")
        expect(local.meta_template_id).to eq("abc123")
        expect(local.meta_synced_at).to be_present
      end

      it "no toca variable_labels/variable_names existentes" do
        local = create(:whatsapp_template, tenant: tenant, meta_template_name: "confirmacion_contacto",
                        language: "es_CO", variable_labels: ["Nombre del lead"], variable_names: [])

        stub_request(:get, %r{graph\.facebook\.com/v18\.0/999/message_templates})
          .to_return(
            status: 200,
            body: { data: [
              { id: "abc123", name: "confirmacion_contacto", language: "es_CO",
                status: "APPROVED", category: "MARKETING" }
            ] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        described_class.call(tenant: tenant)

        expect(local.reload.variable_labels).to eq(["Nombre del lead"])
      end

      it "reporta plantillas que están en Meta pero no registradas localmente" do
        stub_request(:get, %r{graph\.facebook\.com/v18\.0/999/message_templates})
          .to_return(
            status: 200,
            body: { data: [
              { id: "xyz", name: "nueva_no_registrada", language: "es_CO", status: "APPROVED", category: "UTILITY" }
            ] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = described_class.call(tenant: tenant)

        expect(result.updated).to eq([])
        expect(result.new_in_meta).to eq(
          [{ name: "nueva_no_registrada", language: "es_CO", status: "APPROVED" }]
        )
      end

      it "reporta plantillas locales que ya no aparecen en Meta" do
        create(:whatsapp_template, tenant: tenant, meta_template_name: "borrada_en_meta", language: "es_CO")

        stub_request(:get, %r{graph\.facebook\.com/v18\.0/999/message_templates})
          .to_return(status: 200, body: { data: [] }.to_json,
                     headers: { "Content-Type" => "application/json" })

        result = described_class.call(tenant: tenant)

        expect(result.missing_in_meta).to eq([{ name: "borrada_en_meta", language: "es_CO" }])
      end

      it "da un mensaje específico cuando Meta rechaza el token por falta de permiso (190)" do
        stub_request(:get, %r{graph\.facebook\.com/v18\.0/999/message_templates})
          .to_return(
            status: 401,
            body: { error: { message: "Invalid OAuth access token", code: 190 } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = described_class.call(tenant: tenant)

        expect(result.success?).to be(false)
        expect(result.message).to include("whatsapp_business_management")
      end
    end
  end
end
