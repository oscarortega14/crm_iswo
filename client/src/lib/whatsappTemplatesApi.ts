import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, type JsonApiResource } from '@/lib/opportunityApi'

export interface WhatsappTemplate {
  id: string
  name: string
  metaTemplateName: string
  language: string
  variableLabels: string[]
  /** Nombre exacto de cada variable en Meta (formato nuevo: {{primer_nombre}}). Vacío = plantilla posicional clásica ({{1}}). */
  variableNames: string[]
  active: boolean
  /** Plantilla redactada para pedir autorización de WhatsApp — una campaña
   * que la use salta el gate de opt-in (ver backend). */
  optInRequest: boolean
  /** Los siguientes 4 campos solo los escribe el botón «Sincronizar» (WhatsApp::TemplateSync
   * en el backend) — reflejan el estado real en Meta, nunca se editan a mano. */
  category: string | null
  metaStatus: string | null
  metaTemplateId: string | null
  metaSyncedAt: string | null
}

export function mapWhatsappTemplate(resource: JsonApiResource): WhatsappTemplate | null {
  if (!resource.id) return null
  const a = resource.attributes ?? {}
  const labels = Array.isArray(a.variable_labels) ? a.variable_labels : []
  const names = Array.isArray(a.variable_names) ? a.variable_names : []

  return {
    id:               String(resource.id),
    name:             String(a.name ?? ''),
    metaTemplateName: String(a.meta_template_name ?? ''),
    language:         String(a.language ?? ''),
    variableLabels:   labels.map((l) => String(l)),
    variableNames:    names.map((n) => String(n)),
    active:           Boolean(a.active ?? true),
    optInRequest:     Boolean(a.opt_in_request ?? false),
    category:         a.category != null ? String(a.category) : null,
    metaStatus:       a.meta_status != null ? String(a.meta_status) : null,
    metaTemplateId:   a.meta_template_id != null ? String(a.meta_template_id) : null,
    metaSyncedAt:     a.meta_synced_at != null ? String(a.meta_synced_at) : null,
  }
}

export async function fetchWhatsappTemplates(activeOnly = false): Promise<WhatsappTemplate[]> {
  const res = await api.get('/whatsapp_templates', { params: activeOnly ? { active: 'true' } : {} })
  return jsonApiPrimaryList(res.data)
    .map(mapWhatsappTemplate)
    .filter((t): t is WhatsappTemplate => t !== null)
}

export type WhatsappTemplateInput = {
  name: string
  meta_template_name: string
  language: string
  variable_labels: string[]
  variable_names: string[]
  active?: boolean
  opt_in_request?: boolean
}

export async function createWhatsappTemplate(body: WhatsappTemplateInput): Promise<void> {
  await api.post('/whatsapp_templates', { whatsapp_template: body })
}

export async function updateWhatsappTemplate(id: string, body: Partial<WhatsappTemplateInput>): Promise<void> {
  await api.patch(`/whatsapp_templates/${id}`, { whatsapp_template: body })
}

export async function deleteWhatsappTemplate(id: string): Promise<void> {
  await api.delete(`/whatsapp_templates/${id}`)
}

export interface WhatsappTemplateSyncEntry {
  name: string
  language: string
  status?: string
  category?: string
}

export interface WhatsappTemplateSyncResult {
  updated: WhatsappTemplateSyncEntry[]
  newInMeta: WhatsappTemplateSyncEntry[]
  missingInMeta: WhatsappTemplateSyncEntry[]
}

/** POST /whatsapp_templates/sync — trae category/status/id desde Meta y actualiza
 * el catálogo local (WhatsApp::TemplateSync en el backend). Requiere metadata.waba_id
 * configurado en la integración whatsapp_cloud y un token con whatsapp_business_management. */
export async function syncWhatsappTemplates(): Promise<WhatsappTemplateSyncResult> {
  const res = await api.post('/whatsapp_templates/sync')
  const d = res.data?.data ?? {}
  const mapEntry = (e: Record<string, unknown>): WhatsappTemplateSyncEntry => ({
    name:     String(e.name ?? ''),
    language: String(e.language ?? ''),
    status:   e.status != null ? String(e.status) : undefined,
    category: e.category != null ? String(e.category) : undefined,
  })
  return {
    updated:       Array.isArray(d.updated) ? d.updated.map(mapEntry) : [],
    newInMeta:     Array.isArray(d.new_in_meta) ? d.new_in_meta.map(mapEntry) : [],
    missingInMeta: Array.isArray(d.missing_in_meta) ? d.missing_in_meta.map(mapEntry) : [],
  }
}

export function whatsappTemplateErrorMessage(err: unknown): string {
  return formatRailsError(err, 'No se pudo guardar la plantilla')
}

export function whatsappTemplateSyncErrorMessage(err: unknown): string {
  return formatRailsError(err, 'No se pudo sincronizar con Meta')
}
