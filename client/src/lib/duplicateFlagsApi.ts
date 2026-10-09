import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, type JsonApiResource } from '@/lib/opportunityApi'

export type ContactLite = {
  id: number
  full_name: string
  email?: string | null
  phone?: string | null
}

export type OpportunitySummary = {
  id: string
  contact_name: string
  owner_name?: string | null
  owner_id?: number | null
  created_at?: string | null
}

export interface DuplicateFlagRow {
  id: string
  matchedOn: string
  matchPercent: number
  resolution: string
  pending: boolean
  detectedAt?: string
  detectedByName?: string
  resolvedAt?: string | null
  resolvedByName?: string | null
  resolutionNote?: string | null
  contactNew: ContactLite | null
  contactExisting: ContactLite | null
  opportunityNew: OpportunitySummary | null
  opportunityExisting: OpportunitySummary | null
}

export type DuplicateFlagsListFilters = {
  resolution?: 'pending' | string
  page?: number
  items?: number
}

export type DuplicateFlagsPagination = {
  page: number
  pages: number
  count: number
  items: number
}

export type DuplicateFlagsListResult = {
  flags: DuplicateFlagRow[]
  pagination?: DuplicateFlagsPagination
}

export type DuplicateFlagsStats = {
  pending: number
  total: number
}

export type DuplicateScanResult = {
  scanned: number
  created: number
}

function parseContact(raw: unknown): ContactLite | null {
  if (!raw || typeof raw !== 'object') return null
  const o = raw as Record<string, unknown>
  const id = typeof o.id === 'number' ? o.id : Number(o.id)
  if (!Number.isFinite(id)) return null
  const full_name =
    typeof o.full_name === 'string' ? o.full_name : [o.first_name, o.last_name].filter(Boolean).join(' ')
  return {
    id,
    full_name: String(full_name || '').trim(),
    email: o.email != null ? String(o.email) : undefined,
    phone: o.phone != null ? String(o.phone) : undefined,
  }
}

function parseOpportunitySummary(raw: unknown, fallbackId: string): OpportunitySummary | null {
  if (!raw || typeof raw !== 'object') {
    return fallbackId ? { id: fallbackId, contact_name: `Oportunidad #${fallbackId}` } : null
  }
  const o = raw as Record<string, unknown>
  const id = o.id != null ? String(o.id) : fallbackId
  if (!id) return null
  return {
    id,
    contact_name: String(o.contact_name ?? o.title ?? `Oportunidad #${id}`),
    owner_name: o.owner_name != null ? String(o.owner_name) : null,
    owner_id: o.owner_id != null ? Number(o.owner_id) : null,
    created_at: o.created_at != null ? String(o.created_at) : null,
  }
}

export function mapDuplicateFlagResource(resource: JsonApiResource): DuplicateFlagRow | null {
  if (!resource.id) return null
  const a = resource.attributes ?? {}
  const rawScore = a.match_score
  const score =
    typeof rawScore === 'number'
      ? rawScore
      : typeof rawScore === 'string'
        ? parseFloat(rawScore)
        : NaN
  const matchPercent = Number.isFinite(score) ? Math.min(100, Math.round(score * 100)) : 0

  const oppNewId = a.opportunity_a_id != null ? String(a.opportunity_a_id) : ''
  const oppExId = a.opportunity_b_id != null ? String(a.opportunity_b_id) : ''

  return {
    id: String(resource.id),
    matchedOn: typeof a.matched_on === 'string' ? a.matched_on : '',
    matchPercent,
    resolution: typeof a.resolution === 'string' ? a.resolution : 'pending',
    pending: Boolean(a.pending),
    detectedAt: typeof a.created_at === 'string' ? a.created_at : undefined,
    detectedByName: typeof a.detected_by_name === 'string' ? a.detected_by_name : undefined,
    resolvedAt: a.resolved_at != null ? String(a.resolved_at) : null,
    resolvedByName: typeof a.resolved_by_name === 'string' ? a.resolved_by_name : undefined,
    resolutionNote: typeof a.resolution_note === 'string' ? a.resolution_note : null,
    contactNew: parseContact(a.contact_a),
    contactExisting: parseContact(a.contact_b),
    opportunityNew: parseOpportunitySummary(a.opportunity_a, oppNewId),
    opportunityExisting: parseOpportunitySummary(a.opportunity_b, oppExId),
  }
}

export function matchedOnLabel(m: string): string {
  switch (m) {
    case 'phone':
      return 'Coincidencia por teléfono'
    case 'email':
      return 'Coincidencia por email'
    case 'both':
      return 'Coincidencia por email y teléfono'
    default:
      return m || 'Coincidencia detectada'
  }
}

export async function fetchDuplicateFlagsList(
  filters: DuplicateFlagsListFilters,
): Promise<DuplicateFlagsListResult> {
  const params: Record<string, string | number> = {
    items: filters.items ?? 25,
    page: filters.page ?? 1,
  }
  if (filters.resolution) params.resolution = filters.resolution

  const response = await api.get('/duplicate_flags', { params })
  const flags = jsonApiPrimaryList(response.data)
    .map(mapDuplicateFlagResource)
    .filter((row): row is DuplicateFlagRow => row !== null)
  const pagination = (response.data as { meta?: { pagination?: DuplicateFlagsPagination } })?.meta
    ?.pagination

  return { flags, pagination }
}

export async function fetchDuplicateFlagsStats(): Promise<DuplicateFlagsStats> {
  const response = await api.get<{ data: DuplicateFlagsStats }>('/duplicate_flags/stats')
  const d = response.data.data
  return {
    pending: Number(d?.pending ?? 0),
    total: Number(d?.total ?? 0),
  }
}

export async function mergeDuplicateFlag(flagId: string): Promise<void> {
  await api.post(`/duplicate_flags/${flagId}/merge`, {})
}

/** Fusión masiva: las alertas elegidas o todas las pendientes (máx. 500 por vez). */
export async function bulkMergeDuplicateFlags(
  target: { ids: string[] } | { all: true },
): Promise<{ merged: number; skipped: { id: string; reason: string }[] }> {
  const res = await api.post('/duplicate_flags/bulk_merge', target)
  const d = (res.data as { data?: { merged?: number; skipped?: { id: string; reason: string }[] } }).data ?? {}
  return { merged: Number(d.merged ?? 0), skipped: d.skipped ?? [] }
}

export async function ignoreDuplicateFlag(flagId: string): Promise<void> {
  await api.post(`/duplicate_flags/${flagId}/ignore`, {})
}

export async function reassignDuplicateFlag(flagId: string, newOwnerUserId: string): Promise<void> {
  await api.post(`/duplicate_flags/${flagId}/reassign`, { new_owner_user_id: newOwnerUserId })
}

export async function scanDuplicateFlags(): Promise<DuplicateScanResult> {
  const response = await api.post<{ scanned: number; created: number }>('/duplicate_flags/scan', {})
  return {
    scanned: Number(response.data?.scanned ?? 0),
    created: Number(response.data?.created ?? 0),
  }
}

export function duplicateFlagsErrorMessage(err: unknown): string {
  return formatRailsError(err, 'No se pudieron cargar los duplicados')
}
