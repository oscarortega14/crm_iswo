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

  describe "plantilla en español (Nombres, Apellidos, Celular, Email, Ciudad, País)" do
    # Columnas opcionales Ciudad/País/Etapa: siguen soportadas fuera de la plantilla base.
    let(:header) { "Nombres,Apellidos,Celular (con indicativo),Email,Ciudad,País,Etapa" }

    def import(rows)
      csv = ([ header ] + rows).join("\n") + "\n"
      described_class.new(tenant: tenant, user: user, io: csv_io(csv), filename: "plantilla.csv").call
    end

    def contact(email)
      ActsAsTenant.with_tenant(tenant) { Contact.find_by(email: email) }
    end

    it "carga nombres, apellidos, celular con indicativo, email, ciudad y país" do
      result = import([ "Laura,Gómez Pérez,+573001234567,laura@e.co,Bogotá,Colombia," ])

      expect(result.created_count).to eq(1)
      expect(result.warnings).to be_empty
      c = contact("laura@e.co")
      expect([ c.first_name, c.last_name, c.phone_e164, c.city, c.country ])
        .to eq([ "Laura", "Gómez Pérez", "+573001234567", "Bogotá", "CO" ])
    end

    it "acepta el celular sin «+» que deja Excel (573001234567) y con espacios" do
      import([ "Ana,Ruiz,573001112233,ana@e.co,Cali,Colombia,", "Beto,Paz,+52 55 1234 5678,beto@e.co,CDMX,México," ])

      expect(contact("ana@e.co").phone_e164).to eq("+573001112233")
      expect(contact("beto@e.co")).to have_attributes(phone_e164: "+525512345678", country: "MX")
    end

    it "sin País toma el país del indicativo del celular" do
      import([ "Carla,Díaz,+51987654321,carla@e.co,Lima,," ])
      expect(contact("carla@e.co").country).to eq("PE")
    end

    it "acepta códigos de país de 2 letras" do
      import([ "Dani,Ruiz,+593991234567,dani@e.co,Quito,ec," ])
      expect(contact("dani@e.co").country).to eq("EC")
    end

    it "avisa por fila si el celular, el email o el país no son válidos (e importa igual)" do
      result = import([ "Eva,Mora,12345,correo-malo,Bogotá,Narnia," ])

      expect(result.created_count).to eq(1)
      messages = result.warnings.map { |w| w[:message] }
      expect(messages).to include(a_string_matching(/celular «12345» no es válido/))
      expect(messages).to include(a_string_matching(/email «correo-malo» no es válido/))
      expect(messages).to include(a_string_matching(/país «Narnia» no reconocido; se usó CO/))
      expect(result.warnings.map { |w| w[:row] }.uniq).to eq([ 2 ])
    end
  end

  describe "plantilla: Nombres, Apellidos, Cédula o NIT, Celular, Correo, Origen del lead" do
    def import(rows)
      csv = ([ described_class::TEMPLATE_HEADERS.join(",") ] + rows).join("\n") + "\n"
      described_class.new(tenant: tenant, user: user, io: csv_io(csv), filename: "base.csv").call
    end

    def contact(email)
      ActsAsTenant.with_tenant(tenant) { Contact.find_by(email: email) }
    end

    it "con cédula crea persona natural y guarda el documento limpio" do
      result = import([ "Laura,Gómez Pérez,CC 1.020.304.050,+573001234567,laura@e.co,Feria ISO" ])
      expect(result.errors).to be_empty
      expect(contact("laura@e.co")).to have_attributes(kind: "person", first_name: "Laura", last_name: "Gómez Pérez",
                                                       document_id: "1020304050", phone_e164: "+573001234567")
    end

    it "con NIT crea empresa y usa «Nombres» como razón social" do
      import([ "Constructora Andina S.A.S.,,900123456-7,+576014567890,compras@andina.co,Referido" ])
      c = contact("compras@andina.co")
      expect(c).to have_attributes(kind: "company", company_name: "Constructora Andina S.A.S.",
                                   first_name: nil, document_id: "900123456-7")
    end

    it "el origen se asigna como fuente del lead de la oportunidad (existente o nueva)" do
      pipeline = create(:pipeline, tenant: tenant, is_default: true)
      create(:pipeline_stage, tenant: tenant, pipeline: pipeline, name: "Nueva", position: 0)
      existing = ActsAsTenant.with_tenant(tenant) { create(:lead_source, tenant: tenant, name: "Feria ISO", kind: "manual") }
      import([ "Ana,Ruiz,1020304050,,ana@e.co,feria iso", "Beto,Paz,79123456,,beto@e.co,Facebook campaña septiembre" ])

      ActsAsTenant.with_tenant(tenant) do
        expect(contact("ana@e.co").opportunities.first.lead_source).to eq(existing)
        created = contact("beto@e.co").opportunities.first.lead_source
        expect(created).to have_attributes(name: "Facebook campaña septiembre", kind: "meta")
        expect(contact("beto@e.co").origins.map { |o| o["label"] }).to include("Facebook campaña septiembre")
      end
    end
  end
end
