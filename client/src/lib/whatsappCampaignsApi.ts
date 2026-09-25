import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, type JsonApiResource } from '@/lib/opportunityApi'

export type WhatsappCampaignStatus = 'draft' | 'scheduled' | 'running' | 'paused' | 'completed' | 'canceled'

export interface WhatsappCampaignAudienceFilters {
  pipeline_id?: string
  pipeline_stage_id?: string
  owner_id?: string
  temperature?: string
  status?: string
}

export interface WhatsappCampaign {
  id: string
  name: string
  whatsappTemplateId: string
  whatsappTemplateName: string
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
}

export async function fetchAudiencePreview(filters: WhatsappCampaignAudienceFilters): Promise<AudiencePreview> {
  const res = await api.get('/whatsapp_campaigns/audience_preview', { params: filters })
  return {
    total:          Number(res.data.total ?? 0),
    optedIn:        Number(res.data.opted_in ?? 0),
    skippedNoOptIn: Number(res.data.skipped_no_opt_in ?? 0),
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

export function whatsappCampaignErrorMessage(err: unknown): string {
  return formatRailsError(err, 'No se pudo guardar la campaña')
}
