import { describe, it, expect } from 'vitest'
import {
  jsonApiPrimaryList,
  jsonApiPrimaryOne,
  jsonApiIncluded,
  mapUserResource,
  mapPipelineResource,
  mapOpportunityResource,
  toOpportunityUpdatePayload,
  buildOpportunityListParams,
  buildOpportunityExportFilters,
  type JsonApiResource,
} from '@/lib/opportunityApi'

// ─── Fixtures ────────────────────────────────────────────────────────────────

function makeOpportunityResource(attrs: Record<string, unknown> = {}): JsonApiResource {
  return {
    id: '42',
    type: 'opportunity',
    attributes: {
      contact_name: 'Laura Gómez',
      estimated_value: 5000000,
      currency: 'COP',
      status: 'new_lead',
      temperature: 'warm',
      bant_score: 60,
      pipeline_id: '1',
      pipeline_stage_id: '10',
      stage_name: 'Nueva',
      stage_position: 0,
      probability: 20,
      created_at: '2026-05-01T00:00:00Z',
      updated_at: '2026-05-15T00:00:00Z',
      ...attrs,
    },
    relationships: {},
  }
}

// ─── jsonApiPrimaryList ───────────────────────────────────────────────────────
describe('jsonApiPrimaryList', () => {
  it('devuelve array cuando data es array', () => {
    const body = { data: [{ id: '1' }, { id: '2' }] }
    expect(jsonApiPrimaryList(body)).toHaveLength(2)
  })

  it('envuelve en array cuando data es objeto único', () => {
    const body = { data: { id: '1' } }
    expect(jsonApiPrimaryList(body)).toHaveLength(1)
  })

  it('devuelve array vacío para null/undefined', () => {
    expect(jsonApiPrimaryList(null)).toEqual([])
    expect(jsonApiPrimaryList(undefined)).toEqual([])
    expect(jsonApiPrimaryList({})).toEqual([])
  })
})

// ─── jsonApiPrimaryOne ────────────────────────────────────────────────────────
describe('jsonApiPrimaryOne', () => {
  it('devuelve el primer recurso', () => {
    const body = { data: { id: '99' } }
    expect(jsonApiPrimaryOne(body)?.id).toBe('99')
  })

  it('devuelve null para body vacío', () => {
    expect(jsonApiPrimaryOne({})).toBeNull()
  })
})

// ─── jsonApiIncluded ──────────────────────────────────────────────────────────
describe('jsonApiIncluded', () => {
  it('devuelve recursos del included', () => {
    const body = { included: [{ id: '5', type: 'user' }] }
    expect(jsonApiIncluded(body)).toHaveLength(1)
  })

  it('devuelve array vacío cuando no hay included', () => {
    expect(jsonApiIncluded({})).toEqual([])
    expect(jsonApiIncluded({ included: 'not-array' })).toEqual([])
  })
})

// ─── mapUserResource ──────────────────────────────────────────────────────────
describe('mapUserResource', () => {
  it('construye nombre desde first_name + last_name', () => {
    const resource: JsonApiResource = {
      id: '1',
      type: 'user',
      attributes: { first_name: 'Ana', last_name: 'Torres', email: 'ana@iswo.co', role: 'consultant', active: true, created_at: '', updated_at: '' },
    }
    const user = mapUserResource(resource)
    expect(user.name).toBe('Ana Torres')
    expect(user.email).toBe('ana@iswo.co')
    expect(user.role).toBe('consultant')
  })

  it('cae back a email como nombre si no hay nombre', () => {
    const resource: JsonApiResource = {
      id: '2',
      type: 'user',
      attributes: { email: 'solo@email.co', role: 'admin', created_at: '', updated_at: '' },
    }
    const user = mapUserResource(resource)
    expect(user.name).toBe('solo@email.co')
  })

  it('normaliza roles inválidos a consultant', () => {
    const resource: JsonApiResource = {
      id: '3',
      type: 'user',
      attributes: { email: 'x@x.co', role: 'superuser', created_at: '', updated_at: '' },
    }
    expect(mapUserResource(resource).role).toBe('consultant')
  })
})

// ─── mapPipelineResource ──────────────────────────────────────────────────────
describe('mapPipelineResource', () => {
  it('mapea pipeline con etapas', () => {
    const resource: JsonApiResource = {
      id: '5',
      type: 'pipeline',
      attributes: {
        name: 'Principal',
        is_default: true,
        active: true,
        stages: [
          { id: '10', name: 'Nueva', position: 0, probability: 10, pipeline_id: '5' },
          { id: '11', name: 'Calificada', position: 1, probability: 50, pipeline_id: '5', is_closed_won: false, is_closed_lost: false },
        ],
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      },
    }
    const pipeline = mapPipelineResource(resource)
    expect(pipeline.name).toBe('Principal')
    expect(pipeline.is_default).toBe(true)
    expect(pipeline.stages).toHaveLength(2)
    expect(pipeline.stages[1].name).toBe('Calificada')
  })

  it('mapea auto_trigger válido y descarta valores desconocidos', () => {
    const resource: JsonApiResource = {
      id: '7',
      type: 'pipeline',
      attributes: {
        name: 'Auto',
        stages: [
          { id: '30', name: 'Nueva', position: 0, auto_trigger: null },
          { id: '31', name: 'Contactada', position: 1, auto_trigger: 'whatsapp_outbound' },
          { id: '32', name: 'Rara', position: 2, auto_trigger: 'magia' },
        ],
      },
    }
    const stages = mapPipelineResource(resource).stages
    expect(stages.map((s) => s.auto_trigger)).toEqual([null, 'whatsapp_outbound', null])
  })

  it('clampea probabilidad a 0–100', () => {
    const resource: JsonApiResource = {
      id: '6',
      type: 'pipeline',
      attributes: {
        name: 'Test',
        stages: [{ id: '20', name: 'X', position: 0, probability: 150, pipeline_id: '6' }],
        created_at: '',
        updated_at: '',
      },
    }
    const pipeline = mapPipelineResource(resource)
    expect(pipeline.stages[0].probability).toBe(100)
  })
})

// ─── mapOpportunityResource ───────────────────────────────────────────────────
describe('mapOpportunityResource', () => {
  it('mapea campos básicos correctamente', () => {
    const opp = mapOpportunityResource(makeOpportunityResource())
    expect(opp.id).toBe('42')
    expect(opp.contact_name).toBe('Laura Gómez')
    expect(opp.estimated_value).toBe(5000000)
    expect(opp.status).toBe('new_lead')
    expect(opp.temperature).toBe('warm')
  })

  it('normaliza estimated_value a 0 para valores inválidos', () => {
    const opp = mapOpportunityResource(makeOpportunityResource({ estimated_value: 'no-es-numero' }))
    expect(opp.estimated_value).toBe(0)
  })

  it('usa cold como temperature por defecto', () => {
    const opp = mapOpportunityResource(makeOpportunityResource({ temperature: null }))
    expect(opp.temperature).toBe('cold')
  })

  // ── Regresión: bug expected_close_date ──────────────────────────────────────
  it('lee expected_close_on desde el campo expected_close_date del API', () => {
    const opp = mapOpportunityResource(
      makeOpportunityResource({ expected_close_date: '2026-12-31' })
    )
    expect(opp.expected_close_on).toBe('2026-12-31')
  })

  it('expected_close_on es undefined cuando la API no lo envía', () => {
    const opp = mapOpportunityResource(makeOpportunityResource())
    expect(opp.expected_close_on).toBeUndefined()
  })

  it('expected_close_on es undefined si el API envía null', () => {
    const opp = mapOpportunityResource(
      makeOpportunityResource({ expected_close_date: null })
    )
    expect(opp.expected_close_on).toBeUndefined()
  })
  // ─────────────────────────────────────────────────────────────────────────────

  it('mapea BANT desde formato breakdown del BantScorer', () => {
    const opp = mapOpportunityResource(
      makeOpportunityResource({
        bant_data: { breakdown: { budget: 100, authority: 50, need: 0, timeline: 75 } },
      })
    )
    expect(opp.bant_budget).toBe(25)   // 100 → slider 25
    expect(opp.bant_authority).toBe(13) // 50 → slider ~13
    expect(opp.bant_need).toBe(0)
    expect(opp.bant_timeline).toBe(19) // 75 → slider ~19
  })

  it('mapea BANT desde formato input manual { budget: { score } }', () => {
    const opp = mapOpportunityResource(
      makeOpportunityResource({
        bant_data: {
          budget:    { score: 100, answer: 'Sí' },
          authority: { score: 0 },
          need:      { score: 50 },
          timeline:  { score: 25 },
        },
      })
    )
    expect(opp.bant_budget).toBe(25)
    expect(opp.bant_authority).toBe(0)
    expect(opp.bant_need).toBe(13)
    expect(opp.bant_timeline).toBe(6)
  })

  it('resuelve owner desde atributo embebido', () => {
    const resource = makeOpportunityResource({
      owner: { id: '7', name: 'Pedro Ruiz', email: 'pedro@iswo.co', avatar_url: null },
    })
    const opp = mapOpportunityResource(resource)
    expect(opp.owner?.id).toBe('7')
    expect(opp.owner?.name).toBe('Pedro Ruiz')
  })

  it('resuelve owner desde included cuando no hay atributo embebido', () => {
    const resource = makeOpportunityResource()
    resource.relationships = { owner_user: { data: { id: '9', type: 'user' } } }
    const included: JsonApiResource[] = [
      {
        id: '9',
        type: 'user',
        attributes: { first_name: 'María', last_name: 'López', email: 'm@iswo.co', role: 'manager', active: true, created_at: '', updated_at: '' },
      },
    ]
    const opp = mapOpportunityResource(resource, included)
    expect(opp.owner?.name).toBe('María López')
  })

  it('mapea custom_fields cuando es objeto', () => {
    const opp = mapOpportunityResource(
      makeOpportunityResource({ custom_fields: { nit: '123456', plazo: '24 meses' } })
    )
    expect(opp.custom_fields).toEqual({ nit: '123456', plazo: '24 meses' })
  })

  it('custom_fields es undefined cuando no viene en la respuesta', () => {
    const opp = mapOpportunityResource(makeOpportunityResource())
    expect(opp.custom_fields).toBeUndefined()
  })
})

// ─── toOpportunityUpdatePayload ───────────────────────────────────────────────
describe('toOpportunityUpdatePayload', () => {
  it('no incluye claves no provistas', () => {
    const payload = toOpportunityUpdatePayload({ notes: 'Hola' })
    expect(Object.keys(payload)).toEqual(['notes'])
  })

  it('mapea stage_id → pipeline_stage_id', () => {
    const payload = toOpportunityUpdatePayload({ stage_id: '99' })
    expect(payload.pipeline_stage_id).toBe('99')
    expect(payload.stage_id).toBeUndefined()
  })

  it('mapea source_id → lead_source_id', () => {
    const payload = toOpportunityUpdatePayload({ source_id: '5' })
    expect(payload.lead_source_id).toBe('5')
  })

  it('source_id vacío se convierte en null', () => {
    const payload = toOpportunityUpdatePayload({ source_id: '' })
    expect(payload.lead_source_id).toBeNull()
  })

  // ── Regresión: bug expected_close_date ──────────────────────────────────────
  it('envía expected_close_date (no expected_close_on) al API', () => {
    const payload = toOpportunityUpdatePayload({ expected_close_on: '2026-12-31' })
    expect(payload.expected_close_date).toBe('2026-12-31')
    expect(payload.expected_close_on).toBeUndefined()
  })

  it('expected_close_on vacío se convierte en null en el payload', () => {
    const payload = toOpportunityUpdatePayload({ expected_close_on: '' })
    expect(payload.expected_close_date).toBeNull()
  })
  // ─────────────────────────────────────────────────────────────────────────────

  it('incluye todos los campos cuando se proveen', () => {
    const payload = toOpportunityUpdatePayload({
      notes: 'nota',
      estimated_value: 1000,
      status: 'contacted',
      temperature: 'hot',
      qualified: true,
    })
    expect(payload.notes).toBe('nota')
    expect(payload.estimated_value).toBe(1000)
    expect(payload.status).toBe('contacted')
    expect(payload.temperature).toBe('hot')
    expect(payload.qualified).toBe(true)
  })
})

// ─── buildOpportunityListParams ───────────────────────────────────────────────
describe('buildOpportunityListParams', () => {
  it('con contact_id devuelve solo ese filtro (y paginación amplia)', () => {
    const params = buildOpportunityListParams({ contact_id: '5', status: 'won' })
    expect(params.get('contact_id')).toBe('5')
    expect(params.get('items')).toBe('200')
    expect(params.has('status')).toBe(false)
  })

  it('construye parámetros de búsqueda general', () => {
    const params = buildOpportunityListParams({ pipeline_id: '1', status: 'new_lead', q: 'juan' })
    expect(params.get('pipeline_id')).toBe('1')
    expect(params.get('status')).toBe('new_lead')
    expect(params.get('q')).toBe('juan')
  })

  it('omite q si tiene menos de 2 caracteres', () => {
    const params = buildOpportunityListParams({ q: 'a' })
    expect(params.has('q')).toBe(false)
  })

  it('incluye stale_days si es mayor a 0', () => {
    const params = buildOpportunityListParams({ stale_days: 7 })
    expect(params.get('stale_days')).toBe('7')
  })
})

// ─── buildOpportunityExportFilters ─────────────────────────────────────────────
describe('buildOpportunityExportFilters', () => {
  it('mapea filtros de pantalla a claves Ransack', () => {
    const filters = buildOpportunityExportFilters({
      pipeline_id: '1',
      stage_id: '10',
      owner_id: '3',
      temperature: 'hot',
      status: 'qualified',
      stale_days: 7,
      q: 'juan',
    })
    expect(filters.pipeline_id_eq).toBe('1')
    expect(filters.pipeline_stage_id_eq).toBe('10')
    expect(filters.owner_user_id_eq).toBe('3')
    expect(filters.temperature_eq).toBe('hot')
    expect(filters.status_eq).toBe('qualified')
    expect(filters.last_activity_at_lteq).toBeDefined()
    expect(
      filters.title_or_contact_first_name_or_contact_last_name_or_contact_company_name_or_contact_email_or_contact_phone_e164_or_contact_phone_normalized_cont,
    ).toBe('juan')
  })

  it('omite q con menos de 2 caracteres', () => {
    const filters = buildOpportunityExportFilters({ q: 'a' })
    expect(
      filters.title_or_contact_first_name_or_contact_last_name_or_contact_company_name_or_contact_email_or_contact_phone_e164_or_contact_phone_normalized_cont,
    ).toBeUndefined()
  })
})
