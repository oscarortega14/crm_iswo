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

export function whatsappTemplateErrorMessage(err: unknown): string {
  return formatRailsError(err, 'No se pudo guardar la plantilla')
}
