import { createFileRoute, redirect } from '@tanstack/react-router'
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient, useQueries } from '@tanstack/react-query'
import {
  Download,
  FileSpreadsheet,
  CheckCircle2,
  AlertCircle,
  RefreshCw,
  Plus,
  Clock,
  Upload,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'
import { formatDate } from '@/lib/utils'
import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, mapPipelineResource, mapUserResource, buildOpportunityExportFilters } from '@/lib/opportunityApi'
import { buildContactExportFilters, triggerBlobDownload } from '@/lib/contactApi'
import type { JsonApiResource } from '@/lib/opportunityApi'
import { getAuthQueryScope, queryKeys } from '@/lib/queryClient'
import { currentAuth } from '@/lib/authGuards'
import { useAuthStore } from '@/stores/auth'
import { tenantHasModule } from '@/lib/tenantModules'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { ContactImportDialog } from '@/components/contacts/ContactImportDialog'
import { statGridClass } from '@/lib/layoutClasses'

export const Route = createFileRoute('/_app/exports')({
  beforeLoad: () => {
    const role = currentAuth().user?.role
    if (role !== 'admin' && role !== 'manager') {
      throw redirect({ to: role === 'consultant' ? '/contacts' : '/' })
    }
  },
  component: ExportsPage,
})

type ExportResource = 'contacts' | 'opportunities'
type ExportFormat = 'csv' | 'xlsx'

/** Estados que envía el modelo Export (API). El job puede usar variantes puntuales; las normalizamos en UI. */
type UiStatus = 'queued' | 'processing' | 'completed' | 'failed' | 'expired'

interface ExportRow {
  id: string
  label: string
  resource: ExportResource
  format: ExportFormat
  uiStatus: UiStatus
  ready: boolean
  expired: boolean
  fileSize: number | null
  fileUrl: string | null
  errorMessage: string | null
  createdAt: string
}

function bytesLabel(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n) || n < 0) return '—'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

function mapApiStatus(raw: string): UiStatus {
  const s = raw.toLowerCase()
  if (s === 'queued') return 'queued'
  if (s === 'running' || s === 'processing') return 'processing'
  if (s === 'succeeded' || s === 'ready') return 'completed'
  if (s === 'failed') return 'failed'
  if (s === 'expired') return 'expired'
  return 'processing'
}

function mapExportRow(r: JsonApiResource): ExportRow | null {
  if (!r.id) return null
  const a = r.attributes ?? {}
  const resource = String(a.resource ?? '')
  const format = String(a.format ?? '')
  if (resource !== 'contacts' && resource !== 'opportunities') return null
  if (format !== 'csv' && format !== 'xlsx') return null

  const statusRaw = String(a.status ?? 'queued')
  const uiStatus = mapApiStatus(statusRaw)
  const ready = Boolean(a.ready)
  const expired = Boolean(a.expired)

  const createdAt =
    typeof a.created_at === 'string'
      ? a.created_at
      : typeof (a as { createdAt?: string }).createdAt === 'string'
        ? (a as { createdAt: string }).createdAt
        : new Date().toISOString()

  const fileUrl =
    typeof a.file_url === 'string'
      ? a.file_url
      : typeof (a as { fileUrl?: string }).fileUrl === 'string'
        ? (a as { fileUrl: string }).fileUrl
        : null

  const fs = a.file_size ?? (a as { fileSize?: unknown }).fileSize
  const fileSize =
    typeof fs === 'number'
      ? fs
      : typeof fs === 'string'
        ? parseInt(fs, 10)
        : null

  const resourceLabel = resource === 'contacts' ? 'Contactos' : 'Oportunidades'
  const label = `${resourceLabel} · ${format.toUpperCase()} · #${r.id}`

  return {
    id: String(r.id),
    label,
    resource,
    format: format as ExportFormat,
    uiStatus,
    ready,
    expired,
    fileSize: Number.isFinite(fileSize as number) ? fileSize : null,
    fileUrl,
    errorMessage: typeof a.error_message === 'string' ? a.error_message : null,
    createdAt,
  }
}

function buildExportFilters(config: typeof INITIAL_CONFIG): Record<string, string> {
  if (config.resource === 'contacts') {
    return buildContactExportFilters({
      dateRange: config.dateRange,
      contactKind: config.contactKind,
      ownerId: config.ownerId,
      contactSourceKind: config.contactSourceKind,
      stageId: config.stageId || undefined,
    })
  }
  return buildOpportunityExportFilters({
    stage_id: config.stageId || undefined,
    owner_id: config.ownerId || undefined,
    source_id: config.sourceId || undefined,
    date_range: config.dateRange !== 'all' ? config.dateRange : undefined,
  })
}

const INITIAL_CONFIG = {
  resource: 'opportunities' as ExportResource,
  format: 'xlsx' as ExportFormat,
  dateRange: 'all',
  stageId: '',
  ownerId: '',
  sourceId: '',
  contactKind: '' as '' | 'person' | 'company',
  contactSourceKind: '',
}

function ExportsPage() {
  const queryClient = useQueryClient()
  const tenant = useAuthStore((s) => s.tenant)
  const hasExportsModule = tenantHasModule(tenant, 'exports')
  const userRole = useAuthStore((s) => s.user?.role)
  const isManagerOrAdmin = userRole === 'admin' || userRole === 'manager'
  const canCreateExport = isManagerOrAdmin
  const canImportContacts = isManagerOrAdmin
  const authScope = getAuthQueryScope()

  const [isExportDialogOpen, setIsExportDialogOpen] = useState(false)
  const [importDialogOpen, setImportDialogOpen] = useState(false)
  const [exportConfig, setExportConfig] = useState(INITIAL_CONFIG)

  const isOpportunities = exportConfig.resource === 'opportunities'

  // Carga pipelines, usuarios y fuentes solo cuando se abre el diálogo de oportunidades
  const [pipelinesQ, usersQ, sourcesQ] = useQueries({
    queries: [
      {
        queryKey: queryKeys.pipelines.all,
        queryFn: async () => {
          const res = await api.get('/pipelines')
          return jsonApiPrimaryList(res.data).filter((r) => r.id).map(mapPipelineResource)
        },
        // Se usa para el selector de etapa tanto en oportunidades como en contactos
        // (filtro "etapa del pipeline" de RFC §6.7, vía opportunities_pipeline_stage_id_eq).
        enabled: isExportDialogOpen,
        staleTime: 60_000,
      },
      {
        queryKey: queryKeys.users.all,
        queryFn: async () => {
          const res = await api.get('/users')
          return jsonApiPrimaryList(res.data).filter((r) => r.id).map(mapUserResource)
        },
        enabled: isExportDialogOpen,
        staleTime: 60_000,
      },
      {
        queryKey: queryKeys.leadSources.all,
        queryFn: async () => {
          const res = await api.get('/lead_sources')
          return jsonApiPrimaryList(res.data)
            .filter((r) => r.id)
            .map((r) => ({ id: String(r.id), name: String(r.attributes?.name ?? '') }))
        },
        enabled: isExportDialogOpen && isOpportunities,
        staleTime: 60_000,
      },
    ],
  })

  const allStages = (pipelinesQ.data ?? []).flatMap((p) =>
    (p.stages ?? []).map((s) => ({ id: s.id, name: `${p.name} › ${s.name}` }))
  )

  const {
    data: exports = [],
    isLoading,
    isError,
    error,
    refetch,
    isRefetching,
  } = useQuery({
    queryKey: queryKeys.exports.list(authScope, { page: 1, items: 50 }),
    enabled: authScope.length > 0 && hasExportsModule,
    queryFn: async () => {
      const response = await api.get('/exports', {
        params: { page: 1, items: 50 },
      })
      return jsonApiPrimaryList(response.data)
        .filter((r) => r.id)
        .map(mapExportRow)
        .filter((row): row is ExportRow => row !== null)
    },
    refetchInterval: (query) => {
      const rows = query.state.data
      if (!rows?.length) return false
      const pending = rows.some(
        (e) => e.uiStatus === 'queued' || e.uiStatus === 'processing',
      )
      return pending ? 5_000 : false
    },
    refetchIntervalInBackground: true,
  })

  const createExportMutation = useMutation({
    mutationFn: async (config: typeof exportConfig) => {
      const filters = buildExportFilters(config)
      const response = await api.post('/exports', {
        resource: config.resource,
        export_format: config.format,
        filters,
      })
      return response.data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.exports.all })
      toast.success('Exportación encolada; aparecerá en el historial cuando el servidor la procese.')
      setIsExportDialogOpen(false)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudo iniciar la exportación'))
    },
  })

  const syncDownloadMutation = useMutation({
    mutationFn: async (config: typeof exportConfig) => {
      const filters = buildExportFilters(config)
      const response = await api.get(`/${config.resource}/export.${config.format}`, {
        params: { filters },
        responseType: 'blob',
      })
      return {
        blob: response.data as Blob,
        resource: config.resource,
        format: config.format,
      }
    },
    onSuccess: ({ blob, resource, format }) => {
      triggerBlobDownload(
        blob,
        `${resource}_${new Date().toISOString().slice(0, 10)}.${format}`,
      )
      toast.success('Archivo descargado (exportación directa, RFC §6.7)')
      setIsExportDialogOpen(false)
    },
    onError: (err: unknown) => {
      toast.error(
        formatRailsError(
          err,
          'No se pudo descargar. Si hay muchos registros, usa «Encolar exportación».'
        )
      )
    },
  })

  const [downloadingId, setDownloadingId] = useState<string | null>(null)

  const handleDownload = async (exp: ExportRow) => {
    if (!exp.ready && exp.uiStatus !== 'completed') return
    setDownloadingId(exp.id)
    try {
      const response = await api.get(`/exports/${exp.id}/download`, {
        responseType: 'blob',
      })
      triggerBlobDownload(
        response.data as Blob,
        `export_${exp.resource}_${exp.id}.${exp.format}`,
      )
      toast.success('Exportación descargada')
    } catch (err: unknown) {
      toast.error(formatRailsError(err, 'No se pudo descargar el archivo'))
    } finally {
      setDownloadingId(null)
    }
  }

  const getStatusBadge = (exp: ExportRow) => {
    if (exp.expired || exp.uiStatus === 'expired') {
      return (
        <Badge variant="secondary" className="bg-muted">
          <AlertCircle className="mr-1 h-3 w-3" />
          Expirado
        </Badge>
      )
    }
    switch (exp.uiStatus) {
      case 'completed':
        return (
          <Badge variant="success">
            <CheckCircle2 className="mr-1 h-3 w-3" />
            Listo
          </Badge>
        )
      case 'processing':
        return (
          <Badge className="border border-primary/25 bg-primary/12 text-primary hover:bg-primary/15 dark:border-primary/35 dark:bg-primary/18">
            <RefreshCw className="mr-1 h-3 w-3 animate-spin" />
            En proceso
          </Badge>
        )
      case 'queued':
        return (
          <Badge className="bg-amber-100 text-amber-800 hover:bg-amber-100 dark:bg-amber-950 dark:text-amber-200">
            <Clock className="mr-1 h-3 w-3" />
            En cola
          </Badge>
        )
      case 'failed':
        return (
          <Badge className="bg-red-100 text-red-800 hover:bg-red-100 dark:bg-red-950 dark:text-red-200">
            <AlertCircle className="mr-1 h-3 w-3" />
            Fallido
          </Badge>
        )
      default:
        return <Badge variant="secondary">{exp.uiStatus}</Badge>
    }
  }

  const completedExports = exports.filter((e) => e.uiStatus === 'completed' && e.ready).length
  const inProgressExports = exports.filter((e) => e.uiStatus === 'queued' || e.uiStatus === 'processing').length

  if (!hasExportsModule) {
    return (
      <AppPageShell>
        <PageHeader
          title="Exportaciones e importaciones"
          description="El módulo de exportaciones no está activo en la configuración de este tenant."
        />
      </AppPageShell>
    )
  }

  return (
    <AppPageShell contentClassName="gap-8">
      <PageHeader
        title="Exportaciones e importaciones"
        description="Exportación directa (≤5.000 filas) o asíncrona con descarga segura (7 días). Importación masiva de contactos vía Excel. Aplica a todo el tenant (RFC §6.7)."
      >
        <Button variant="outline" size="sm" onClick={() => void refetch()} disabled={isRefetching}>
          {isRefetching ? <Spinner className="mr-2 size-4" /> : <RefreshCw className="mr-2 h-4 w-4" />}
          Actualizar
        </Button>
        <Button
          variant="outline"
          size="sm"
          className="gap-2"
          disabled={!canImportContacts}
          title={
            canImportContacts
              ? 'Importar contactos desde Excel (.xlsx)'
              : 'Solo administradores y managers pueden importar'
          }
          onClick={() => setImportDialogOpen(true)}
        >
          <Upload className="h-4 w-4" />
          <span className="hidden sm:inline">Importar contactos</span>
          <span className="sm:hidden">Importar</span>
        </Button>
        {canCreateExport && (
          <Button size="sm" className="shadow-sm" onClick={() => setIsExportDialogOpen(true)}>
            <Plus className="mr-2 h-4 w-4" />
            Nueva exportación
          </Button>
        )}
      </PageHeader>

      <div className={`${statGridClass} md:grid-cols-3`}>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10">
                <FileSpreadsheet className="h-5 w-5 text-primary" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{exports.length}</p>
                <p className="text-xs text-muted-foreground">En esta página (activas)</p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/15">
                <CheckCircle2 className="h-5 w-5 text-primary" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{completedExports}</p>
                <p className="text-xs text-muted-foreground">Listas para descargar</p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-chart-2/15">
                <RefreshCw className="h-5 w-5 text-chart-2" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{inProgressExports}</p>
                <p className="text-xs text-muted-foreground">En cola o procesando</p>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

      <Card className="border-primary/20 bg-card/60 shadow-sm">
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-base">
            <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary/10">
              <Upload className="h-4 w-4 text-primary" />
            </span>
            Importación de contactos (Excel)
          </CardTitle>
          <CardDescription>
            Sube un archivo Excel (.xlsx) para crear contactos en bloque. Descarga la plantilla y revisa errores por fila
            en el asistente.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3 pt-0">
          <Button
            size="sm"
            className="gap-2"
            disabled={!canImportContacts}
            onClick={() => setImportDialogOpen(true)}
          >
            <Upload className="h-4 w-4" />
            Abrir importación
          </Button>
          <p className="text-xs text-muted-foreground">
            Tras importar, los nuevos contactos aparecen en Contactos y pueden usarse en oportunidades.
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Historial de exportaciones</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {isError ? (
            <div className="p-6 text-sm text-destructive">
              {formatRailsError(error, 'No se pudo cargar el historial')}
            </div>
          ) : isLoading ? (
            <div className="space-y-4 p-4">
              {Array.from({ length: 4 }).map((_, i) => (
                <div key={i} className="flex items-center gap-4">
                  <Skeleton className="h-10 w-10" />
                  <div className="flex-1 space-y-2">
                    <Skeleton className="h-4 w-48" />
                    <Skeleton className="h-3 w-32" />
                  </div>
                  <Skeleton className="h-6 w-24" />
                </div>
              ))}
            </div>
          ) : exports.length === 0 ? (
            <div className="p-8 text-center text-sm text-muted-foreground">
              No hay exportaciones en el historial. Las expiradas no se listan; crea una nueva desde el botón superior.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Exportación</TableHead>
                  <TableHead>Recurso</TableHead>
                  <TableHead>Formato</TableHead>
                  <TableHead>Estado</TableHead>
                  <TableHead>Tamaño</TableHead>
                  <TableHead>Creada</TableHead>
                  <TableHead className="w-24 text-right">Acción</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {exports.map((exp) => (
                  <TableRow key={exp.id}>
                    <TableCell>
                      <div className="flex items-center gap-3">
                        <div className="flex h-8 w-8 items-center justify-center rounded bg-muted">
                          <FileSpreadsheet className="h-4 w-4 text-muted-foreground" />
                        </div>
                        <span className="font-medium">{exp.label}</span>
                      </div>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {exp.resource === 'contacts' ? 'Contactos' : 'Oportunidades'}
                    </TableCell>
                    <TableCell>
                      <Badge variant="outline" className="uppercase">
                        {exp.format}
                      </Badge>
                    </TableCell>
                    <TableCell>
                      {getStatusBadge(exp)}
                      {exp.uiStatus === 'failed' && exp.errorMessage ? (
                        <p className="mt-1 max-w-xs truncate text-xs text-destructive" title={exp.errorMessage}>
                          {exp.errorMessage}
                        </p>
                      ) : null}
                    </TableCell>
                    <TableCell className="text-muted-foreground">{bytesLabel(exp.fileSize)}</TableCell>
                    <TableCell className="text-muted-foreground">{formatDate(exp.createdAt)}</TableCell>
                    <TableCell className="text-right">
                      {exp.ready || exp.uiStatus === 'completed' ? (
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={downloadingId === exp.id || exp.expired}
                          onClick={() => void handleDownload(exp)}
                        >
                          {downloadingId === exp.id
                            ? <Spinner className="mr-1 h-4 w-4" />
                            : <Download className="mr-1 h-4 w-4" />}
                          Descargar
                        </Button>
                      ) : (
                        <span className="text-xs text-muted-foreground">—</span>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Dialog open={isExportDialogOpen} onOpenChange={setIsExportDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Nueva exportación</DialogTitle>
            <DialogDescription>
              Descarga directa para volúmenes pequeños, o encola un trabajo async (Sidekiq) para listas grandes.
              Los archivos async se cifran en reposo y expiran a los 7 días.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label>Recurso</Label>
              <Select
                value={exportConfig.resource}
                onValueChange={(v) =>
                  setExportConfig((c) => ({
                    ...INITIAL_CONFIG,
                    dateRange: c.dateRange,
                    format: c.format,
                    resource: v as ExportResource,
                  }))
                }
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="opportunities">Oportunidades</SelectItem>
                  <SelectItem value="contacts">Contactos</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Formato</Label>
              <Select
                value={exportConfig.format}
                onValueChange={(v) => setExportConfig((c) => ({ ...c, format: v as ExportFormat }))}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="xlsx">Excel (.xlsx)</SelectItem>
                  <SelectItem value="csv">CSV (.csv)</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Rango de fecha (última actualización)</Label>
              <Select
                value={exportConfig.dateRange}
                onValueChange={(v) => setExportConfig((c) => ({ ...c, dateRange: v }))}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">Todos los registros</SelectItem>
                  <SelectItem value="week">Últimos 7 días</SelectItem>
                  <SelectItem value="month">Últimos 30 días</SelectItem>
                  <SelectItem value="quarter">Últimos 90 días</SelectItem>
                  <SelectItem value="year">Últimos 365 días</SelectItem>
                </SelectContent>
              </Select>
            </div>

            {!isOpportunities && (
              <>
                <div className="space-y-2">
                  <Label>Tipo (opcional)</Label>
                  <Select
                    value={exportConfig.contactKind || '__all__'}
                    onValueChange={(v) =>
                      setExportConfig((c) => ({
                        ...c,
                        contactKind: v === '__all__' ? '' : (v as 'person' | 'company'),
                      }))
                    }
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Personas y empresas" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todos</SelectItem>
                      <SelectItem value="person">Solo personas</SelectItem>
                      <SelectItem value="company">Solo empresas</SelectItem>
                    </SelectContent>
                  </Select>
                </div>

                <div className="space-y-2">
                  <Label>Etapa del pipeline (opcional)</Label>
                  <Select
                    value={exportConfig.stageId || '__all__'}
                    onValueChange={(v) => setExportConfig((c) => ({ ...c, stageId: v === '__all__' ? '' : v }))}
                    disabled={pipelinesQ.isLoading}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Todas las etapas" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todas las etapas</SelectItem>
                      {allStages.map((s) => (
                        <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <p className="text-xs text-muted-foreground">
                    Incluye contactos con al menos una oportunidad en esa etapa.
                  </p>
                </div>

                <div className="space-y-2">
                  <Label>Consultor responsable (opcional)</Label>
                  <Select
                    value={exportConfig.ownerId || '__all__'}
                    onValueChange={(v) =>
                      setExportConfig((c) => ({ ...c, ownerId: v === '__all__' ? '' : v }))
                    }
                    disabled={usersQ.isLoading}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Todos" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todos</SelectItem>
                      {(usersQ.data ?? []).map((u) => (
                        <SelectItem key={u.id} value={u.id}>
                          {u.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="space-y-2">
                  <Label>Origen del contacto (opcional)</Label>
                  <Select
                    value={exportConfig.contactSourceKind || '__all__'}
                    onValueChange={(v) =>
                      setExportConfig((c) => ({
                        ...c,
                        contactSourceKind: v === '__all__' ? '' : v,
                      }))
                    }
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Todos" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todos</SelectItem>
                      <SelectItem value="web">Web / Orgánico</SelectItem>
                      <SelectItem value="whatsapp">WhatsApp</SelectItem>
                      <SelectItem value="meta">Meta Ads</SelectItem>
                      <SelectItem value="google">Google Ads</SelectItem>
                      <SelectItem value="referral">Referido</SelectItem>
                      <SelectItem value="manual">Manual / Presencial</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </>
            )}

            {isOpportunities && (
              <>
                <div className="space-y-2">
                  <Label>Etapa del pipeline (opcional)</Label>
                  <Select
                    value={exportConfig.stageId || '__all__'}
                    onValueChange={(v) => setExportConfig((c) => ({ ...c, stageId: v === '__all__' ? '' : v }))}
                    disabled={pipelinesQ.isLoading}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Todas las etapas" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todas las etapas</SelectItem>
                      {allStages.map((s) => (
                        <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="space-y-2">
                  <Label>Consultor asignado (opcional)</Label>
                  <Select
                    value={exportConfig.ownerId || '__all__'}
                    onValueChange={(v) => setExportConfig((c) => ({ ...c, ownerId: v === '__all__' ? '' : v }))}
                    disabled={usersQ.isLoading}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Todos los consultores" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todos los consultores</SelectItem>
                      {(usersQ.data ?? []).map((u) => (
                        <SelectItem key={u.id} value={u.id}>{u.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="space-y-2">
                  <Label>Origen del lead (opcional)</Label>
                  <Select
                    value={exportConfig.sourceId || '__all__'}
                    onValueChange={(v) => setExportConfig((c) => ({ ...c, sourceId: v === '__all__' ? '' : v }))}
                    disabled={sourcesQ.isLoading}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Todos los orígenes" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__all__">Todos los orígenes</SelectItem>
                      {(sourcesQ.data ?? []).map((s) => (
                        <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </>
            )}
          </div>

          <DialogFooter className="flex-col gap-2 sm:flex-row sm:justify-end">
            <Button variant="outline" onClick={() => setIsExportDialogOpen(false)}>
              Cancelar
            </Button>
            <Button
              variant="secondary"
              onClick={() => syncDownloadMutation.mutate(exportConfig)}
              disabled={syncDownloadMutation.isPending || !canCreateExport}
            >
              {syncDownloadMutation.isPending && <Spinner className="mr-2" />}
              Descargar ahora
            </Button>
            <Button
              onClick={() => createExportMutation.mutate(exportConfig)}
              disabled={createExportMutation.isPending || !canCreateExport}
            >
              {createExportMutation.isPending && <Spinner className="mr-2" />}
              Encolar exportación
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ContactImportDialog open={importDialogOpen} onOpenChange={setImportDialogOpen} />
    </AppPageShell>
  )
}
