# frozen_string_literal: true

# ============================================================================
# Auditable — registra automáticamente create/update/destroy en AuditEvent
# ============================================================================
# Incluido en BaseController. Cubre todas las entidades excepto las que tienen
# auditoría propia más detallada (opportunities → opportunity_logs) o que son
# de solo lectura / ya auditadas manualmente.
#
# Uso por defecto (ivar == controller_name.singularize):
#   UsersController     → @user        ✅
#   LeadSourcesController → @lead_source ✅
#
# Cuando el ivar no sigue la convención, declararlo en el controller:
#   auditable_resource :landing   # LandingPagesController → @landing
# ============================================================================
module Auditable
  extend ActiveSupport::Concern

  EXCLUDED_CONTROLLERS = %w[
    opportunities
    contacts
    sessions
    audit_events
    searches
    dashboard
    notifications
    exports
    ad_integrations
    whatsapp_messages
    opportunity_logs
    landing_form_submissions
    duplicate_flags
  ].freeze

  included do
    after_action :write_crud_audit_event!, if: :auditable_action?
  end

  class_methods do
    def auditable_resource(name)
      define_method(:auditable_ivar_name) { name.to_s }
    end
  end

  private

  def auditable_ivar_name
    controller_name.singularize
  end

  def auditable_record
    instance_variable_get(:"@#{auditable_ivar_name}")
  end

  def auditable_action?
    return false if EXCLUDED_CONTROLLERS.include?(controller_name)
    return false unless response.successful?

    %w[create update destroy].include?(action_name)
  end

  def write_crud_audit_event!
    record = auditable_record
    return unless record.is_a?(ApplicationRecord)

    AuditLogger.record_entity!(
      tenant:     current_tenant,
      user:       current_user,
      action:     action_name,
      entity:     record,
      metadata:   build_audit_metadata(record),
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

  def build_audit_metadata(record)
    case action_name
    when "create"
      { name: audit_display_name(record) }
    when "update"
      changes = (record.previous_changes || {}).except("updated_at", "created_at")
      { changes: LogSanitizer.redact(changes).presence }.compact
    when "destroy"
      { name: audit_display_name(record) }
    else
      {}
    end
  end

  def audit_display_name(record)
    %i[title name email slug label].each do |m|
      val = record.try(m)
      return val.to_s if val.present?
    end
    record.id.to_s
  end
end
