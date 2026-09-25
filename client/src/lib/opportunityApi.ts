import type { QueryClient } from '@tanstack/react-query'
import api, { formatRailsError } from '@/lib/api'
import { queryKeys } from '@/lib/queryClient'
import { isStageAutoTrigger } from '@/lib/opportunityVisuals'
import type {
  Opportunity,
  OpportunityStatus,
  LeadSource,
  LeadSourceKind,
  Pipeline,
  PipelineStage,
  User,
  UserRole,
} from '@/types'

/** JSON:API recurso genérico del backend */
export type JsonApiResource = {
  id: string
  type?: string
  attributes?: Record<string, unknown>
  relationships?: Record<string, { data: { id: string; type?: string } | null }>
}

/** Normaliza `response.data` de Axios (lista o un solo recurso). */
export function jsonApiPrimaryList(body: unknown): JsonApiResource[] {
  if (!body || typeof body !== 'object') return []
  const data = (body as { data?: unknown }).data
  if (data == null) return []
  if (Array.isArray(data)) return data as JsonApiResource[]
  return [data as JsonApiResource]
}

export function jsonApiPrimaryOne(body: unknown): JsonApiResource | null {
  const list = jsonApiPrimaryList(body)
  return list[0] ?? null
}

function normalizeOpportunityTemperature(value: unknown): import('@/types').OpportunityTemperature {
  const t = typeof value === 'string' ? value.toLowerCase() : ''
  if (t === 'hot' || t === 'warm' || t === 'cold') return t
  return 'cold'
}

/** Recursos JSON:API en `included` (p. ej. usuarios al incluir `owner_user`). */
export function jsonApiIncluded(body: unknown): JsonApiResource[] {
  if (!body || typeof body !== 'object') return []
  const inc = (body as { included?: unknown }).included
  if (!Array.isArray(inc)) return []
  return inc as JsonApiResource[]
}

/** Mapea un recurso JSON:API `user` a nuestro tipo de dominio. */
export function mapUserResource(resource: JsonApiResource): User {
  const a = resource.attributes ?? {}
  const fromParts = [a.first_name, a.last_name]
    .filter((x): x is string => typeof x === 'string' && x.length > 0)
    .join(' ')
  const fullName =
    (typeof a.full_name === 'string' && a.full_name.trim()) ||
    (typeof a.name === 'string' && a.name.trim()) ||
    fromParts ||
    String(a.email ?? '')
  const rawRole = typeof a.role === 'string' ? a.role : ''
  const role: UserRole =
    rawRole === 'admin' || rawRole === 'manager' || rawRole === 'consultant' || rawRole === 'viewer'
      ? rawRole
      : 'consultant'
  return {
    id: String(resource.id ?? ''),
    email: String(a.email ?? ''),
    name: fullName || String(a.email ?? ''),
    role,
    avatar_url: a.avatar_url != null && a.avatar_url !== '' ? String(a.avatar_url) : undefined,
    active: Boolean(a.active ?? true),
    last_sign_in_at: a.last_sign_in_at != null ? String(a.last_sign_in_at) : undefined,
    created_at: String(a.created_at ?? ''),
    updated_at: String(a.updated_at ?? ''),
  }
}

function normalizeEmbeddedStage(s: Record<string, unknown>, index: number): PipelineStage {
  const pos = Number(s.position)
  const prob = Number(s.probability)
  return {
    id: String(s.id ?? ''),
    pipeline_id: String(s.pipeline_id ?? ''),
    name: String(s.name ?? ''),
    position: Number.isFinite(pos) ? Math.floor(pos) : index,
    probability: Number.isFinite(prob) ? Math.min(100, Math.max(0, Math.floor(prob))) : 0,
    is_closed_won: Boolean(s.is_closed_won ?? s.closed_won),
    is_closed_lost: Boolean(s.is_closed_lost ?? s.closed_lost),
    color: s.color != null ? String(s.color) : undefined,
    auto_trigger: isStageAutoTrigger(s.auto_trigger) ? s.auto_trigger : null,
  }
}

export function mapPipelineResource(resource: JsonApiResource): Pipeline {
  const a = resource.attributes ?? {}
  const raw = (a.stages as Record<string, unknown>[] | undefined) ?? []
  const stages = raw.map((row, i) => normalizeEmbeddedStage(row, i))
  return {
    id: String(resource.id ?? ''),
    name: String(a.name ?? ''),
    description: a.description != null ? String(a.description) : undefined,
    is_default: Boolean(a.is_default),
    active: a.active !== false,
    stages,
    created_at: String(a.created_at ?? ''),
    updated_at: String(a.updated_at ?? ''),
  }
}

/** Convierte score BANT 0–100 del API a pasos 0–25 del slider del SPA. */
function bantDimScore01ToSlider(score01: unknown): number {
  const n = typeof score01 === 'number' ? score01 : Number(score01)
  if (!Number.isFinite(n)) return 0
  return Math.min(25, Math.max(0, Math.round((n * 25) / 100)))
}

function mapBantSlidersFromApi(a: Record<string, unknown>): {
  bant_budget: number
  bant_authority: number
  bant_need: number
  bant_timeline: number
} {
  const raw = a.bant_data
  const bd =
    raw != null && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {}

  // BantScorer escribe breakdown: { budget: 60, authority: 50, ... }
  // El input manual escribe { budget: { score: 60 }, ... }
  // Leemos ambos formatos; el manual tiene precedencia.
  const breakdown =
    bd.breakdown != null && typeof bd.breakdown === 'object' && !Array.isArray(bd.breakdown)
      ? (bd.breakdown as Record<string, unknown>)
      : {}

  const pick = (key: string) => {
    const block = bd[key]
    if (block != null && typeof block === 'object' && !Array.isArray(block)) {
      return bantDimScore01ToSlider((block as Record<string, unknown>).score)
    }
    // Fallback: formato breakdown del recálculo automático
    if (typeof breakdown[key] === 'number') {
      return bantDimScore01ToSlider(breakdown[key])
    }
    return 0
  }
  return {
    bant_budget: pick('budget'),
    bant_authority: pick('authority'),
    bant_need: pick('need'),
    bant_timeline: pick('timeline'),
  }
}

function resolveOpportunityOwner(
  resource: JsonApiResource,
  included: JsonApiResource[],
): User | undefined {
  const a = resource.attributes ?? {}
  const ownerAttr = a.owner as
    | { id?: string; name?: string; avatar_url?: string; email?: string }
    | undefined

  if (ownerAttr?.id) {
    return {
      id: String(ownerAttr.id),
      email: String(ownerAttr.email ?? ''),
      name: String(ownerAttr.name ?? ''),
      role: 'consultant',
      active: true,
      avatar_url: ownerAttr.avatar_url,
      created_at: '',
      updated_at: '',
    }
  }

  const rel = resource.relationships?.owner_user?.data as { id?: string; type?: string } | null
  const rid = rel?.id != null ? String(rel.id) : ''
  if (!rid) return undefined

  const inc = included.find(
    (r) =>
      String(r.id) === rid &&
      (r.type === 'user' || r.type === 'users' || String(r.type ?? '').toLowerCase() === 'user'),
  )
  if (inc) return mapUserResource(inc)

  return {
    id: rid,
    email: '',
    name: 'Usuario',
    role: 'consultant',
    active: true,
    created_at: '',
    updated_at: '',
  }
}

export function mapOpportunityResource(resource: JsonApiResource, included: JsonApiResource[] = []): Opportunity {
  const a = resource.attributes ?? {}
  const relStage   = resource.relationships?.pipeline_stage?.data as { id?: string } | null
  const relPipe    = resource.relationships?.pipeline?.data    as { id?: string } | null
  const relContact = resource.relationships?.contact?.data     as { id?: string } | null

  const stageId = String(a.pipeline_stage_id ?? relStage?.id ?? '')
  const pipelineId = String(a.pipeline_id ?? relPipe?.id ?? '')

  const owner = resolveOpportunityOwner(resource, included)

  const est = a.estimated_value
  let estimatedValue =
    typeof est === 'number' ? est : est != null ? Number(est) : 0
  if (!Number.isFinite(estimatedValue)) estimatedValue = 0

  const bs = a.bant_score
  let bantScore = typeof bs === 'number' ? bs : bs != null ? Number(bs) : 0
  if (!Number.isFinite(bantScore)) bantScore = 0

  const pos = a.stage_position
  const prob = a.probability
  const stagePosition = typeof pos === 'number' ? pos : pos != null ? Number(pos) : 0
  const probability = typeof prob === 'number' ? prob : prob != null ? Number(prob) : 0

  const stageName =
    typeof a.stage_name === 'string' && a.stage_name.trim() ? String(a.stage_name) : undefined

  const stage: PipelineStage | undefined =
    stageId && stageName
      ? {
          id: stageId,
          pipeline_id: pipelineId,
          name: stageName,
          position: Number.isFinite(stagePosition) ? Math.floor(stagePosition) : 0,
          probability: Number.isFinite(probability)
            ? Math.min(100, Math.max(0, Math.floor(probability)))
            : 0,
          is_closed_won: false,
          is_closed_lost: false,
        }
      : undefined

  const bantBars = mapBantSlidersFromApi(a)

  const relSource = resource.relationships?.lead_source?.data as { id?: string } | null
  const sourceId = relSource?.id != null ? String(relSource.id) : undefined
  const sourceInc = sourceId
    ? included.find((r) => String(r.id) === sourceId && String(r.type ?? '').toLowerCase() === 'lead_source')
    : undefined
  const source: LeadSource | undefined = sourceInc
    ? {
        id: String(sourceInc.id),
        name: String(sourceInc.attributes?.name ?? ''),
        kind: String(sourceInc.attributes?.kind ?? 'manual') as LeadSourceKind,
        active: Boolean(sourceInc.attributes?.active ?? true),
        opportunities_count: Number(sourceInc.attributes?.opportunities_count ?? 0),
        created_at: String(sourceInc.attributes?.created_at ?? ''),
      }
    : undefined

  const titleRaw = typeof a.title === 'string' ? a.title.trim() : ''

  return {
    id: String(resource.id ?? ''),
    title: titleRaw || undefined,
    contact_id: relContact?.id ? String(relContact.id) : undefined,
    contact_name: String(a.contact_name ?? titleRaw ?? 'Sin nombre'),
    contact_email: a.contact_email != null ? String(a.contact_email) : undefined,
    contact_phone: a.contact_phone != null ? String(a.contact_phone) : undefined,
    company_name: a.company_name != null ? String(a.company_name) : undefined,
    contact_city: a.contact_city != null ? String(a.contact_city) : undefined,
    contact_last_contacted_at:
      a.contact_last_contacted_at != null ? String(a.contact_last_contacted_at) : undefined,
    lead_source_label:
      (source?.name?.trim() ||
        (typeof a.lead_source_label === 'string' ? a.lead_source_label.trim() : '')) ||
      undefined,
    estimated_value: estimatedValue,
    currency: String(a.currency ?? 'COP'),
    stage_id: stageId,
    stage,
    pipeline_id: pipelineId,
    owner_id: owner?.id ?? '',
    owner,
    bant_budget: bantBars.bant_budget,
    bant_authority: bantBars.bant_authority,
    bant_need: bantBars.bant_need,
    bant_timeline: bantBars.bant_timeline,
    bant_score: bantScore,
    source_id: sourceId,
    source,
    status: (a.status as OpportunityStatus) ?? 'new_lead',
    temperature: normalizeOpportunityTemperature(a.temperature),
    qualified: a.qualified != null ? Boolean(a.qualified) : undefined,
    notes: a.notes != null ? String(a.notes) : undefined,
    last_activity_at: a.last_activity_at != null ? String(a.last_activity_at) : undefined,
    expected_close_on: a.expected_close_date != null ? String(a.expected_close_date) : undefined,
    reminder_due_at: a.reminder_due_at != null ? String(a.reminder_due_at) : undefined,
    custom_fields: a.custom_fields != null && typeof a.custom_fields === 'object'
      ? (a.custom_fields as Record<string, unknown>)
      : undefined,
    from_network: a.from_network === true,
    network_read_only: a.network_read_only === true,
    created_at: String(a.created_at ?? ''),
    updated_at: String(a.updated_at ?? ''),
  }
}

function normalizeOpportunityLogChanges(
  raw: unknown,
): import('@/types').OpportunityLog['changes_data'] {
  if (raw == null || typeof raw !== 'object' || Array.isArray(raw)) return undefined
  const out: Record<string, { from: unknown; to: unknown }> = {}
  for (const [key, val] of Object.entries(raw as Record<string, unknown>)) {
    if (val != null && typeof val === 'object' && !Array.isArray(val)) {
      const entry = val as Record<string, unknown>
      out[key] = { from: entry.from ?? null, to: entry.to ?? null }
    }
  }
  return Object.keys(out).length > 0 ? out : undefined
}

/** Mapea un recurso JSON:API `opportunity_log` a nuestro tipo de dominio. */
export function mapOpportunityLogResource(
  resource: JsonApiResource,
  included: JsonApiResource[] = [],
): import('@/types').OpportunityLog {
  const a = resource.attributes ?? {}
  const rel = resource.relationships?.user?.data as { id?: string; type?: string } | null
  const userId = rel?.id ? String(rel.id) : ''
  const userInc = userId
    ? included.find(
        (r) =>
          String(r.id) === userId &&
          (r.type === 'user' || r.type === 'users'),
      )
    : undefined

  const changes_data = normalizeOpportunityLogChanges(a.changes_data)

  return {
    id: String(resource.id ?? ''),
    action: String(a.action ?? ''),
    changes_data,
    note: a.note != null && a.note !== '' ? String(a.note) : undefined,
    author_name: a.author_name != null ? String(a.author_name) : undefined,
    user: userInc ? mapUserResource(userInc) : undefined,
    created_at: String(a.created_at ?? ''),
  }
}

/** PATCH /opportunities/:id — solo claves que el API permite */
export function toOpportunityUpdatePayload(
  patch: Partial<Opportunity> & {
    bant_data?: Record<string, { score?: number; answer?: string } | unknown>
  },
): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  if (patch.notes !== undefined) out.notes = patch.notes
  if (patch.estimated_value !== undefined) out.estimated_value = patch.estimated_value
  if (patch.status !== undefined) out.status = patch.status
  if (patch.temperature !== undefined) out.temperature = patch.temperature
  if (patch.qualified !== undefined) out.qualified = patch.qualified
  if (patch.stage_id !== undefined) out.pipeline_stage_id = patch.stage_id
  if (patch.source_id !== undefined) out.lead_source_id = patch.source_id || null
  if (patch.expected_close_on !== undefined) out.expected_close_date = patch.expected_close_on || null
  if (patch.bant_score !== undefined) out.bant_score = patch.bant_score
  if (patch.bant_data !== undefined) out.bant_data = patch.bant_data
  if (patch.custom_fields !== undefined) out.custom_fields = patch.custom_fields
  return out
}

/** Filtros GET /api/v1/opportunities (RFC F1 + extensiones UI) */
export interface OpportunityListFilters {
  pipeline_id?: string
  stage_id?: string
  contact_id?: string
  landing_page_id?: string
  owner_id?: string
  status?: string
  temperature?: string
  q?: string
  stale_days?: number
}

const OPPORTUNITY_LIST_PAGE_SIZE = 200

export function buildOpportunityListParams(filters: OpportunityListFilters): URLSearchParams {
  const params = new URLSearchParams()
  params.set('items', String(OPPORTUNITY_LIST_PAGE_SIZE))

  if (filters.contact_id) {
    params.set('contact_id', filters.contact_id)
    return params
  }
  if (filters.landing_page_id) {
    params.set('landing_page_id', filters.landing_page_id)
    return params
  }
  if (filters.pipeline_id) params.set('pipeline_id', filters.pipeline_id)
  if (filters.stage_id) params.set('stage_id', filters.stage_id)
  if (filters.owner_id) params.set('owner_id', filters.owner_id)
  if (filters.status) params.set('status', filters.status)
  if (filters.temperature) params.set('temperature', filters.temperature)
  if (filters.q && filters.q.length >= 2) params.set('q', filters.q)
  if (filters.stale_days != null && filters.stale_days > 0) {
    params.set('stale_days', String(filters.stale_days))
  }
  return params
}

export async function fetchOpportunities(
  filters: OpportunityListFilters,
): Promise<Opportunity[]> {
  const params = buildOpportunityListParams(filters)
  const response = await api.get(`/opportunities?${params.toString()}`)
  const rows = jsonApiPrimaryList(response.data)
  const included = jsonApiIncluded(response.data)
  return rows
    .filter((r) => r.id)
    .map((r) => mapOpportunityResource(r, included))
    .filter((o) => o.id.length > 0)
}

export async function fetchOpportunityDetail(id: string): Promise<Opportunity> {
  const response = await api.get(`/opportunities/${id}`, {
    params: { include: 'owner_user,lead_source,contact' },
  })
  const row = jsonApiPrimaryOne(response.data)
  if (!row?.id) throw new Error('Oportunidad no encontrada')
  return mapOpportunityResource(row, jsonApiIncluded(response.data))
}

/** Actualiza detalle y listas en caché tras PATCH (p. ej. temperatura). */
export function upsertOpportunityInQueryCache(
  queryClient: QueryClient,
  opportunity: Opportunity,
): void {
  if (!opportunity.id) return
  queryClient.setQueryData(queryKeys.opportunities.detail(opportunity.id), opportunity)
  queryClient.setQueriesData<Opportunity[]>(
    {
      queryKey: queryKeys.opportunities.all,
      predicate: (query) => query.queryKey[1] === 'list',
    },
    (old) => {
      if (!old?.length) return old
      const idx = old.findIndex((o) => o.id === opportunity.id)
      if (idx < 0) return old
      const next = [...old]
      next[idx] = opportunity
      return next
    },
  )
}

export async function moveOpportunityStage(
  opportunityId: string,
  pipelineStageId: string,
): Promise<void> {
  await api.post(
    `/opportunities/${opportunityId}/move_stage`,
    JSON.stringify({ pipeline_stage_id: pipelineStageId }),
    { headers: { 'Content-Type': 'application/json' } },
  )
}

export async function assignOpportunityOwner(
  opportunityId: string,
  ownerUserId: string,
): Promise<void> {
  await api.post(
    `/opportunities/${opportunityId}/assign`,
    JSON.stringify({ owner_user_id: ownerUserId }),
    { headers: { 'Content-Type': 'application/json' } },
  )
}

export interface RecalculateBantResult {
  bant_score?: number
  qualified?: boolean
  temperature_ai?: {
    ai_used?: boolean
    temperature?: string
    reasoning?: string
  }
}

export async function recalculateOpportunityBant(
  opportunityId: string,
): Promise<RecalculateBantResult> {
  const response = await api.post(`/opportunities/${opportunityId}/recalculate_bant`)
  const data = response.data?.data
  const attrs = data?.attributes ?? {}
  const meta = response.data?.meta ?? {}
  return {
    bant_score: typeof attrs.bant_score === 'number' ? attrs.bant_score : Number(attrs.bant_score),
    qualified: attrs.qualified != null ? Boolean(attrs.qualified) : undefined,
    temperature_ai: meta.temperature_ai,
  }
}

export type OpportunityExportFormat = 'csv' | 'xlsx'

/** Filtros Ransack para export (alineado con /exports) */
const DATE_RANGE_DAYS: Record<string, number> = {
  week: 7, month: 30, quarter: 90, year: 365,
}

export function buildOpportunityExportFilters(filters: {
  pipeline_id?: string
  stage_id?: string
  owner_id?: string
  temperature?: string
  status?: string
  date_range?: string
  source_id?: string
  stale_days?: number
  q?: string
}): Record<string, string> {
  const out: Record<string, string> = {}
  if (filters.pipeline_id) out.pipeline_id_eq = filters.pipeline_id
  if (filters.stage_id) out.pipeline_stage_id_eq = filters.stage_id
  if (filters.owner_id) out.owner_user_id_eq = filters.owner_id
  if (filters.temperature) out.temperature_eq = filters.temperature
  if (filters.status) out.status_eq = filters.status
  if (filters.source_id) out.lead_source_id_eq = filters.source_id
  const days = filters.date_range ? (DATE_RANGE_DAYS[filters.date_range] ?? 0) : 0
  if (days > 0) {
    out.updated_at_gteq = new Date(Date.now() - days * 86_400_000).toISOString()
  }
  if (filters.stale_days != null && filters.stale_days > 0) {
    out.last_activity_at_lteq = new Date(
      Date.now() - filters.stale_days * 86_400_000,
    ).toISOString()
  }
  const q = filters.q?.trim()
  if (q && q.length >= 2) {
    out.title_or_contact_first_name_or_contact_last_name_or_contact_company_name_or_contact_email_or_contact_phone_e164_or_contact_phone_normalized_cont =
      q
  }
  return out
}

export async function downloadOpportunitiesExport(
  format: OpportunityExportFormat,
  filters: Record<string, string>,
): Promise<Blob> {
  const response = await api.get(`/opportunities/export.${format}`, {
    params: { filters },
    responseType: 'blob',
  })
  return response.data as Blob
}

export async function enqueueOpportunitiesExport(
  format: OpportunityExportFormat,
  filters: Record<string, string>,
): Promise<void> {
  await api.post('/exports', {
    resource: 'opportunities',
    export_format: format,
    filters,
  })
}

export function triggerBlobDownload(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  URL.revokeObjectURL(url)
}

export async function bulkDeleteOpportunities(ids: string[]): Promise<{ deleted: number }> {
  const response = await api.delete('/opportunities/bulk_destroy', { data: { ids } })
  return (response.data as { data: { deleted: number } }).data
}

export function opportunityListErrorMessage(err: unknown): string {
  return formatRailsError(err, 'Error al cargar oportunidades')
}
