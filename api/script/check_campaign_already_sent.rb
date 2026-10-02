# frozen_string_literal: true

# Solo lectura. Lista, para cada tenant, las campañas de WhatsApp más recientes
# que ya enviaron mensajes a al menos un contacto (status: sent), junto con
# esos contactos — pensado para evitar reenviar una plantilla a gente que ya
# la recibió al armar una campaña nueva de reemplazo (ver campaña cancelada
# "Confirmación de contacto" / confirmacion_contacto_whatsapp).
#
# Uso: bundle exec rails runner script/check_campaign_already_sent.rb
#      bundle exec rails runner script/check_campaign_already_sent.rb --template=confirmacion_contacto_whatsapp

template_filter = ARGV.find { |a| a.start_with?("--template=") }&.split("=", 2)&.last

Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    campaigns = tenant.whatsapp_campaigns
                       .joins(:whatsapp_template)
                       .where.not(status: "draft")
                       .order(created_at: :desc)

    campaigns = campaigns.where(whatsapp_templates: { meta_template_name: template_filter }) if template_filter

    campaigns.find_each do |c|
      recipients = c.whatsapp_campaign_recipients.status_sent.includes(:contact)
      next if recipients.none?

      puts "=== Tenant #{tenant.slug} — Campaña \"#{c.name}\" (##{c.id}, status=#{c.status}, plantilla=#{c.whatsapp_template.meta_template_name}) ==="
      puts "  Creada: #{c.created_at} · Lanzada: #{c.started_at} · #{recipients.count} contacto(s) ya recibieron el mensaje:"
      recipients.each do |r|
        contact = r.contact
        puts "  - ##{contact.id} #{contact.display_name} · #{contact.phone_e164_safe.presence || contact.phone_normalized_legacy}"
      end
      puts
    end
  end
end
