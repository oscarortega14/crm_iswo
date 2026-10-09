# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappTemplate, type: :model do
  let(:tenant) { ActsAsTenant.current_tenant }

  subject(:tpl) { build(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto", language: "es_CO") }

  describe "validaciones" do
    it { is_expected.to be_valid }

    it "requiere name" do
      tpl.name = nil
      expect(tpl).not_to be_valid
    end

    it "requiere meta_template_name" do
      tpl.meta_template_name = nil
      expect(tpl).not_to be_valid
    end

    it "requiere language" do
      tpl.language = nil
      expect(tpl).not_to be_valid
    end

    it "meta_template_name único por tenant + language (case-insensitive)" do
      create(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto", language: "es_CO")
      dup = build(:whatsapp_template, tenant: tenant, meta_template_name: "PRIMER_CONTACTO", language: "es_CO")
      expect(dup).not_to be_valid
    end

    it "permite el mismo meta_template_name en otro idioma" do
      create(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto", language: "es_CO")
      other_lang = build(:whatsapp_template, tenant: tenant, meta_template_name: "primer_contacto", language: "en_US")
      expect(other_lang).to be_valid
    end

    it "acepta el mismo meta_template_name en tenants distintos" do
      other = create(:tenant, slug: "other-#{SecureRandom.hex(3)}")
      ActsAsTenant.with_tenant(other) do
        create(:whatsapp_template, tenant: other, meta_template_name: "primer_contacto", language: "es_CO")
      end
      expect(tpl).to be_valid
    end
  end

  describe "#opt_in_request" do
    it "es false por defecto" do
      expect(tpl.opt_in_request).to be(false)
    end

    it "se puede marcar con el trait :opt_in_request" do
      marked = create(:whatsapp_template, :opt_in_request, tenant: tenant)
      expect(marked.opt_in_request?).to be(true)
    end
  end

  describe ".active scope" do
    it "devuelve solo plantillas activas" do
      active = create(:whatsapp_template, tenant: tenant, active: true)
      inactive = create(:whatsapp_template, tenant: tenant, active: false)
      expect(WhatsappTemplate.active).to include(active)
      expect(WhatsappTemplate.active).not_to include(inactive)
    end
  end

  describe "#variable_count" do
    it "cuenta las variable_labels" do
      tpl.variable_labels = %w[Nombre Fecha]
      expect(tpl.variable_count).to eq(2)
    end

    it "es 0 sin variables" do
      expect(tpl.variable_count).to eq(0)
    end
  end

  describe "#named_parameters?" do
    it "es true si variable_names tiene al menos un nombre" do
      tpl.variable_names = ["primer_nombre"]
      expect(tpl.named_parameters?).to be(true)
    end

    it "es false sin variable_names (plantilla posicional clásica)" do
      expect(tpl.named_parameters?).to be(false)
    end
  end
end
