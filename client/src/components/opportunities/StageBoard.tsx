import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ArrowRight, Bell, CheckCircle2, Clock } from 'lucide-react'
import { cn, formatCurrency } from '@/lib/utils'
import { daysInStageLabel, nextAdvanceStage } from '@/lib/opportunityVisuals'
import { Button } from '@/components/ui/button'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { TemperatureBadge } from './TemperatureBadge'
import { useOpportunityStageMove } from './useOpportunityStageMove'
import type { Opportunity, Pipeline, PipelineStage } from '@/types'

interface StageBoardProps {
  opportunities: Opportunity[]
  pipeline?: Pipeline
  onSelectOpportunity: (id: string) => void
}

function initials(name?: string): string {
  return (name ?? '')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('')
}

/**
 * Tablero de oportunidades con botón «Pasar a …» en cada tarjeta para avanzar a
 * la siguiente etapa con un toque (el cierre ganado pide confirmación).
 * - Celular (< md): una etapa a la vez, pestañas arriba y deslizar para cambiar.
 * - Computador (≥ md): una columna por etapa, lado a lado (scroll horizontal si
 *   no caben), sin pestañas. Mismo DOM: solo cambian las clases.
 */
export function StageBoard({ opportunities, pipeline, onSelectOpportunity }: StageBoardProps) {
  const stages = useMemo(
    () => [...(pipeline?.stages ?? [])].sort((a, b) => a.position - b.position),
    [pipeline?.stages],
  )
  const { canMove, moveStage, isPending } = useOpportunityStageMove(pipeline)
  const [current, setCurrent] = useState(0)
  const [confirm, setConfirm] = useState<{ opp: Opportunity; stage: PipelineStage } | null>(null)
  const pagerRef = useRef<HTMLDivElement>(null)
  const tabsRef = useRef<HTMLDivElement>(null)

  const byStage = useMemo(() => {
    const grouped: Record<string, Opportunity[]> = {}
    stages.forEach((s) => {
      grouped[s.id] = []
    })
    const first = stages[0]?.id
    opportunities.forEach((o) => {
      if (o.stage_id && grouped[o.stage_id]) grouped[o.stage_id].push(o)
      else if (first) grouped[first].push(o)
    })
    return grouped
  }, [opportunities, stages])

  // Al cambiar de pipeline, volver a la primera etapa.
  useEffect(() => {
    setCurrent(0)
    pagerRef.current?.scrollTo({ left: 0 })
  }, [pipeline?.id])

  // Mantener la pestaña activa visible.
  useEffect(() => {
    const tab = tabsRef.current?.children[current] as HTMLElement | undefined
    tab?.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' })
  }, [current])

  const goTo = useCallback((idx: number) => {
    const pager = pagerRef.current
    if (!pager) return
    setCurrent(idx)
    pager.scrollTo({ left: idx * pager.clientWidth, behavior: 'smooth' })
  }, [])

  const onPagerScroll = () => {
    const pager = pagerRef.current
    if (!pager || pager.clientWidth === 0) return
    const idx = Math.round(pager.scrollLeft / pager.clientWidth)
    if (idx !== current) setCurrent(idx)
  }

  const advance = (opp: Opportunity, stage: PipelineStage) => {
    if (stage.is_closed_won) setConfirm({ opp, stage })
    else moveStage(opp, stage.id)
  }

  if (!stages.length) {
    return (
      <div className="flex h-full items-center justify-center p-8">
        <p className="text-muted-foreground">No hay etapas configuradas en el pipeline</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div
        ref={tabsRef}
        role="tablist"
        aria-label="Etapas"
        className="flex shrink-0 gap-1.5 overflow-x-auto border-b px-3 pb-2.5 pt-1 sm:px-4 sm:pt-3 md:hidden [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        {stages.map((stage, idx) => {
          const selected = idx === current
          return (
            <button
              key={stage.id}
              type="button"
              role="tab"
              aria-selected={selected}
              onClick={() => goTo(idx)}
              className={cn(
                'flex min-h-9 shrink-0 items-center gap-1.5 rounded-full border px-3 text-[13px] font-medium transition-colors',
                'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                selected
                  ? 'border-primary bg-primary text-primary-foreground'
                  : 'bg-card text-foreground',
              )}
            >
              <span
                className="size-2 rounded-full"
                style={{ backgroundColor: stage.color || '#94A3B8' }}
                aria-hidden
              />
              {stage.name}
              <span
                className={cn(
                  'rounded-full px-1.5 text-xs font-semibold tabular-nums',
                  selected ? 'bg-white/20' : 'bg-muted text-muted-foreground',
                )}
              >
                {byStage[stage.id]?.length ?? 0}
              </span>
            </button>
          )
        })}
      </div>

      <div
        ref={pagerRef}
        onScroll={onPagerScroll}
        className="flex min-h-0 flex-1 snap-x snap-mandatory overflow-x-auto overflow-y-hidden overscroll-x-contain [scrollbar-width:none] [&::-webkit-scrollbar]:hidden md:snap-none md:gap-3 md:p-3 md:[scrollbar-width:thin] md:[&::-webkit-scrollbar]:block"
      >
        {stages.map((stage) => {
          const items = byStage[stage.id] ?? []
          const total = items.reduce(
            (sum, o) => sum + (Number.isFinite(Number(o.estimated_value)) ? Number(o.estimated_value) : 0),
            0,
          )
          const next = nextAdvanceStage(stages, stage.id)
          return (
            <section
              key={stage.id}
              role="tabpanel"
              aria-label={stage.name}
              className="w-full shrink-0 snap-start overflow-y-auto px-3 pb-6 pt-3 sm:px-4 md:w-auto md:min-w-[230px] md:flex-1 md:overflow-x-hidden md:rounded-xl md:border md:bg-muted/40 md:px-2.5 md:pb-3 md:pt-2.5"
            >
              <div className="mb-2.5 flex items-baseline justify-between gap-2">
                <h3 className="flex min-w-0 items-center gap-1.5 text-[15px] font-semibold md:text-sm">
                  <span
                    className="size-2.5 rounded-full"
                    style={{ backgroundColor: stage.color || '#94A3B8' }}
                    aria-hidden
                  />
                  <span className="truncate">{stage.name}</span>
                </h3>
                <span className="shrink-0 text-xs tabular-nums text-muted-foreground">
                  {items.length} · {formatCurrency(total, items[0]?.currency ?? 'COP')}
                </span>
              </div>

              {items.length === 0 ? (
                <p className="rounded-xl border border-dashed p-10 text-center text-sm text-muted-foreground md:p-6 md:text-xs">
                  No hay oportunidades en esta etapa
                </p>
              ) : (
                <div className="grid gap-2.5 sm:grid-cols-2 md:grid-cols-[minmax(0,1fr)] md:gap-2">
                  {items.map((opp) => (
                    <StageOpportunityCard
                      key={opp.id}
                      opportunity={opp}
                      next={canMove(opp) ? next : null}
                      disabled={isPending}
                      onOpen={() => onSelectOpportunity(opp.id)}
                      onAdvance={(stageTo) => advance(opp, stageTo)}
                    />
                  ))}
                </div>
              )}
            </section>
          )
        })}
      </div>

      <AlertDialog open={confirm != null} onOpenChange={(open) => !open && setConfirm(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Marcar «{confirm?.stage.name}»?</AlertDialogTitle>
            <AlertDialogDescription>
              {confirm?.opp.contact_name} quedará como negocio ganado. Si fue un error, puedes
              moverla de nuevo desde su ficha.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (confirm) moveStage(confirm.opp, confirm.stage.id)
                setConfirm(null)
              }}
            >
              Sí, marcar como ganada
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

interface StageOpportunityCardProps {
  opportunity: Opportunity
  /** Etapa del botón «Pasar a …»; null = sin botón (cierre o sin permiso). */
  next: PipelineStage | null
  disabled: boolean
  onOpen: () => void
  onAdvance: (stage: PipelineStage) => void
}

function StageOpportunityCard({ opportunity: opp, next, disabled, onOpen, onAdvance }: StageOpportunityCardProps) {
  const days = daysInStageLabel(opp.updated_at)
  const value = Number.isFinite(Number(opp.estimated_value)) ? Number(opp.estimated_value) : 0
  const hasReminder =
    opp.reminder_due_at && new Date(opp.reminder_due_at) <= new Date(Date.now() + 24 * 60 * 60 * 1000)

  return (
    <article
      className={cn(
        'grid min-w-0 grid-cols-[minmax(0,1fr)] content-between gap-2 rounded-xl border bg-card p-3 shadow-sm',
        opp.status === 'lost' && 'opacity-60',
        opp.status === 'won' && 'border-green-500/40',
        opp.from_network && 'border-indigo-500/35',
      )}
    >
      <button
        type="button"
        onClick={onOpen}
        className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-2 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring rounded-md"
      >
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0 flex-1">
            <p className="flex items-center gap-1.5 text-[15px] font-semibold leading-tight md:text-sm">
              <span className="min-w-0 truncate" title={opp.contact_name || opp.title}>{opp.contact_name || opp.title || 'Sin nombre'}</span>
              {hasReminder && <Bell className="size-3.5 shrink-0 text-amber-500" aria-label="Recordatorio próximo" />}
            </p>
            {opp.company_name && (
              <p className="mt-0.5 truncate text-xs text-muted-foreground">{opp.company_name}</p>
            )}
          </div>
          {opp.owner?.name && (
            <span
              className="grid size-8 shrink-0 place-items-center rounded-full bg-primary/10 text-[11px] font-bold text-primary"
              title={opp.owner.name}
            >
              {initials(opp.owner.name)}
            </span>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
          <TemperatureBadge temperature={opp.temperature ?? 'cold'} />
          <span className="font-semibold tabular-nums">{formatCurrency(value, opp.currency)}</span>
          {days.label && (
            <span
              className={cn(
                'flex items-center gap-1',
                days.urgent ? 'font-semibold text-amber-600 dark:text-amber-400' : 'text-muted-foreground',
              )}
            >
              {days.urgent && <Clock className="size-3" aria-hidden />}
              {days.label}
            </span>
          )}
        </div>
      </button>

      {next && (
        <Button
          type="button"
          className={cn('h-11 w-full min-w-0 gap-1.5 text-sm font-semibold md:h-9 md:text-[13px]', next.is_closed_won && 'bg-green-600 hover:bg-green-700')}
          disabled={disabled}
          onClick={() => onAdvance(next)}
        >
          {next.is_closed_won ? (
            <>
              <CheckCircle2 className="size-4" />
              <span className="truncate">Marcar {next.name}</span>
            </>
          ) : (
            <>
              <ArrowRight className="size-4" />
              <span className="truncate">Pasar a {next.name}</span>
            </>
          )}
        </Button>
      )}
    </article>
  )
}
