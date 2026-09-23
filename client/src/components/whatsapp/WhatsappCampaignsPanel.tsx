import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Play, Pause, Pencil, X, Users } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Label } from '@/components/ui/label'
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  fetchWhatsappCampaigns,
  createWhatsappCampaign,
  updateWhatsappCampaign,
  fetchAudiencePreview,
  launchWhatsappCampaign,
  pauseWhatsappCampaign,
  resumeWhatsappCampaign,
  cancelWhatsappCampaign,
  whatsappCampaignErrorMessage,
  type WhatsappCampaign,
  type WhatsappCampaignAudienceFilters,
  type WhatsappCampaignStatus,
} from '@/lib/whatsappCampaignsApi'
import { fetchWhatsappTemplates, type WhatsappTemplate } from '@/lib/whatsappTemplatesApi'
import { fetchUsersList } from '@/lib/userApi'
import api from '@/lib/api'
import { jsonApiPrimaryList } from '@/lib/opportunityApi'
import type { Pipeline } from '@/types'
import { queryKeys } from '@/lib/queryClient'

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

// Valor centinela del Select: la variable se llena con un texto escrito a
// mano (p. ej. el nombre de nuestra empresa) en vez de un campo del contacto.
// El backend (Dispatcher#resolve_field) envía tal cual cualquier valor que
// no sea un campo conocido.
const FIXED_TEXT = '__fixed_text__'

const isFieldOption = (value: string) => FIELD_OPTIONS.some((f) => f.value === value)

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
  const [editingId, setEditingId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [templateId, setTemplateId] = useState('')
  const [fieldMap, setFieldMap] = useState<string[]>([])
  // Índices de variables en modo "texto fijo" (se distingue de "sin elegir"
  // aunque el texto todavía esté vacío).
  const [fixedIdx, setFixedIdx] = useState<Set<number>>(new Set())
  const [filters, setFilters] = useState<WhatsappCampaignAudienceFilters>(emptyFilters)

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

  const selectTemplate = (id: string) => {
    setTemplateId(id)
    const tpl = templates.find((t) => t.id === id)
    setFieldMap(tpl ? tpl.variableLabels.map(() => '') : [])
    setFixedIdx(new Set())
  }

  const setVariableSource = (i: number, value: string) => {
    const fixed = value === FIXED_TEXT
    setFixedIdx((prev) => {
      const next = new Set(prev)
      if (fixed) next.add(i)
      else next.delete(i)
      return next
    })
    setFieldMap((m) => m.map((x, idx) => (idx === i ? (fixed ? '' : value) : x)))
  }

  const setFixedText = (i: number, text: string) =>
    setFieldMap((m) => m.map((x, idx) => (idx === i ? text : x)))

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['whatsappCampaigns'] })

  const saveMutation = useMutation({
    mutationFn: () => {
      const body = {
        name: name.trim(),
        whatsapp_template_id: templateId,
        variable_field_map: fieldMap.map((v) => v.trim()),
        audience_filters: filters,
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

  const openCreate = () => {
    setEditingId(null)
    setName('')
    setTemplateId('')
    setFieldMap([])
    setFixedIdx(new Set())
    setFilters(emptyFilters)
    setDialogOpen(true)
  }

  const openEdit = (c: WhatsappCampaign) => {
    setEditingId(c.id)
    setName(c.name)
    setTemplateId(c.whatsappTemplateId)
    setFieldMap(c.variableFieldMap)
    setFixedIdx(new Set(c.variableFieldMap.flatMap((v, i) => (v && !isFieldOption(v) ? [i] : []))))
    setFilters(c.audienceFilters ?? emptyFilters)
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
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-medium">Campañas de WhatsApp</h2>
          <p className="text-sm text-muted-foreground">
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
              busy={
                launchMutation.isPending ||
                pauseMutation.isPending ||
                resumeMutation.isPending ||
                cancelMutation.isPending
              }
            />
          ))}
        </div>
      )}

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
                    <SelectItem key={t.id} value={t.id}>{t.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {selectedTemplate && selectedTemplate.variableLabels.length > 0 && (
              <div className="space-y-2">
                <Label>Variables de la plantilla</Label>
                <p className="text-xs text-muted-foreground">
                  De qué campo del contacto/oportunidad sacar cada variable al enviar, o un texto fijo
                  igual para todos (p. ej. el nombre de tu empresa). Si el campo está vacío para un
                  contacto, ese contacto se omite.
                </p>
                {selectedTemplate.variableLabels.map((label, i) => (
                  <div key={i} className="space-y-1.5">
                    <div className="flex items-center gap-2">
                      <span className="w-32 shrink-0 truncate text-xs text-muted-foreground">{`{{${i + 1}}} ${label}`}</span>
                      <Select
                        value={fixedIdx.has(i) ? FIXED_TEXT : (fieldMap[i] ?? '')}
                        onValueChange={(v) => setVariableSource(i, v)}
                      >
                        <SelectTrigger className="h-8 flex-1 text-xs">
                          <SelectValue placeholder="Elegir campo…" />
                        </SelectTrigger>
                        <SelectContent>
                          {FIELD_OPTIONS.map((f) => (
                            <SelectItem key={f.value} value={f.value}>{f.label}</SelectItem>
                          ))}
                          <SelectItem value={FIXED_TEXT}>Texto fijo…</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                    {fixedIdx.has(i) && (
                      <div className="flex items-center gap-2">
                        <span className="w-32 shrink-0" />
                        <Input
                          className="h-8 flex-1 text-xs"
                          value={fieldMap[i] ?? ''}
                          onChange={(e) => setFixedText(i, e.target.value)}
                          placeholder="Ej: SIG ISWO Software + IA"
                          aria-label={`Texto fijo para ${label}`}
                        />
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}

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
              </div>

              <div className="flex items-center gap-2 pt-1 text-xs">
                <Users className="size-3.5 text-muted-foreground" />
                {previewLoading ? (
                  <Spinner className="size-3" />
                ) : preview ? (
                  <span>
                    <strong>{preview.optedIn}</strong> de {preview.total} contacto(s) con opt-in registrado
                    {preview.skippedNoOptIn > 0 && (
                      <span className="text-muted-foreground"> · {preview.skippedNoOptIn} sin opt-in (no reciben)</span>
                    )}
                  </span>
                ) : null}
              </div>
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

function CampaignRow({
  campaign,
  onEdit,
  onLaunch,
  onPause,
  onResume,
  onCancel,
  busy,
}: {
  campaign: WhatsappCampaign
  onEdit: () => void
  onLaunch: () => void
  onPause: () => void
  onResume: () => void
  onCancel: () => void
  busy: boolean
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <p className="font-medium">{campaign.name}</p>
            <Badge variant={STATUS_VARIANTS[campaign.status]}>{STATUS_LABELS[campaign.status]}</Badge>
          </div>
          <p className="text-xs text-muted-foreground">Plantilla: {campaign.whatsappTemplateName}</p>
        </div>

        <div className="flex shrink-0 items-center gap-2">
          {campaign.status === 'draft' && (
            <Button size="sm" variant="outline" onClick={onEdit} disabled={busy}>
              <Pencil className="mr-1.5 h-3.5 w-3.5" />
              Editar
            </Button>
          )}
          {campaign.status === 'draft' && (
            <Button size="sm" onClick={onLaunch} disabled={busy}>
              <Play className="mr-1.5 h-3.5 w-3.5" />
              Lanzar
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
        </div>
      </div>

      {campaign.status !== 'draft' && (
        <Table className="mt-3">
          <TableHeader>
            <TableRow>
              <TableHead className="h-7 text-xs">Total</TableHead>
              <TableHead className="h-7 text-xs">Enviados</TableHead>
              <TableHead className="h-7 text-xs">Fallidos</TableHead>
              <TableHead className="h-7 text-xs">Sin opt-in</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            <TableRow>
              <TableCell className="py-1.5 text-sm">{campaign.totalRecipients}</TableCell>
              <TableCell className="py-1.5 text-sm">{campaign.sentCount}</TableCell>
              <TableCell className="py-1.5 text-sm">{campaign.failedCount}</TableCell>
              <TableCell className="py-1.5 text-sm">{campaign.skippedNoOptInCount}</TableCell>
            </TableRow>
          </TableBody>
        </Table>
      )}
    </div>
  )
}
