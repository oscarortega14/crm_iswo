# frozen_string_literal: true

# Solo lectura. Imprime variable_field_map de las campañas recientes de un
# template dado, para confirmar qué quedó realmente guardado (texto fijo vs.
# campo del contacto) — diagnóstico del 131008 "missing text value".
#
# Uso: bundle exec rails runner script/check_campaign_field_map.rb --template=confirmacion_contacto_whatsapp

template_filter = ARGV.find { |a| a.start_with?("--template=") }&.split("=", 2)&.last
abort("Uso: ... --template=<meta_template_name>") if template_filter.blank?

Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    campaigns = tenant.whatsapp_campaigns
                       .joins(:whatsapp_template)
                       .where(whatsapp_templates: { meta_template_name: template_filter })
                       .order(created_at: :desc)

    campaigns.find_each do |c|
      puts "=== Tenant #{tenant.slug} — Campaña \"#{c.name}\" (##{c.id}, status=#{c.status}) ==="
      puts "  variable_field_map: #{c.variable_field_map.inspect}"
      puts "  Creada: #{c.created_at} · Actualizada: #{c.updated_at} · Lanzada: #{c.started_at}"
      puts
    end
  end
end
