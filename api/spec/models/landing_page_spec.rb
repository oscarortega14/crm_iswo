# frozen_string_literal: true

require "rails_helper"

RSpec.describe LandingPage, type: :model do
  let(:tenant) { ActsAsTenant.current_tenant }
  subject { build(:landing_page, tenant: tenant) }

  describe "asociaciones" do
    it { is_expected.to belong_to(:tenant).optional }
    it { is_expected.to have_many(:landing_form_submissions).dependent(:destroy) }
  end

  describe "validaciones" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:slug) }

    it "valida unicidad del slug por tenant (case-insensitive)" do
      create(:landing_page, tenant: tenant, slug: "oferta-2026")
      duplicate = build(:landing_page, tenant: tenant, slug: "OFERTA-2026")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end

    it "rechaza slugs con caracteres inválidos" do
      page = build(:landing_page, tenant: tenant, slug: "Slug Inválido!")
      expect(page).not_to be_valid
      expect(page.errors[:slug]).to be_present
    end

    it "permite mismo slug en tenants distintos", :without_tenant do
      t1 = create(:tenant, slug: "tenant-uno")
      t2 = create(:tenant, slug: "tenant-dos")
      ActsAsTenant.with_tenant(t1) { create(:landing_page, tenant: t1, slug: "oferta") }
      ActsAsTenant.with_tenant(t2) { expect(build(:landing_page, tenant: t2, slug: "oferta")).to be_valid }
    end
  end

  describe "callbacks" do
    it "normaliza el slug a minúsculas antes de validar" do
      page = build(:landing_page, tenant: tenant, slug: "  MiLanding  ")
      page.valid?
      expect(page.slug).to eq("milanding")
    end

    it "setea published_at cuando se publica por primera vez" do
      page = create(:landing_page, tenant: tenant, published: false, published_at: nil)
      page.update!(published: true)
      expect(page.published_at).to be_present
    end

    it "resetea published_at si se despublica" do
      page = create(:landing_page, :published, tenant: tenant)
      page.update!(published: false)
      expect(page.published_at).to be_nil
    end

    it "sanitiza gjs_html y gjs_css al guardar" do
      page = create(
        :landing_page,
        tenant: tenant,
        content: {
          "gjs_html" => '<p>Hola</p><script>evil()</script>',
          "gjs_css"  => "p { color: red; } javascript:evil()"
        }
      )
      expect(page.content["gjs_html"]).not_to include("script")
      expect(page.content["gjs_css"]).not_to include("javascript:")
    end
  end

  describe "scopes" do
    it ".published filtra por published=true" do
      published = create(:landing_page, :published, tenant: tenant)
      draft     = create(:landing_page, tenant: tenant, published: false)

      expect(LandingPage.published).to include(published)
      expect(LandingPage.published).not_to include(draft)
    end
  end

  describe "#public_url" do
    let(:page) { build(:landing_page, tenant: tenant, slug: "black-friday") }

    it "en production usa subdominio del APP_HOST" do
      allow(Rails.env).to receive(:production?).and_return(true)
      expect(page.public_url).to eq("https://#{tenant.slug}.iswocrm.com/black-friday")
    end

    it "en development simula subdominio .localhost" do
      allow(Rails.env).to receive(:production?).and_return(false)
      expect(page.public_url).to eq("http://#{tenant.slug}.localhost:3001/black-friday")
    end

    it "respeta LANDING_PUBLIC_HOST si está definido" do
      original = ENV["LANDING_PUBLIC_HOST"]
      ENV["LANDING_PUBLIC_HOST"] = "https://landings.test"
      expect(page.public_url).to eq("https://landings.test/black-friday")
    ensure
      ENV["LANDING_PUBLIC_HOST"] = original
    end
  end
end
