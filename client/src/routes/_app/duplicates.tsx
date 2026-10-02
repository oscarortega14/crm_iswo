import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { requireRole } from '@/lib/authGuards'
import { useState, useEffect, useRef } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  Merge,
  Trash2,
  CheckCircle2,
  AlertTriangle,
  User,
  Briefcase,
  RefreshCw,
  ScanSearch,
  ExternalLink,
  Clock,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'
import { jsonApiPrimaryList, mapUserResource } from '@/lib/opportunityApi'
import api, { formatRailsError } from '@/lib/api'
import {
  duplicateFlagsErrorMessage,
  fetchDuplicateFlagsList,
  fetchDuplicateFlagsStats,
  ignoreDuplicateFlag,
  matchedOnLabel,
  mergeDuplicateFlag,
  reassignDuplicateFlag,
  scanDuplicateFlags,
  type ContactLite,
  type DuplicateFlagRow,
  type OpportunitySummary,
} from '@/lib/duplicateFlagsApi'
import {
  DUPLICATE_FLAGS_POLL_MS,
  getAuthQueryScope,
  invalidateDuplicateFlagsQueries,
  invalidateNotificationsQueries,
  queryKeys,
} from '@/lib/queryClient'
import { tenantHasModule } from '@/lib/tenantModules'
import { useAuthStore } from '@/stores/auth'
import { formatDate } from '@/lib/utils'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { statGridClass } from '@/lib/layoutClasses'

const PAGE_SIZE = 25

export const Route = createFileRoute('/_app/duplicates')({
  beforeLoad: () => requireRole('admin', 'manager', 'consultant'),
  component: DuplicatesPage,
})

function CollisionSide({
  title,
  contact,
  opportunity,
  onOpenOpportunity,
}: {
  title: string
  contact: ContactLite | null
  opportunity: OpportunitySummary | null
  onOpenOpportunity: (id: string) => void
}) {
  const displayName =
    opportunity?.contact_name?.trim() ||
    contact?.full_name?.trim() ||
    (opportunity?.id ? `Oportunidad #${opportunity.id}` : 'Sin datos')

  return (
    <div className="flex flex-col gap-2 rounded-lg border bg-muted/30 p-4">
      <p className="text-xs font-medium text-muted-foreground">{title}</p>
      <div className="min-w-0 space-y-1">
          <p className="truncate font-medium">{displayName}</p>
          {contact?.email ? (
            <p className="truncate text-sm text-muted-foreground">{contact.email}</p>
          ) : null}
          {contact?.phone ? (
            <p className="text-sm text-muted-foreground">{contact.phone}</p>
          ) : null}
          {opportunity?.owner_name ? (
            <p className="text-sm text-muted-foreground flex items-center gap-1">
              <User className="h-3.5 w-3.5 shrink-0" />
              <span>
                Responsable: <strong className="text-foreground">{opportunity.owner_name}</strong>
              </span>
            </p>
          ) : null}
          {opportunity?.created_at ? (
            <p className="text-sm text-muted-foreground flex items-center gap-1">
              <Clock className="h-3.5 w-3.5 shrink-0" />
              Desde {formatDate(opportunity.created_at)}
            </p>
          ) : null}
          {opportunity?.id ? (
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="mt-2 h-7 text-xs"
              onClick={() => onOpenOpportunity(opportunity.id)}
            >
              <ExternalLink className="mr-1 h-3 w-3" />
              Ver en pipeline
            </Button>
          ) : null}
      </div>
    </div>
  )
}

function DuplicatesPage() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const tenant = useAuthStore((s) => s.tenant)
  const authScope = getAuthQueryScope()
  const hasOpportunities = tenantHasModule(tenant, 'opportunities')
  const userRole = useAuthStore((s) => s.user?.role)
  const canResolve = userRole === 'admin' || userRole === 'manager'

  const [resolutionFilter, setResolutionFilter] = useState<'pending' | 'all'>('pending')
  const [page, setPage] = useState(1)
  const [mergeConfirmFlag, setMergeConfirmFlag] = useState<DuplicateFlagRow | null>(null)
  const [ignoreConfirmFlag, setIgnoreConfirmFlag] = useState<DuplicateFlagRow | null>(null)
  const [reassignFlag, setReassignFlag] = useState<DuplicateFlagRow | null>(null)
  const [reassignUserId, setReassignUserId] = useState('')

  const openOpportunity = (id: string) => {
    void navigate({ to: '/opportunities', search: { selected: id } })
  }

  const {
    data: listPayload,
    isLoading,
    isError,
    error,
    refetch,
    isRefetching,
  } = useQuery({
    queryKey: queryKeys.duplicateFlags.list(authScope, { resolution: resolutionFilter, page }),
    queryFn: () =>
      fetchDuplicateFlagsList({
        page,
        items: PAGE_SIZE,
        resolution: resolutionFilter === 'pending' ? 'pending' : undefined,
      }),
    enabled: Boolean(authScope) && hasOpportunities,
    staleTime: 0,
    refetchInterval: canResolve ? DUPLICATE_FLAGS_POLL_MS : false,
    refetchIntervalInBackground: canResolve,
    refetchOnWindowFocus: canResolve,
  })

  const { data: duplicateStats } = useQuery({
    queryKey: queryKeys.duplicateFlags.stats(authScope),
    queryFn: fetchDuplicateFlagsStats,
    enabled: Boolean(authScope) && hasOpportunities,
    staleTime: 0,
    refetchInterval: canResolve ? DUPLICATE_FLAGS_POLL_MS : false,
    refetchIntervalInBackground: canResolve,
    refetchOnWindowFocus: canResolve,
  })

  const flags = listPayload?.flags ?? []
  const pagination = listPayload?.pagination
  const totalCount = pagination?.count ?? flags.length
  const totalPages = pagination?.pages ?? 1

  const prevPendingCountRef = useRef<number | null>(null)
  useEffect(() => {
    if (!canResolve || resolutionFilter !== 'pending' || isLoading) return
    const prev = prevPendingCountRef.current
    if (prev !== null && totalCount > prev) {
      const delta = totalCount - prev
      toast.info(
        delta === 1 ? 'Nuevo duplicado detectado' : `${delta} duplicados nuevos detectados`
      )
    }
    prevPendingCountRef.current = totalCount
  }, [totalCount, canResolve, resolutionFilter, isLoading])

  const invalidate = () => {
    void invalidateDuplicateFlagsQueries(queryClient)
    void invalidateNotificationsQueries(queryClient)
  }

  const mergeMutation = useMutation({
    mutationFn: mergeDuplicateFlag,
    onSuccess: () => { invalidate(); toast.success('Duplicados fusionados: queda una sola oportunidad y un solo contacto'); setMergeConfirmFlag(null) },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo fusionar')),
  })

  const ignoreMutation = useMutation({
    mutationFn: ignoreDuplicateFlag,
    onSuccess: () => { invalidate(); toast.success('Marcado como no duplicado'); setIgnoreConfirmFlag(null) },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo descartar')),
  })

  const { data: users = [] } = useQuery({
    enabled: Boolean(authScope) && canResolve && hasOpportunities,
    queryKey: queryKeys.users.list({ forReassignPicker: true }),
    queryFn: async () => {
      const response = await api.get('/users', { params: { items: 200 } })
      return jsonApiPrimaryList(response.data).filter((r) => r.id).map(mapUserResource)
    },
    staleTime: 60_000,
  })

  const reassignMutation = useMutation({
    mutationFn: ({ flagId, userId }: { flagId: string; userId: string }) =>
      reassignDuplicateFlag(flagId, userId),
    onSuccess: () => {
      invalidate()
      toast.success('Oportunidad reasignada correctamente')
      setReassignFlag(null)
      setReassignUserId('')
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo reasignar')),
  })

  const scanMutation = useMutation({
    mutationFn: scanDuplicateFlags,
    onSuccess: (d) => {
      invalidate()
      toast[d.created > 0 ? 'success' : 'info'](
        d.created > 0
          ? `Escaneo completado: ${d.created} duplicado(s) nuevo(s) detectado(s)`
          : `Sin duplicados nuevos (${d.scanned} contacto(s) revisados)`
      )
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'Error durante el escaneo')),
  })

  const pendingInView = flags.filter((f) => f.pending).length
  const pendingTotal = duplicateStats?.pending ?? (resolutionFilter === 'pending' ? totalCount : pendingInView)

  const getMatchScoreColor = (score: number) => {
    if (score >= 90) return 'text-red-600'
    if (score >= 80) return 'text-amber-600'
    return 'text-primary'
  }

  if (!hasOpportunities) {
    return (
      <AppPageShell>
        <PageHeader
          title="Duplicados"
          description="El módulo de oportunidades no está activo en este tenant."
        />
      </AppPageShell>
    )
  }

  return (
    <AppPageShell contentClassName="gap-8">
      <PageHeader
        title="Duplicados"
        description={
          canResolve
            ? 'Colisiones entre oportunidades (RFC §6.2). Admin y manager ven nuevos registros de consultores en esta lista cada pocos segundos.'
            : 'Colisiones donde participas: registraste la oportunidad o eres responsable de alguna de las dos (RFC §6.2). Un manager resolverá la duplicidad.'
        }
      >
        <Select
          value={resolutionFilter}
          onValueChange={(v) => {
            setResolutionFilter(v as 'pending' | 'all')
            setPage(1)
          }}
        >
          <SelectTrigger className="w-[200px]">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="pending">Solo pendientes</SelectItem>
            <SelectItem value="all">Todos los estados</SelectItem>
          </SelectContent>
        </Select>
        {canResolve && (
          <Button
            variant="outline"
            size="sm"
            onClick={() => scanMutation.mutate()}
            disabled={scanMutation.isPending}
          >
            {scanMutation.isPending ? <Spinner className="mr-2" /> : <ScanSearch className="mr-2 h-4 w-4" />}
            Escanear duplicados
          </Button>
        )}
        <Button variant="outline" size="sm" onClick={() => void refetch()} disabled={isRefetching}>
          {isRefetching ? <Spinner className="mr-2" /> : <RefreshCw className="mr-2 h-4 w-4" />}
          Actualizar
        </Button>
      </PageHeader>

      <div className={`${statGridClass} md:grid-cols-3`}>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-amber-100 dark:bg-amber-950">
                <AlertTriangle className="h-5 w-5 text-amber-600" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{pendingTotal}</p>
                <p className="text-xs text-muted-foreground">
                  {canResolve ? 'Pendientes (tenant)' : 'Pendientes (tuyos)'}
                </p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/15">
                <Briefcase className="h-5 w-5 text-primary" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{totalCount}</p>
                <p className="text-xs text-muted-foreground">Total con filtro actual</p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-muted">
                <CheckCircle2 className="h-5 w-5 text-muted-foreground" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{resolutionFilter === 'all' ? flags.filter((f) => !f.pending).length : '—'}</p>
                <p className="text-xs text-muted-foreground">Resueltos en esta página</p>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

      {!canResolve && (
        <p className="text-sm text-muted-foreground">
          Solo administradores y managers pueden fusionar, reasignar o descartar. Puedes revisar quién tiene cada
          oportunidad y desde cuándo (RFC §6.2).
        </p>
      )}

      {isError && (
        <Card className="border-destructive/50">
          <CardContent className="py-6 text-sm text-destructive">
            {duplicateFlagsErrorMessage(error)}
          </CardContent>
        </Card>
      )}

      {isLoading ? (
        <div className="space-y-4">
          {Array.from({ length: 3 }).map((_, i) => (
            <Card key={i}>
              <CardHeader>
                <Skeleton className="h-6 w-48" />
              </CardHeader>
              <CardContent>
                <div className="grid gap-3 md:grid-cols-2">
                  <Skeleton className="h-32 w-full" />
                  <Skeleton className="h-32 w-full" />
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      ) : flags.length === 0 ? (
        <Card>
          <CardContent className="py-12">
            <div className="text-center">
              <CheckCircle2 className="mx-auto h-12 w-12 text-primary" />
              <h3 className="mt-4 text-lg font-medium">Sin resultados</h3>
              <p className="mt-1 text-sm text-muted-foreground">
                {resolutionFilter === 'pending'
                  ? canResolve
                    ? 'No hay colisiones pendientes. Usa "Escanear duplicados" para detectar pares sin flag.'
                    : 'No tienes colisiones pendientes. Si registras un lead duplicado, aparecerá aquí y un manager lo resolverá.'
                  : 'No hay registros con el filtro actual.'}
              </p>
            </div>
          </CardContent>
        </Card>
      ) : (
        <>
          <div className="space-y-4">
            {flags.map((flag) => (
              <Card key={flag.id}>
                <CardHeader className="pb-3">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div className="flex items-start gap-3">
                      <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-amber-100 dark:bg-amber-950">
                        <AlertTriangle className="h-4 w-4 text-amber-600" />
                      </div>
                      <div>
                        <CardTitle className="text-base">Posible duplicado de oportunidad</CardTitle>
                        <CardDescription>{matchedOnLabel(flag.matchedOn)}</CardDescription>
                        <div className="mt-2 flex flex-wrap gap-2">
                          <Badge variant={flag.pending ? 'destructive' : 'secondary'}>
                            {flag.pending ? 'Pendiente' : flag.resolution}
                          </Badge>
                          <Badge variant="outline" className={getMatchScoreColor(flag.matchPercent)}>
                            ~{flag.matchPercent}% similitud
                          </Badge>
                        </div>
                        <p className="mt-2 text-xs text-muted-foreground">
                          Detectado{flag.detectedByName ? ` por ${flag.detectedByName}` : ''}
                          {flag.detectedAt ? ` · ${formatDate(flag.detectedAt)}` : ''}
                          {!flag.pending && flag.resolvedByName
                            ? ` · Resuelto por ${flag.resolvedByName}${flag.resolvedAt ? ` (${formatDate(flag.resolvedAt)})` : ''}`
                            : ''}
                        </p>
                        {flag.resolutionNote ? (
                          <p className="mt-1 text-xs text-muted-foreground italic">{flag.resolutionNote}</p>
                        ) : null}
                      </div>
                    </div>
                    {flag.pending && canResolve ? (
                      <div className="flex flex-wrap gap-2">
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => setIgnoreConfirmFlag(flag)}
                          disabled={ignoreMutation.isPending}
                        >
                          <Trash2 className="mr-2 h-4 w-4" />
                          Ignorar
                        </Button>
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => { setReassignFlag(flag); setReassignUserId('') }}
                          disabled={reassignMutation.isPending}
                        >
                          <User className="mr-2 h-4 w-4" />
                          Reasignar
                        </Button>
                        <Button
                          size="sm"
                          onClick={() => setMergeConfirmFlag(flag)}
                          disabled={mergeMutation.isPending}
                        >
                          <Merge className="mr-2 h-4 w-4" />
                          Fusionar
                        </Button>
                      </div>
                    ) : null}
                  </div>
                </CardHeader>
                <CardContent>
                  <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
                    <CollisionSide
                      title="Oportunidad detectada (se unifica en la otra al fusionar)"
                      contact={flag.contactNew}
                      opportunity={flag.opportunityNew}
                      onOpenOpportunity={openOpportunity}
                    />
                    <CollisionSide
                      title="Oportunidad existente (se mantiene al fusionar)"
                      contact={flag.contactExisting}
                      opportunity={flag.opportunityExisting}
                      onOpenOpportunity={openOpportunity}
                    />
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>

          {totalPages > 1 && (
            <div className="flex items-center justify-between gap-4 border-t pt-4">
              <p className="text-sm text-muted-foreground">
                Página {pagination?.page ?? page} de {totalPages} · {totalCount} registro(s)
              </p>
              <div className="flex gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  disabled={page <= 1}
                  onClick={() => setPage((p) => Math.max(1, p - 1))}
                >
                  Anterior
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={page >= totalPages}
                  onClick={() => setPage((p) => p + 1)}
                >
                  Siguiente
                </Button>
              </div>
            </div>
          )}
        </>
      )}

      <Dialog open={!!mergeConfirmFlag} onOpenChange={(o) => !o && setMergeConfirmFlag(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Fusionar en oportunidad existente</DialogTitle>
            <DialogDescription>
              Se consolidará la oportunidad #{mergeConfirmFlag?.opportunityNew?.id} en la existente #
              {mergeConfirmFlag?.opportunityExisting?.id} (responsable:{' '}
              {mergeConfirmFlag?.opportunityExisting?.owner_name ?? '—'}). Si son contactos distintos, también se
              unen en uno solo: se conservan sus datos, conversaciones y todos sus orígenes (landing, importación,
              WhatsApp…). Esta acción no se puede deshacer desde aquí.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setMergeConfirmFlag(null)}>
              Cancelar
            </Button>
            <Button
              onClick={() => mergeConfirmFlag && mergeMutation.mutate(mergeConfirmFlag.id)}
              disabled={mergeMutation.isPending}
            >
              {mergeMutation.isPending && <Spinner className="mr-2" />}
              Confirmar fusión
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={!!reassignFlag}
        onOpenChange={(o) => { if (!o) { setReassignFlag(null); setReassignUserId('') } }}
      >
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Reasignar oportunidad</DialogTitle>
            <DialogDescription>
              La oportunidad existente ({reassignFlag?.opportunityExisting?.owner_name ?? 'sin asignar'}) pasará al
              consultor seleccionado.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2 py-2">
            <Label>Nuevo responsable</Label>
            <Select value={reassignUserId} onValueChange={setReassignUserId}>
              <SelectTrigger>
                <SelectValue placeholder="Seleccionar consultor..." />
              </SelectTrigger>
              <SelectContent>
                {users
                  .sort((a, b) => a.name.localeCompare(b.name))
                  .map((u) => (
                    <SelectItem key={u.id} value={u.id}>
                      {u.name || u.email} · {u.role}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => { setReassignFlag(null); setReassignUserId('') }}>
              Cancelar
            </Button>
            <Button
              disabled={!reassignUserId || reassignMutation.isPending}
              onClick={() => reassignFlag && reassignMutation.mutate({ flagId: reassignFlag.id, userId: reassignUserId })}
            >
              {reassignMutation.isPending && <Spinner className="mr-2" />}
              Reasignar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={!!ignoreConfirmFlag} onOpenChange={(o) => !o && setIgnoreConfirmFlag(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Ignorar duplicado</DialogTitle>
            <DialogDescription>
              Se marcará esta colisión como ignorada. Las dos oportunidades seguirán existiendo por separado.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setIgnoreConfirmFlag(null)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              onClick={() => ignoreConfirmFlag && ignoreMutation.mutate(ignoreConfirmFlag.id)}
              disabled={ignoreMutation.isPending}
            >
              {ignoreMutation.isPending && <Spinner className="mr-2" />}
              Ignorar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </AppPageShell>
  )
}
