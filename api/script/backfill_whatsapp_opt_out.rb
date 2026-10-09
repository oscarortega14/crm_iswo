# frozen_string_literal: true

# Backfill de respuestas de consentimiento de WhatsApp: revisa los mensajes
# ENTRANTES y aplica la ÚLTIMA respuesta de consentimiento de cada contacto
# (ver WhatsApp::ConsentReply):
#   - "No" ("No autorizo", "Stop"…) → opt-out.
#   - "Sí" ("Sí, autorizo", "Acepto"…) → opt-in confirmado
#     (whatsapp_opt_in_source: "reply_confirm"), que es lo que usa el filtro
#     de audiencia "Solo quienes confirmaron Sí" de las campañas.
#
# Pensado para respuestas que llegaron antes de que existieran el opt-out y
# la confirmación (cuando cualquier respuesta marcaba opt-in genérico, o no
# marcaba nada si el contacto ya tenía opt-in por import). Si el contacto
# respondió "No" y después "Sí" (o al revés), gana la última respuesta.
#
# Por defecto es DRY RUN (solo lista). En producción (Dokku):
#   ssh dokku@$DOKKU_HOST run crm-iswo-api bin/rails runner script/backfill_whatsapp_opt_out.rb
#   ssh dokku@$DOKKU_HOST run crm-iswo-api bash -c "DRY_RUN=false bin/rails runner script/backfill_whatsapp_opt_out.rb"
#
# Opcional: SINCE=2026-09-23 (solo mensajes desde esa fecha), TENANT_SLUGS=a,b
#
# Idempotente: no toca contactos que ya reflejan su última respuesta.

dry_run      = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "true"))
since        = ENV["SINCE"].presence && Time.zone.parse(ENV["SINCE"])
tenant_slugs = ENV["TENANT_SLUGS"].to_s.split(",").map(&:strip).reject(&:blank?)

tenants = Tenant.kept.order(:id)
tenants = tenants.where(slug: tenant_slugs) if tenant_slugs.any?

puts "=== Backfill respuestas de consentimiento WhatsApp — dry_run=#{dry_run}" \
     "#{since ? " since=#{since.to_date}" : ''} ==="

totals = { opt_out: 0, opt_in: 0 }

tenants.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    inbound = tenant.whatsapp_messages.inbound.where.not(contact_id: nil)
    inbound = inbound.where(created_at: since..) if since

    # Última respuesta de consentimiento (sí/no) por contacto.
    last_decision = {}
    inbound.order(:created_at, :id).each do |m|
      decision = WhatsApp::ConsentReply.classify(m.body)
      last_decision[m.contact_id] = [ decision, m ] if decision
    end
    next if last_decision.empty?

    tenant.contacts.kept.where(id: last_decision.keys).find_each do |contact|
      decision, msg = last_decision[contact.id]

      already =
        if decision == :opt_out
          contact.whatsapp_opted_out?
        else
          contact.whatsapp_opt_in_source == "reply_confirm" && !contact.whatsapp_opted_out?
        end
      next if already

      label = decision == :opt_out ? "NO" : "SÍ"
      puts "  [#{tenant.slug}] #{label} ##{contact.id} #{contact.display_name} · " \
           "\"#{msg.body.to_s.truncate(40)}\" (#{msg.created_at.to_date})"
      totals[decision] += 1
      next if dry_run

      if decision == :opt_out
        contact.update!(whatsapp_opt_in_at: nil, whatsapp_opt_out_at: msg.created_at, whatsapp_opt_out_source: "reply")
      else
        contact.update!(whatsapp_opt_in_at: msg.created_at, whatsapp_opt_in_source: "reply_confirm",
                        whatsapp_opt_out_at: nil, whatsapp_opt_out_source: nil)
      end
      AuditLogger.record_entity!(
        tenant: tenant, user: nil, entity: contact,
        action: decision == :opt_out ? "contact.whatsapp_opt_out" : "contact.whatsapp_opt_in",
        metadata: { source: "backfill_whatsapp_consent", whatsapp_message_id: msg.id }
      )
    end
  end
end

verb = dry_run ? "se marcarían" : "marcados"
puts "=== Total: #{totals[:opt_out]} \"No\" (opt-out) y #{totals[:opt_in]} \"Sí\" (confirmados) #{verb} ==="
puts "(dry run — nada se guardó; usa DRY_RUN=false para aplicar)" if dry_run
