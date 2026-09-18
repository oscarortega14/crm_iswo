# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappCampaignPolicy do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:template)   { create(:whatsapp_template, tenant: tenant) }
  let(:campaign)   { create(:whatsapp_campaign, tenant: tenant, whatsapp_template: template) }
  let(:admin)      { create(:user, :admin,      tenant: tenant) }
  let(:manager)    { create(:user, :manager,    tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
  let(:viewer)     { create(:user, :viewer,     tenant: tenant) }

  describe "index? / show? / create? / update?" do
    it "permite a admin y manager" do
      [admin, manager].each do |u|
        expect(described_class.new(u, campaign).index?).to be(true)
        expect(described_class.new(u, campaign).create?).to be(true)
        expect(described_class.new(u, campaign).update?).to be(true)
      end
    end

    it "deniega a consultant y viewer" do
      [consultant, viewer].each do |u|
        expect(described_class.new(u, campaign).index?).to be(false)
        expect(described_class.new(u, campaign).create?).to be(false)
      end
    end
  end

  describe "destroy?" do
    it "solo admin" do
      expect(described_class.new(admin,   campaign).destroy?).to be(true)
      expect(described_class.new(manager, campaign).destroy?).to be(false)
    end
  end

  describe "Scope" do
    it "admin y manager ven todas las campañas del tenant" do
      resolved = described_class::Scope.new(admin, WhatsappCampaign.all).resolve
      expect(resolved).to include(campaign)
    end

    it "consultant y viewer no ven ninguna" do
      resolved = described_class::Scope.new(consultant, WhatsappCampaign.all).resolve
      expect(resolved).to be_empty
    end
  end
end
