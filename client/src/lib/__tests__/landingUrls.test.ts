import { describe, it, expect, afterEach } from 'vitest'
import {
  getTenantFromHostname,
  buildLandingPublicUrl,
  buildLandingDevFallbackUrl,
  resolveLandingPublicUrl,
} from '@/lib/landingUrls'

// ─── getTenantFromHostname ───────────────────────────────────────────────────
describe('getTenantFromHostname', () => {
  const originalLocation = window.location

  function mockHostname(hostname: string) {
    Object.defineProperty(window, 'location', {
      value: { ...originalLocation, hostname },
      writable: true,
      configurable: true,
    })
  }

  afterEach(() => {
    Object.defineProperty(window, 'location', {
      value: originalLocation,
      writable: true,
      configurable: true,
    })
  })

  it('devuelve vacío para localhost', () => {
    mockHostname('localhost')
    expect(getTenantFromHostname()).toBe('')
  })

  it('extrae tenant de subdominio .localhost', () => {
    mockHostname('micasita.localhost')
    expect(getTenantFromHostname()).toBe('micasita')
  })

  it('ignora labels reservados', () => {
    mockHostname('www.localhost')
    expect(getTenantFromHostname()).toBe('')
    mockHostname('api.localhost')
    expect(getTenantFromHostname()).toBe('')
  })

  it('extrae tenant de subdominio de producción', () => {
    mockHostname('libranzas.iswocrm.com')
    expect(getTenantFromHostname()).toBe('libranzas')
  })

  it('devuelve vacío para el apex sin subdominio de tenant', () => {
    mockHostname('iswocrm.com')
    expect(getTenantFromHostname()).toBe('')
  })
})

// ─── buildLandingPublicUrl ───────────────────────────────────────────────────
describe('buildLandingPublicUrl', () => {
  it('genera URL de dev por defecto', () => {
    const url = buildLandingPublicUrl('micasita', 'solicitud-credito')
    expect(url).toMatch(/micasita\.localhost/)
    expect(url).toContain('/solicitud-credito')
  })
})

// ─── buildLandingDevFallbackUrl ──────────────────────────────────────────────
describe('buildLandingDevFallbackUrl', () => {
  it('genera URL fallback con parámetro tenant', () => {
    const url = buildLandingDevFallbackUrl('iswo', 'contacto')
    expect(url).toContain('/l/contacto')
    expect(url).toContain('tenant=iswo')
  })
})

// ─── resolveLandingPublicUrl ─────────────────────────────────────────────────
describe('resolveLandingPublicUrl', () => {
  it('usa apiPublicUrl si comienza con http', () => {
    const url = resolveLandingPublicUrl('tenant', 'slug', 'https://mi-dominio.com/slug')
    expect(url).toBe('https://mi-dominio.com/slug')
  })

  it('usa buildLandingPublicUrl cuando no hay apiPublicUrl pero hay tenantSlug', () => {
    const url = resolveLandingPublicUrl('micasita', 'formulario')
    expect(url).toContain('micasita')
    expect(url).toContain('formulario')
  })

  it('usa fallback iswo cuando no hay tenantSlug', () => {
    const url = resolveLandingPublicUrl('', 'formulario')
    expect(url).toContain('formulario')
  })
})
