import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Play, Pause, Pencil, X, Users, Copy, BarChart3, AlertTriangle } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Spinner } from '@/components/ui/spinner'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  fetchWhatsappCampaigns,
  createWhatsappCampaign,
  updateWhatsappCampaign,
  fetchAudiencePreview,
  launchWhatsappCampaign,
  pauseWhatsappCampaign,
  resumeWhatsappCampaign,
  cancelWhatsappCampaign,
  duplicateWhatsappCampaign,
  isTemplateLaunchable,
  whatsappCampaignErrorMessage,
  type DeliveryResult,
  type WhatsappCampaign,
  type WhatsappCampaignAudienceFilters,
  type WhatsappCampaignStatus,
} from '@/lib/whatsappCampaignsApi'
import { fetchWhatsappTemplates, type WhatsappTemplate } from '@/lib/whatsappTemplatesApi'
import { cn } from '@/lib/utils'
import { DELIVERY_BADGE, WhatsappCampaignDetailDialog } from './WhatsappCampaignDetailDialog'
import { fetchUsersList } from '@/lib/userApi'
import api from '@/lib/api'
import { jsonApiPrimaryList } from '@/lib/opportunityApi'
import type { Pipeline } from '@/types'
import { queryKeys } from '@/lib/queryClient'
import { ContactOriginSelect, countriesSummary } from '@/components/campaigns/ContactOriginSelect'

const STATUS_LABELS: Record<WhatsappCampaignStatus, string> = {
  draft: 'Borrador',
  scheduled: 'Programada',
  running: 'Enviando',
  paused: 'Pausada',
  completed: 'Completada',
  canceled: 'Cancelada',
}

const STATUS_VARIANTS: Record<WhatsappCampaignStatus, 'outline' | 'default' | 'secondary' | 'destructive'> = {
  draft: 'outline',
  scheduled: 'secondary',
  running: 'default',
  paused: 'secondary',
  completed: 'outline',
  canceled: 'destructive',
}

const FIELD_OPTIONS = [
  { value: 'contact.first_name', label: 'Nombre del contacto' },
  { value: 'contact.last_name', label: 'Apellido del contacto' },
  { value: 'contact.display_name', label: 'Nombre completo del contacto' },
  { value: 'contact.company_name', label: 'Empresa del contacto' },
  { value: 'opportunity.title', label: 'Título de la oportunidad' },
]

/** Sentinel para el modo "texto fijo" en el Select de variables — nunca se
 * manda al backend, solo indica que fieldMap[i] es texto libre en vez de
 * uno de los FIELD_OPTIONS. Antes no existía esta opción: para una
 * variable como "nuestra empresa" en la plantilla, no había forma de
 * escribir el nombre fijo — solo se podía elegir un campo del contacto/
 * oportunidad, así que terminaba saliendo la empresa DEL LEAD en vez de
 * la propia (incidente real: campaña enviada a 40 leads con este bug).
 */
const CUSTOM_TEXT_VALUE = '__custom_text__'

const TEMPERATURE_OPTIONS = [
  { value: 'cold', label: 'Frío' },
  { value: 'warm', label: 'Tibio' },
  { value: 'hot', label: 'Caliente' },
]

const emptyFilters: WhatsappCampaignAudienceFilters = {}

/**
 * Envío masivo con plantilla del catálogo. Solo admin/manager llegan a este
 * tab (ver visibilidad en /whatsapp); el backend igual exige
 * manager_or_admin? para crear/lanzar.
 */
export function WhatsappCampaignsPanel() {
  const queryClient = useQueryClient()
  const [dialogOpen, setDialogOpen] = useState(false)
  /** id del borrador en edición; null = creando una campaña nueva. */
  const [editingId, setEditingId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [templateId, setTemplateId] = useState('')
  const [fieldMap, setFieldMap] = useState<string[]>([])
  /** Slots en modo "texto fijo" (muestran un Input en vez del valor del Select). */
  const [customSlots, setCustomSlots] = useState<boolean[]>([])
  const [filters, setFilters] = useState<WhatsappCampaignAudienceFilters>(emptyFilters)
  const [confirmReply, setConfirmReply] = useState('')
  /** Campaña cuyo resultado por destinatario se está viendo. */
  const [detailCampaign, setDetailCampaign] = useState<WhatsappCampaign | null>(null)

  const { data: campaigns = [], isLoading } = useQuery({
    queryKey: ['whatsappCampaigns'],
    queryFn: fetchWhatsappCampaigns,
    refetchInterval: 15_000,
  })

  const { data: templates = [] } = useQuery({
    queryKey: queryKeys.whatsappTemplates.all,
    queryFn: () => fetchWhatsappTemplates(true),
  })

  const { data: pipelines = [] } = useQuery({
    queryKey: queryKeys.pipelines.all,
    queryFn: async () => {
      const res = await api.get('/pipelines')
      return jsonApiPrimaryList(res.data)
        .filter((r) => r.id)
        .map((r) => {
          const a = r.attributes ?? {}
          return { id: String(r.id), name: String(a.name ?? ''), stages: (a.stages as Pipeline['stages']) ?? [] }
        })
    },
  })

  const { data: users = [] } = useQuery({
    queryKey: ['users', 'for-campaign-owner-filter'],
    queryFn: () => fetchUsersList({ items: 200 }),
  })

  const selectedTemplate: WhatsappTemplate | undefined = templates.find((t) => t.id === templateId)
  const selectedPipeline = pipelines.find((p) => p.id === filters.pipeline_id)

  const { data: preview, isFetching: previewLoading } = useQuery({
    queryKey: ['whatsappCampaigns', 'audience-preview', filters],
    queryFn: () => fetchAudiencePreview(filters),
    enabled: dialogOpen,
  })

  // Reinicia el mapeo solo cuando el usuario cambia de plantilla (no al abrir
  // un borrador para editar, que ya trae su variable_field_map guardado).
  const selectTemplate = (id: string) => {
    setTemplateId(id)
    const labels = templates.find((t) => t.id === id)?.variableLabels ?? []
    setFieldMap(labels.map(() => ''))
    setCustomSlots(labels.map(() => false))
  }

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['whatsappCampaigns'] })

  const saveMutation = useMutation({
    mutationFn: () => {
      const body = {
        name: name.trim(),
        whatsapp_template_id: templateId,
        variable_field_map: fieldMap,
        audience_filters: filters,
        confirm_reply_body: confirmReply.trim(),
      }
      return editingId ? updateWhatsappCampaign(editingId, body) : createWhatsappCampaign(body)
    },
    onSuccess: () => {
      invalidate()
      toast.success(editingId ? 'Borrador actualizado' : 'Campaña creada como borrador')
      closeDialog()
    },
    onError: (err) => toast.error(whatsappCampaignErrorMessage(err)),
  })

  const launchMutation = useMutation({
    mutationFn: (id: string) => launchWhatsappCampaign(id),
    onSuccess: () => {
      invalidate()
      toast.success('Campaña lanzada — los envíos empiezan en el próximo lote')
    },
    onError: (err) => toast.error(whatsappCampaignErrorMessage(err)),
  })

  const pauseMutation = useMutation({
    mutationFn: (id: string) => pauseWhatsappCampaign(id),
    onSuccess: () => {
      invalidate()
      toast.success('Campaña pausada')
    },
    onError: (err) => toast.error(whatsappCampaignErrorMessage(err)),
  })

  const resumeMutation = useMutation({
    mutationFn: (id: string) => resumeWhatsappCampaign(id),
    onSuccess: () => {
      invalidate()
      toast.success('Campaña reanudada')
    },
    onError: (err) => toast.error(whatsappCampaignErrorMessage(err)),
  })

  const cancelMutation = useMutation({
    mutationFn: (id: string) => cancelWhatsappCampaign(id),
    onSuccess: () => {
      invalidate()
      toast.success('Campaña cancelada')
    },
    onError: (err) => toast.error(whatsappCampaignErrorMessage(err)),
  })

  const duplicateMutation = useMutation({
    mutationFn: (id: string) => duplicateWhatsappCampaign(id),
    onSuccess: (copy) => {
      invalidate()
      toast.success('Copia creada como borrador — ajústala y lánzala cuando esté lista')
      if (copy) openEdit(copy)
    },
    onError: (err) => toast.error(whatsappCampaignErrorMessage(err)),
  })

  const openCreate = () => {
    setEditingId(null)
    setName('')
    setTemplateId('')
    setFieldMap([])
    setCustomSlots([])
    setFilters(emptyFilters)
    setConfirmReply('')
    setDialogOpen(true)
  }

  const openEdit = (c: WhatsappCampaign) => {
    const isField = (v: string) => FIELD_OPTIONS.some((f) => f.value === v)
    setEditingId(c.id)
    setName(c.name)
    setTemplateId(c.whatsappTemplateId)
    setFieldMap(c.variableFieldMap)
    setCustomSlots(c.variableFieldMap.map((v) => v !== '' && !isField(v)))
    setFilters(c.audienceFilters ?? emptyFilters)
    setConfirmReply(c.confirmReplyBody ?? '')
    setDialogOpen(true)
  }

  const closeDialog = () => {
    setDialogOpen(false)
  }

  const canSave =
    name.trim() &&
    templateId &&
    fieldMap.every((v) => v.trim()) &&
    (selectedTemplate ? fieldMap.length === selectedTemplate.variableLabels.length : true)

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div>
          <h2 className="text-lg font-medium">Campañas de WhatsApp</h2>
          <p className="hidden text-sm text-muted-foreground sm:block">
            Envío masivo con una plantilla del catálogo, respetando el opt-in de cada contacto y con
            pausas automáticas entre lotes para proteger la calidad del número.
          </p>
        </div>
        <Button size="sm" onClick={openCreate} disabled={templates.length === 0}>
          <Plus className="mr-2 h-4 w-4" />
          Nueva campaña
        </Button>
      </div>

      {templates.length === 0 && (
        <div className="rounded-lg border border-dashed p-4 text-sm text-muted-foreground">
          Todavía no hay plantillas activas en el catálogo — crea una en la pestaña "Plantillas" antes
          de lanzar una campaña.
        </div>
      )}

      {isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-16 w-full rounded-lg" />
          ))}
        </div>
      ) : campaigns.length === 0 ? (
        <div className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
          No hay campañas todavía.
        </div>
      ) : (
        <div className="space-y-2">
          {campaigns.map((c) => (
            <CampaignRow
              key={c.id}
              campaign={c}
              onEdit={() => openEdit(c)}
              onLaunch={() => launchMutation.mutate(c.id)}
              onPause={() => pauseMutation.mutate(c.id)}
              onResume={() => resumeMutation.mutate(c.id)}
              onCancel={() => cancelMutation.mutate(c.id)}
              onDuplicate={() => duplicateMutation.mutate(c.id)}
              onShowDetail={() => setDetailCampaign(c)}
              busy={
                launchMutation.isPending ||
                pauseMutation.isPending ||
                resumeMutation.isPending ||
                cancelMutation.isPending ||
                duplicateMutation.isPending
              }
            />
          ))}
        </div>
      )}

      <WhatsappCampaignDetailDialog
        campaign={detailCampaign}
        onOpenChange={(open) => { if (!open) setDetailCampaign(null) }}
      />

      <Dialog open={dialogOpen} onOpenChange={(open) => { if (!open) closeDialog() }}>
        <DialogContent className="sm:max-w-lg max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{editingId ? 'Editar borrador' : 'Nueva campaña'}</DialogTitle>
            <DialogDescription>
              Queda como borrador — revisa la audiencia y lánzala cuando estés listo.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="campName">Nombre</Label>
              <Input id="campName" value={name} onChange={(e) => setName(e.target.value)}
                     placeholder="Ej: Congreso SST — seguimiento" />
            </div>

            <div className="space-y-2">
              <Label>Plantilla</Label>
              <Select value={templateId} onValueChange={selectTemplate}>
                <SelectTrigger>
                  <SelectValue placeholder="Elegir plantilla…" />
                </SelectTrigger>
                <SelectContent>
                  {templates.map((t) => (
                    <SelectItem key={t.id} value={t.id} disabled={!isTemplateLaunchable(t.metaStatus)}>
                      {t.name}
                      <span className="ml-2 text-xs text-muted-foreground">
                        {templateStatusLabel(t.metaStatus)}
                      </span>
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {selectedTemplate && !selectedTemplate.metaStatus && (
                <p className="flex items-start gap-1.5 text-xs text-amber-700 dark:text-amber-300">
                  <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                  No sabemos si Meta aprobó esta plantilla. Antes de lanzar, pulsa «Sincronizar» en la pestaña
                  Plantillas: si no está aprobada, WhatsApp rechazará todos los envíos.
                </p>
              )}
            </div>

            {selectedTemplate && selectedTemplate.variableLabels.length > 0 && (
              <div className="space-y-2">
                <Label>Variables de la plantilla</Label>
                <p className="text-xs text-muted-foreground">
                  De qué campo del contacto/oportunidad sacar cada variable al enviar, o elegí
                  "Texto fijo" para escribir un valor que no cambia (ej. el nombre de tu empresa).
                </p>
                {selectedTemplate.variableLabels.map((label, i) => (
                  <div key={i} className="space-y-1">
                    <div className="flex items-center gap-2">
                      <span className="w-32 shrink-0 truncate text-xs text-muted-foreground">{`{{${i + 1}}} ${label}`}</span>
                      <Select
                        value={customSlots[i] ? CUSTOM_TEXT_VALUE : (fieldMap[i] ?? '')}
                        onValueChange={(v) => {
                          const isCustom = v === CUSTOM_TEXT_VALUE
                          setCustomSlots((m) => m.map((x, idx) => (idx === i ? isCustom : x)))
                          setFieldMap((m) => m.map((x, idx) => (idx === i ? (isCustom ? '' : v) : x)))
                        }}
                      >
                        <SelectTrigger className="h-8 flex-1 text-xs">
                          <SelectValue placeholder="Elegir campo…" />
                        </SelectTrigger>
                        <SelectContent>
                          {FIELD_OPTIONS.map((f) => (
                            <SelectItem key={f.value} value={f.value}>{f.label}</SelectItem>
                          ))}
                          <SelectItem value={CUSTOM_TEXT_VALUE}>Texto fijo (escribir)…</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                    {customSlots[i] && (
                      <Input
                        value={fieldMap[i] ?? ''}
                        onChange={(e) =>
                          setFieldMap((m) => m.map((x, idx) => (idx === i ? e.target.value : x)))
                        }
                        placeholder="Ej: SIG ISWO Software + IA"
                        className="ml-[8.5rem] h-8 text-xs"
                      />
                    )}
                  </div>
                ))}
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="campConfirmReply">Mensaje al autorizar (opcional)</Label>
              <Textarea
                id="campConfirmReply"
                value={confirmReply}
                onChange={(e) => setConfirmReply(e.target.value)}
                rows={3}
                placeholder="Ej: ¡Gracias {{nombre}}! Te comparto la información de nuestra certificación ISO 9001: https://…"
              />
              <p className="text-xs text-muted-foreground">
                Le llega al instante a quien responda «Sí» a esta campaña, aunque autorice días después. Si lo dejas
                vacío y el asistente IA está activo, responde el asistente.
              </p>
            </div>

            <div className="space-y-2 rounded-lg border p-3">
              <Label>Audiencia</Label>
              <div className="grid grid-cols-2 gap-2">
                <Select
                  value={filters.pipeline_id ?? 'all'}
                  onValueChange={(v) =>
                    setFilters((f) => ({ ...f, pipeline_id: v === 'all' ? undefined : v, pipeline_stage_id: undefined }))
                  }
                >
                  <SelectTrigger className="h-8 text-xs"><SelectValue placeholder="Pipeline" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">Todos los pipelines</SelectItem>
                    {pipelines.map((p) => (
                      <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>

                <Select
                  value={filters.pipeline_stage_id ?? 'all'}
                  onValueChange={(v) => setFilters((f) => ({ ...f, pipeline_stage_id: v === 'all' ? undefined : v }))}
                  disabled={!selectedPipeline}
                >
                  <SelectTrigger className="h-8 text-xs"><SelectValue placeholder="Etapa" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">Todas las etapas</SelectItem>
                    {selectedPipeline?.stages.map((s) => (
                      <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>

                <Select
                  value={filters.owner_id ?? 'all'}
                  onValueChange={(v) => setFilters((f) => ({ ...f, owner_id: v === 'all' ? undefined : v }))}
                >
                  <SelectTrigger className="h-8 text-xs"><SelectValue placeholder="Dueño" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">Todos los dueños</SelectItem>
                    {users.map((u) => (
                      <SelectItem key={u.id} value={u.id}>{u.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>

                <Select
                  value={filters.temperature ?? 'all'}
                  onValueChange={(v) => setFilters((f) => ({ ...f, temperature: v === 'all' ? undefined : v }))}
                >
                  <SelectTrigger className="h-8 text-xs"><SelectValue placeholder="Temperatura" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">Cualquier temperatura</SelectItem>
                    {TEMPERATURE_OPTIONS.map((t) => (
                      <SelectItem key={t.value} value={t.value}>{t.label}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>

                <ContactOriginSelect
                  className="col-span-2 h-8 text-xs"
                  value={filters.contact_origin}
                  onChange={(v) => setFilters((f) => ({ ...f, contact_origin: v }))}
                />

                <Select
                  value={filters.whatsapp_consent ?? 'any'}
                  onValueChange={(v) =>
                    setFilters((f) => ({ ...f, whatsapp_consent: v === 'confirmed' ? 'confirmed' : undefined }))
                  }
                >
                  <SelectTrigger className="col-span-2 h-8 text-xs" aria-label="Consentimiento de WhatsApp">
                    <SelectValue placeholder="Consentimiento" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="any">Cualquier contacto con opt-in</SelectItem>
                    <SelectItem value="confirmed">Solo quienes confirmaron "Sí" por WhatsApp</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="flex items-center gap-2 pt-1 text-xs">
                <Users className="size-3.5 text-muted-foreground" />
                {previewLoading ? (
                  <Spinner className="size-3" />
                ) : preview && selectedTemplate?.optInRequest ? (
                  <span>
                    <strong>{preview.total}</strong> contacto(s) · plantilla de solicitud de autorización: también
                    les llega a quienes aún no autorizaron (nunca a quien dijo «No»)
                  </span>
                ) : preview ? (
                  <span>
                    <strong>{preview.optedIn}</strong> de {preview.total} contacto(s) con opt-in registrado
                    {preview.skippedNoOptIn > 0 && (
                      <span className="text-muted-foreground"> · {preview.skippedNoOptIn} sin opt-in (no reciben)</span>
                    )}
                  </span>
                ) : null}
              </div>
              {preview && Object.keys(preview.countries).length > 0 && (
                <p
                  className={cn(
                    'text-xs',
                    Object.keys(preview.countries).length > 1
                      ? 'text-amber-700 dark:text-amber-300'
                      : 'text-muted-foreground',
                  )}
                >
                  Países de los celulares: {countriesSummary(preview.countries)}
                  {Object.keys(preview.countries).length > 1 &&
                    ' — revisa que el indicativo de cada número sea el correcto.'}
                </p>
              )}
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={closeDialog}>Cancelar</Button>
            <Button onClick={() => saveMutation.mutate()} disabled={!canSave || saveMutation.isPending}>
              {saveMutation.isPending && <Spinner className="mr-2" />}
              {editingId ? 'Guardar cambios' : 'Crear borrador'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

/** Estado de la plantilla en Meta, en palabras del usuario. */
function templateStatusLabel(metaStatus: string | null): string {
  switch ((metaStatus ?? '').toUpperCase()) {
    case '':
      return 'Sin sincronizar'
    case 'APPROVED':
      return 'Aprobada'
    case 'PENDING':
      return 'Pendiente en Meta'
    case 'REJECTED':
      return 'Rechazada'
    case 'PAUSED':
      return 'Pausada por Meta'
    case 'DISABLED':
      return 'Desactivada por Meta'
    default:
      return metaStatus ?? ''
  }
}

const STAT_ORDER: DeliveryResult[] = ['pending', 'sent', 'delivered', 'read', 'failed', 'skipped']

const STAT_LABELS: Record<DeliveryResult, string> = {
  pending: 'Pendientes',
  sent: 'Enviados (sin confirmar)',
  delivered: 'Entregados',
  read: 'Leídos',
  failed: 'Fallidos',
  skipped: 'Omitidos',
}

function CampaignRow({
  campaign,
  onEdit,
  onLaunch,
  onPause,
  onResume,
  onCancel,
  onDuplicate,
  onShowDetail,
  busy,
}: {
  campaign: WhatsappCampaign
  onEdit: () => void
  onLaunch: () => void
  onPause: () => void
  onResume: () => void
  onCancel: () => void
  onDuplicate: () => void
  onShowDetail: () => void
  busy: boolean
}) {
  const isDraft = campaign.status === 'draft'
  const templateBlocked = !isTemplateLaunchable(campaign.whatsappTemplateMetaStatus)
  const stats = campaign.deliveryStats

  return (
    <div className="space-y-3 rounded-lg border bg-card p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <p className="font-medium">{campaign.name}</p>
            <Badge variant={STATUS_VARIANTS[campaign.status]}>{STATUS_LABELS[campaign.status]}</Badge>
          </div>
          <p className="text-xs text-muted-foreground">
            Plantilla: {campaign.whatsappTemplateName} · {templateStatusLabel(campaign.whatsappTemplateMetaStatus)}
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2 sm:shrink-0 sm:justify-end">
          {isDraft && (
            <Button size="sm" variant="outline" onClick={onEdit} disabled={busy}>
              <Pencil className="mr-1.5 h-3.5 w-3.5" />
              Editar
            </Button>
          )}
          {isDraft && (
            <Button size="sm" onClick={onLaunch} disabled={busy || templateBlocked}>
              <Play className="mr-1.5 h-3.5 w-3.5" />
              Lanzar
            </Button>
          )}
          {!isDraft && (
            <Button size="sm" variant="outline" onClick={onShowDetail}>
              <BarChart3 className="mr-1.5 h-3.5 w-3.5" />
              Ver resultados
            </Button>
          )}
          {campaign.status === 'running' && (
            <Button size="sm" variant="outline" onClick={onPause} disabled={busy}>
              <Pause className="mr-1.5 h-3.5 w-3.5" />
              Pausar
            </Button>
          )}
          {campaign.status === 'paused' && (
            <Button size="sm" onClick={onResume} disabled={busy}>
              <Play className="mr-1.5 h-3.5 w-3.5" />
              Reanudar
            </Button>
          )}
          {(campaign.status === 'running' || campaign.status === 'paused') && (
            <Button size="sm" variant="ghost" className="text-destructive" onClick={onCancel} disabled={busy}>
              <X className="mr-1.5 h-3.5 w-3.5" />
              Cancelar
            </Button>
          )}
          <Button
            size="sm"
            variant="ghost"
            onClick={onDuplicate}
            disabled={busy}
            title="Crear una copia en borrador para editarla y volver a lanzarla"
          >
            <Copy className="mr-1.5 h-3.5 w-3.5" />
            Duplicar
          </Button>
        </div>
      </div>

      {isDraft && templateBlocked && (
        <p className="flex items-start gap-1.5 rounded-md bg-destructive/10 px-3 py-2 text-xs text-destructive">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          La plantilla está «{templateStatusLabel(campaign.whatsappTemplateMetaStatus)}»: no se puede lanzar hasta
          que Meta la apruebe. Edita el borrador para elegir otra plantilla.
        </p>
      )}

      {!isDraft && stats && (
        <div className="flex flex-wrap gap-1.5 text-xs">
          <span className="rounded-md bg-muted px-2 py-1 font-medium tabular-nums">Total {stats.total}</span>
          {STAT_ORDER.filter((k) => stats[k] > 0 || k === 'failed').map((k) => (
            <span key={k} className={cn('rounded-md px-2 py-1 font-medium tabular-nums', DELIVERY_BADGE[k])}>
              {STAT_LABELS[k]} {stats[k]}
            </span>
          ))}
          {campaign.confirmationStats && campaign.confirmationStats.confirmed > 0 && (
            <span className="rounded-md bg-emerald-600/15 px-2 py-1 font-medium tabular-nums text-emerald-800 dark:text-emerald-200">
              Autorizaron {campaign.confirmationStats.confirmed}
              {campaign.confirmReplyBody ? ` · respuesta automática ${campaign.confirmationStats.replied}` : ''}
            </span>
          )}
        </div>
      )}
    </div>
  )
}
