# frozen_string_literal: true

# ============================================================================
# ExportAuditable — auditoría RFC §6.7 (opportunity_logs + audit_events).
# ============================================================================
# `action:` distingue creación ("export", default) de descarga
# ("export_download") — ISO A.7.10 exige auditar el acceso al archivo, no
# solo su generación.
# ============================================================================
module ExportAuditable
  extend ActiveSupport::Concern

  private

  def record_export_audit!(resource:, format:, filters: {}, row_count: nil, sync: false,
                            action: "export", export_id: nil)
    meta = {
      resource:   resource,
      format:     format,
      filters:    filters.presence,
      row_count:  row_count,
      sync:       sync,
      ip:         request.remote_ip
    }.compact

    AuditLogger.record!(
      tenant:      current_tenant,
      user:        current_user,
      action:      action,
      entity_type: resource.to_s.singularize.classify,
      entity_id:   export_id,
      metadata:    meta,
      ip_address:  request.remote_ip,
      user_agent:  request.user_agent
    )

    OpportunityLog.create!(
      tenant:       current_tenant,
      user:         current_user,
      opportunity:  nil,
      action:       action,
      ip_address:   request.remote_ip,
      user_agent:   request.user_agent,
      changes_data: LogSanitizer.redact(meta)
    )
  rescue StandardError => e
    Rails.logger.warn("[ExportAuditable] #{resource}/#{format}: #{e.message}")
  end
end
