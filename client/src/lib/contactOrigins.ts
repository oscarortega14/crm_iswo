/** Vía por la que llegó un contacto (backend: contacts.origins). */
export interface ContactOrigin {
  kind: string
  label?: string | null
  at?: string | null
}

const KIND_LABELS: Record<string, string> = {
  manual: 'Creado en el CRM',
  import: 'Importación',
  web: 'Landing',
  meta: 'Meta Ads',
  google: 'Google Ads',
  whatsapp: 'Escribió por WhatsApp',
  blog: 'Blog',
  referral: 'Referido',
}

/** «Importación» / «Landing» / … para el tipo de origen; el valor crudo si es desconocido. */
export function originKindLabel(kind: string): string {
  return KIND_LABELS[kind] ?? kind
}

/** Detalle legible: «Excel: base.xlsx», «Landing ISO 9001»; oculta el «inbound» técnico de WhatsApp. */
export function originDetail(origin: ContactOrigin): string | null {
  const label = origin.label?.trim()
  if (!label || label === 'inbound') return null
  return label
}

export function mapContactOrigins(raw: unknown): ContactOrigin[] {
  if (!Array.isArray(raw)) return []
  return raw
    .filter((o): o is Record<string, unknown> => !!o && typeof o === 'object' && typeof (o as { kind?: unknown }).kind === 'string')
    .map((o) => ({
      kind: String(o.kind),
      label: o.label != null ? String(o.label) : null,
      at: o.at != null ? String(o.at) : null,
    }))
}
