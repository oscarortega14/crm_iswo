# frozen_string_literal: true

# ============================================================================
# WebhookProcessorJob — procesa payloads recibidos por los webhook controllers.
# ============================================================================
# Diseñado para ser idempotente y tolerante a payloads parciales. El controller
# del webhook responde 200 inmediatamente y deja todo el trabajo aquí, así
# evitamos timeouts del proveedor.
#
# Tipos soportados (kind):
#   "meta" (alias meta_ads) → Ads::MetaLeadProcessor
#   "google" (alias google_ads) → Ads::GoogleLeadProcessor
#   "whatsapp_cloud"  → procesa inbound de Meta Cloud API
#
# Persiste el payload en AuditEvent al inicio para tener trazabilidad ISO.
# ============================================================================
class WebhookProcessorJob < ApplicationJob
  queue_as :integrations

  # Meta Cloud API — statuses[].status → enum WhatsappMessage
  WHATSAPP_CLOUD_DELIVERY_STATUS_MAP = {
    "sent"       => "sent",
    "delivered"  => "delivered",
    "read"       => "read",
    "failed"     => "failed",
    "pending"    => "queued"
  }.freeze

  # Reintentos específicos para errores de red contra Meta/Google.
  retry_on Faraday::Error, wait: :polynomially_longer, attempts: 5

  # ArgumentError indica integración no configurada o payload inválido:
  # no reintentar (el reintento no ayuda), pero sí loguear y descartar.
  discard_on ArgumentError do |job, error|
    Rails.logger.error(
      "[WebhookProcessorJob] DISCARD args=#{job.arguments.first.inspect} " \
      "#{error.class}: #{error.message}"
    )
  end

  def perform(kind, payload)
    audit_received(kind, payload)

    case kind
    when "meta", "meta_ads"    then Ads::MetaLeadProcessor.new(payload).call
    when "google", "google_ads" then Ads::GoogleLeadProcessor.new(payload).call
    when "whatsapp_cloud"      then process_whatsapp_cloud(payload)
    when "whatsapp_openwa"     then process_whatsapp_openwa(payload)
    else
      Rails.logger.warn("[WebhookProcessorJob] kind desconocido: #{kind}")
    end
  end

  # ===========================================================================

  private

  def audit_received(kind, payload)
    # Vía AuditLogger (regla del proyecto): sanitiza metadata y falla en silencio.
    AuditLogger.record!(
      tenant:      nil, # se resuelve adentro del processor
      user:        nil,
      action:      "webhook_received",
      entity_type: "Webhook",
      entity_id:   nil,
      metadata:    { kind: kind, keys: payload.keys.first(20) },
      ip_address:  payload["remote_ip"],
      user_agent:  payload["user_agent"]
    )
  end

  # --- WhatsApp inbound (Cloud API) --------------------------------------

  def process_whatsapp_cloud(payload)
    Array(payload["entry"]).each do |entry|
      Array(entry["changes"]).each do |change|
        value = change["value"] || {}
        meta_phone_id = value.dig("metadata", "phone_number_id").to_s
        next Rails.logger.warn("[WhatsApp Cloud] phone_number_id vacío") if meta_phone_id.blank?

        tenant = ActsAsTenant.without_tenant do
          integration = AdIntegration.unscoped.where(provider: "whatsapp_cloud")
                                     .find_by(account_identifier: meta_phone_id)
          integration&.tenant || resolve_tenant_by_setting("whatsapp.cloud_phone_id", meta_phone_id)
        end
        next Rails.logger.warn("[WhatsApp Cloud] sin tenant para phone_number_id=#{meta_phone_id}") unless tenant

        ActsAsTenant.with_tenant(tenant) do
          Array(value["statuses"]).each { |st| apply_whatsapp_cloud_status_callback(st) }

          Array(value["messages"]).each do |m|
            sid = m["id"].presence
            if sid.present? &&
               tenant.whatsapp_messages.where(provider: "whatsapp_cloud", provider_message_id: sid).exists?
              next
            end

            from         = m["from"]
            profile_name = profile_name_from_cloud_contacts(value["contacts"], from)
            contact      = upsert_contact(tenant, from, profile_name: profile_name)
            opportunity  = find_opportunity_for_inbound(tenant, contact, from)
            msg = tenant.whatsapp_messages.create!(
              contact:             contact,
              opportunity:         opportunity,
              direction:           "in",
              provider:            "whatsapp_cloud",
              provider_message_id: sid,
              from_number:         from,
              to_number:           cloud_inbound_to_number(value["metadata"]),
              body:                inbound_body_from_cloud_message(m),
              media_url:           inbound_media_url_from_cloud_message(m),
              status:              "delivered",
              raw_payload:         m
            )
            opportunity&.touch_activity!
            Notifications::WhatsappMessageNotifier.call(message: msg)
          end
        end
      end
    end
  end

  # --- WhatsApp inbound (OpenWA) ----------------------------------------

  def process_whatsapp_openwa(payload)
    event      = payload["event"].to_s
    session_id = payload["sessionId"].to_s
    data       = payload["data"].is_a?(Hash) ? payload["data"] : {}

    msg_id = openwa_extract_message_id(data)

    case event
    when "message.received"
      process_openwa_inbound(session_id, data, msg_id)
    when "message.delivered"
      openwa_update_status(msg_id, "delivered", delivered_at: true)
    when "message.read"
      openwa_update_status(msg_id, "read", read_at: true)
    when "message.failed"
      openwa_update_status(msg_id, "failed")
    else
      Rails.logger.info("[WhatsApp OpenWA] evento ignorado: #{event}")
    end
  end

  def process_openwa_inbound(session_id, data, msg_id)
    from_wa = data["from"].to_s
    to_wa   = data["to"].to_s

    from_number = openwa_wa_id_to_e164(from_wa)
    to_number   = openwa_wa_id_to_e164(to_wa)

    tenant = ActsAsTenant.without_tenant do
      AdIntegration.unscoped
                   .where(provider: "openwa", account_identifier: session_id)
                   .first&.tenant ||
        resolve_tenant_by_setting("whatsapp.openwa_session_id", session_id)
    end

    return Rails.logger.warn("[WhatsApp OpenWA] sin tenant para sessionId=#{session_id}") unless tenant

    ActsAsTenant.with_tenant(tenant) do
      if msg_id.present? &&
         tenant.whatsapp_messages.exists?(provider: "openwa", provider_message_id: msg_id)
        Rails.logger.info("[WhatsApp OpenWA] duplicado msg_id=#{msg_id}")
        return
      end

      contact     = upsert_contact(tenant, from_number)
      opportunity = find_opportunity_for_inbound(tenant, contact, from_number)
      msg = tenant.whatsapp_messages.create!(
        contact:             contact,
        opportunity:         opportunity,
        direction:           "in",
        provider:            "openwa",
        provider_message_id: msg_id,
        from_number:         from_number,
        to_number:           to_number,
        body:                data["body"].to_s,
        status:              "delivered",
        raw_payload:         data
      )
      opportunity&.touch_activity!
      Notifications::WhatsappMessageNotifier.call(message: msg)
    end
  end

  def openwa_extract_message_id(data)
    id_field = data["id"]
    if id_field.is_a?(Hash)
      id_field["_serialized"].to_s.presence
    else
      id_field.to_s.presence
    end
  end

  # Convierte chatId de whatsapp-web.js (628123456789@c.us) a E.164 (+628123456789)
  def openwa_wa_id_to_e164(wa_id)
    digits = wa_id.to_s.split("@").first.to_s.gsub(/\D/, "")
    digits.blank? ? wa_id : "+#{digits}"
  end

  def openwa_update_status(msg_id, new_status, delivered_at: false, read_at: false)
    return if msg_id.blank?

    msg = ActsAsTenant.without_tenant do
      WhatsappMessage.unscoped.find_by(provider: "openwa", provider_message_id: msg_id)
    end
    return unless msg

    attrs = { status: new_status }
    attrs[:delivered_at] = Time.current if delivered_at && msg.delivered_at.blank?
    attrs[:read_at]      = Time.current if read_at      && msg.read_at.blank?
    ActsAsTenant.with_tenant(msg.tenant) { msg.update!(attrs) }
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[WhatsApp OpenWA] no se pudo actualizar estado: #{e.message}")
  end

  def resolve_tenant_by_setting(path, value)
    ActsAsTenant.without_tenant do
      Tenant.where("settings #>> ? = ?", "{#{path.split('.').join(',')}}", value.to_s).first
    end
  end

  # Encuentra la oportunidad más apropiada para enlazar un mensaje entrante.
  # Prioridad: (1) oportunidad con el último saliente a ese número,
  #            (2) oportunidad abierta más reciente del contacto.
  def find_opportunity_for_inbound(tenant, contact, from_number)
    normalized = Phonelib.parse(from_number).sanitized

    # Buscar la oportunidad que tenga el saliente más reciente a este número
    last_out = tenant.whatsapp_messages
                     .where(direction: "out")
                     .where("to_number LIKE ?", "%#{normalized.last(9)}%")
                     .where.not(opportunity_id: nil)
                     .order(created_at: :desc)
                     .first
    return last_out.opportunity if last_out&.opportunity

    # Fallback: oportunidad abierta más activa del contacto
    return nil unless contact

    tenant.opportunities
          .where(contact: contact)
          .where.not(status: %w[won lost])
          .order(last_activity_at: :desc)
          .first
  end

  def upsert_contact(tenant, phone, profile_name: nil)
    parsed = Phonelib.parse(phone)
    e164 = parsed.e164
    raise ArgumentError, "teléfono WhatsApp inválido" if e164.blank?

    contact = tenant.contacts.kept.find_by(phone_e164: e164)
    if contact
      contact.record_origin!("whatsapp", "inbound") # p. ej. un contacto importado que escribió
      return contact
    end

    # Volvió a escribir alguien cuyo contacto se había eliminado: se restaura
    # (conserva su historial). Antes el mensaje quedaba colgado del contacto
    # eliminado y la bandeja no podía responderle («Couldn't find Contact»).
    deleted = tenant.contacts.discarded.order(discarded_at: :desc).find_by(phone_e164: e164)
    if deleted
      deleted.undiscard
      deleted.record_origin!("whatsapp", "inbound")
      return deleted
    end

    first_name, last_part = split_whatsapp_profile_name(profile_name)
    last_name = last_part.presence || parsed.sanitized.to_s.last(4).presence || "wa"

    tenant.contacts.create!(
      first_name:   first_name,
      last_name:    last_name,
      phone_e164:   e164,
      source_kind:  "whatsapp",
      source_label: "inbound"
    )
  rescue ActiveRecord::RecordNotUnique
    tenant.contacts.find_by!(phone_e164: e164)
  end

  def split_whatsapp_profile_name(name)
    return ["Contacto", nil] if name.blank?

    parts = name.to_s.strip.split(/\s+/, 2)
    [parts[0].presence || "Contacto", parts[1]]
  end

  def profile_name_from_cloud_contacts(contacts, wa_from)
    Array(contacts).each do |c|
      next if c["wa_id"].to_s != wa_from.to_s

      return c.dig("profile", "name").to_s.strip.presence
    end
    nil
  end

  def cloud_inbound_to_number(metadata)
    raw = metadata&.dig("display_phone_number").to_s.strip
    return raw if raw.blank?

    e164 = Phonelib.parse(raw).e164
    return e164 if e164.present?

    digits = raw.gsub(/\D/, "")
    digits.present? ? "+#{digits}" : raw
  end

  def inbound_body_from_cloud_message(m)
    case m["type"].to_s
    when "text"
      m.dig("text", "body")
    when "button"
      m.dig("button", "text")
    when "interactive"
      m.dig("interactive", "button_reply", "title") ||
        m.dig("interactive", "list_reply", "title")
    else
      m.dig("text", "body")
    end
  end

  def inbound_media_url_from_cloud_message(m)
    return if m.blank?

    inner = m[m["type"].to_s]
    return unless inner.is_a?(Hash)

    # Meta suele mandar `id` de media, no URL; sólo persistimos si viene enlace explícito.
    inner["link"].presence
  end

  def apply_whatsapp_cloud_status_callback(st)
    sid = st["id"].presence
    return if sid.blank?

    msg = ActsAsTenant.without_tenant do
      WhatsappMessage.unscoped.find_by(provider: "whatsapp_cloud", provider_message_id: sid)
    end
    return unless msg

    key = st["status"].to_s.downcase
    mapped = WHATSAPP_CLOUD_DELIVERY_STATUS_MAP[key] || msg.status

    attrs = { status: mapped }
    attrs[:sent_at] = Time.current if mapped.to_s == "sent" && msg.sent_at.blank?
    attrs[:delivered_at] = Time.current if mapped.to_s == "delivered" && msg.delivered_at.blank?
    attrs[:read_at] = Time.current if mapped.to_s == "read" && msg.read_at.blank?

    if mapped.to_s == "failed" || st["errors"].present?
      attrs[:error_message] = format_whatsapp_cloud_status_errors(st).presence ||
                              "WhatsApp Cloud (#{st['status']})"
    end

    ActsAsTenant.with_tenant(msg.tenant) do
      msg.update!(attrs)
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[WhatsApp Cloud] no se pudo actualizar estado: #{e.message}")
  end

  def format_whatsapp_cloud_status_errors(st)
    errs = st["errors"]
    return unless errs.is_a?(Array) && errs.any?

    errs.filter_map do |e|
      next e.to_s unless e.is_a?(Hash)

      [e["code"], e["title"], e["message"]].compact.join(": ").presence
    end.join(" | ").presence
  end
end
