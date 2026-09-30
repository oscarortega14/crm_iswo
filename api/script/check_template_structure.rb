# frozen_string_literal: true

# Solo lectura. Trae de Meta (Graph API) la estructura completa y actual de
# una plantilla — components, tipo de parámetro por componente (posicional
# vs named) — para diagnosticar errores de envío como el 131008 "Required
# parameter is missing", que suele salir cuando el formato que el CRM envía
# (posicional/named) no coincide con lo que Meta tiene aprobado ahora mismo.
#
# Uso: bundle exec rails runner script/check_template_structure.rb --template=confirmacion_contacto_whatsapp

template_filter = ARGV.find { |a| a.start_with?("--template=") }&.split("=", 2)&.last
abort("Uso: bundle exec rails runner script/check_template_structure.rb --template=<meta_template_name>") if
  template_filter.blank?

Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    integ = tenant.preferred_whatsapp_cloud_integration
    next unless integ

    waba_id = (integ.metadata || {}).stringify_keys["waba_id"]
    token   = (integ.credentials || {}).stringify_keys["access_token"]
    next if waba_id.blank? || token.blank?

    conn = Faraday.new(url: "https://graph.facebook.com") do |f|
      f.response :json, content_type: /\bjson$/
    end

    api_version = ENV["WHATSAPP_CLOUD_API_VERSION"].presence || "v18.0"
    api_version = "v#{api_version.delete_prefix('v')}"

    res = conn.get("/#{api_version}/#{waba_id}/message_templates") do |req|
      req.headers["Authorization"] = "Bearer #{token}"
      req.params = { fields: "name,language,status,category,components", limit: 100 }
    end

    unless res.success?
      puts "=== Tenant #{tenant.slug}: error consultando Meta (#{res.status}) ==="
      puts res.body.inspect
      next
    end

    matches = Array(res.body["data"]).select { |t| t["name"] == template_filter }
    next if matches.empty?

    puts "=== Tenant #{tenant.slug} — plantilla \"#{template_filter}\" en Meta ==="
    matches.each do |t|
      puts "  language=#{t['language']} status=#{t['status']} category=#{t['category']}"
      Array(t["components"]).each do |c|
        puts "  Componente: #{c['type']} format=#{c['format']}"
        puts "    text: #{c['text']}" if c["text"]
        Array(c["example"]&.dig("body_text")).each { |ex| puts "    ejemplo body_text: #{ex.inspect}" }
        Array(c["buttons"]).each { |b| puts "    botón: #{b.inspect}" }
      end
      puts
    end
  end
end
