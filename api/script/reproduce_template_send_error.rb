# frozen_string_literal: true

# Solo diagnóstico. Reconstruye el payload exacto que WhatsApp::Adapters::Cloud
# arma para UN mensaje fallido real (mismo to/template/params) y lo reenvía
# directo a Meta, imprimiendo la respuesta CRUDA completa (incluye
# error_data.details, que el código de producción no muestra porque lo
# resume). Pensado para diagnosticar 131008 "Required parameter is missing".
#
# Uso: bundle exec rails runner script/reproduce_template_send_error.rb --template=confirmacion_contacto_whatsapp
#
# OJO: esto reenvía un mensaje real a un contacto real (el que ya recibió el
# intento fallido). No es un dry-run.

template_filter = ARGV.find { |a| a.start_with?("--template=") }&.split("=", 2)&.last
abort("Uso: ... --template=<meta_template_name>") if template_filter.blank?

Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    failed = tenant.whatsapp_messages
                   .where(message_type: "template", template_name: template_filter, status: "failed")
                   .order(created_at: :desc)
                   .first
    next unless failed

    integ = tenant.preferred_whatsapp_cloud_integration
    next unless integ

    token = (integ.credentials || {}).stringify_keys["access_token"]
    phone_number_id = integ.account_identifier.presence || (integ.credentials || {}).stringify_keys["phone_number_id"]
    next if token.blank? || phone_number_id.blank?

    to = failed.to_number.to_s.sub(/\A\+/, "")
    names = Array(failed.template_variable_names)
    params = Array(failed.template_params).each_with_index.map do |v, i|
      { type: "text", parameter_name: names[i].presence, text: v.to_s }.compact
    end

    payload = {
      messaging_product: "whatsapp",
      recipient_type:    "individual",
      to:                to,
      type:               "template",
      template: {
        name:       failed.template_name,
        language:   { code: failed.template_language },
        components: [{ type: "body", parameters: params }]
      }.compact
    }

    puts "=== Tenant #{tenant.slug} — reenviando mensaje ##{failed.id} a #{to} ==="
    puts "Payload enviado:"
    puts JSON.pretty_generate(payload)

    conn = Faraday.new(url: "https://graph.facebook.com") do |f|
      f.request  :json
      f.response :json, content_type: /\bjson$/
    end

    res = conn.post("/v18.0/#{phone_number_id}/messages") do |req|
      req.headers["Authorization"] = "Bearer #{token}"
      req.headers["Content-Type"]  = "application/json"
      req.body = payload
    end

    puts
    puts "HTTP #{res.status}"
    puts "Respuesta cruda de Meta:"
    puts JSON.pretty_generate(res.body)
  end
end
