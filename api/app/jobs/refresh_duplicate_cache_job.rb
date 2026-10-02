# frozen_string_literal: true

# ============================================================================
# RefreshDuplicateCacheJob — escaneo diario de duplicados (config/recurring.yml)
# ============================================================================
# Corre DuplicateFlags::Scanner en cada tenant activo: mismo contacto con varias
# oportunidades abiertas y contactos distintos con el mismo celular o correo.
# Las alertas quedan a nombre del primer admin del tenant (detected_by_user es
# obligatorio). Antes este job usaba columnas inexistentes (contact_a_id) y
# fallaba todos los días apenas había un contacto nuevo.
# ============================================================================
class RefreshDuplicateCacheJob < ApplicationJob
  queue_as :low

  def perform
    ActsAsTenant.without_tenant do
      Tenant.active.find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) { scan_tenant(tenant) }
      end
    end
  end

  private

  def scan_tenant(tenant)
    actor = tenant.users.where(role: "admin").order(:id).first
    return unless actor

    result = DuplicateFlags::Scanner.call(tenant: tenant, actor: actor)
    Rails.logger.info("[RefreshDuplicateCacheJob] tenant=#{tenant.id} grupos=#{result.scanned} alertas=#{result.created}")
  rescue StandardError => e
    Rails.logger.error("[RefreshDuplicateCacheJob] tenant=#{tenant.id}: #{e.class} #{e.message}")
  end
end
