# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260926170000_restore_contacts_that_wrote_after_deletion")

RSpec.describe RestoreContactsThatWroteAfterDeletion do
  let(:tenant) { ActsAsTenant.current_tenant }

  def deleted_contact(at:)
    create(:contact, tenant: tenant).tap { |c| c.update_columns(discarded_at: at) }
  end

  it "restaura solo los contactos eliminados que escribieron DESPUÉS de ser eliminados" do
    wrote_after  = deleted_contact(at: 3.days.ago)
    wrote_before = deleted_contact(at: 1.day.ago)
    silent       = deleted_contact(at: 2.days.ago)
    create(:whatsapp_message, tenant: tenant, contact: wrote_after, direction: "in", created_at: 1.day.ago)
    create(:whatsapp_message, tenant: tenant, contact: wrote_before, direction: "in", created_at: 2.days.ago)
    create(:whatsapp_message, :outbound, tenant: tenant, contact: silent, created_at: 1.day.ago)

    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.transaction { described_class.new.up }
    end

    expect(wrote_after.reload).to be_kept
    expect(wrote_before.reload).to be_discarded
    expect(silent.reload).to be_discarded
  end
end
