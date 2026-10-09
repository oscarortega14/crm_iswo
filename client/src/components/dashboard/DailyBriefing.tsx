import { Link, useNavigate } from '@tanstack/react-router'
import {
  Briefcase,
  CheckCircle2,
  Flame,
  Gauge,
  Lightbulb,
  Snowflake,
  Target,
  TrendingUp,
} from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { OpportunityLeadRow } from '@/components/opportunities/OpportunityLeadRow'
import { TemperatureBadge } from '@/components/opportunities/TemperatureBadge'
import type { DashboardBriefing } from '@/lib/dashboardApi'
import {
  fraseMotivadora,
  getEnergyEmoji,
  getTimeGreeting,
} from '@/lib/routeDayGreeting'
import { cn, formatCurrency, formatRelativeTime, type TemperatureLevel } from '@/lib/utils'
import { statGridClass } from '@/lib/layoutClasses'

interface DailyBriefingProps {
  data?: DashboardBriefing
  userName?: string | null
  currency: string
  isLoading?: boolean
  isError?: boolean
}

function RouteDayWelcome({ userName, hotLeadsCount }: { userName?: string | null; hotLeadsCount: number }) {
  const saludo = getTimeGreeting()
  const energia = getEnergyEmoji(hotLeadsCount)
  const nombre = userName?.trim() || 'equipo'

  return (
    <div className="rounded-xl border border-primary/20 bg-gradient-to-r from-primary/[0.08] via-transparent to-transparent px-4 py-4 sm:px-5">
      <h2 className="text-xl font-semibold tracking-tight text-foreground sm:text-2xl">
        {saludo}, {nombre} {energia}
      </h2>
      <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">
        {fraseMotivadora(hotLeadsCount)}
      </p>
    </div>
  )
}

export function DailyBriefing({
  data,
  currency,
  isLoading,
  isError,
  userName,
}: DailyBriefingProps) {
  const navigate = useNavigate()

  if (isLoading) {
    return (
      <BriefingSkeleton userName={userName} />
    )
  }

  if (isError || !data) {
    return (
      <Card>
        <CardContent className="p-5 text-sm text-muted-foreground">
          No se pudo cargar la ruta del día. Recarga la página.
        </CardContent>
      </Card>
    )
  }

  const { kpis, hot_leads, stale_leads } = data
  const displayCurrency = kpis.currency || currency
  const hasItems = hot_leads.length > 0 || stale_leads.length > 0

  const openOpportunity = (id: string) =>
    navigate({ to: '/opportunities', search: { selected: id } })

  const winRateLabel =
    kpis.win_rate != null
      ? `${kpis.win_rate}%`
      : '—'

  const kpiCards = [
    {
      title: 'Oportunidades abiertas',
      hint: formatCurrency(kpis.pipeline_value, displayCurrency),
      value: String(kpis.total_open),
      icon: Briefcase,
      color: 'text-blue-600',
      bg: 'bg-blue-50 dark:bg-blue-950/40',
    },
    {
      title: 'Cierre del mes',
      hint: `${kpis.won_count} ganadas · ${kpis.lost_count} perdidas`,
      value: formatCurrency(kpis.month_closed_value ?? 0, displayCurrency),
      icon: Target,
      color: 'text-amber-600',
      bg: 'bg-amber-50 dark:bg-amber-950/40',
    },
    {
      title: 'Tasa de cierre',
      hint: 'Mes en curso',
      value: winRateLabel,
      icon: TrendingUp,
      color: 'text-emerald-600',
      bg: 'bg-emerald-50 dark:bg-emerald-950/40',
    },
    {
      title: 'BANT promedio',
      hint: 'Portafolio abierto',
      value: String(kpis.bant_average ?? 0),
      icon: Gauge,
      color: 'text-violet-600',
      bg: 'bg-violet-50 dark:bg-violet-950/40',
    },
    {
      title: 'Leads calientes',
      hint: 'Prioridad inmediata',
      value: String(kpis.hot_count),
      icon: Flame,
      color: 'text-red-600',
      bg: 'bg-red-50 dark:bg-red-950/40',
    },
    {
      title: 'Nuevas esta semana',
      hint: 'Últimos 7 días',
      value: String(kpis.new_this_week),
      icon: TrendingUp,
      color: 'text-green-600',
      bg: 'bg-green-50 dark:bg-green-950/40',
    },
  ]

  const hotLeadsCount = kpis.hot_count ?? hot_leads.length

  return (
    <div className="space-y-4">
      <RouteDayWelcome userName={userName} hotLeadsCount={hotLeadsCount} />

      {data.day_recommendation ? (
        <Card className="border-amber-500/30 bg-gradient-to-r from-amber-500/10 via-transparent to-transparent">
          <CardContent className="flex gap-3 p-4">
            <Lightbulb className="size-5 shrink-0 text-amber-600 dark:text-amber-400" />
            <div>
              <p className="text-xs font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-300">
                Recomendación del día
              </p>
              <p className="mt-1 text-sm leading-relaxed text-foreground">
                {data.day_recommendation}
              </p>
            </div>
          </CardContent>
        </Card>
      ) : null}

      <div className={`${statGridClass} xl:grid-cols-3`}>
        {kpiCards.map((card) => (
          <Card key={card.title}>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium text-muted-foreground">
                {card.title}
              </CardTitle>
              <div className={cn('rounded-lg p-2', card.bg)}>
                <card.icon className={cn('size-4', card.color)} />
              </div>
            </CardHeader>
            <CardContent>
              <p className="text-xl font-bold tabular-nums sm:text-2xl">{card.value}</p>
              {card.hint ? (
                <p className="mt-1 text-[11px] text-muted-foreground">{card.hint}</p>
              ) : null}
            </CardContent>
          </Card>
        ))}
      </div>

      {!hasItems ? (
        <Card>
          <CardContent className="flex items-center gap-3 p-5">
            <CheckCircle2 className="size-5 shrink-0 text-emerald-500" />
            <div>
              <p className="text-sm font-medium">
                {kpis.total_open === 0
                  ? 'Sin oportunidades abiertas. Buen momento para captar leads.'
                  : 'Todo al día — sin leads sin seguimiento reciente.'}
              </p>
              {kpis.total_open > 0 && (
                <p className="text-xs text-muted-foreground mt-1">
                  {kpis.total_open} oportunidad{kpis.total_open !== 1 ? 'es' : ''} activa
                  {kpis.total_open !== 1 ? 's' : ''}.
                </p>
              )}
            </div>
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardContent className="divide-y divide-border p-0">
            {hot_leads.length > 0 && (
              <Section
                icon={Flame}
                title="Leads calientes"
                iconColor="text-red-500"
                action={
                  <Link
                    to="/opportunities"
                    search={{ temperature: 'hot', view: 'kanban' }}
                    className="text-xs text-primary hover:underline"
                  >
                    Ver kanban
                  </Link>
                }
              >
                {hot_leads.map((lead) => (
                  <button
                    key={lead.id}
                    type="button"
                    onClick={() => openOpportunity(lead.id)}
                    className="flex w-full items-center gap-3 rounded-md px-2 py-2 text-left transition-colors hover:bg-muted/60"
                  >
                    <OpportunityLeadRow
                      size="md"
                      className="flex-1 min-w-0"
                      contactName={lead.contact_name || lead.title || 'Sin nombre'}
                      stageName={lead.stage_name}
                      stageReferenceAt={lead.updated_at}
                      customFields={lead.custom_fields}
                      propertyTitle={lead.title}
                    />
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      {lead.days_without_activity != null && lead.days_without_activity > 0 && (
                        <span className="text-[10px] font-medium text-amber-600 dark:text-amber-400">
                          {lead.days_without_activity}d sin actividad
                        </span>
                      )}
                      <span className="font-mono text-xs font-semibold text-red-600 dark:text-red-400">
                        BANT {lead.bant_score}
                      </span>
                      {lead.estimated_value > 0 && (
                        <span className="text-[10px] text-muted-foreground tabular-nums">
                          {formatCurrency(lead.estimated_value, lead.currency || displayCurrency)}
                        </span>
                      )}
                      <TemperatureBadge
                        temperature={lead.temperature as TemperatureLevel}
                        className="scale-90"
                      />
                    </div>
                  </button>
                ))}
              </Section>
            )}

            {stale_leads.length > 0 && (
              <Section icon={Snowflake} title="Sin actividad reciente" iconColor="text-slate-400">
                {stale_leads.map((lead) => (
                  <button
                    key={lead.id}
                    type="button"
                    onClick={() => openOpportunity(lead.id)}
                    className="flex w-full items-center gap-3 rounded-md px-2 py-2 text-left transition-colors hover:bg-muted/60"
                  >
                    <OpportunityLeadRow
                      size="md"
                      className="flex-1 min-w-0"
                      contactName={lead.contact_name || lead.title || 'Sin nombre'}
                      stageName={lead.stage_name}
                      stageReferenceAt={lead.last_activity_at}
                      customFields={lead.custom_fields}
                      propertyTitle={lead.title}
                    />
                    <span className="shrink-0 text-[10px] text-amber-600 dark:text-amber-400 tabular-nums">
                      {lead.last_activity_at ? formatRelativeTime(lead.last_activity_at) : '—'}
                    </span>
                  </button>
                ))}
              </Section>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  )
}

function Section({
  icon: Icon,
  title,
  iconColor,
  action,
  children,
}: {
  icon: typeof Flame
  title: string
  iconColor: string
  action?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <div className="p-4">
      <div className="mb-3 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Icon className={cn('size-4', iconColor)} aria-hidden />
          <h3 className="text-sm font-semibold">{title}</h3>
        </div>
        {action}
      </div>
      <div className="space-y-1">{children}</div>
    </div>
  )
}

function BriefingSkeleton({ userName }: { userName?: string | null }) {
  return (
    <div className="space-y-4">
      <RouteDayWelcome userName={userName} hotLeadsCount={0} />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 3 }).map((_, i) => (
          <Card key={i}>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <Skeleton className="h-4 w-28" />
              <Skeleton className="h-8 w-8 rounded-lg" />
            </CardHeader>
            <CardContent>
              <Skeleton className="h-8 w-12" />
            </CardContent>
          </Card>
        ))}
      </div>
      <Card>
        <CardContent className="space-y-3 p-4">
          <Skeleton className="h-4 w-36" />
          <Skeleton className="h-10 w-full rounded-md" />
          <Skeleton className="h-10 w-full rounded-md" />
        </CardContent>
      </Card>
    </div>
  )
}
