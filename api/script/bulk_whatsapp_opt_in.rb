# Marca opt-in de WhatsApp en bloque para TODOS los contactos de TODOS los
# tenants (ajuste global, no específico a un tenant) que fueron autorizados
# fuera del sistema antes de existir el gate de opt-in.
#
# Reutiliza exactamente la misma lógica que ya usa el sistema para marcar
# opt-in (Contact#mark_whatsapp_opt_in! + AuditEvent por contacto vía
# AuditLogger), pero recorriendo TODOS los contactos sin opt-in de TODOS los
# tenants de una sola corrida.
#
# Uso:
#   DRY_RUN=true  bin/rails runner script/bulk_whatsapp_opt_in.rb   # solo cuenta, no persiste
#   DRY_RUN=false bin/rails runner script/bulk_whatsapp_opt_in.rb   # ejecuta de verdad
#
# Para limitar la corrida a uno o más tenants puntuales (en vez de todos):
#   TENANT_SLUGS=iswo bin/rails runner script/bulk_whatsapp_opt_in.rb
#   TENANT_SLUGS=micasita,libranzas DRY_RUN=false bin/rails runner script/bulk_whatsapp_opt_in.rb
#
# En producción (Dokku, ver .github/workflows/deploy.yml — app "crm-iswo-api"):
#   ssh dokku@$DOKKU_HOST run crm-iswo-api bin/rails runner script/bulk_whatsapp_opt_in.rb
#   ssh dokku@$DOKKU_HOST run crm-iswo-api bash -c "DRY_RUN=false bin/rails runner script/bulk_whatsapp_opt_in.rb"
#
# Idempotente: solo toca contactos con whatsapp_opt_in_at: nil, así que se
# puede correr más de una vez sin duplicar nada.

dry_run      = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "true"))
source       = ENV.fetch("WHATSAPP_OPT_IN_SOURCE", "import")
tenant_slugs = ENV["TENANT_SLUGS"].to_s.split(",").map(&:strip).reject(&:blank?)

tenants = Tenant.kept.order(:id)
tenants = tenants.where(slug: tenant_slugs) if tenant_slugs.any?

puts "=== Bulk WhatsApp opt-in global — dry_run=#{dry_run} source=#{source.inspect}" \
     "#{tenant_slugs.any? ? " tenants=#{tenant_slugs.join(',')}" : ''} ==="

total_marked = 0

tenants.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    scope = tenant.contacts.kept.where(whatsapp_opt_in_at: nil, whatsapp_opt_out_at: nil)
    count = scope.count
    next if count.zero?

    puts "- Tenant ##{tenant.id} (#{tenant.slug}): #{count} contacto(s) sin opt-in"

    next if dry_run

    scope.find_each do |contact|
      contact.mark_whatsapp_opt_in!(source: source)
      AuditLogger.record_entity!(
        tenant:   tenant,
        user:     nil,
        action:   "contact.whatsapp_opt_in",
        entity:   contact,
        metadata: { name: contact.display_name, bulk: "script:bulk_whatsapp_opt_in" }
      )
    end

    total_marked += count
  end
end

if dry_run
  puts "=== dry-run: nada persistido. Corré con DRY_RUN=false para aplicar. ==="
else
  puts "=== Listo: #{total_marked} contacto(s) marcados con opt-in en total. ==="
end
