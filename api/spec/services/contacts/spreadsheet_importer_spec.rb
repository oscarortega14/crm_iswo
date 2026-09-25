# frozen_string_literal: true

require "rails_helper"
require "csv"
require "tempfile"

RSpec.describe Contacts::SpreadsheetImporter do
  let(:tenant) { ActsAsTenant.current_tenant }
  let(:user)   { create(:user, :admin, tenant: tenant) }

  def csv_io(content)
    tf = Tempfile.new(["import", ".csv"])
    tf.write(content)
    tf.rewind
    tf
  end

  describe "#call con CSV" do
    let(:csv_content) do
      "first_name,last_name,email,phone\nAna,Torres,ana@test.co,3001234567\nBeto,López,beto@test.co,3119876543\n"
    end

    it "crea contactos a partir de filas válidas" do
      io = csv_io(csv_content)
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "import.csv").call
      expect(result.created_count).to eq(2)
      expect(result.errors).to be_empty
    end

    it "devuelve error si el archivo supera MAX_ROWS" do
      giant = "first_name,email\n" + (1..2001).map { |i| "Name#{i},u#{i}@t.co" }.join("\n")
      io = csv_io(giant)
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "big.csv").call
      expect(result.errors.first[:message]).to match(/Máximo/)
    end

    it "omite filas completamente en blanco" do
      io = csv_io("first_name,email\n\nAna,ana@t.co\n")
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "blank.csv").call
      expect(result.created_count).to eq(1)
      expect(result.skipped_count).to eq(1)
    end

    it "devuelve error para formato no admitido" do
      io = StringIO.new("datos")
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "file.pdf").call
      expect(result.errors.first[:message]).to match(/Formato no admitido/)
    end

    it "normaliza cabeceras en español" do
      es_csv = "nombre,apellido,correo\nPedro,Ruiz,pedro@t.co\n"
      io = csv_io(es_csv)
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "es.csv").call
      expect(result.created_count).to eq(1)
      contact = ActsAsTenant.with_tenant(tenant) { Contact.last }
      expect(contact.first_name).to eq("Pedro")
    end

    it "infiere kind=company si no hay nombre pero sí empresa" do
      io = csv_io("company,email\nAcme Corp,info@acme.co\n")
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "co.csv").call
      expect(result.created_count).to eq(1)
      contact = ActsAsTenant.with_tenant(tenant) { Contact.last }
      expect(contact.kind).to eq("company")
    end

    it "parte full_name en first_name + last_name" do
      io = csv_io("full_name,email\nJuan Pérez,juan@t.co\n")
      result = described_class.new(tenant: tenant, user: user, io: io, filename: "fn.csv").call
      contact = ActsAsTenant.with_tenant(tenant) { Contact.last }
      expect(contact.first_name).to eq("Juan")
      expect(contact.last_name).to eq("Pérez")
    end
  end

  describe "columna de etapa (stage / etapa / estado / fase)" do
    let!(:pipeline) do
      ActsAsTenant.with_tenant(tenant) do
        tenant.pipelines.update_all(is_default: false)
        create(:pipeline, tenant: tenant, name: "Ventas", is_default: true)
      end
    end
    let!(:nueva)     { create(:pipeline_stage, tenant: tenant, pipeline: pipeline, name: "Nueva", position: 0) }
    let!(:propuesta) { create(:pipeline_stage, tenant: tenant, pipeline: pipeline, name: "Propuesta Enviada", position: 1) }
    let!(:ganada)    { create(:pipeline_stage, :won, tenant: tenant, pipeline: pipeline, name: "Ganada", position: 2) }

    def import(csv)
      described_class.new(tenant: tenant, user: user, io: csv_io(csv), filename: "etapas.csv").call
    end

    def opp_for(email)
      ActsAsTenant.with_tenant(tenant) { Contact.find_by(email: email).opportunities.first }
    end

    it "ubica cada oportunidad en su etapa sin distinguir mayúsculas ni tildes" do
      result = import("nombre,correo,etapa\nAna,ana@e.co,propuesta enviada\nBeto,beto@e.co,NUEVA\n")

      expect(result.created_count).to eq(2)
      expect(result.warnings).to be_empty
      expect(opp_for("ana@e.co").pipeline_stage).to eq(propuesta)
      expect(opp_for("beto@e.co").pipeline_stage).to eq(nueva)
    end

    it "etapa vacía → primera etapa, sin aviso" do
      result = import("nombre,correo,etapa\nAna,ana@e.co,\n")
      expect(result.warnings).to be_empty
      expect(opp_for("ana@e.co").pipeline_stage).to eq(nueva)
    end

    it "etapa desconocida → importa en la primera etapa y avisa con la fila" do
      result = import("nombre,correo,stage\nAna,ana@e.co,Cotizado\n")

      expect(result.created_count).to eq(1)
      expect(result.errors).to be_empty
      expect(result.warnings).to contain_exactly(
        { row: 2, message: "etapa «Cotizado» no existe en «Ventas»; quedó en «Nueva»" }
      )
      expect(opp_for("ana@e.co").pipeline_stage).to eq(nueva)
    end

    it "etapa de cierre ganado sincroniza status won" do
      import("nombre,correo,estado\nAna,ana@e.co,Ganada\n")
      opp = opp_for("ana@e.co")
      expect(opp.pipeline_stage).to eq(ganada)
      expect(opp.status).to eq("won")
    end

    it "registra la etapa de importación en el log de creación" do
      import("nombre,correo,fase\nAna,ana@e.co,Propuesta Enviada\n")
      log = opp_for("ana@e.co").opportunity_logs.find_by(action: "create")
      expect(log.changes_data).to include("origin" => "contact_import", "stage" => "Propuesta Enviada")
    end
  end
end
