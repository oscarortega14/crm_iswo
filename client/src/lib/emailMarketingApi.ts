import api from '@/lib/api'
import { jsonApiPrimaryList, type JsonApiResource } from '@/lib/opportunityApi'
import { getAuthQueryScope } from '@/lib/queryClient'

// ---------------------------------------------------------------------------
// Email marketing — campañas de correo por AWS SES desde el dominio propio
// del tenant. Solo admin/manager (el remitente lo cambia solo el admin).
// ---------------------------------------------------------------------------

export const emailQueryKeys = {
  all: () => ['emailMarketing', getAuthQueryScope()] as const,
  sender: () => [...emailQueryKeys.all(), 'sender'] as const,
  campaigns: () => [...emailQueryKeys.all(), 'campaigns'] as const,
  campaign: (id: string) => [...emailQueryKeys.campaigns(), id] as const,
  recipients: (id: string, result: string) => [...emailQueryKeys.campaign(id), 'recipients', result] as const,
  preview: (filters: EmailAudienceFilters) => [...emailQueryKeys.all(), 'preview', filters] as const,
}

// ---- Remitente --------------------------------------------------------------

export type EmailSenderStatus = 'not_started' | 'pending' | 'verified' | 'failed'

export interface DnsRecord {
  type: 'CNAME' | 'TXT'
  name: string
  value: string
  purpose: 'dkim' | 'dmarc'
}

export interface EmailSender {
  domain: string | null
  fromLocal: string
  fromName: string
  fromEmail: string | null
  replyTo: string | null
  address: string | null
  status: EmailSenderStatus
  verifiedAt: string | null
  checkedAt: string | null
  dnsRecords: DnsRecord[]
  /** Hay configuration set de SES: se registran entregas, rebotes, aperturas y clics. */
  trackingEnabled: boolean
}

function mapSender(raw: Record<string, unknown>): EmailSender {
  const str = (v: unknown) => (v != null && String(v).trim() ? String(v) : null)
  return {
    domain: str(raw.domain),
    fromLocal: String(raw.from_local ?? 'info'),
    fromName: String(raw.from_name ?? ''),
    fromEmail: str(raw.from_email),
    replyTo: str(raw.reply_to),
    address: str(raw.address),
    status: (raw.status as EmailSenderStatus) ?? 'not_started',
    verifiedAt: str(raw.verified_at),
    checkedAt: str(raw.checked_at),
    dnsRecords: Array.isArray(raw.dns_records) ? (raw.dns_records as DnsRecord[]) : [],
    trackingEnabled: raw.tracking_enabled === true,
  }
}

export async function fetchEmailSender(): Promise<EmailSender> {
  const res = await api.get('/email_sender')
  return mapSender(res.data.data ?? {})
}

export type EmailSenderInput = {
  domain: string
  from_local: string
  from_name: string
  reply_to: string
  address: string
}

export async function updateEmailSender(body: EmailSenderInput): Promise<EmailSender> {
  const res = await api.patch('/email_sender', { email_sender: body })
  return mapSender(res.data.data ?? {})
}

export async function verifyEmailSender(): Promise<EmailSender> {
  const res = await api.post('/email_sender/verify')
  return mapSender(res.data.data ?? {})
}

export async function refreshEmailSender(): Promise<EmailSender> {
  const res = await api.post('/email_sender/refresh')
  return mapSender(res.data.data ?? {})
}

// ---- Campañas -------------------------------------------------------------

export type EmailCampaignStatus = 'draft' | 'scheduled' | 'running' | 'paused' | 'completed' | 'canceled'

export interface EmailAudienceFilters {
  pipeline_id?: string
  pipeline_stage_id?: string
  owner_id?: string
  temperature?: string
  lead_source_id?: string
  kind?: 'person' | 'company'
  /** Solo contactos que llegaron por este origen (p. ej. «Excel: base.xlsx»). */
  contact_origin?: string
}

export type EmailResult =
  | 'pending'
  | 'sent'
  | 'delivered'
  | 'opened'
  | 'clicked'
  | 'bounced'
  | 'complained'
  | 'failed'
  | 'skipped'
  | 'unsubscribed'

export const EMAIL_RESULTS: EmailResult[] = [
  'pending',
  'sent',
  'delivered',
  'opened',
  'clicked',
  'bounced',
  'complained',
  'failed',
  'skipped',
  'unsubscribed',
]

export type EmailResultStats = Record<EmailResult, number> & { total: number }

export interface EmailCampaign {
  id: string
  name: string
  subject: string
  preheader: string
  /** Solo en el detalle (no en el listado). */
  bodyHtml?: string
  bodyDesign?: Record<string, unknown>
  audienceFilters: EmailAudienceFilters
  status: EmailCampaignStatus
  scheduledAt: string | null
  totalRecipients: number
  sentCount: number
  failedCount: number
  skippedCount: number
  startedAt: string | null
  completedAt: string | null
  createdAt: string
  createdByName: string | null
  /** null en borradores y programadas. */
  resultStats: EmailResultStats | null
}

function mapStats(raw: unknown): EmailResultStats | null {
  if (!raw || typeof raw !== 'object') return null
  const r = raw as Record<string, unknown>
  const stats = { total: Number(r.total ?? 0) } as EmailResultStats
  for (const k of EMAIL_RESULTS) stats[k] = Number(r[k] ?? 0)
  return stats
}

export function mapEmailCampaign(resource: JsonApiResource): EmailCampaign | null {
  if (!resource.id) return null
  const a = resource.attributes ?? {}
  const str = (v: unknown) => (v != null && String(v).trim() ? String(v) : null)
  return {
    id: String(resource.id),
    name: String(a.name ?? ''),
    subject: String(a.subject ?? ''),
    preheader: String(a.preheader ?? ''),
    bodyHtml: typeof a.body_html === 'string' ? a.body_html : undefined,
    bodyDesign:
      a.body_design && typeof a.body_design === 'object' ? (a.body_design as Record<string, unknown>) : undefined,
    audienceFilters: (a.audience_filters ?? {}) as EmailAudienceFilters,
    status: (a.status as EmailCampaignStatus) ?? 'draft',
    scheduledAt: str(a.scheduled_at),
    totalRecipients: Number(a.total_recipients ?? 0),
    sentCount: Number(a.sent_count ?? 0),
    failedCount: Number(a.failed_count ?? 0),
    skippedCount: Number(a.skipped_count ?? 0),
    startedAt: str(a.started_at),
    completedAt: str(a.completed_at),
    createdAt: String(a.created_at ?? ''),
    createdByName: str(a.created_by_name),
    resultStats: mapStats(a.result_stats),
  }
}

function single(res: { data: unknown }): EmailCampaign {
  const data = (res.data as { data?: JsonApiResource })?.data
  const campaign = data ? mapEmailCampaign(data) : null
  if (!campaign) throw new Error('Respuesta inesperada del servidor')
  return campaign
}

export async function fetchEmailCampaigns(): Promise<EmailCampaign[]> {
  const res = await api.get('/email_campaigns', { params: { items: 100 } })
  return jsonApiPrimaryList(res.data)
    .map(mapEmailCampaign)
    .filter((c): c is EmailCampaign => c !== null)
}

export async function fetchEmailCampaign(id: string): Promise<EmailCampaign> {
  return single(await api.get(`/email_campaigns/${id}`))
}

export type EmailCampaignInput = {
  name: string
  subject: string
  preheader: string
  body_html: string
  body_design: Record<string, unknown>
  audience_filters: EmailAudienceFilters
  scheduled_at: string | null
}

export async function createEmailCampaign(body: EmailCampaignInput): Promise<EmailCampaign> {
  return single(await api.post('/email_campaigns', { email_campaign: body }))
}

export async function updateEmailCampaign(id: string, body: EmailCampaignInput): Promise<EmailCampaign> {
  return single(await api.patch(`/email_campaigns/${id}`, { email_campaign: body }))
}

export async function deleteEmailCampaign(id: string): Promise<void> {
  await api.delete(`/email_campaigns/${id}`)
}

type CampaignAction = 'launch' | 'pause' | 'resume' | 'cancel' | 'duplicate'

export async function emailCampaignAction(id: string, action: CampaignAction): Promise<EmailCampaign> {
  return single(await api.post(`/email_campaigns/${id}/${action}`))
}

export async function sendEmailCampaignTest(id: string, email: string): Promise<string> {
  const res = await api.post(`/email_campaigns/${id}/send_test`, { email })
  return String(res.data.sent_to ?? email)
}

export interface EmailAudiencePreview {
  total: number
  optedOut: number
}

export async function fetchEmailAudiencePreview(filters: EmailAudienceFilters): Promise<EmailAudiencePreview> {
  const res = await api.get('/email_campaigns/audience_preview', { params: filters })
  return { total: Number(res.data.total ?? 0), optedOut: Number(res.data.opted_out ?? 0) }
}

export type RecipientFilter = 'all' | 'delivered' | 'opened' | 'clicked' | 'unsubscribed' | 'problems'

export interface EmailRecipientRow {
  id: string
  contactId: string
  contactName: string
  email: string
  result: EmailResult
  reason: string | null
  sentAt: string | null
  openedAt: string | null
  clickedAt: string | null
}

export async function fetchEmailCampaignRecipients(
  id: string,
  result: RecipientFilter,
  page = 1,
): Promise<{ rows: EmailRecipientRow[]; hasMore: boolean }> {
  const res = await api.get(`/email_campaigns/${id}/recipients`, {
    params: { page, items: 100, result: result === 'all' ? undefined : result },
  })
  const str = (v: unknown) => (v != null && String(v).trim() ? String(v) : null)
  const rows = jsonApiPrimaryList(res.data).map((r): EmailRecipientRow => {
    const a = r.attributes ?? {}
    return {
      id: String(r.id ?? ''),
      contactId: String(a.contact_id ?? ''),
      contactName: String(a.contact_name ?? 'Sin nombre'),
      email: String(a.email ?? ''),
      result: (EMAIL_RESULTS.includes(a.result as EmailResult) ? a.result : 'pending') as EmailResult,
      reason: str(a.reason),
      sentAt: str(a.sent_at),
      openedAt: str(a.opened_at),
      clickedAt: str(a.clicked_at),
    }
  })
  const pagination = (res.data as { meta?: { pagination?: { page?: number; pages?: number } } })?.meta?.pagination
  return { rows, hasMore: Boolean(pagination && Number(pagination.page) < Number(pagination.pages)) }
}

/** Variables que el backend reemplaza por destinatario (EmailMarketing::Renderer). */
export const EMAIL_VARIABLES: { token: string; label: string }[] = [
  { token: '{{nombre}}', label: 'Nombre (o razón social si es empresa)' },
  { token: '{{apellido}}', label: 'Apellido' },
  { token: '{{nombre_completo}}', label: 'Nombre completo' },
  { token: '{{empresa}}', label: 'Empresa' },
  { token: '{{asesor}}', label: 'Asesor asignado' },
]
