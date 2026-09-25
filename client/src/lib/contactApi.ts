import type { QueryClient } from '@tanstack/react-query'
import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, jsonApiPrimaryOne, type JsonApiResource } from '@/lib/opportunityApi'
import { queryKeys } from '@/lib/queryClient'

export type ContactKind = 'person' | 'company'

/** Segmentos de métricas rápidas en /contacts */
export type ContactSegment = 'clients' | 'prospects' | 'hot_leads' | 'stale'

export interface ContactQuickStats {
  clients: number
  prospects: number
  hot_leads: number
  stale: number
  stale_days: number
}

export interface ContactLandingOrigin {
  id: string
  landing_page_id: string
  landing_title?: string
  landing_slug?: string
  opportunity_id?: string
  created_at?: string
}

export interface ContactSummary {
  id: string
  fullName: string
  firstName: string
  lastName: string
  email: string
  phone: string
  company: unknown
  position: string
  opportunitiesCount: number
  kind: ContactKind
  city?: string
  country?: string
  notes?: string
  documentId?: string
  ownerName?: string
  ownerId?: string
  canEdit?: boolean
  sourceLabel?: string
  lastContactedAt?: string
  customFields?: Record<string, unknown>
  landingOrigins?: ContactLandingOrigin[]
  whatsappOptedIn?: boolean
  whatsappOptInSource?: string
}

type ContactAttributes = {
  kind: ContactKind
  first_name?: string
  last_name?: string
  full_name?: string
  email?: string
  phone_e164?: string
  phone_display?: string
  company?: string
  position?: string
  city?: string
  country?: string
  notes?: string
  document_id?: string
  owner_name?: string
  owner_user_id?: string
  can_edit?: boolean
  opportunities_count?: number
  source_label?: string
  last_contacted_at?: string
  custom_fields?: Record<string, unknown>
  landing_origins?: ContactLandingOrigin[]
  whatsapp_opted_in?: boolean
  whatsapp_opt_in_source?: string
}

export interface ContactListFilters {
  q?: string
  kind?: ContactKind
  owner_id?: string
  segment?: ContactSegment
  page?: number
  items?: number
}

export interface ContactListResult {
  contacts: ContactSummary[]
  total: number
  page: number
  pageSize: number
  totalPages: number
}

export function mapContactResource(resource: JsonApiResource): ContactSummary {
  const attrs = (resource.attributes ?? {}) as ContactAttributes
  const fallbackName = [attrs.first_name, attrs.last_name].filter(Boolean).join(' ').trim()
  const relOwner = resource.relationships?.owner_user?.data as { id?: string } | null

  return {
    id: String(resource.id ?? ''),
    fullName: attrs.full_name || fallbackName || attrs.email || 'Sin nombre',
    firstName: attrs.first_name || '',
    lastName: attrs.last_name || '',
    email: attrs.email || '-',
    phone: attrs.phone_display || attrs.phone_e164 || '-',
    company: attrs.company || '-',
    position: attrs.position || '-',
    opportunitiesCount: attrs.opportunities_count ?? 0,
    kind: attrs.kind || 'person',
    city: attrs.city,
    country: attrs.country,
    notes: attrs.notes,
    documentId: attrs.document_id?.trim() || undefined,
    ownerName: attrs.owner_name?.trim() || undefined,
    ownerId:
      relOwner?.id != null
        ? String(relOwner.id)
        : attrs.owner_user_id != null
          ? String(attrs.owner_user_id)
          : undefined,
    canEdit: attrs.can_edit === true,
    sourceLabel: attrs.source_label?.trim() || undefined,
    lastContactedAt: attrs.last_contacted_at,
    customFields:
      attrs.custom_fields != null && typeof attrs.custom_fields === 'object'
        ? (attrs.custom_fields as Record<string, unknown>)
        : undefined,
    landingOrigins: Array.isArray(attrs.landing_origins)
      ? attrs.landing_origins.map((o) => ({
          id: String(o.id ?? ''),
          landing_page_id: String(o.landing_page_id ?? ''),
          landing_title: o.landing_title,
          landing_slug: o.landing_slug,
          opportunity_id: o.opportunity_id,
          created_at: o.created_at,
        }))
      : undefined,
    whatsappOptedIn: attrs.whatsapp_opted_in === true,
    whatsappOptInSource: attrs.whatsapp_opt_in_source?.trim() || undefined,
  }
}

export function buildContactListParams(filters: ContactListFilters): Record<string, string | number> {
  const params: Record<string, string | number> = {}
  if (filters.kind) params.kind = filters.kind
  if (filters.owner_id) params.owner_id = filters.owner_id
  if (filters.segment) params.segment = filters.segment
  if (filters.q && filters.q.length >= 2) params.q = filters.q
  if (filters.page) params.page = filters.page
  if (filters.items) params.items = filters.items
  return params
}

export async function fetchContactStats(): Promise<ContactQuickStats> {
  const response = await api.get<{ data: ContactQuickStats }>('/contacts/stats')
  const d = response.data.data
  return {
    clients: Number(d?.clients ?? 0),
    prospects: Number(d?.prospects ?? 0),
    hot_leads: Number(d?.hot_leads ?? 0),
    stale: Number(d?.stale ?? 0),
    stale_days: Number(d?.stale_days ?? 7),
  }
}

export async function fetchContactsList(filters: ContactListFilters): Promise<ContactListResult> {
  const page = filters.page ?? 1
  const pageSize = filters.items ?? 10
  const response = await api.get('/contacts', { params: buildContactListParams({ ...filters, page, items: pageSize }) })
  const rows = jsonApiPrimaryList(response.data)
  const pagination = (
    response.data as { meta?: { pagination?: { count?: number; page?: number; pages?: number } } }
  )?.meta?.pagination
  const contacts = rows.filter((r) => r.id).map(mapContactResource)
  return {
    contacts,
    total: pagination?.count ?? contacts.length,
    page: pagination?.page ?? page,
    pageSize,
    totalPages: pagination?.pages ?? 1,
  }
}

export async function fetchContactDetail(id: string): Promise<ContactSummary> {
  const response = await api.get(`/contacts/${id}`)
  const one = jsonApiPrimaryOne(response.data)
  if (!one?.id) throw new Error('Contacto no encontrado')
  return mapContactResource(one)
}

export type ContactUpdatePayload = {
  first_name?: string
  last_name?: string
  email?: string
  phone_e164?: string
  company?: string
  position?: string
  document_id?: string
  city?: string
  country?: string
  notes?: string
  owner_user_id?: string
}

export async function updateContact(
  id: string,
  payload: ContactUpdatePayload,
): Promise<ContactSummary> {
  const response = await api.patch(`/contacts/${id}`, { contact: payload })
  const one = jsonApiPrimaryOne(response.data)
  if (!one?.id) throw new Error('Contacto no encontrado')
  return mapContactResource(one)
}

/** Sincroniza detalle y filas de listas en caché tras crear/editar/asignar. */
export function upsertContactInQueryCache(
  queryClient: QueryClient,
  contact: ContactSummary,
): void {
  queryClient.setQueryData(queryKeys.contacts.detail(contact.id), contact)
  queryClient.setQueriesData<ContactListResult>(
    {
      queryKey: queryKeys.contacts.all,
      predicate: (q) => q.queryKey[1] === 'list',
    },
    (old) => {
      if (!old?.contacts?.length) return old
      const idx = old.contacts.findIndex((c) => c.id === contact.id)
      if (idx < 0) return old
      const contacts = [...old.contacts]
      contacts[idx] = contact
      return { ...old, contacts }
    },
  )
}

export async function deleteContact(id: string): Promise<void> {
  await api.delete(`/contacts/${id}`)
}

export async function bulkDeleteContacts(ids: string[]): Promise<{ deleted: number }> {
  const response = await api.delete('/contacts/bulk_destroy', { data: { ids } })
  return (response.data as { data: { deleted: number } }).data
}

export async function bulkMarkWhatsappOptIn(ids: string[]): Promise<{ marked: number }> {
  const response = await api.post('/contacts/bulk_whatsapp_opt_in', { ids })
  return (response.data as { data: { marked: number } }).data
}

export async function assignContactOwner(contactId: string, ownerUserId: string): Promise<void> {
  await api.patch(`/contacts/${contactId}`, {
    contact: { owner_user_id: ownerUserId },
  })
}

export type ContactExportFormat = 'csv' | 'xlsx'

const CONTACT_DATE_RANGE_DAYS: Record<string, number> = {
  week: 7,
  month: 30,
  quarter: 90,
  year: 365,
}

/** Filtros Ransack para exportación de contactos (RFC §6.7). */
export function buildContactExportFilters(config: {
  dateRange?: string
  contactKind?: '' | 'person' | 'company'
  ownerId?: string
  contactSourceKind?: string
  stageId?: string
}): Record<string, string> {
  const out: Record<string, string> = {}
  const days =
    config.dateRange && config.dateRange !== 'all'
      ? (CONTACT_DATE_RANGE_DAYS[config.dateRange] ?? 0)
      : 0
  if (days > 0) {
    out.updated_at_gteq = new Date(Date.now() - days * 86_400_000).toISOString()
  }
  if (config.contactKind) out.kind_eq = config.contactKind
  if (config.ownerId) out.owner_user_id_eq = config.ownerId
  if (config.contactSourceKind) out.source_kind_eq = config.contactSourceKind
  // Filtra por etapa del pipeline de las oportunidades del contacto (RFC §6.7).
  if (config.stageId) out.opportunities_pipeline_stage_id_eq = config.stageId
  return out
}

export async function downloadContactsExport(
  format: ContactExportFormat,
  filters: Record<string, string>,
): Promise<Blob> {
  const response = await api.get(`/contacts/export.${format}`, {
    params: { filters },
    responseType: 'blob',
  })
  return response.data as Blob
}

export async function enqueueContactsExport(
  format: ContactExportFormat,
  filters: Record<string, string>,
): Promise<void> {
  await api.post('/contacts/export', {
    export_format: format,
    filters,
  })
}

export type ContactImportResult = {
  created_count: number
  skipped_count: number
  errors: Array<{ row: number; message: string }>
  /** Filas importadas con ajuste (p.ej. etapa desconocida → primera etapa). */
  warnings?: Array<{ row: number; message: string }>
}

export async function downloadContactImportTemplate(): Promise<void> {
  const response = await api.get('/contacts/import_template', { responseType: 'blob' })
  const blob = response.data as Blob
  triggerBlobDownload(
    blob,
    'plantilla_contactos.xlsx',
  )
}

export async function importContactsFromFile(file: File): Promise<ContactImportResult> {
  const formData = new FormData()
  formData.append('file', file)
  const response = await api.post<{ data: ContactImportResult }>('/contacts/import', formData)
  return response.data.data
}

export function triggerBlobDownload(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  URL.revokeObjectURL(url)
}

export function contactListErrorMessage(err: unknown): string {
  return formatRailsError(err, 'Error al cargar contactos')
}

export function getCompanyLabel(company: unknown): string {
  if (!company) return '-'
  if (typeof company === 'string') return company
  if (typeof company === 'object' && company !== null && 'name' in company) {
    const name = (company as { name?: unknown }).name
    return typeof name === 'string' && name.trim() ? name : '-'
  }
  return '-'
}

export function getContactInitials(value: string | undefined): string {
  if (!value) return '--'
  return value
    .trim()
    .split(' ')
    .filter(Boolean)
    .map((part) => part[0])
    .join('')
    .slice(0, 2)
    .toUpperCase()
}
