import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, type JsonApiResource } from '@/lib/opportunityApi'

export type WhatsappCampaignStatus = 'draft' | 'scheduled' | 'running' | 'paused' | 'completed' | 'canceled'

export interface WhatsappCampaignAudienceFilters {
  pipeline_id?: string
  pipeline_stage_id?: string
  owner_id?: string
  temperature?: string
  status?: string
  /** 'confirmed' = solo quienes respondieron "Sí" por WhatsApp (no basta opt-in por import/manual). */
  whatsapp_consent?: 'confirmed'
  /** Solo contactos que llegaron por este origen (p. ej. «Excel: base.xlsx»). */
  contact_origin?: string
}

/** Resultado real por destinatario (según Meta). `sent` = aceptado, sin confirmación de entrega aún. */
export type DeliveryResult = 'pending' | 'sent' | 'delivered' | 'read' | 'failed' | 'skipped'

export type DeliveryStats = Record<DeliveryResult, number> & { total: number }

export interface WhatsappCampaign {
  id: string
  name: string
  whatsappTemplateId: string
  whatsappTemplateName: string
  /** Estado de la plantilla en Meta (APPROVED, PENDING, REJECTED…); null = nunca sincronizada. */
  whatsappTemplateMetaStatus: string | null
  /** null en borradores. */
  deliveryStats: DeliveryStats | null
  /** Mensaje automático a quien responde «Sí» (texto libre, admite {{nombre}}). */
  confirmReplyBody: string
  /** Cuántos respondieron «Sí» y cuántos recibieron el mensaje automático. null en borradores. */
  confirmationStats: { confirmed: number; replied: number } | null
  variableFieldMap: string[]
  audienceFilters: WhatsappCampaignAudienceFilters
  status: WhatsappCampaignStatus
  batchSize: number
  batchIntervalMinutes: number
  totalRecipients: number
  sentCount: number
  failedCount: number
  skippedNoOptInCount: number
  startedAt: string | null
  completedAt: string | null
  lastBatchAt: string | null
  createdAt: string
}

export function mapWhatsappCampaign(resource: JsonApiResource): WhatsappCampaign | null {
  if (!resource.id) return null
  const a = resource.attributes ?? {}
  const map = Array.isArray(a.variable_field_map) ? a.variable_field_map : []
  const filters = (a.audience_filters ?? {}) as Record<string, unknown>

  return {
    id:                    String(resource.id),
    name:                  String(a.name ?? ''),
    whatsappTemplateId:    String(a.whatsapp_template_id ?? ''),
    whatsappTemplateName:  String(a.whatsapp_template_name ?? ''),
    whatsappTemplateMetaStatus:
      a.whatsapp_template_meta_status != null ? String(a.whatsapp_template_meta_status) : null,
    deliveryStats:         mapDeliveryStats(a.delivery_stats),
    confirmReplyBody:      String(a.confirm_reply_body ?? ''),
    confirmationStats:
      a.confirmation_stats && typeof a.confirmation_stats === 'object'
        ? {
            confirmed: Number((a.confirmation_stats as Record<string, unknown>).confirmed ?? 0),
            replied: Number((a.confirmation_stats as Record<string, unknown>).replied ?? 0),
          }
        : null,
    variableFieldMap:      map.map((f) => String(f)),
    audienceFilters:       filters as WhatsappCampaignAudienceFilters,
    status:                (a.status as WhatsappCampaignStatus) ?? 'draft',
    batchSize:             Number(a.batch_size ?? 40),
    batchIntervalMinutes:  Number(a.batch_interval_minutes ?? 15),
    totalRecipients:       Number(a.total_recipients ?? 0),
    sentCount:             Number(a.sent_count ?? 0),
    failedCount:           Number(a.failed_count ?? 0),
    skippedNoOptInCount:   Number(a.skipped_no_opt_in_count ?? 0),
    startedAt:             a.started_at != null ? String(a.started_at) : null,
    completedAt:           a.completed_at != null ? String(a.completed_at) : null,
    lastBatchAt:           a.last_batch_at != null ? String(a.last_batch_at) : null,
    createdAt:             String(a.created_at ?? ''),
  }
}

const DELIVERY_RESULTS: DeliveryResult[] = ['pending', 'sent', 'delivered', 'read', 'failed', 'skipped']

function mapDeliveryStats(raw: unknown): DeliveryStats | null {
  if (!raw || typeof raw !== 'object') return null
  const r = raw as Record<string, unknown>
  const stats = { total: Number(r.total ?? 0) } as DeliveryStats
  for (const k of DELIVERY_RESULTS) stats[k] = Number(r[k] ?? 0)
  return stats
}

/** ¿La plantilla se puede usar para lanzar? Desconocida (nunca sincronizada) = sí, con aviso. */
export function isTemplateLaunchable(metaStatus: string | null | undefined): boolean {
  return !metaStatus || metaStatus.toUpperCase() === 'APPROVED'
}

export async function fetchWhatsappCampaigns(): Promise<WhatsappCampaign[]> {
  const res = await api.get('/whatsapp_campaigns')
  return jsonApiPrimaryList(res.data)
    .map(mapWhatsappCampaign)
    .filter((c): c is WhatsappCampaign => c !== null)
}

export type WhatsappCampaignInput = {
  name: string
  whatsapp_template_id: string
  variable_field_map: string[]
  audience_filters: WhatsappCampaignAudienceFilters
  batch_size?: number
  batch_interval_minutes?: number
  confirm_reply_body?: string
}

export async function createWhatsappCampaign(body: WhatsappCampaignInput): Promise<void> {
  await api.post('/whatsapp_campaigns', { whatsapp_campaign: body })
}

/** Solo borradores — el backend responde 409 `not_draft` si ya se lanzó. */
export async function updateWhatsappCampaign(id: string, body: WhatsappCampaignInput): Promise<void> {
  await api.patch(`/whatsapp_campaigns/${id}`, { whatsapp_campaign: body })
}

export interface AudiencePreview {
  total: number
  optedIn: number
  skippedNoOptIn: number
  /** País de los celulares de la audiencia según su indicativo: { EC: 120, CO: 3 }. */
  countries: Record<string, number>
}

export async function fetchAudiencePreview(filters: WhatsappCampaignAudienceFilters): Promise<AudiencePreview> {
  const res = await api.get('/whatsapp_campaigns/audience_preview', { params: filters })
  return {
    total:          Number(res.data.total ?? 0),
    optedIn:        Number(res.data.opted_in ?? 0),
    skippedNoOptIn: Number(res.data.skipped_no_opt_in ?? 0),
    countries: (res.data.countries ?? {}) as Record<string, number>,
  }
}

export async function launchWhatsappCampaign(id: string): Promise<void> {
  await api.post(`/whatsapp_campaigns/${id}/launch`)
}

export async function pauseWhatsappCampaign(id: string): Promise<void> {
  await api.post(`/whatsapp_campaigns/${id}/pause`)
}

export async function resumeWhatsappCampaign(id: string): Promise<void> {
  await api.post(`/whatsapp_campaigns/${id}/resume`)
}

export async function cancelWhatsappCampaign(id: string): Promise<void> {
  await api.post(`/whatsapp_campaigns/${id}/cancel`)
}

/** Copia la campaña como borrador editable (así se «edita» una campaña ya lanzada). */
export async function duplicateWhatsappCampaign(id: string): Promise<WhatsappCampaign | null> {
  const res = await api.post(`/whatsapp_campaigns/${id}/duplicate`)
  const data = (res.data as { data?: JsonApiResource })?.data
  return data ? mapWhatsappCampaign(data) : null
}

export interface CampaignRecipientRow {
  id: string
  contactId: string
  contactName: string
  toNumber: string | null
  result: DeliveryResult
  /** Error de Meta o motivo de omisión. */
  reason: string | null
  sentAt: string | null
  deliveredAt: string | null
  readAt: string | null
}

export async function fetchCampaignRecipients(
  id: string,
  page = 1,
): Promise<{ rows: CampaignRecipientRow[]; hasMore: boolean }> {
  const res = await api.get(`/whatsapp_campaigns/${id}/recipients`, { params: { page, items: 100 } })
  const rows = jsonApiPrimaryList(res.data).map((r): CampaignRecipientRow => {
    const a = r.attributes ?? {}
    const str = (v: unknown) => (v != null && String(v).trim() ? String(v) : null)
    return {
      id:          String(r.id ?? ''),
      contactId:   String(a.contact_id ?? ''),
      contactName: String(a.contact_name ?? 'Sin nombre'),
      toNumber:    str(a.to_number),
      result:      (DELIVERY_RESULTS.includes(a.result as DeliveryResult) ? a.result : 'pending') as DeliveryResult,
      reason:      str(a.reason),
      sentAt:      str(a.sent_at),
      deliveredAt: str(a.delivered_at),
      readAt:      str(a.read_at),
    }
  })
  const pagination = (res.data as { meta?: { pagination?: { page?: number; pages?: number } } })?.meta?.pagination
  return { rows, hasMore: Boolean(pagination && Number(pagination.page) < Number(pagination.pages)) }
}

export function whatsappCampaignErrorMessage(err: unknown): string {
  return formatRailsError(err, 'No se pudo guardar la campaña')
}
