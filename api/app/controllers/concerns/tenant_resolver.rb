# frozen_string_literal: true

# ============================================================================
# TenantResolver — identifica el tenant desde el request.
# ============================================================================
# Prioridad:
#   1. Header `X-Tenant-Slug` (SPA, login, tests).
#   2. Subdominio (`micasita.iswocrm.com` → slug "micasita") o
#      `{tenant}.localhost` en dev/test si no hay header.
#
# Si no resuelve, responde 400 para evitar caer en `ActsAsTenant::NoTenantSet`
# más profundo con un mensaje poco útil.
# ----------------------------------------------------------------------------
module TenantResolver
  extend ActiveSupport::Concern

  RESERVED_SUBDOMAINS = %w[www api app admin].freeze

  included do
    before_action :resolve_tenant!
    around_action :scope_to_tenant
  end

  attr_reader :current_tenant

  private

  def resolve_tenant!
    slug = tenant_slug_from_header || tenant_slug_from_subdomain
    return render_tenant_missing if slug.blank?

    @current_tenant = Tenant.with_discarded.find_by(slug: slug)
    return render_tenant_not_found(slug) unless @current_tenant
    return render_tenant_inactive if !@current_tenant.active? || (@current_tenant.respond_to?(:discarded?) && @current_tenant.discarded?)
  end

  def tenant_slug_from_subdomain
    slug = request.subdomains.reject { |s| RESERVED_SUBDOMAINS.include?(s) }.first
    slug.presence || tenant_slug_from_localhost_host
  end

  # Dev/test: {tenant}.localhost no siempre aparece en request.subdomains.
  def tenant_slug_from_localhost_host
    host = request.host.to_s.downcase
    return nil unless host.end_with?(".localhost")

    label = host.delete_suffix(".localhost")
    return nil if label.blank? || label.include?(".")
    return nil if RESERVED_SUBDOMAINS.include?(label)

    label
  end

  def tenant_slug_from_header
    request.headers["X-Tenant-Slug"].to_s.strip.downcase.presence
  end

  def scope_to_tenant
    if @current_tenant
      ActsAsTenant.with_tenant(@current_tenant) { yield }
    else
      yield
    end
  end

  def render_tenant_inactive
    render json: {
      error: "tenant_inactive",
      message: "El tenant existe pero está inactivo"
    }, status: :forbidden
  end

  def render_tenant_not_found(slug)
    render json: {
      error:   "tenant_not_found",
      message: "No existe un tenant con slug «#{slug}». Revisa el identificador de empresa o ejecuta: bin/rails db:seed"
    }, status: :bad_request
  end
end
