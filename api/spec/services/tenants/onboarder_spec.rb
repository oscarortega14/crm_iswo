# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tenants::Onboarder do
  let(:slug)  { "onboard-test-#{SecureRandom.hex(4)}" }

  subject(:onboarder) do
    described_class.new(
      slug:           slug,
      name:           "Tenant Onboard Test",
      admin_email:    "admin@#{slug}.co",
      admin_name:     "Admin Test",
      admin_password: "SecurePass123!"
    )
  end

  describe "#call" do
    it "crea el tenant, usuario admin y pipeline por defecto" do
      result = onboarder.call

      expect(result.tenant).to be_a(Tenant)
      expect(result.tenant.slug).to eq(slug)
      expect(result.admin_user.role).to eq("admin")
      expect(result.pipeline).to be_a(Pipeline)
      expect(result.pipeline.is_default).to be(true)
    end

    it "crea las 6 etapas por defecto en el pipeline" do
      result = onboarder.call
      stage_count = ActsAsTenant.with_tenant(result.tenant) { result.pipeline.pipeline_stages.count }
      names       = ActsAsTenant.with_tenant(result.tenant) { result.pipeline.pipeline_stages.pluck(:name) }
      expect(stage_count).to eq(6)
      expect(names).to include("Nueva", "Calificada", "Ganada", "Perdida")
    end

    it "siembra reglas de auto-avance (Contactada ← WhatsApp enviado, Calificada ← BANT)" do
      result = onboarder.call
      triggers = ActsAsTenant.with_tenant(result.tenant) do
        result.pipeline.pipeline_stages.to_h { |s| [s.name, s.auto_trigger] }
      end
      expect(triggers).to include("Contactada" => "whatsapp_outbound", "Calificada" => "bant_qualified", "Nueva" => nil)
    end

    it "crea las fuentes de lead por defecto" do
      result = onboarder.call
      ActsAsTenant.with_tenant(result.tenant) do
        kinds = LeadSource.pluck(:kind)
        expect(kinds).to include("web", "whatsapp", "meta", "google", "referral", "manual")
      end
    end

    it "crea criterio BANT" do
      result = onboarder.call
      expect(result.tenant.bant_criterion).to be_present
    end

    it "inicializa network_depth RFC F2" do
      result = onboarder.call
      expect(result.tenant.settings["network_depth"]).to eq(ConsultantNetworkAccess::DEFAULT_NETWORK_DEPTH)
    end

    context "vertical libranzas", :without_tenant do
      it "crea campos personalizados de la vertical" do
        result = described_class.new(
          slug: "libranzas", name: "Libranzas", admin_email: "admin@libranzas.co",
          admin_name: "Admin", admin_password: "SecurePass123!"
        ).call
        ActsAsTenant.with_tenant(result.tenant) do
          keys = TenantFieldDefinition.pluck(:key)
          expect(keys).to include("empleador_nombre", "salario_base")
        end
      end

      it "aplica pipeline y BANT F5 de la vertical" do
        slug = "libranzas-onboard-#{SecureRandom.hex(3)}"
        result = described_class.new(
          slug: slug,
          vertical: "libranzas",
          name: "Libranzas Clone",
          admin_email: "admin-#{SecureRandom.hex(3)}@libranzas.co",
          admin_name: "Admin",
          admin_password: "SecurePass123!"
        ).call

        expect(result.pipeline.name).to eq("Proceso de Libranza")
        expect(result.tenant.settings["industry"]).to eq("payroll_credit")
        ActsAsTenant.with_tenant(result.tenant) do
          expect(result.pipeline.pipeline_stages.count).to eq(7)
          expect(result.tenant.bant_criterion.threshold_qualified).to eq(55)
          expect(result.tenant.bant_criterion.authority_weight).to eq(30)
        end
      end
    end

    context "vertical micasita", :without_tenant do
      it "crea campos personalizados de la vertical" do
        result = described_class.new(
          slug: "micasita", name: "Mi Casita", admin_email: "admin@micasita.co",
          admin_name: "Admin", admin_password: "SecurePass123!"
        ).call
        ActsAsTenant.with_tenant(result.tenant) do
          keys = TenantFieldDefinition.pluck(:key)
          expect(keys).to include("tipo_inmueble", "valor_comercial")
        end
      end

      it "aplica pipeline F5 de inmobiliaria" do
        slug = "micasita-onboard-#{SecureRandom.hex(3)}"
        result = described_class.new(
          slug: slug,
          vertical: "micasita",
          name: "Mi Casita Clone",
          admin_email: "admin-#{slug}@micasita.co",
          admin_name: "Admin",
          admin_password: "SecurePass123!"
        ).call

        expect(result.pipeline.name).to eq("Ciclo de Venta Inmobiliaria")
        expect(result.tenant.settings["industry"]).to eq("real_estate")
        ActsAsTenant.with_tenant(result.tenant) do
          expect(result.pipeline.pipeline_stages.count).to eq(8)
          # Verticales: solo "Calificada" recibe regla (BANT), como antes.
          expect(result.pipeline.pipeline_stages.where.not(auto_rule: {}).map(&:auto_trigger)).to eq(["bant_qualified"])
        end
      end
    end

    context "vertical iswo", :without_tenant do
      it "aplica pipeline ISO y pesos BANT F5" do
        slug = "iswo-onboard-#{SecureRandom.hex(3)}"
        result = described_class.new(
          slug: slug,
          vertical: "iswo",
          name: "ISWO Clone",
          admin_email: "admin-#{slug}@iswo.co",
          admin_name: "Admin",
          admin_password: "SecurePass123!"
        ).call

        expect(result.pipeline.name).to eq("Ciclo de Consultoría ISO")
        expect(result.tenant.settings["industry"]).to eq("consulting_iso")
        ActsAsTenant.with_tenant(result.tenant) do
          expect(result.pipeline.pipeline_stages.pluck(:name)).to include("Diagnóstico", "Contrato Firmado")
          expect(result.tenant.bant_criterion.authority_weight).to eq(35)
        end
      end
    end

    context "alias mi_casita", :without_tenant do
      it "resuelve la vertical micasita por slug alias" do
        slug = "mi-casita-#{SecureRandom.hex(3)}"
        result = described_class.new(
          slug: slug,
          vertical: "mi_casita",
          name: "Alias Casita",
          admin_email: "admin-#{SecureRandom.hex(3)}@casita.co",
          admin_name: "Admin",
          admin_password: "SecurePass123!"
        ).call

        expect(result.pipeline.name).to eq("Ciclo de Venta Inmobiliaria")
        ActsAsTenant.with_tenant(result.tenant) do
          expect(TenantFieldDefinition.pluck(:key)).to include("tipo_inmueble")
        end
      end
    end

    it "es atómico — rollback completo si algo falla" do
      allow(LeadSource).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
      slug_before = Tenant.count
      expect { onboarder.call }.to raise_error(ActiveRecord::RecordInvalid)
      expect(Tenant.count).to eq(slug_before) # no quedó registro parcial
    end
  end
end
