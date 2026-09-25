# Marca opt-in de WhatsApp en bloque para TODOS los contactos de TODOS los
# tenants (ajuste global, no específico a un tenant) que fueron autorizados
# fuera del sistema antes de existir el gate de opt-in.
#
# Reutiliza exactamente la misma lógica que POST /api/v1/contacts/bulk_whatsapp_opt_in
# (Contact#mark_whatsapp_opt_in! + AuditEvent por contacto vía AuditLogger),
# pero sin el límite de "10 por página" de la UI y recorriendo todos los tenants.
#
# Uso:
#   DRY_RUN=true  bin/rails runner script/bulk_whatsapp_opt_in.rb   # solo cuenta, no persiste
#   DRY_RUN=false bin/rails runner script/bulk_whatsapp_opt_in.rb   # ejecuta de verdad
#
# En producción (Kamal):
#   kamal app exec -i 'bin/rails runner script/bulk_whatsapp_opt_in.rb' # con DRY_RUN=true por defecto
#   kamal app exec -i -e DRY_RUN=false 'bin/rails runner script/bulk_whatsapp_opt_in.rb'
#
# Idempotente: solo toca contactos con whatsapp_opt_in_at: nil, así que se
# puede correr más de una vez sin duplicar nada.

dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "true"))
source  = ENV.fetch("WHATSAPP_OPT_IN_SOURCE", "import")

puts "=== Bulk WhatsApp opt-in global — dry_run=#{dry_run} source=#{source.inspect} ==="

total_marked = 0

Tenant.kept.order(:id).find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    scope = tenant.contacts.kept.where(whatsapp_opt_in_at: nil)
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
