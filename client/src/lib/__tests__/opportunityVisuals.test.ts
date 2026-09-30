import { describe, expect, it } from 'vitest'
import type { PipelineStage } from '@/types'
import {
  daysInStageLabel,
  formatCompactCurrency,
  nextAdvanceStage,
  formatStageTimePain,
  getPropertyLabel,
  getStageEmoji,
} from '@/lib/opportunityVisuals'

describe('opportunityVisuals', () => {
  it('getStageEmoji maps diagnóstico', () => {
    expect(getStageEmoji('Diagnóstico')).toBe('🔬')
    expect(getStageEmoji('Visita Agendada')).toBe('🏠')
  })

  it('getPropertyLabel reads custom fields', () => {
    expect(
      getPropertyLabel({ tipo_inmueble: 'Apartamento', ciudad: 'Medellín' }),
    ).toBe('Apartamento')
  })

  it('formatStageTimePain marks long waits urgent', () => {
    const old = new Date()
    old.setDate(old.getDate() - 20)
    const result = formatStageTimePain(old.toISOString())
    expect(result.urgent).toBe(true)
    expect(result.label).toMatch(/20d/)
  })

  it('formatCompactCurrency', () => {
    expect(formatCompactCurrency(5_000_000)).toBe('$5M')
    expect(formatCompactCurrency(25_000_000)).toBe('$25M')
  })
})

describe('nextAdvanceStage (botón «Pasar a …» del tablero móvil)', () => {
  const stage = (id: string, position: number, extra: Partial<PipelineStage> = {}): PipelineStage => ({
    id, pipeline_id: 'p', name: id, position, probability: 0,
    is_closed_won: false, is_closed_lost: false, ...extra,
  })
  // Orden desordenado a propósito: debe ordenar por posición.
  const iso = [
    stage('negociacion', 4),
    stage('prospecto', 0),
    stage('diagnostico', 1),
    stage('perdida', 6, { is_closed_lost: true }),
    stage('contrato', 5, { is_closed_won: true }),
  ]

  it('devuelve la siguiente etapa por posición', () => {
    expect(nextAdvanceStage(iso, 'prospecto')?.id).toBe('diagnostico')
    expect(nextAdvanceStage(iso, 'diagnostico')?.id).toBe('negociacion')
  })

  it('desde la última etapa abierta lleva al cierre ganado', () => {
    expect(nextAdvanceStage(iso, 'negociacion')?.id).toBe('contrato')
  })

  it('nunca propone cierre perdido y no avanza desde etapas de cierre', () => {
    const lostBeforeWon = [stage('a', 0), stage('perdida', 1, { is_closed_lost: true }), stage('ganada', 2, { is_closed_won: true })]
    expect(nextAdvanceStage(lostBeforeWon, 'a')?.id).toBe('ganada')
    expect(nextAdvanceStage(iso, 'contrato')).toBeNull()
    expect(nextAdvanceStage(iso, 'perdida')).toBeNull()
    expect(nextAdvanceStage(iso, 'no-existe')).toBeNull()
  })
})

describe('daysInStageLabel', () => {
  const daysAgo = (n: number) => new Date(Date.now() - n * 24 * 60 * 60 * 1000).toISOString()

  it('formatea hoy, singular y plural', () => {
    expect(daysInStageLabel(daysAgo(0)).label).toBe('Hoy en esta etapa')
    expect(daysInStageLabel(daysAgo(1)).label).toBe('1 día en esta etapa')
    expect(daysInStageLabel(daysAgo(3))).toEqual({ label: '3 días en esta etapa', urgent: false })
  })

  it('marca urgente desde 7 días y tolera fechas vacías o inválidas', () => {
    expect(daysInStageLabel(daysAgo(9)).urgent).toBe(true)
    expect(daysInStageLabel(null).label).toBe('')
    expect(daysInStageLabel('no-es-fecha').label).toBe('')
  })
})
