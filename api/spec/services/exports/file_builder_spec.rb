# frozen_string_literal: true

require "rails_helper"

RSpec.describe Exports::FileBuilder do
  let(:tenant)  { ActsAsTenant.current_tenant }
  let(:contact) { create(:contact, tenant: tenant, first_name: "Ana", last_name: "Torres") }
  let(:scope)   { ActsAsTenant.with_tenant(tenant) { Contact.where(id: contact.id) } }

  after do
    Dir[Rails.root.join("tmp", "exports", "sync", "*.{csv,xlsx}")].each { |f| File.delete(f) if File.exist?(f) }
  end

  describe ".build (CSV)" do
    it "genera un archivo CSV con la fila del contacto" do
      result = described_class.build(scope: scope, resource: "contacts", format: "csv")
      expect(File.exist?(result.path)).to be(true)
      expect(result.row_count).to eq(1)
      expect(result.filename).to end_with(".csv")
      content = File.read(result.path)
      expect(content).to include("Ana")
    end

    it "genera CSV vacío (solo cabeceras) si el scope está vacío" do
      result = described_class.build(scope: Contact.none, resource: "contacts", format: "csv")
      expect(result.row_count).to eq(0)
      expect(File.exist?(result.path)).to be(true)
    end
  end

  describe ".build (XLSX)" do
    it "genera un archivo XLSX" do
      result = described_class.build(scope: scope, resource: "contacts", format: "xlsx")
      expect(File.exist?(result.path)).to be(true)
      expect(result.row_count).to eq(1)
      expect(result.filename).to end_with(".xlsx")
    end
  end

  describe "formato inválido" do
    it "lanza ArgumentError" do
      expect {
        described_class.build(scope: scope, resource: "contacts", format: "pdf")
      }.to raise_error(ArgumentError, /Formato no soportado/)
    end
  end

  describe "columnas legibles con origen del lead" do
    it "contactos: cabeceras en español, documento y celular legibles, origen desde la fuente del lead" do
      ActsAsTenant.with_tenant(tenant) do
        source = create(:lead_source, tenant: tenant, name: "Feria ISO", kind: "manual")
        company = create(:contact, tenant: tenant, kind: "company", company_name: "Andina S.A.S.",
                                   document_id: "900123456-7", phone_e164: "+576014567890", email: "c@andina.co")
        create(:opportunity, tenant: tenant, contact: company, lead_source: source)

        result = described_class.build(scope: Contact.where(id: company.id), resource: "contacts", format: "csv")
        rows = CSV.parse(File.read(result.path).delete_prefix("\uFEFF"), headers: true)

        expect(rows.headers.first(7)).to eq(
          [ "Nombres", "Apellidos", "Tipo", "Cédula o NIT", "Celular", "Correo", "Origen del lead" ]
        )
        expect(rows.headers.join).not_to match(/ciphertext|bidx|tenant_id/)
        expect(rows.first.to_h).to include("Tipo" => "Empresa", "Cédula o NIT" => "900123456-7",
                                           "Celular" => "+576014567890", "Origen del lead" => "Feria ISO")
      end
    end

    it "oportunidades: incluye el origen del lead y la etapa" do
      ActsAsTenant.with_tenant(tenant) do
        source = create(:lead_source, tenant: tenant, name: "Landing ISO 9001", kind: "web")
        opp = create(:opportunity, tenant: tenant, contact: contact, lead_source: source)

        result = described_class.build(scope: Opportunity.where(id: opp.id), resource: "opportunities", format: "csv")
        row = CSV.parse(File.read(result.path).delete_prefix("\uFEFF"), headers: true).first

        expect(row["Origen del lead"]).to eq("Landing ISO 9001")
        expect(row["Tipo"]).to eq("Persona natural")
        expect(row["Etapa"]).to eq(opp.pipeline_stage.name)
      end
    end
  end
end
