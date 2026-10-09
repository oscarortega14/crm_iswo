import { createFileRoute, Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ArrowRight, CalendarDays, LayoutGrid, Plus, Sparkles, TrendingUp, BarChart2 } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { getAuthQueryScope, queryKeys } from '@/lib/queryClient'
import { tenantHasModule, tenantShowBant } from '@/lib/tenantModules'
import { canUseReminders } from '@/lib/reminderChannels'
import {
  fetchDashboardActivity,
  fetchDashboardBantDistribution,
  fetchDashboardBriefing,
  fetchDashboardKpis,
  fetchDashboardLeadSources,
  fetchDashboardPipeline,
  fetchDashboardTopConsultants,
} from '@/lib/dashboardApi'
import { jsonApiPrimaryList, mapPipelineResource } from '@/lib/opportunityApi'
import api from '@/lib/api'
import { Button } from '@/components/ui/button'
import { PipelineFunnel } from '@/components/dashboard/PipelineFunnel'
import { TopConsultants } from '@/components/dashboard/TopConsultants'
import { ActivityFeed } from '@/components/dashboard/ActivityFeed'
import { DailyBriefing } from '@/components/dashboard/DailyBriefing'
import { RemindersDashboardCard } from '@/components/dashboard/RemindersDashboardCard'
import { BantDistribution } from '@/components/dashboard/BantDistribution'
import { LeadSourcesChart } from '@/components/dashboard/LeadSourcesChart'
import { LeadTemperatureStrip } from '@/components/dashboard/LeadTemperatureStrip'
import { QuickAddOpportunity } from '@/components/opportunities/QuickAddOpportunity'
import { DashboardSkeleton } from '@/components/dashboard/DashboardSkeleton'
import { DashboardDateLine } from '@/components/dashboard/DashboardKpiStrip'
import { DashboardSection } from '@/components/dashboard/DashboardSection'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAuthStore } from '@/stores/auth'

export const Route = createFileRoute('/_app/')({
  component: DashboardPage,
})

function DashboardPage() {
  const [quickAddOpen, setQuickAddOpen] = useState(false)
  const tenant = useAuthStore((s) => s.tenant)
  const user = useAuthStore((s) => s.user)
  const currency = tenant?.currency ?? 'COP'
  const isManagerOrAbove = user?.role === 'admin' || user?.role === 'manager'

  const { data: pipelines = [], isPending: pipelinesLoading } = useQuery({
    queryKey: queryKeys.pipelines.all,
    queryFn: async () => {
      const response = await api.get('/pipelines')
      return jsonApiPrimaryList(response.data).filter((r) => r.id).map(mapPipelineResource)
    },
    staleTime: 60 * 1000,
  })

  const defaultPipeline = pipelines.find((p) => p.is_default) ?? pipelines[0]
  const [selectedPipelineId, setSelectedPipelineId] = useState<string | undefined>(undefined)

  useEffect(() => {
    if (!selectedPipelineId && defaultPipeline?.id) {
      setSelectedPipelineId(defaultPipeline.id)
    }
  }, [defaultPipeline?.id, selectedPipelineId])

  const activePipelineId = selectedPipelineId ?? defaultPipeline?.id
  const pipelineFilterKey = activePipelineId ?? 'all'
  const authScope = getAuthQueryScope()

  const hasOpportunities = tenantHasModule(tenant, 'opportunities')
  const hasPipeline = tenantHasModule(tenant, 'pipeline')
  const hasReminders = tenantHasModule(tenant, 'reminders') && canUseReminders(user?.role)
  const showBant = tenantShowBant(tenant)

  // 45s de caché: el dashboard no re-fetcha en cada navegación interna.
  // refetchOnWindowFocus desactivado — evita 7 peticiones al hacer alt-tab.
  const dashboardQueryOpts = { staleTime: 45_000, refetchOnWindowFocus: false } as const

  const briefingEnabled = Boolean(authScope) && hasOpportunities

  const { data: briefing, isPending: briefingPending, isError: briefingError } = useQuery({
    queryKey: queryKeys.dashboard.briefing(authScope, pipelineFilterKey),
    queryFn: () => fetchDashboardBriefing(activePipelineId),
    enabled: briefingEnabled,
    ...dashboardQueryOpts,
  })

  // kpisQ solo se activa cuando briefing no está habilitado: briefing ya incluye
  // todos los KPIs como superset, llamar a ambos duplica trabajo en el servidor.
  const kpisQ = useQuery({
    queryKey: queryKeys.dashboard.kpis(authScope, pipelineFilterKey),
    queryFn: () => fetchDashboardKpis(activePipelineId),
    enabled: Boolean(authScope) && hasOpportunities && !briefingEnabled,
    ...dashboardQueryOpts,
  })

  const pipelineQ = useQuery({
    queryKey: queryKeys.dashboard.pipeline(authScope, activePipelineId ?? 'default'),
    queryFn: () => fetchDashboardPipeline(activePipelineId),
    enabled: Boolean(authScope) && hasPipeline,
    ...dashboardQueryOpts,
  })

  // Fase 2: solo se disparan cuando briefing o pipeline ya respondieron (evita saturar Puma)
  const phase2Ready = Boolean(authScope) && (!briefingEnabled || Boolean(briefing) || Boolean(pipelineQ.data))

  const consultantsQ = useQuery({
    queryKey: queryKeys.dashboard.topConsultants(authScope, pipelineFilterKey),
    queryFn: () => fetchDashboardTopConsultants(activePipelineId),
    enabled: phase2Ready && isManagerOrAbove && hasOpportunities,
    ...dashboardQueryOpts,
  })

  const activityQ = useQuery({
    queryKey: queryKeys.dashboard.activity(authScope, pipelineFilterKey),
    queryFn: () => fetchDashboardActivity(activePipelineId),
    enabled: phase2Ready && hasOpportunities,
    refetchInterval: 120_000,
    ...dashboardQueryOpts,
  })

  const bantQ = useQuery({
    queryKey: queryKeys.dashboard.bantDistribution(authScope, pipelineFilterKey),
    queryFn: () => fetchDashboardBantDistribution(activePipelineId),
    enabled: phase2Ready && hasOpportunities && showBant,
    ...dashboardQueryOpts,
  })

  const leadSourcesQ = useQuery({
    queryKey: queryKeys.dashboard.leadSources(authScope, pipelineFilterKey),
    queryFn: () => fetchDashboardLeadSources(activePipelineId),
    enabled: phase2Ready && hasOpportunities,
    ...dashboardQueryOpts,
  })

  const movementActivity = useMemo(
    () => (activityQ.data ?? []).filter((item) => item.type !== 'reminder_due'),
    [activityQ.data],
  )

  // Solo bloquea en pipelines (query ligera). El resto muestra loading inline.
  if (pipelinesLoading) return <DashboardSkeleton />

  const pipelineOptions = pipelines.map((p) => ({
    id: p.id,
    name: p.name,
    is_default: p.is_default,
  }))

  const activePipelineName =
    pipelineOptions.find((p) => p.id === activePipelineId)?.name ?? 'Pipeline'

  return (
    <AppPageShell contentClassName="space-y-6 sm:space-y-10">

      {/* ── Header ──────────────────────────────────────────────────────── */}
      <PageHeader
        title={tenant?.name ?? 'CRM ISWO'}
        belowTitle={<DashboardDateLine />}
      >
        <Button variant="outline" size="sm" className="gap-2" asChild>
          <Link to="/opportunities" search={{ view: 'kanban' }}>
            <LayoutGrid className="size-4" />
            Ver oportunidades
            <ArrowRight className="size-3.5 opacity-70" />
          </Link>
        </Button>
        <Button size="sm" className="gap-2 shadow-sm" onClick={() => setQuickAddOpen(true)}>
          <Plus className="size-4" />
          <span className="hidden sm:inline">Nueva oportunidad</span>
          <span className="sm:hidden">Nueva</span>
        </Button>
      </PageHeader>

      {hasOpportunities && (
      <DashboardSection title="Ruta del día" icon={Sparkles} accent="brand">
        <DailyBriefing
          data={briefing}
          userName={user?.name}
          currency={currency}
          isLoading={briefingPending}
          isError={briefingError}
        />
      </DashboardSection>
      )}

      {hasPipeline && (
      <DashboardSection
        title="Pipeline"
        subtitle={pipelines.length > 1 ? activePipelineName : undefined}
        icon={TrendingUp}
        accent="brand"
      >
        <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
          <div className="xl:col-span-2">
            <PipelineFunnel
              currency={currency}
              data={pipelineQ.data}
              isLoading={pipelineQ.isPending}
              isError={pipelineQ.isError}
              pipelines={pipelineOptions}
              selectedPipelineId={activePipelineId}
              onPipelineChange={setSelectedPipelineId}
            />
          </div>
          {isManagerOrAbove && (
            <TopConsultants
              currency={currency}
              data={consultantsQ.data}
              isLoading={consultantsQ.isPending}
              isError={consultantsQ.isError}
            />
          )}
        </div>
      </DashboardSection>
      )}

      {hasOpportunities && showBant && (
      <DashboardSection title="Distribución BANT" icon={BarChart2} accent="brand">
        <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
          <BantDistribution
            data={bantQ.data}
            isLoading={bantQ.isPending}
            isError={bantQ.isError}
          />
          <LeadSourcesChart
            currency={currency}
            data={leadSourcesQ.data}
            isLoading={leadSourcesQ.isPending}
            isError={leadSourcesQ.isError}
          />
        </div>
        <LeadTemperatureStrip
          hotCount={briefing?.kpis.hot_count ?? kpisQ.data?.hot_count ?? 0}
          warmCount={briefing?.kpis.warm_count ?? kpisQ.data?.warm_count ?? 0}
          coldCount={briefing?.kpis.cold_count ?? kpisQ.data?.cold_count ?? 0}
          loading={briefingPending && kpisQ.isPending}
        />
      </DashboardSection>
      )}

      {(hasReminders || hasOpportunities) && (
      <DashboardSection title="Seguimiento comercial" icon={CalendarDays} accent="sky">
        <div className="space-y-6">
          {hasReminders && (
            <RemindersDashboardCard briefing={briefing} isLoading={briefingPending} />
          )}
          {hasOpportunities && (
            <ActivityFeed
              data={movementActivity}
              isLoading={activityQ.isPending}
              isError={activityQ.isError}
              variant="movement-only"
            />
          )}
        </div>
      </DashboardSection>
      )}

      <QuickAddOpportunity open={quickAddOpen} onOpenChange={setQuickAddOpen} />
    </AppPageShell>
  )
}

