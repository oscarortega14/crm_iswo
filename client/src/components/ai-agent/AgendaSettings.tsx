import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { AlertTriangle, BellRing, CalendarCheck, CalendarDays, Copy, UserCheck, UserX, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Spinner } from '@/components/ui/spinner'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { formatRailsError } from '@/lib/api'
import { cn } from '@/lib/utils'
import {
  aiAgentQueryKeys,
  cancelAppointment,
  fetchAppointments,
  setAppointmentOutcome,
  testCalendar,
  updateAiAgentConfig,
  type AiAgentConfig,
  type AiCalendarSettings,
  type AiReminderSettings,
} from '@/lib/aiAgentApi'
import { fetchWhatsappTemplates } from '@/lib/whatsappTemplatesApi'
import { useAuthStore } from '@/stores/auth'

const DAYS = [
  { value: 1, label: 'Lun' },
  { value: 2, label: 'Mar' },
  { value: 3, label: 'Mié' },
  { value: 4, label: 'Jue' },
  { value: 5, label: 'Vie' },
  { value: 6, label: 'Sáb' },
  { value: 0, label: 'Dom' },
]

const DURATIONS = [15, 30, 45, 60, 90, 120]

/**
 * Agenda del asistente (fase 2): Google Calendar compartido con la cuenta de
 * servicio del CRM, horario de atención y duración de las reuniones.
 */
export function AgendaSettings({ config, canEdit }: { config: AiAgentConfig; canEdit: boolean }) {
  const queryClient = useQueryClient()
  const [form, setForm] = useState<AiCalendarSettings>(config.calendar)
  useEffect(() => {
    setForm(config.calendar)
  }, [config.calendar])
  const set = <K extends keyof AiCalendarSettings>(k: K, v: AiCalendarSettings[K]) => setForm((f) => ({ ...f, [k]: v }))
  const dirty = JSON.stringify(form) !== JSON.stringify(config.calendar)

  const saveMutation = useMutation({
    mutationFn: () => updateAiAgentConfig({ calendar: form }),
    onSuccess: ({ config: next }) => {
      queryClient.setQueryData(aiAgentQueryKeys.config(), next)
      toast.success('Agenda guardada')
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo guardar la agenda')),
  })

  const testMutation = useMutation({
    mutationFn: testCalendar,
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo conectar con Google Calendar')),
  })

  const copy = (text: string) => {
    void navigator.clipboard?.writeText(text)
    toast.success('Copiado')
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex flex-wrap items-center gap-2 text-base">
          <CalendarDays className="size-4" />
          Agenda (Google Calendar)
          {config.calendarActive ? (
            <Badge className="border-0 bg-emerald-500/15 text-emerald-700 dark:text-emerald-300">Agendando</Badge>
          ) : (
            <Badge variant="outline">Sin conectar</Badge>
          )}
        </CardTitle>
        <CardDescription>
          El asistente ofrece horarios libres de este calendario y agenda, reprograma o cancela citas por WhatsApp.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {!config.googleConfigured ? (
          <p className="flex items-start gap-2 rounded-md bg-amber-500/10 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">
            <AlertTriangle className="mt-0.5 size-4 shrink-0" />
            Falta la cuenta de servicio de Google en el servidor. Puedes dejar la agenda configurada mientras tanto.
          </p>
        ) : (
          <div className="space-y-1.5 rounded-md border bg-muted/40 p-3 text-sm">
            <p className="font-medium">1. Comparte el calendario con el CRM</p>
            <p className="text-xs text-muted-foreground">
              En Google Calendar → configuración del calendario → «Compartir con personas específicas» → agrega este
              correo con permiso «Hacer cambios en los eventos»:
            </p>
            <div className="flex items-center gap-2">
              <code className="min-w-0 flex-1 break-all rounded bg-background px-2 py-1 text-xs">
                {config.serviceAccountEmail}
              </code>
              <Button variant="ghost" size="icon" className="size-7" onClick={() => copy(config.serviceAccountEmail ?? '')} aria-label="Copiar correo">
                <Copy className="size-3.5" />
              </Button>
            </div>
          </div>
        )}

        <div className="space-y-1.5">
          <Label htmlFor="calendarId">
            {config.googleConfigured ? '2. ' : ''}ID del calendario
          </Label>
          <Input
            id="calendarId"
            value={form.calendar_id}
            onChange={(e) => set('calendar_id', e.target.value)}
            placeholder="agenda@iswo.com.co (o el ID de «Integrar el calendario»)"
            disabled={!canEdit}
          />
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label>Duración de la reunión</Label>
            <Select
              value={String(form.duration_minutes)}
              onValueChange={(v) => set('duration_minutes', Number(v))}
              disabled={!canEdit}
            >
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                {DURATIONS.map((d) => (
                  <SelectItem key={d} value={String(d)}>{d < 60 ? `${d} minutos` : `${d / 60} hora${d > 60 ? 's' : ''}`}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>Horario de atención</Label>
            <div className="flex items-center gap-2">
              <Input type="time" value={form.start_time} onChange={(e) => set('start_time', e.target.value)} disabled={!canEdit} aria-label="Desde" />
              <span className="text-sm text-muted-foreground">a</span>
              <Input type="time" value={form.end_time} onChange={(e) => set('end_time', e.target.value)} disabled={!canEdit} aria-label="Hasta" />
            </div>
          </div>
        </div>

        <div className="space-y-1.5">
          <Label>Días de atención</Label>
          <div className="flex flex-wrap gap-1.5">
            {DAYS.map((d) => {
              const on = form.work_days.includes(d.value)
              return (
                <button
                  key={d.value}
                  type="button"
                  disabled={!canEdit}
                  onClick={() =>
                    set('work_days', on ? form.work_days.filter((x) => x !== d.value) : [...form.work_days, d.value])
                  }
                  className={cn(
                    'rounded-md border px-3 py-1.5 text-sm transition-colors',
                    on ? 'border-primary bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted',
                  )}
                  aria-pressed={on}
                >
                  {d.label}
                </button>
              )
            })}
          </div>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="minNotice">Anticipación mínima (horas)</Label>
            <Input
              id="minNotice"
              type="number"
              min={0}
              max={168}
              value={form.min_notice_hours}
              onChange={(e) => set('min_notice_hours', Number(e.target.value))}
              disabled={!canEdit}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="maxDays">Agendar hasta (días adelante)</Label>
            <Input
              id="maxDays"
              type="number"
              min={1}
              max={60}
              value={form.max_days_ahead}
              onChange={(e) => set('max_days_ahead', Number(e.target.value))}
              disabled={!canEdit}
            />
          </div>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="location">Lugar o enlace de la reunión (opcional)</Label>
          <Input
            id="location"
            value={form.location}
            onChange={(e) => set('location', e.target.value)}
            placeholder="Ej: https://meet.google.com/abc-defg-hij o Calle 00 # 00-00, Bogotá"
            disabled={!canEdit}
          />
          <p className="text-xs text-muted-foreground">
            Para que la oportunidad avance sola al agendar, en Ajustes → Pipelines elige en la etapa el avance
            automático «Se agendó una reunión».
          </p>
        </div>

        {canEdit && (
          <div className="flex flex-col gap-2 sm:flex-row sm:justify-end">
            <Button
              variant="outline"
              onClick={() => testMutation.mutate()}
              disabled={dirty || !config.calendarActive || testMutation.isPending}
              title={dirty ? 'Guarda antes de probar' : undefined}
            >
              {testMutation.isPending ? <Spinner className="mr-2" /> : <CalendarCheck className="mr-2 size-4" />}
              Probar conexión
            </Button>
            <Button onClick={() => saveMutation.mutate()} disabled={!dirty || saveMutation.isPending}>
              {saveMutation.isPending && <Spinner className="mr-2" />}
              Guardar agenda
            </Button>
          </div>
        )}

        {testMutation.data && (
          <div className="rounded-md border border-emerald-500/30 bg-emerald-500/5 p-3 text-sm">
            <p className="font-medium text-emerald-700 dark:text-emerald-300">Conexión correcta. Próximos horarios libres:</p>
            <ul className="mt-1 list-disc pl-5 text-muted-foreground">
              {testMutation.data.length === 0 ? (
                <li>No hay horarios libres en el rango configurado.</li>
              ) : (
                testMutation.data.map((s) => <li key={s.startsAt}>{s.label}</li>)
              )}
            </ul>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

/** Próximas citas (con confirmación y recordatorios enviados) y las ya pasadas por marcar. */
export function UpcomingAppointments({ canCancel }: { canCancel: boolean }) {
  const queryClient = useQueryClient()
  const { data, isLoading } = useQuery({
    queryKey: aiAgentQueryKeys.appointments(),
    queryFn: fetchAppointments,
    refetchInterval: 60_000,
  })
  const upcoming = data?.upcoming ?? []
  const pending = data?.awaitingOutcome ?? []
  const invalidate = () => queryClient.invalidateQueries({ queryKey: aiAgentQueryKeys.appointments() })

  const cancelMutation = useMutation({
    mutationFn: cancelAppointment,
    onSuccess: () => {
      toast.success('Cita cancelada (también en Google Calendar)')
      void invalidate()
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo cancelar la cita')),
  })

  const outcomeMutation = useMutation({
    mutationFn: ({ id, outcome }: { id: string; outcome: 'attended' | 'no_show' }) => setAppointmentOutcome(id, outcome),
    onSuccess: (_d, { outcome }) => {
      toast.success(outcome === 'attended' ? 'Marcada como asistida' : 'Marcada como no asistió: se le envió el mensaje para reagendar')
      void invalidate()
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo guardar el resultado')),
  })

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="flex items-center gap-2 text-base">
          <CalendarCheck className="size-4" />
          Citas
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        {pending.length > 0 && (
          <div className="space-y-2 rounded-md border border-amber-500/30 bg-amber-500/5 p-3">
            <p className="text-sm font-medium">¿Asistieron? ({pending.length})</p>
            <ul className="divide-y text-sm">
              {pending.map((a) => (
                <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                  <div className="min-w-0">
                    <p className="truncate font-medium">{a.contactName ?? 'Contacto'}</p>
                    <p className="text-xs text-muted-foreground first-letter:uppercase">{a.label}</p>
                  </div>
                  {canCancel && (
                    <div className="flex gap-1.5">
                      <Button size="sm" variant="outline" className="h-7 text-xs" disabled={outcomeMutation.isPending}
                        onClick={() => outcomeMutation.mutate({ id: a.id, outcome: 'attended' })}>
                        <UserCheck className="mr-1 size-3.5" />
                        Asistió
                      </Button>
                      <Button size="sm" variant="outline" className="h-7 text-xs text-destructive" disabled={outcomeMutation.isPending}
                        onClick={() => outcomeMutation.mutate({ id: a.id, outcome: 'no_show' })}>
                        <UserX className="mr-1 size-3.5" />
                        No asistió
                      </Button>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          </div>
        )}

        {isLoading ? (
          <Skeleton className="h-20 w-full" />
        ) : upcoming.length === 0 ? (
          <p className="py-4 text-center text-sm text-muted-foreground">No hay citas próximas.</p>
        ) : (
          <ul className="max-h-80 divide-y overflow-y-auto text-sm">
            {upcoming.map((a) => (
              <li key={a.id} className="flex items-start justify-between gap-2 py-2.5">
                <div className="min-w-0 space-y-0.5">
                  <p className="font-medium first-letter:uppercase">{a.label}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {a.contactName ?? 'Contacto'}
                    {a.ownerName ? ` · ${a.ownerName}` : ''}
                    {a.notes ? ` · ${a.notes}` : ''}
                  </p>
                  <div className="flex flex-wrap gap-1">
                    {a.confirmedAt ? (
                      <Badge className="border-0 bg-emerald-500/15 text-[10px] text-emerald-700 dark:text-emerald-300">Confirmó</Badge>
                    ) : (
                      <Badge variant="outline" className="text-[10px]">Sin confirmar</Badge>
                    )}
                    {a.remindersSent.length > 0 && (
                      <Badge variant="outline" className="text-[10px]">
                        Recordatorio: {a.remindersSent.map((h) => `${h} h`).join(', ')}
                      </Badge>
                    )}
                  </div>
                </div>
                {canCancel && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="shrink-0 text-destructive"
                    onClick={() => {
                      if (window.confirm(`¿Cancelar la cita de ${a.contactName ?? 'este contacto'}?`)) cancelMutation.mutate(a.id)
                    }}
                    disabled={cancelMutation.isPending}
                  >
                    <X className="mr-1 size-3.5" />
                    Cancelar
                  </Button>
                )}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}

const OFFSETS = [48, 24, 4, 2, 1]
const STAFF_OFFSETS = [
  { value: 0, label: 'No avisar' },
  { value: 15, label: '15 minutos antes' },
  { value: 30, label: '30 minutos antes' },
  { value: 60, label: '1 hora antes' },
  { value: 120, label: '2 horas antes' },
  { value: 1440, label: '1 día antes' },
]
const NONE = '__none__'

/** Textos sugeridos para crear las plantillas en Meta (categoría Utilidad). */
export const reminderTemplateText = (company: string) =>
  `Hola {{1}}, te recordamos tu reunión con ${company} el {{2}}. ¿Nos confirmas tu asistencia?\n[Botones: Confirmo · Reprogramar]`
export const noShowTemplateText = (company: string) =>
  `Hola {{1}}, te esperábamos en la reunión con ${company} del {{2}} y no pudimos conectarnos. ¿Agendamos otro horario?`

/** Recordatorios al cliente y al equipo (fase 3). */
export function RemindersSettings({ config, canEdit }: { config: AiAgentConfig; canEdit: boolean }) {
  const queryClient = useQueryClient()
  const company = useAuthStore((s) => s.tenant?.name) ?? 'nuestra empresa'
  const [form, setForm] = useState<AiReminderSettings>(config.reminders)
  useEffect(() => {
    setForm(config.reminders)
  }, [config.reminders])
  const set = <K extends keyof AiReminderSettings>(k: K, v: AiReminderSettings[K]) => setForm((f) => ({ ...f, [k]: v }))
  const dirty = JSON.stringify(form) !== JSON.stringify(config.reminders)

  const { data: templates = [] } = useQuery({
    queryKey: [...aiAgentQueryKeys.config(), 'templates'],
    queryFn: () => fetchWhatsappTemplates(true),
    enabled: canEdit,
  })

  const saveMutation = useMutation({
    mutationFn: () => updateAiAgentConfig({ reminders: form }),
    onSuccess: ({ config: next }) => {
      queryClient.setQueryData(aiAgentQueryKeys.config(), next)
      toast.success('Recordatorios guardados')
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo guardar')),
  })

  const templateSelect = (key: 'whatsapp_template_id' | 'no_show_template_id', id: string) => (
    <Select value={form[key] ?? NONE} onValueChange={(v) => set(key, v === NONE ? null : v)} disabled={!canEdit}>
      <SelectTrigger id={id}><SelectValue placeholder="Sin plantilla" /></SelectTrigger>
      <SelectContent>
        <SelectItem value={NONE}>Sin plantilla</SelectItem>
        {templates.map((t) => (
          <SelectItem key={t.id} value={t.id}>
            {t.name}
            <span className="ml-2 text-xs text-muted-foreground">
              {t.metaStatus?.toUpperCase() === 'APPROVED' ? 'aprobada' : t.metaStatus ? t.metaStatus.toLowerCase() : 'sin sincronizar'}
            </span>
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <BellRing className="size-4" />
          Recordatorios de citas
        </CardTitle>
        <CardDescription>
          Al cliente por WhatsApp y correo (responde «Confirmo» o «Reprogramar»), al asesor antes de la reunión y un
          resumen diario para admin y manager.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="space-y-1.5">
          <Label>Recordar al cliente</Label>
          <div className="flex flex-wrap gap-1.5">
            {OFFSETS.map((h) => {
              const on = form.client_offsets.includes(h)
              return (
                <button key={h} type="button" disabled={!canEdit} aria-pressed={on}
                  onClick={() => set('client_offsets', on ? form.client_offsets.filter((x) => x !== h) : [...form.client_offsets, h])}
                  className={cn('rounded-md border px-3 py-1.5 text-sm transition-colors',
                    on ? 'border-primary bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted')}>
                  {h} h antes
                </button>
              )
            })}
          </div>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="reminderTemplate">Plantilla de WhatsApp para el recordatorio</Label>
          {templateSelect('whatsapp_template_id', 'reminderTemplate')}
          <p className="text-xs text-muted-foreground">
            Se usa cuando el cliente no ha escrito en las últimas 24 h (si escribió, se envía como mensaje normal, sin
            costo de plantilla). Créala en Meta como <b>Utilidad</b> con las variables en este orden — {'{{1}}'} nombre,
            {' {{2}}'} fecha y hora:
          </p>
          <TemplateHint text={reminderTemplateText(company)} />
        </div>

        <label className="flex items-center justify-between gap-3 text-sm">
          <span>
            <span className="font-medium">También por correo</span>
            <span className="block text-xs text-muted-foreground">Si el cliente dejó correo.</span>
          </span>
          <Switch checked={form.email_enabled} onCheckedChange={(v) => set('email_enabled', v)} disabled={!canEdit} />
        </label>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label>Recordatorio al asesor</Label>
            <Select value={String(form.staff_offset_minutes)} onValueChange={(v) => set('staff_offset_minutes', Number(v))} disabled={!canEdit}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                {STAFF_OFFSETS.map((o) => <SelectItem key={o.value} value={String(o.value)}>{o.label}</SelectItem>)}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">Por WhatsApp a su celular (o en la campana si no tiene celular).</p>
          </div>
          <label className="flex items-start justify-between gap-3 text-sm">
            <span>
              <span className="font-medium">Resumen diario</span>
              <span className="block text-xs text-muted-foreground">A las 7:00 a. m., citas del día para admin y manager.</span>
            </span>
            <Switch checked={form.daily_summary} onCheckedChange={(v) => set('daily_summary', v)} disabled={!canEdit} />
          </label>
        </div>

        <div className="space-y-2">
          <label className="flex items-center justify-between gap-3 text-sm">
            <span>
              <span className="font-medium">Si no asistió, ofrecer reagendar</span>
              <span className="block text-xs text-muted-foreground">Al marcar «No asistió» en Citas.</span>
            </span>
            <Switch checked={form.no_show_followup} onCheckedChange={(v) => set('no_show_followup', v)} disabled={!canEdit} />
          </label>
          {form.no_show_followup && (
            <>
              {templateSelect('no_show_template_id', 'noShowTemplate')}
              <TemplateHint text={noShowTemplateText(company)} />
            </>
          )}
        </div>

        {canEdit && (
          <div className="flex justify-end">
            <Button onClick={() => saveMutation.mutate()} disabled={!dirty || saveMutation.isPending}>
              {saveMutation.isPending && <Spinner className="mr-2" />}
              Guardar recordatorios
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function TemplateHint({ text }: { text: string }) {
  return (
    <div className="flex items-start gap-2 rounded-md border bg-muted/40 p-2 text-xs">
      <p className="min-w-0 flex-1 whitespace-pre-wrap text-muted-foreground">{text}</p>
      <Button variant="ghost" size="icon" className="size-6 shrink-0" aria-label="Copiar texto"
        onClick={() => { void navigator.clipboard?.writeText(text.split('\n[')[0]); toast.success('Texto copiado') }}>
        <Copy className="size-3" />
      </Button>
    </div>
  )
}
