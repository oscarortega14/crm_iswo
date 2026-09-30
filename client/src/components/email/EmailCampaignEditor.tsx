import { useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, CalendarClock, Copy, Send, Users } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Checkbox } from '@/components/ui/checkbox'
import { Spinner } from '@/components/ui/spinner'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
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
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { cn } from '@/lib/utils'
import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList } from '@/lib/opportunityApi'
import { fetchUsersList } from '@/lib/userApi'
import { queryKeys } from '@/lib/queryClient'
import { useAuthStore } from '@/stores/auth'
import type { Pipeline } from '@/types'
import {
  EMAIL_VARIABLES,
  createEmailCampaign,
  emailCampaignAction,
  emailQueryKeys,
  fetchEmailAudiencePreview,
  sendEmailCampaignTest,
  updateEmailCampaign,
  type EmailAudienceFilters,
  type EmailCampaign,
  type EmailCampaignInput,
} from '@/lib/emailMarketingApi'
import { EmailDesignEditor, emailStarterHtml, type EmailDesignHandle } from './EmailDesignEditor'
import { ContactOriginSelect } from '@/components/campaigns/ContactOriginSelect'

const TEMPERATURE_OPTIONS = [
  { value: 'cold', label: 'Frío' },
  { value: 'warm', label: 'Tibio' },
  { value: 'hot', label: 'Caliente' },
]

type Tab = 'datos' | 'diseno'

/** `YYYY-MM-DDTHH:mm` local (para <input type="datetime-local">) ↔ ISO. */
function toLocalInput(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/**
 * Crear/editar un borrador de campaña de correo: datos y audiencia en una
 * pestaña y el diseño (editor visual) en otra. Desde aquí también se envía
 * la prueba y se lanza (o programa) con la confirmación de autorización.
 */
export function EmailCampaignEditor({
  campaign,
  senderVerified,
  onClose,
}: {
  /** null = campaña nueva. */
  campaign: EmailCampaign | null
  senderVerified: boolean
  onClose: () => void
}) {
  const queryClient = useQueryClient()
  const tenant = useAuthStore((s) => s.tenant)
  const userEmail = useAuthStore((s) => s.user?.email ?? '')
  const editorRef = useRef<EmailDesignHandle>(null)

  const [savedId, setSavedId] = useState<string | null>(campaign?.id ?? null)
  const [tab, setTab] = useState<Tab>('datos')
  const [name, setName] = useState(campaign?.name ?? '')
  const [subject, setSubject] = useState(campaign?.subject ?? '')
  const [preheader, setPreheader] = useState(campaign?.preheader ?? '')
  const [filters, setFilters] = useState<EmailAudienceFilters>(campaign?.audienceFilters ?? {})
  const [schedule, setSchedule] = useState(toLocalInput(campaign?.scheduledAt ?? null))
  const [testEmail, setTestEmail] = useState(userEmail)
  const [confirmLaunch, setConfirmLaunch] = useState(false)
  const [authorized, setAuthorized] = useState(false)

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
  const { data: leadSources = [] } = useQuery({
    queryKey: [...emailQueryKeys.all(), 'leadSources'],
    queryFn: async () => {
      const res = await api.get('/lead_sources')
      return jsonApiPrimaryList(res.data)
        .filter((r) => r.id)
        .map((r) => ({ id: String(r.id), name: String(r.attributes?.name ?? '') }))
    },
    staleTime: 60_000,
  })
  const { data: preview, isFetching: previewLoading } = useQuery({
    queryKey: emailQueryKeys.preview(filters),
    queryFn: () => fetchEmailAudiencePreview(filters),
  })

  const selectedPipeline = pipelines.find((p) => p.id === filters.pipeline_id)
  const scheduledIso = schedule ? new Date(schedule).toISOString() : null
  const isFuture = scheduledIso ? new Date(scheduledIso).getTime() > Date.now() : false

  const body = (): EmailCampaignInput => ({
    name: name.trim(),
    subject: subject.trim(),
    preheader: preheader.trim(),
    body_html: editorRef.current?.getInlinedHtml() ?? campaign?.bodyHtml ?? '',
    body_design: editorRef.current?.getProjectData() ?? campaign?.bodyDesign ?? {},
    audience_filters: filters,
    scheduled_at: scheduledIso,
  })

  const save = async (): Promise<EmailCampaign> => {
    const saved = savedId ? await updateEmailCampaign(savedId, body()) : await createEmailCampaign(body())
    setSavedId(saved.id)
    void queryClient.invalidateQueries({ queryKey: emailQueryKeys.campaigns() })
    return saved
  }

  const saveMutation = useMutation({
    mutationFn: save,
    onSuccess: () => toast.success('Borrador guardado'),
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo guardar el borrador')),
  })

  const testMutation = useMutation({
    mutationFn: async () => {
      const saved = await save()
      return sendEmailCampaignTest(saved.id, testEmail.trim())
    },
    onSuccess: (to) => toast.success(`Prueba enviada a ${to}. Revisa tu bandeja (y la carpeta de spam).`),
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo enviar la prueba')),
  })

  const launchMutation = useMutation({
    mutationFn: async () => {
      const saved = await save()
      return emailCampaignAction(saved.id, 'launch')
    },
    onSuccess: (c) => {
      toast.success(
        c.status === 'scheduled'
          ? `Campaña programada para el ${new Date(c.scheduledAt ?? '').toLocaleString('es-CO')}`
          : 'Campaña lanzada: los correos salen en el próximo minuto',
      )
      void queryClient.invalidateQueries({ queryKey: emailQueryKeys.campaigns() })
      setConfirmLaunch(false)
      onClose()
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo lanzar la campaña')),
  })

  const busy = saveMutation.isPending || testMutation.isPending || launchMutation.isPending
  const canSave = Boolean(name.trim())
  const canLaunch = canSave && Boolean(subject.trim()) && senderVerified && (preview?.total ?? 0) > 0

  const copyVariable = (token: string) => {
    void navigator.clipboard?.writeText(token)
    toast.success(`${token} copiado: pégalo en el texto del correo o en el asunto`)
  }

  return (
    <>
      <Dialog open onOpenChange={(open) => { if (!open && !busy) onClose() }}>
        <DialogContent className="flex h-[92vh] max-w-[calc(100%-1rem)] flex-col gap-3 p-4 sm:max-w-[95vw] sm:p-6">
          <DialogHeader>
            <DialogTitle>{campaign ? 'Editar campaña de correo' : 'Nueva campaña de correo'}</DialogTitle>
            <DialogDescription className="hidden sm:block">
              Define a quién le llega, diseña el correo, envíate una prueba y lánzala o prográmala.
            </DialogDescription>
          </DialogHeader>

          <div className="flex gap-1 rounded-lg bg-muted p-1 text-sm sm:w-fit">
            {(['datos', 'diseno'] as Tab[]).map((t) => (
              <button
                key={t}
                type="button"
                onClick={() => setTab(t)}
                className={cn(
                  'flex-1 rounded-md px-4 py-1.5 font-medium transition-colors sm:flex-none',
                  tab === t ? 'bg-background shadow-sm' : 'text-muted-foreground hover:text-foreground',
                )}
              >
                {t === 'datos' ? '1. Datos y audiencia' : '2. Diseño del correo'}
              </button>
            ))}
          </div>

          {/* Datos y audiencia */}
          <div className={cn('min-h-0 flex-1 overflow-y-auto', tab !== 'datos' && 'hidden')}>
            <div className="mx-auto grid max-w-3xl gap-5 pb-2">
              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="emailCampName">Nombre interno</Label>
                  <Input
                    id="emailCampName"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    placeholder="Ej: Boletín ISO 9001 — octubre"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="emailCampSubject">Asunto</Label>
                  <Input
                    id="emailCampSubject"
                    value={subject}
                    onChange={(e) => setSubject(e.target.value)}
                    placeholder="Ej: {{nombre}}, así puedes certificarte en ISO 9001"
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="emailCampPreheader">Texto de vista previa (opcional)</Label>
                  <Input
                    id="emailCampPreheader"
                    value={preheader}
                    onChange={(e) => setPreheader(e.target.value)}
                    placeholder="Lo que se lee junto al asunto en la bandeja de entrada"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <Label>Personalizar con datos del contacto</Label>
                <div className="flex flex-wrap gap-1.5">
                  {EMAIL_VARIABLES.map((v) => (
                    <button
                      key={v.token}
                      type="button"
                      onClick={() => copyVariable(v.token)}
                      title={v.label}
                      className="inline-flex items-center gap-1 rounded-md border bg-muted/40 px-2 py-1 font-mono text-xs hover:bg-muted"
                    >
                      <Copy className="size-3" />
                      {v.token}
                    </button>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">
                  Toca una variable para copiarla. Si el dato falta, puedes poner un valor por defecto:{' '}
                  <code>{'{{nombre|cliente}}'}</code>.
                </p>
              </div>

              <div className="space-y-3 rounded-lg border p-3">
                <Label>Audiencia</Label>
                <div className="grid gap-2 sm:grid-cols-2">
                  <Select
                    value={filters.pipeline_id ?? 'all'}
                    onValueChange={(v) =>
                      setFilters((f) => ({ ...f, pipeline_id: v === 'all' ? undefined : v, pipeline_stage_id: undefined }))
                    }
                  >
                    <SelectTrigger className="h-9 text-sm"><SelectValue placeholder="Pipeline" /></SelectTrigger>
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
                    <SelectTrigger className="h-9 text-sm"><SelectValue placeholder="Etapa" /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Todas las etapas</SelectItem>
                      {selectedPipeline?.stages.map((s) => (
                        <SelectItem key={s.id} value={String(s.id)}>{s.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Select
                    value={filters.lead_source_id ?? 'all'}
                    onValueChange={(v) => setFilters((f) => ({ ...f, lead_source_id: v === 'all' ? undefined : v }))}
                  >
                    <SelectTrigger className="h-9 text-sm"><SelectValue placeholder="Origen del lead" /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Cualquier origen</SelectItem>
                      {leadSources.map((s) => (
                        <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Select
                    value={filters.temperature ?? 'all'}
                    onValueChange={(v) => setFilters((f) => ({ ...f, temperature: v === 'all' ? undefined : v }))}
                  >
                    <SelectTrigger className="h-9 text-sm"><SelectValue placeholder="Temperatura" /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Cualquier temperatura</SelectItem>
                      {TEMPERATURE_OPTIONS.map((t) => (
                        <SelectItem key={t.value} value={t.value}>{t.label}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Select
                    value={filters.owner_id ?? 'all'}
                    onValueChange={(v) => setFilters((f) => ({ ...f, owner_id: v === 'all' ? undefined : v }))}
                  >
                    <SelectTrigger className="h-9 text-sm"><SelectValue placeholder="Asesor" /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Todos los asesores</SelectItem>
                      {users.map((u) => (
                        <SelectItem key={u.id} value={u.id}>{u.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Select
                    value={filters.kind ?? 'all'}
                    onValueChange={(v) =>
                      setFilters((f) => ({ ...f, kind: v === 'person' || v === 'company' ? v : undefined }))
                    }
                  >
                    <SelectTrigger className="h-9 text-sm"><SelectValue placeholder="Tipo" /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Personas y empresas</SelectItem>
                      <SelectItem value="person">Solo personas naturales</SelectItem>
                      <SelectItem value="company">Solo empresas</SelectItem>
                    </SelectContent>
                  </Select>
                  <ContactOriginSelect
                    className="h-9 text-sm sm:col-span-2"
                    value={filters.contact_origin}
                    onChange={(v) => setFilters((f) => ({ ...f, contact_origin: v }))}
                  />
                </div>
                <div className="flex items-center gap-2 text-sm">
                  <Users className="size-4 text-muted-foreground" />
                  {previewLoading ? (
                    <Spinner className="size-3" />
                  ) : preview ? (
                    <span>
                      <strong>{preview.total}</strong> correo(s) recibirían esta campaña
                      {preview.optedOut > 0 && (
                        <span className="text-muted-foreground">
                          {' '}· {preview.optedOut} dado(s) de baja no la reciben
                        </span>
                      )}
                    </span>
                  ) : null}
                </div>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="emailCampSchedule">Programar envío (opcional)</Label>
                  <Input
                    id="emailCampSchedule"
                    type="datetime-local"
                    value={schedule}
                    onChange={(e) => setSchedule(e.target.value)}
                  />
                  <p className="text-xs text-muted-foreground">Vacío = se envía apenas la lances.</p>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="emailCampTest">Enviarme una prueba</Label>
                  <div className="flex gap-2">
                    <Input
                      id="emailCampTest"
                      type="email"
                      value={testEmail}
                      onChange={(e) => setTestEmail(e.target.value)}
                      placeholder="tu@correo.com"
                    />
                    <Button
                      variant="outline"
                      onClick={() => testMutation.mutate()}
                      disabled={!canSave || !senderVerified || !testEmail.trim() || busy}
                    >
                      {testMutation.isPending ? <Spinner className="size-4" /> : <Send className="size-4" />}
                    </Button>
                  </div>
                  <p className="text-xs text-muted-foreground">Llega con datos de ejemplo y «[Prueba]» en el asunto.</p>
                </div>
              </div>

              {!senderVerified && (
                <p className="flex items-start gap-2 rounded-md bg-amber-500/10 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0" />
                  Puedes preparar el borrador, pero para enviar pruebas o lanzar primero hay que verificar el
                  dominio en la pestaña «Remitente».
                </p>
              )}
            </div>
          </div>

          {/* Diseño: se mantiene montado para no perder cambios al cambiar de pestaña. */}
          <div className={cn('min-h-0 flex-1 overflow-hidden rounded-md border', tab !== 'diseno' && 'hidden')}>
            <p className="border-b bg-muted/40 px-3 py-1.5 text-xs text-muted-foreground md:hidden">
              El editor funciona mejor en un computador.
            </p>
            <EmailDesignEditor
              ref={editorRef}
              initialProjectData={campaign?.bodyDesign}
              starterHtml={emailStarterHtml(tenant?.name ?? 'Tu empresa', tenant?.primary_color || undefined)}
            />
          </div>

          <div className="flex flex-col-reverse gap-2 border-t pt-3 sm:flex-row sm:justify-end">
            <Button variant="outline" onClick={onClose} disabled={busy}>
              Cerrar
            </Button>
            <Button variant="secondary" onClick={() => saveMutation.mutate()} disabled={!canSave || busy}>
              {saveMutation.isPending && <Spinner className="mr-2" />}
              Guardar borrador
            </Button>
            <Button
              onClick={() => {
                setAuthorized(false)
                setConfirmLaunch(true)
              }}
              disabled={!canLaunch || busy}
              title={!senderVerified ? 'Primero verifica el dominio en «Remitente»' : undefined}
            >
              {isFuture ? <CalendarClock className="mr-2 size-4" /> : <Send className="mr-2 size-4" />}
              {isFuture ? 'Programar' : 'Lanzar ahora'}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <AlertDialog open={confirmLaunch} onOpenChange={(open) => { if (!launchMutation.isPending) setConfirmLaunch(open) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{isFuture ? '¿Programar la campaña?' : '¿Lanzar la campaña ahora?'}</AlertDialogTitle>
            <AlertDialogDescription>
              Se enviará a <strong>{preview?.total ?? 0}</strong> correo(s)
              {isFuture && scheduledIso ? ` el ${new Date(scheduledIso).toLocaleString('es-CO')}` : ''}. Después de
              lanzarla no se puede editar (sí pausar o cancelar).
            </AlertDialogDescription>
          </AlertDialogHeader>
          <label className="flex items-start gap-2 text-sm">
            <Checkbox checked={authorized} onCheckedChange={(v) => setAuthorized(v === true)} className="mt-0.5" />
            <span>
              Confirmo que estos contactos autorizaron recibir comunicaciones de nuestra empresa (Ley 1581 de 2012,
              habeas data).
            </span>
          </label>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={launchMutation.isPending}>Volver</AlertDialogCancel>
            <AlertDialogAction
              disabled={!authorized || launchMutation.isPending}
              onClick={(e) => {
                e.preventDefault()
                launchMutation.mutate()
              }}
            >
              {launchMutation.isPending && <Spinner className="mr-2" />}
              {isFuture ? 'Programar' : 'Lanzar'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
