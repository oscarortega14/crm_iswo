import { describe, it, expect } from 'vitest'
import { buildContactListParams, mapContactResource } from '@/lib/contactApi'
import type { JsonApiResource } from '@/lib/opportunityApi'

function makeContactResource(attrs: Record<string, unknown> = {}): JsonApiResource {
  return {
    id: '10',
    type: 'contact',
    attributes: {
      kind: 'person',
      first_name: 'Carlos',
      last_name: 'Mendoza',
      email: 'carlos@email.co',
      phone_display: '+57 300 123 4567',
      phone_e164: '+573001234567',
      opportunities_count: 3,
      ...attrs,
    },
    relationships: {},
  }
}

describe('mapContactResource', () => {
  it('mapea campos básicos', () => {
    const contact = mapContactResource(makeContactResource())
    expect(contact.id).toBe('10')
    expect(contact.firstName).toBe('Carlos')
    expect(contact.lastName).toBe('Mendoza')
    expect(contact.email).toBe('carlos@email.co')
    expect(contact.phone).toBe('+57 300 123 4567')
    expect(contact.opportunitiesCount).toBe(3)
    expect(contact.kind).toBe('person')
  })

  it('usa full_name si está disponible', () => {
    const contact = mapContactResource(
      makeContactResource({ full_name: 'Carlos Alberto Mendoza' })
    )
    expect(contact.fullName).toBe('Carlos Alberto Mendoza')
  })

  it('construye fullName desde first_name + last_name cuando no hay full_name', () => {
    const contact = mapContactResource(makeContactResource())
    expect(contact.fullName).toBe('Carlos Mendoza')
  })

  it('usa email como fullName cuando no hay nombre', () => {
    const contact = mapContactResource(
      makeContactResource({ first_name: null, last_name: null, full_name: null })
    )
    expect(contact.fullName).toBe('carlos@email.co')
  })

  it('usa Sin nombre como fallback absoluto', () => {
    const contact = mapContactResource(
      makeContactResource({ first_name: null, last_name: null, full_name: null, email: null })
    )
    expect(contact.fullName).toBe('Sin nombre')
  })

  it('usa phone_e164 como fallback si no hay phone_display', () => {
    const contact = mapContactResource(
      makeContactResource({ phone_display: null })
    )
    expect(contact.phone).toBe('+573001234567')
  })

  it('devuelve - para teléfono si no hay ninguno', () => {
    const contact = mapContactResource(
      makeContactResource({ phone_display: null, phone_e164: null })
    )
    expect(contact.phone).toBe('-')
  })

  it('mapea kind company', () => {
    const contact = mapContactResource(makeContactResource({ kind: 'company' }))
    expect(contact.kind).toBe('company')
  })

  it('mapea custom_fields', () => {
    const contact = mapContactResource(
      makeContactResource({ custom_fields: { empleador: 'EPM', nit: '9002345' } })
    )
    expect(contact.customFields).toEqual({ empleador: 'EPM', nit: '9002345' })
  })

  it('mapea ownerId desde relationships', () => {
    const resource = makeContactResource()
    resource.relationships = { owner_user: { data: { id: '7', type: 'user' } } }
    const contact = mapContactResource(resource)
    expect(contact.ownerId).toBe('7')
  })

  it('ownerId es undefined cuando no hay relación owner', () => {
    const contact = mapContactResource(makeContactResource())
    expect(contact.ownerId).toBeUndefined()
  })

  it('opportunitiesCount es 0 por defecto', () => {
    const contact = mapContactResource(
      makeContactResource({ opportunities_count: undefined })
    )
    expect(contact.opportunitiesCount).toBe(0)
  })
})

describe('buildContactListParams', () => {
  it('envía whatsapp_consent cuando hay filtro de consentimiento', () => {
    expect(buildContactListParams({ kind: 'person', whatsapp_consent: 'opted_out' })).toEqual({
      kind: 'person',
      whatsapp_consent: 'opted_out',
    })
  })

  it('omite whatsapp_consent sin filtro', () => {
    expect(buildContactListParams({ kind: 'person' })).not.toHaveProperty('whatsapp_consent')
  })
})

describe('mapContactResource — confirmación de WhatsApp', () => {
  it('mapea la fuente y la fecha del opt-in confirmado', () => {
    const contact = mapContactResource(
      makeContactResource({
        whatsapp_opted_in: true,
        whatsapp_opt_in_source: 'reply_confirm',
        whatsapp_opt_in_at: '2026-09-23T15:00:00Z',
      }),
    )
    expect(contact.whatsappOptInSource).toBe('reply_confirm')
    expect(contact.whatsappOptInAt).toBe('2026-09-23T15:00:00Z')
  })
})
