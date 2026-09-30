import { differenceInCalendarDays, parseISO } from 'date-fns'
import type { PipelineStage, StageAutoTrigger } from '@/types'

/** Disparadores de auto-avance de etapa (espejo de Opportunities::StageAutomation::TRIGGERS). */
export const STAGE_AUTO_TRIGGER_LABELS: Record<StageAutoTrigger, string> = {
  whatsapp_outbound: 'Se envió un WhatsApp al lead',
  whatsapp_inbound: 'El lead escribió por WhatsApp',
  bant_qualified: 'Supera el umbral BANT',
}

export function isStageAutoTrigger(value: unknown): value is StageAutoTrigger {
  return typeof value === 'string' && value in STAGE_AUTO_TRIGGER_LABELS
}

/** Emoji por etapa (nombre de pipeline), en lugar del texto largo en tarjetas. */
const STAGE_EMOJI_RULES: { match: RegExp; emoji: string }[] = [
  { match: /diagn[oó]stico/i, emoji: '🔬' },
  { match: /prospecto|interesad/i, emoji: '🌱' },
  { match: /calificad/i, emoji: '✅' },
  { match: /propuesta/i, emoji: '📄' },
  { match: /negociaci[oó]n/i, emoji: '🤝' },
  { match: /contrato|cerrad|ganad|escritura/i, emoji: '📝' },
  { match: /perdid|lost/i, emoji: '❌' },
  { match: /visita/i, emoji: '🏠' },
  { match: /contactad|contacto/i, emoji: '📞' },
  { match: /nueva|new/i, emoji: '✨' },
]

export function getStageEmoji(stageName?: string | null): string {
  const name = stageName?.trim()
  if (!name) return '📋'
  const rule = STAGE_EMOJI_RULES.find((r) => r.match.test(name))
  return rule?.emoji ?? '📋'
}

export function getPropertyLabel(
  customFields?: Record<string, unknown>,
  title?: string | null,
): string | undefined {
  const parts = [
    customFields?.tipo_inmueble,
    customFields?.ciudad,
    customFields?.codigo_lote,
    customFields?.proyecto,
    title?.trim(),
  ]
    .map((p) => (p != null ? String(p).trim() : ''))
    .filter(Boolean)
  const unique = [...new Set(parts)]
  return unique[0]
}

/** Tiempo en etapa (proxy: updated_at) — formato que “duele” si se alarga. */
export function formatStageTimePain(
  referenceAt?: string | null,
): { label: string; urgent: boolean } {
  if (!referenceAt) return { label: '—', urgent: false }
  try {
    const ref = parseISO(referenceAt)
    if (Number.isNaN(ref.getTime())) return { label: '—', urgent: false }
    const days = differenceInCalendarDays(new Date(), ref)
    if (days <= 0) return { label: 'hoy', urgent: false }
    if (days < 7) return { label: `${days}d`, urgent: false }
    if (days < 14) return { label: `${days}d ⏳`, urgent: true }
    return { label: `${days}d 🔥`, urgent: true }
  } catch {
    return { label: '—', urgent: false }
  }
}

export function formatCompactCurrency(value: number, currency = 'COP'): string {
  const n = Number.isFinite(value) ? value : 0
  const abs = Math.abs(n)
  if (abs >= 1_000_000) {
    const m = n / 1_000_000
    const rounded = m >= 10 ? Math.round(m) : Math.round(m * 10) / 10
    return `$${rounded}M`
  }
  if (abs >= 1_000) {
    const k = n / 1_000
    const rounded = k >= 100 ? Math.round(k) : Math.round(k * 10) / 10
    return `$${rounded}K`
  }
  return new Intl.NumberFormat('es-CO', {
    style: 'currency',
    currency,
    maximumFractionDigits: 0,
  }).format(n)
}

/**
 * Etapa a la que lleva el botón «Avanzar» del tablero móvil: la siguiente por
 * posición, saltando las de cierre perdido (perder nunca es "avanzar").
 * null si la actual es de cierre o no hay siguiente.
 */
export function nextAdvanceStage(
  stages: PipelineStage[],
  currentStageId: string | undefined,
): PipelineStage | null {
  const ordered = [...stages].sort((a, b) => a.position - b.position)
  const current = ordered.find((s) => s.id === currentStageId)
  if (!current || current.is_closed_won || current.is_closed_lost) return null
  return ordered.find((s) => s.position > current.position && !s.is_closed_lost) ?? null
}

/** «Hoy», «1 día», «9 días» en la etapa; urgente desde 7 días. */
export function daysInStageLabel(referenceAt?: string | null): { label: string; urgent: boolean } {
  if (!referenceAt) return { label: '', urgent: false }
  const ref = parseISO(referenceAt)
  if (Number.isNaN(ref.getTime())) return { label: '', urgent: false }
  const days = Math.max(0, differenceInCalendarDays(new Date(), ref))
  if (days === 0) return { label: 'Hoy en esta etapa', urgent: false }
  return { label: `${days} ${days === 1 ? 'día' : 'días'} en esta etapa`, urgent: days >= 7 }
}
