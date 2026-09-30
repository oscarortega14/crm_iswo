# frozen_string_literal: true

require "rails_helper"

RSpec.describe WhatsappTemplatePolicy do
  let(:tenant)     { ActsAsTenant.current_tenant }
  let(:template)   { create(:whatsapp_template, tenant: tenant) }
  let(:admin)      { create(:user, :admin,      tenant: tenant) }
  let(:manager)    { create(:user, :manager,    tenant: tenant) }
  let(:consultant) { create(:user, :consultant, tenant: tenant) }
  let(:viewer)     { create(:user, :viewer,     tenant: tenant) }

  describe "index? / show?" do
    it "permite a todo el staff" do
      [admin, manager, consultant, viewer].each do |u|
        expect(described_class.new(u, template).index?).to be(true)
        expect(described_class.new(u, template).show?).to  be(true)
      end
    end
  end

  describe "create? / update?" do
    it "permite a admin y manager" do
      expect(described_class.new(admin,   template).create?).to be(true)
      expect(described_class.new(manager, template).create?).to be(true)
      expect(described_class.new(admin,   template).update?).to be(true)
    end

    it "deniega a consultant y viewer" do
      expect(described_class.new(consultant, template).create?).to be(false)
      expect(described_class.new(viewer,     template).update?).to be(false)
    end
  end

  describe "destroy?" do
    it "solo admin" do
      expect(described_class.new(admin,      template).destroy?).to be(true)
      expect(described_class.new(manager,    template).destroy?).to be(false)
      expect(described_class.new(consultant, template).destroy?).to be(false)
    end
  end

  describe "sync?" do
    it "permite a admin y manager" do
      expect(described_class.new(admin,   template).sync?).to be(true)
      expect(described_class.new(manager, template).sync?).to be(true)
    end

    it "deniega a consultant y viewer" do
      expect(described_class.new(consultant, template).sync?).to be(false)
      expect(described_class.new(viewer,     template).sync?).to be(false)
    end
  end
end
