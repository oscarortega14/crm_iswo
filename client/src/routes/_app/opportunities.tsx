import { createFileRoute, useSearch } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import {
  LayoutGrid,
  Table as TableIcon,
  Plus,
  Search,
  RefreshCw,
  Trash2,
  ArrowRightLeft,
  ChevronDown,
} from 'lucide-react'
import { z } from 'zod'
import {
  invalidateContactSegmentMetrics,
  invalidateNotificationsQueries,
  queryKeys,
} from '@/lib/queryClient'
import { Button } from '@/components/ui/button'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Input } from '@/components/ui/input'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { OpportunitiesFiltersPopover } from '@/components/opportunities/OpportunitiesFiltersPopover'
import { KanbanBoard } from '@/components/opportunities/KanbanBoard'
import { OpportunitiesTable } from '@/components/opportunities/OpportunitiesTable'
import { OpportunitySlideOver } from '@/components/opportunities/OpportunitySlideOver'
import { QuickAddOpportunity } from '@/components/opportunities/QuickAddOpportunity'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { Skeleton } from '@/components/ui/skeleton'
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
import { fetchContactDetail } from '@/lib/contactApi'
import {
  bulkDeleteOpportunities,
  bulkMoveOpportunitiesStage,
  fetchOpportunities,
  jsonApiPrimaryList,
  mapPipelineResource,
  opportunityListErrorMessage,
} from '@/lib/opportunityApi'
import api, { formatRailsError } from '@/lib/api'
import { fetchLandingPageDetail, fetchLandingPagesIndex } from '@/lib/landingPagesApi'
import { tenantHasModule } from '@/lib/tenantModules'
import {
  countOpportunitiesByOwnership,
  matchesOwnershipFilter,
  type OpportunityOwnershipFilter,
} from '@/lib/opportunityOwnership'
import { OpportunityOwnershipToolbar } from '@/components/opportunities/OpportunityOwnershipToolbar'
import { useAuthStore } from '@/stores/auth'
import { toast } from 'sonner'
import type { Opportunity, PipelineStage } from '@/types'

const opportunitiesSearchSchema = z.object({
  view: z.enum(['kanban', 'table']).optional().default('kanban'),
  pipeline: z.string().optional(),
  stage: z.string().optional(),
  selected: z.string().optional(),
  contact: z.string().optional(),
  landing: z.string().optional(),
  add: z.coerce.boolean().optional(),
  temperature: z.enum(['cold', 'warm', 'hot']).optional(),
  owner: z.string().optional(),
  status: z.string().optional(),
  stale: z.coerce.boolean().optional(),
  ownership: z.enum(['all', 'own', 'network']).optional(),
})

export const Route = createFileRoute('/_app/opportunities')({
  validateSearch: opportunitiesSearchSchema,
  component: OpportunitiesPage,
})

function OpportunitiesPage() {
  const search = useSearch({ from: '/_app/opportunities' })
  const navigate = Route.useNavigate()
  const queryClient = useQueryClient()
  const user = useAuthStore((s) => s.user)
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authScope = useAuthStore((s) =>
    s.user?.id && s.tenant?.subdomain
      ? `${s.tenant.subdomain.trim().toLowerCase()}:user:${s.user.id}`
      : '',
  )
  const userRole = user?.role
  const canCreateOpportunity = userRole !== 'viewer'
  const canDeleteOpportunities = userRole === 'admin'
  // Mover en lote: mismas reglas que arrastrar en el Kanban (viewer no; consultor solo propias).
  const canBulkMove = userRole === 'admin' || userRole === 'manager' || userRole === 'consultant'
  const tenant = useAuthStore((s) => s.tenant)
  const hasOpportunitiesModule = tenantHasModule(tenant, 'opportunities')
  const showOwnershipToolbar =
    hasOpportunitiesModule &&
    (userRole === 'consultant' || userRole === 'admin' || userRole === 'manager')
  const ownershipFilter: OpportunityOwnershipFilter = search.ownership ?? 'all'
  const [quickAddOpen, setQuickAddOpen] = useState(false)
  const [searchInput, setSearchInput] = useState('')
  const [debouncedQ, setDebouncedQ] = useState('')
  const [refreshing, setRefreshing] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [confirmBulkDelete, setConfirmBulkDelete] = useState(false)
  const [confirmMoveStage, setConfirmMoveStage] = useState<PipelineStage | null>(null)
  const contactFilterId = search.contact
  const landingFilterId = search.landing

  const view = search.view || 'kanban'
  const selectedId = search.selected
  const showOwnerFilter = userRole === 'admin' || userRole === 'manager'
  const staleDays = tenant?.settings?.stale_days ?? 7

  useEffect(() => {
    const t = window.setTimeout(() => setDebouncedQ(searchInput.trim()), 350)
    return () => window.clearTimeout(t)
  }, [searchInput])

  const { data: pipelines, isLoading: pipelinesLoading } = useQuery({
    queryKey: queryKeys.pipelines.all,
    queryFn: async () => {
      const response = await api.get('/pipelines')
      const rows = jsonApiPrimaryList(response.data)
      return rows.filter((r) => r.id).map(mapPipelineResource)
    },
  })

  const { data: users = [] } = useQuery({
    queryKey: queryKeys.users.all,
    queryFn: async () => {
      const response = await api.get('/users')
      return jsonApiPrimaryList(response.data)
        .filter((r) => r.id)
        .map((r) => ({
          id: String(r.id),
          name: String(r.attributes?.name ?? r.attributes?.email ?? 'Usuario'),
        }))
    },
    enabled: showOwnerFilter,
    staleTime: 60_000,
  })

  const defaultPipeline = pipelines?.find((p) => p.is_default) || pipelines?.[0]
  // Tras db:seed los UUID de pipeline cambian; ?pipeline= antiguo deja la lista vacía.
  const activePipelineId = useMemo(() => {
    if (!pipelines?.length) return undefined
    if (search.pipeline && pipelines.some((p) => p.id === search.pipeline)) {
      return search.pipeline
    }
    return defaultPipeline?.id
  }, [pipelines, search.pipeline, defaultPipeline?.id])
  const activePipeline =
    pipelines?.find((p) => p.id === activePipelineId) ?? defaultPipeline

  useEffect(() => {
    if (!pipelines?.length || !search.pipeline) return
    if (pipelines.some((p) => p.id === search.pipeline)) return
    navigate({
      search: (prev) => ({ ...prev, pipeline: undefined }),
      replace: true,
    })
  }, [pipelines, search.pipeline, navigate])

  const listFilters = useMemo(
    () =>
      search.contact
        ? {
            contact_id: search.contact,
          }
        : search.landing
          ? {
              landing_page_id: search.landing,
            }
          : {
              pipeline_id: activePipelineId,
              stage_id: search.stage,
              owner_id: search.owner,
              status: search.status,
              temperature: search.temperature,
              q: debouncedQ.length >= 2 ? debouncedQ : undefined,
              stale_days: search.stale ? staleDays : undefined,
            },
    [
      activePipelineId,
      search.contact,
      search.landing,
      search.stage,
      search.owner,
      search.status,
      search.temperature,
      search.stale,
      debouncedQ,
      staleDays,
    ],
  )

  const listQueryKey = queryKeys.opportunities.list(authScope, listFilters)

  const {
    data: opportunities,
    isLoading: opportunitiesLoading,
    isFetching: opportunitiesFetching,
    isError: opportunitiesError,
    error: opportunitiesErr,
  } = useQuery({
    queryKey: listQueryKey,
    queryFn: () => fetchOpportunities(listFilters),
    enabled:
      hasOpportunitiesModule &&
      isAuthenticated &&
      !!authScope &&
      !pipelinesLoading &&
      (!!activePipelineId || !!search.contact || !!search.landing),
    refetchInterval: 15_000,
  })

  useEffect(() => {
    if (opportunitiesError) {
      toast.error(opportunityListErrorMessage(opportunitiesErr))
    }
  }, [opportunitiesError, opportunitiesErr])

  const { data: contactForFilter } = useQuery({
    queryKey: queryKeys.contacts.detail(contactFilterId ?? ''),
    queryFn: () => fetchContactDetail(contactFilterId!),
    enabled: !!contactFilterId,
    staleTime: 30_000,
  })

  const { data: landingPagesIndex = [] } = useQuery({
    queryKey: queryKeys.landingPages.list(authScope),
    queryFn: fetchLandingPagesIndex,
    enabled: !!authScope && !!landingFilterId,
    staleTime: 60_000,
  })

  const { data: landingForFilter } = useQuery({
    queryKey: queryKeys.landingPages.detail(landingFilterId ?? ''),
    queryFn: async () => {
      const row = await fetchLandingPageDetail(landingFilterId!)
      const a = row?.attributes ?? {}
      return { title: String(a.title ?? 'Landing'), slug: String(a.slug ?? '') }
    },
    enabled: !!authScope && !!landingFilterId,
    staleTime: 30_000,
  })

  const landingFilterLabel =
    landingForFilter?.title ??
    landingPagesIndex.find((l) => l.id === landingFilterId)?.title ??
    'Landing'

  const filteredOpportunities = useMemo(() => {
    let all = opportunities ?? []
    const q = searchInput.trim().toLowerCase()
    if (q.length > 0 && q.length < 2) {
      all = all.filter(
        (o) =>
          o.contact_name?.toLowerCase().includes(q) ||
          o.company_name?.toLowerCase().includes(q) ||
          o.contact_email?.toLowerCase().includes(q) ||
          o.contact_phone?.includes(q),
      )
    }
    if (showOwnershipToolbar && ownershipFilter !== 'all') {
      all = all.filter((o) =>
        matchesOwnershipFilter(o, ownershipFilter, user?.id),
      )
    }
    return all
  }, [opportunities, searchInput, showOwnershipToolbar, ownershipFilter, user?.id])

  const ownershipCounts = useMemo(
    () => countOpportunitiesByOwnership(opportunities ?? [], user?.id),
    [opportunities, user?.id],
  )

  const selectedPreview = opportunities?.find((o) => o.id === selectedId)

  const displayPipeline = useMemo(() => {
    const scopeId = contactFilterId || landingFilterId
    if (!scopeId || !filteredOpportunities.length) return activePipeline
    const pid = filteredOpportunities[0]?.pipeline_id
    if (!pid) return activePipeline
    return pipelines?.find((p) => p.id === pid) ?? activePipeline
  }, [contactFilterId, landingFilterId, filteredOpportunities, activePipeline, pipelines])

  const prefilledContactForAdd = useMemo(() => {
    if (!contactFilterId) return undefined
    const name =
      contactForFilter?.fullName?.trim() ||
      filteredOpportunities[0]?.contact_name?.trim() ||
      'Contacto'
    return { id: contactFilterId, name }
  }, [contactFilterId, contactForFilter?.fullName, filteredOpportunities])

  useEffect(() => {
    if (!search.add || !contactFilterId || !prefilledContactForAdd) return
    setQuickAddOpen(true)
    navigate({
      search: (prev) => {
        const { add: _add, ...rest } = prev
        return rest
      },
    })
  }, [search.add, contactFilterId, prefilledContactForAdd, navigate])

  const clearContactFilter = () => {
    navigate({
      search: (prev) => {
        const { contact: _c, add: _a, ...rest } = prev
        return rest
      },
    })
  }

  const clearLandingFilter = () => {
    navigate({
      search: (prev) => {
        const { landing: _l, ...rest } = prev
        return rest
      },
    })
  }

  const handleViewChange = (newView: string) => {
    navigate({ search: (prev) => ({ ...prev, view: newView as 'kanban' | 'table' }) })
  }

  const handleSelectOpportunity = (id: string | null) => {
    navigate({ search: (prev) => ({ ...prev, selected: id || undefined }) })
  }

  const handleRefresh = async () => {
    setRefreshing(true)
    await queryClient.invalidateQueries({ queryKey: queryKeys.opportunities.all })
    await invalidateContactSegmentMetrics(queryClient)
    setRefreshing(false)
  }

  useEffect(() => {
    if (view !== 'table') setSelectedIds(new Set())
  }, [view])

  const bulkDeleteMutation = useMutation({
    mutationFn: () => bulkDeleteOpportunities(Array.from(selectedIds)),
    onSuccess: async (result) => {
      const shouldClosePanel = selectedId != null && selectedIds.has(selectedId)
      toast.success(`${result.deleted} oportunidad(es) eliminada(s)`)
      setSelectedIds(new Set())
      setConfirmBulkDelete(false)
      if (shouldClosePanel) {
        handleSelectOpportunity(null)
      }
      await queryClient.invalidateQueries({ queryKey: queryKeys.opportunities.all })
      await queryClient.invalidateQueries({ queryKey: ['dashboard'] })
      await invalidateContactSegmentMetrics(queryClient)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudieron eliminar las oportunidades'))
    },
  })

  const bulkMoveMutation = useMutation({
    mutationFn: (stage: PipelineStage) => bulkMoveOpportunitiesStage(Array.from(selectedIds), stage.id),
    onSuccess: async (result) => {
      const skipped = result.skipped.length
      const msg = `${result.moved} oportunidad(es) movida(s) a ${result.stage_name}`
      if (skipped > 0) toast.warning(`${msg} · ${skipped} omitida(s) (sin permiso o ya estaban ahí)`)
      else toast.success(msg)
      setSelectedIds(new Set())
      setConfirmMoveStage(null)
      await queryClient.invalidateQueries({ queryKey: queryKeys.opportunities.all })
      await queryClient.invalidateQueries({ queryKey: ['dashboard'] })
      await invalidateContactSegmentMetrics(queryClient)
      void invalidateNotificationsQueries(queryClient)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudieron mover las oportunidades'))
    },
  })

  const canMoveOpportunity = (opp: Opportunity) => {
    if (userRole === 'admin' || userRole === 'manager') return true
    if (userRole !== 'consultant' || opp.network_read_only) return false
    return String(opp.owner_id) === String(user?.id ?? '')
  }

  const handleBulkMove = (stage: PipelineStage) => {
    if (stage.is_closed_won || stage.is_closed_lost) setConfirmMoveStage(stage)
    else bulkMoveMutation.mutate(stage)
  }

  const setOpportunitySelected = (id: string, selected: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (selected) next.add(id)
      else next.delete(id)
      return next
    })
  }

  const setAllOnPageSelected = (selected: boolean, pageIds: string[]) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      pageIds.forEach((id) => {
        if (selected) next.add(id)
        else next.delete(id)
      })
      return next
    })
  }

  const listScopeActive = !!contactFilterId || !!landingFilterId
  // Solo carga inicial: isFetching en el poll cada 15s no debe vaciar el Kanban.
  const isLoading =
    pipelinesLoading ||
    (!authScope && isAuthenticated) ||
    (listScopeActive
      ? opportunitiesLoading
      : !!activePipelineId && opportunitiesLoading)
  const oppCount = filteredOpportunities.length
  const subtitle =
    oppCount === 1 ? '1 oportunidad' : `${oppCount} oportunidades`

  const activeFiltersCount = [
    search.temperature,
    search.owner,
    search.status,
    search.stage,
    search.stale,
    debouncedQ.length >= 2 ? debouncedQ : null,
  ].filter(Boolean).length

  const clearAllFilters = () => {
    setSearchInput('')
    setDebouncedQ('')
    navigate({
      search: (prev) => ({
        ...prev,
        temperature: undefined,
        owner: undefined,
        status: undefined,
        stage: undefined,
        stale: undefined,
      }),
    })
  }

  if (!hasOpportunitiesModule) {
    return (
      <AppPageShell>
        <PageHeader
          title="Oportunidades"
          description="El módulo de oportunidades no está activo en la configuración de este tenant."
        />
      </AppPageShell>
    )
  }

  return (
    <AppPageShell
      className="h-full min-h-0"
      contentClassName="flex h-full min-h-0 flex-col gap-6 p-4 lg:p-6"
    >
      <PageHeader title="Oportunidades" description={subtitle}>
        <div className="relative w-full sm:w-auto sm:min-w-[200px] sm:max-w-[240px]">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar..."
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            className="h-8 w-full pl-8 text-sm"
          />
        </div>

        <OpportunitiesFiltersPopover
          search={{
            pipeline: search.pipeline,
            stage: search.stage,
            temperature: search.temperature,
            owner: search.owner,
            status: search.status,
            stale: search.stale,
          }}
          onSearchChange={(updater) =>
            navigate({ search: (prev) => ({ ...prev, ...updater(prev) }) })
          }
          activePipeline={activePipeline}
          activePipelineId={activePipelineId}
          pipelines={pipelines}
          pipelinesLoading={pipelinesLoading}
          users={users}
          showOwnerFilter={showOwnerFilter}
          staleDays={staleDays}
          activeFiltersCount={activeFiltersCount}
          onClearFilters={clearAllFilters}
        />

        <Tabs value={view} onValueChange={handleViewChange}>
          <TabsList>
            <TabsTrigger value="kanban" className="gap-1.5">
              <LayoutGrid className="size-4" />
              <span className="hidden sm:inline">Kanban</span>
            </TabsTrigger>
            <TabsTrigger value="table" className="gap-1.5">
              <TableIcon className="size-4" />
              <span className="hidden sm:inline">Tabla</span>
            </TabsTrigger>
          </TabsList>
        </Tabs>

        <Button
          size="sm"
          variant="outline"
          className="gap-1.5"
          onClick={handleRefresh}
          disabled={refreshing}
          title="Actualizar leads"
        >
          <RefreshCw
            className={`size-3.5 ${refreshing || opportunitiesFetching ? 'animate-spin' : ''}`}
          />
          <span className="hidden sm:inline">Actualizar</span>
        </Button>

        {canCreateOpportunity && (
          <Button size="sm" className="gap-2 shadow-sm" onClick={() => setQuickAddOpen(true)}>
            <Plus className="size-4" />
            <span className="hidden sm:inline">Nueva</span>
          </Button>
        )}
      </PageHeader>

      {showOwnershipToolbar && !listScopeActive && (
        <OpportunityOwnershipToolbar
          value={ownershipFilter}
          onChange={(ownership) =>
            navigate({ search: (prev) => ({ ...prev, ownership: ownership === 'all' ? undefined : ownership }) })
          }
          counts={ownershipCounts}
          showOwnFilter={userRole === 'consultant'}
        />
      )}

      {landingFilterId && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg border border-emerald-500/25 bg-emerald-500/5 px-4 py-2 text-sm">
          <span>
            Landing:{' '}
            <span className="font-medium text-foreground">{landingFilterLabel}</span>
            {filteredOpportunities.length > 0
              ? ` · ${filteredOpportunities.length} lead(s) desde esta landing`
              : ' · sin leads registrados aún'}
          </span>
          <Button size="sm" variant="ghost" className="h-7 ml-auto" onClick={clearLandingFilter}>
            Quitar filtro
          </Button>
        </div>
      )}

      {contactFilterId && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg border border-primary/25 bg-primary/5 px-4 py-2 text-sm">
          <span>
            Contacto:{' '}
            <span className="font-medium text-foreground">
              {contactForFilter?.fullName ?? '…'}
            </span>
            {filteredOpportunities.length > 0
              ? ` · ${filteredOpportunities.length} lead(s) de este contacto`
              : ' · sin leads aún (puedes crear uno)'}
          </span>
          <span className="text-xs text-muted-foreground w-full">
            Los demás contactos siguen en el pipeline; usa «Quitar filtro» para ver todo.
          </span>
          {canCreateOpportunity && (
            <Button
              size="sm"
              variant="secondary"
              className="h-7"
              onClick={() => setQuickAddOpen(true)}
            >
              Nueva oportunidad
            </Button>
          )}
          <Button size="sm" variant="ghost" className="h-7 ml-auto" onClick={clearContactFilter}>
            Quitar filtro
          </Button>
        </div>
      )}

      <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl border border-border/50 bg-card/40 shadow-sm dark:bg-card/20">
        {isLoading ? (
          <div className="p-4">
            <div className="flex gap-4 overflow-x-auto pb-4">
              {[1, 2, 3, 4, 5].map((i) => (
                <div key={i} className="w-72 shrink-0">
                  <Skeleton className="h-8 w-32 mb-4" />
                  <div className="flex flex-col gap-3">
                    {[1, 2, 3].map((j) => (
                      <Skeleton key={j} className="h-32 w-full rounded-lg" />
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </div>
        ) : opportunitiesError ? (
          <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center">
            <p className="text-sm text-muted-foreground">
              {opportunityListErrorMessage(opportunitiesErr)}
            </p>
            <Button variant="outline" size="sm" onClick={handleRefresh}>
              Reintentar
            </Button>
          </div>
        ) : !activePipeline && !contactFilterId && !landingFilterId ? (
          <div className="flex h-full items-center justify-center p-8 text-sm text-muted-foreground">
            {pipelines && pipelines.length === 0
              ? 'No hay embudos. Crea un pipeline y etapas en Ajustes → Pipelines.'
              : 'No se pudo determinar el embudo activo.'}
          </div>
        ) : contactFilterId && filteredOpportunities.length === 0 && !isLoading ? (
          <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center">
            <p className="text-sm text-muted-foreground max-w-md">
              No hay oportunidades para este contacto con tu usuario (o aún no se creó el lead en el
              pipeline).
            </p>
            {canCreateOpportunity && (
              <Button size="sm" onClick={() => setQuickAddOpen(true)}>
                Crear oportunidad para {contactForFilter?.fullName ?? 'este contacto'}
              </Button>
            )}
          </div>
        ) : landingFilterId && filteredOpportunities.length === 0 && !isLoading ? (
          <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center">
            <p className="text-sm text-muted-foreground max-w-md">
              No hay leads registrados para la landing «{landingFilterLabel}». Los envíos nuevos del
              formulario público aparecerán aquí automáticamente.
            </p>
            <Button size="sm" variant="outline" onClick={clearLandingFilter}>
              Ver todo el pipeline
            </Button>
          </div>
        ) : view === 'kanban' ? (
          <div className="flex min-h-[280px] flex-1 flex-col">
            <KanbanBoard
              opportunities={filteredOpportunities}
              pipeline={displayPipeline}
              onSelectOpportunity={handleSelectOpportunity}
            />
          </div>
        ) : (
          <div className="flex min-h-0 flex-1 flex-col overflow-hidden p-4 lg:p-6">
            {selectedIds.size > 0 && (
              <div className="mb-3 flex shrink-0 flex-wrap items-center gap-2 rounded-lg border bg-muted/40 px-4 py-2">
                <span className="text-sm font-medium">
                  {selectedIds.size} oportunidad(es) seleccionada(s)
                </span>
                <div className="ml-auto flex flex-wrap items-center gap-2">
                  {canBulkMove && (displayPipeline?.stages?.length ?? 0) > 0 && (
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button size="sm" className="gap-1.5" disabled={bulkMoveMutation.isPending}>
                          <ArrowRightLeft className="size-3.5" />
                          Mover a etapa
                          <ChevronDown className="size-3.5" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end" className="max-h-80 overflow-y-auto">
                        <DropdownMenuLabel>{displayPipeline?.name}</DropdownMenuLabel>
                        {displayPipeline?.stages
                          ?.filter((st) => !st.is_closed_won && !st.is_closed_lost)
                          .map((st) => (
                            <DropdownMenuItem key={st.id} onSelect={() => handleBulkMove(st)}>
                              <span
                                className="mr-2 size-2 shrink-0 rounded-full"
                                style={{ backgroundColor: st.color || '#94A3B8' }}
                              />
                              {st.name}
                            </DropdownMenuItem>
                          ))}
                        <DropdownMenuSeparator />
                        {displayPipeline?.stages
                          ?.filter((st) => st.is_closed_won || st.is_closed_lost)
                          .map((st) => (
                            <DropdownMenuItem key={st.id} onSelect={() => handleBulkMove(st)}>
                              <span
                                className="mr-2 size-2 shrink-0 rounded-full"
                                style={{ backgroundColor: st.color || '#94A3B8' }}
                              />
                              {st.name}
                              <span className="ml-auto pl-3 text-xs text-muted-foreground">
                                {st.is_closed_won ? 'cierre ganado' : 'cierre perdido'}
                              </span>
                            </DropdownMenuItem>
                          ))}
                      </DropdownMenuContent>
                    </DropdownMenu>
                  )}
                  {canDeleteOpportunities && (
                    <Button
                      size="sm"
                      variant="destructive"
                      className="gap-1.5"
                      onClick={() => setConfirmBulkDelete(true)}
                    >
                      <Trash2 className="size-3.5" />
                      Eliminar
                    </Button>
                  )}
                  <Button size="sm" variant="ghost" onClick={() => setSelectedIds(new Set())}>
                    Cancelar
                  </Button>
                </div>
              </div>
            )}
            <div className="min-h-0 flex-1 overflow-auto rounded-lg border border-border/50">
              <OpportunitiesTable
                opportunities={filteredOpportunities}
                onSelectOpportunity={handleSelectOpportunity}
                selectable={canDeleteOpportunities || canBulkMove}
                isRowSelectable={canDeleteOpportunities ? undefined : canMoveOpportunity}
                selectedIds={selectedIds}
                onSelectionChange={setOpportunitySelected}
                onSelectAllOnPage={setAllOnPageSelected}
              />
            </div>
          </div>
        )}
      </div>

      <OpportunitySlideOver
        opportunityId={selectedId}
        opportunityPreview={selectedPreview}
        pipeline={displayPipeline ?? activePipeline}
        open={!!selectedId}
        onOpenChange={(open) => {
          if (!open) handleSelectOpportunity(null)
        }}
      />

      <QuickAddOpportunity
        open={quickAddOpen}
        onOpenChange={setQuickAddOpen}
        prefilledContact={prefilledContactForAdd}
        onCreated={(newOpp) => {
          handleSelectOpportunity(newOpp.id)
          if (contactFilterId) {
            void queryClient.invalidateQueries({
              queryKey: queryKeys.contacts.detail(contactFilterId),
            })
          }
        }}
      />

      <AlertDialog
        open={confirmMoveStage != null}
        onOpenChange={(open) => {
          if (!open) setConfirmMoveStage(null)
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              Mover {selectedIds.size} oportunidad(es) a «{confirmMoveStage?.name}»
            </AlertDialogTitle>
            <AlertDialogDescription>
              Es una etapa de cierre: quedarán marcadas como{' '}
              {confirmMoveStage?.is_closed_won ? 'ganadas' : 'perdidas'}. Puedes revertirlo moviéndolas
              de nuevo a otra etapa.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (confirmMoveStage) bulkMoveMutation.mutate(confirmMoveStage)
              }}
            >
              Mover {selectedIds.size} oportunidad(es)
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog open={confirmBulkDelete} onOpenChange={setConfirmBulkDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Eliminar {selectedIds.size} oportunidad(es)</AlertDialogTitle>
            <AlertDialogDescription>
              Se descartarán del pipeline (soft delete). Los contactos asociados no se eliminan. Esta
              acción solo la puede deshacer un administrador desde la base de datos.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => bulkDeleteMutation.mutate()}
            >
              Eliminar {selectedIds.size} oportunidad(es)
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppPageShell>
  )
}
