import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { AlertTriangle, CalendarCheck, CalendarDays, Copy, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Spinner } from '@/components/ui/spinner'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { formatRailsError } from '@/lib/api'
import { cn } from '@/lib/utils'
import {
  aiAgentQueryKeys,
  cancelAppointment,
  fetchAppointments,
  testCalendar,
  updateAiAgentConfig,
  type AiAgentConfig,
  type AiCalendarSettings,
} from '@/lib/aiAgentApi'

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

/** Próximas citas agendadas (por el asistente o el equipo), con opción de cancelar. */
export function UpcomingAppointments({ canCancel }: { canCancel: boolean }) {
  const queryClient = useQueryClient()
  const { data = [], isLoading } = useQuery({
    queryKey: aiAgentQueryKeys.appointments(),
    queryFn: fetchAppointments,
    refetchInterval: 60_000,
  })

  const cancelMutation = useMutation({
    mutationFn: cancelAppointment,
    onSuccess: () => {
      toast.success('Cita cancelada (también en Google Calendar)')
      void queryClient.invalidateQueries({ queryKey: aiAgentQueryKeys.appointments() })
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo cancelar la cita')),
  })

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="flex items-center gap-2 text-base">
          <CalendarCheck className="size-4" />
          Próximas citas
        </CardTitle>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <Skeleton className="h-20 w-full" />
        ) : data.length === 0 ? (
          <p className="py-4 text-center text-sm text-muted-foreground">No hay citas agendadas.</p>
        ) : (
          <ul className="max-h-80 divide-y overflow-y-auto text-sm">
            {data.map((a) => (
              <li key={a.id} className="flex items-start justify-between gap-2 py-2.5">
                <div className="min-w-0">
                  <p className="font-medium first-letter:uppercase">{a.label}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {a.contactName ?? 'Contacto'}
                    {a.ownerName ? ` · ${a.ownerName}` : ''}
                    {a.notes ? ` · ${a.notes}` : ''}
                  </p>
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
