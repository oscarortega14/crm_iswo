/**
 * URLs públicas de landing pages — alineadas con RFC (subdominio + slug).
 *
 * Producción: https://{tenant}.iswocrm.com/{slug}
 * Dev:        http://{tenant}.localhost:{port}/{slug}
 * Fallback:   /l/{slug}?tenant={tenant} (localhost plano sin subdominio)
 */

const RESERVED_HOST_LABELS = new Set(['www', 'app', 'api', 'admin'])

/** Tenant inferido solo del hostname (no localStorage). */
export function getTenantFromHostname(): string {
  if (typeof window === 'undefined') return ''

  const hostname = window.location.hostname.toLowerCase()

  if (hostname === 'localhost' || hostname === '127.0.0.1') return ''

  if (hostname.endsWith('.localhost') || hostname.endsWith('.lvh.me')) {
    const label = hostname.split('.')[0]
    return label && !RESERVED_HOST_LABELS.has(label) ? label : ''
  }

  const parts = hostname.split('.')
  if (parts.length >= 3) {
    const label = parts[0]
    if (label && !RESERVED_HOST_LABELS.has(label)) return label
  }

  return ''
}

export function landingDevPort(): string {
  return import.meta.env.VITE_FRONTEND_PORT?.trim() || window.location.port || '3001'
}

export function buildLandingPublicUrl(tenantSlug: string, landingSlug: string): string {
  const override = import.meta.env.VITE_LANDING_PUBLIC_HOST?.trim()
  if (override) {
    return `${override.replace(/\/$/, '')}/${landingSlug}`
  }

  if (import.meta.env.PROD) {
    return `https://${tenantSlug}.iswocrm.com/${landingSlug}`
  }

  return `http://${tenantSlug}.localhost:${landingDevPort()}/${landingSlug}`
}

export function buildLandingDevFallbackUrl(tenantSlug: string, landingSlug: string): string {
  const origin = typeof window !== 'undefined' ? window.location.origin : 'http://localhost:3001'
  return `${origin}/l/${landingSlug}?tenant=${encodeURIComponent(tenantSlug)}`
}

/** URL a mostrar/copiar en admin — subdominio en dev, fallback si no hay tenant. */
export function resolveLandingPublicUrl(
  tenantSlug: string,
  landingSlug: string,
  apiPublicUrl?: string
): string {
  if (apiPublicUrl?.startsWith('http')) return apiPublicUrl
  if (tenantSlug) return buildLandingPublicUrl(tenantSlug, landingSlug)
  return buildLandingDevFallbackUrl('iswo', landingSlug)
}
