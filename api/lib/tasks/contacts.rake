# frozen_string_literal: true

namespace :contacts do
  desc "Descarta oportunidades vivas cuyo contacto ya fue eliminado (soft-delete). DRY_RUN=true solo cuenta."
  task discard_orphan_opportunities: :environment do
    dry_run = ENV["DRY_RUN"].to_s.match?(/\A(1|true|yes)\z/i)

    ActsAsTenant.without_tenant do
      Tenant.find_each do |tenant|
        orphans = Opportunity.kept
                             .where(tenant_id: tenant.id)
                             .where(contact_id: Contact.discarded.where(tenant_id: tenant.id).select(:id))
        count = orphans.count
        next if count.zero?

        ActsAsTenant.with_tenant(tenant) { orphans.discard_all } unless dry_run
        puts "#{tenant.slug}: #{count} oportunidad(es) #{dry_run ? 'por descartar' : 'descartadas'}"
      end
    end
  end
end
