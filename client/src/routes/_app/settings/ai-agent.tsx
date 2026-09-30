import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { AlertTriangle, Bot, RotateCcw, Send, Sparkles } from 'lucide-react'
import { requireSettingsRole } from '@/lib/authGuards'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Switch } from '@/components/ui/switch'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Spinner } from '@/components/ui/spinner'
import { formatRailsError } from '@/lib/api'
import { cn, formatRelativeTime } from '@/lib/utils'
import { useUserRole } from '@/stores/auth'
import {
  TOOL_LABELS,
  aiAgentQueryKeys,
  estimateCostUsd,
  fetchAiAgentActivity,
  fetchAiAgentConfig,
  testAiAgent,
  updateAiAgentConfig,
  type AiAgentConfig,
  type AiAgentInput,
  type AiToolCall,
  type ChatTurn,
} from '@/lib/aiAgentApi'

// Mismo alcance que AiAgentPolicy: admin edita; manager consulta.
export const Route = createFileRoute('/_app/settings/ai-agent')({
  beforeLoad: () => requireSettingsRole('admin', 'manager'),
  component: AiAgentSettingsPage,
})

const BUSINESS_PLACEHOLDER = `Ej:
ISWO es una consultora de sistemas de gestión en Bogotá (Colombia) y Quito (Ecuador).
Servicios: certificación ISO 9001, ISO 14001, ISO 45001 y SG-SST.
Proceso: diagnóstico gratis → propuesta → implementación (3 a 6 meses) → auditoría.
Precios: desde $X según el tamaño de la empresa (el asesor confirma la cotización).
Horario: lunes a viernes, 8:00 a. m. a 6:00 p. m.
Web: https://iswo.com.co`

const FAQ_PLACEHOLDER = `Ej:
¿Cuánto dura la certificación? Entre 3 y 6 meses según el tamaño de la empresa.
¿Trabajan con empresas pequeñas? Sí, desde 5 empleados.`

function AiAgentSettingsPage() {
  const canEdit = useUserRole() === 'admin'
  const { data: config, isLoading } = useQuery({ queryKey: aiAgentQueryKeys.config(), queryFn: fetchAiAgentConfig })

  return (
    <div className="space-y-6">
      <div>
        <h2 className="flex items-center gap-2 text-xl font-semibold">
          <Bot className="size-5" />
          Asistente IA de WhatsApp
        </h2>
        <p className="text-sm text-muted-foreground">
          Responde por WhatsApp con la información de tu negocio, califica a cada lead y le pasa la conversación a un
          asesor cuando hace falta.
        </p>
      </div>

      {isLoading || !config ? (
        <Skeleton className="h-96 w-full rounded-lg" />
      ) : (
        <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_420px]">
          <ConfigForm config={config} canEdit={canEdit} />
          <div className="space-y-6">
            {canEdit && <TestChat disabled={!config.openaiConfigured} />}
            <ActivityCard />
          </div>
        </div>
      )}
    </div>
  )
}

function ConfigForm({ config, canEdit }: { config: AiAgentConfig; canEdit: boolean }) {
  const queryClient = useQueryClient()
  const toForm = (c: AiAgentConfig): AiAgentInput => ({
    enabled: c.enabled,
    assistant_name: c.assistantName,
    business_info: c.businessInfo,
    faq: c.faq,
    tone: c.tone,
    qualification: c.qualification,
    handoff_rules: c.handoffRules,
  })
  const [form, setForm] = useState<AiAgentInput>(() => toForm(config))
  useEffect(() => setForm(toForm(config)), [config])

  const set = <K extends keyof AiAgentInput>(key: K, value: AiAgentInput[K]) => setForm((f) => ({ ...f, [key]: value }))

  const saveMutation = useMutation({
    mutationFn: (body: Partial<AiAgentInput>) => updateAiAgentConfig(body),
    onSuccess: (next, body) => {
      queryClient.setQueryData(aiAgentQueryKeys.config(), next)
      if (body.enabled !== undefined && Object.keys(body).length === 1) {
        toast.success(next.enabled ? 'Asistente activado: ya responde por WhatsApp' : 'Asistente desactivado')
      } else {
        toast.success('Configuración guardada')
      }
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo guardar')),
  })

  const dirty = JSON.stringify(toForm(config)) !== JSON.stringify(form)

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <CardTitle className="flex items-center gap-2 text-base">
              Estado
              {config.active ? (
                <Badge className="border-0 bg-emerald-500/15 text-emerald-700 dark:text-emerald-300">Respondiendo</Badge>
              ) : config.enabled ? (
                <Badge className="border-0 bg-amber-500/15 text-amber-700 dark:text-amber-300">Activado sin clave</Badge>
              ) : (
                <Badge variant="outline">Apagado</Badge>
              )}
            </CardTitle>
            <CardDescription>Modelo: {config.model} (OpenAI)</CardDescription>
          </div>
          <label className="flex items-center gap-2 text-sm font-medium">
            <Switch
              checked={config.enabled}
              disabled={!canEdit || saveMutation.isPending || (!config.enabled && dirty)}
              onCheckedChange={(v) => saveMutation.mutate({ enabled: v })}
              aria-label="Activar asistente"
            />
            {config.enabled ? 'Activado' : 'Apagado'}
          </label>
        </div>
        {!config.openaiConfigured && (
          <p className="mt-2 flex items-start gap-2 rounded-md bg-amber-500/10 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">
            <AlertTriangle className="mt-0.5 size-4 shrink-0" />
            Falta la clave de OpenAI en el servidor. Puedes dejar todo configurado; el asistente empieza a responder
            cuando se agregue.
          </p>
        )}
        {!config.enabled && dirty && canEdit && (
          <p className="mt-2 text-xs text-muted-foreground">Guarda los cambios antes de activarlo.</p>
        )}
      </CardHeader>
      <CardContent className="space-y-5">
        <Field label="Nombre del asistente" hint="Cómo se presenta en el chat.">
          <Input
            value={form.assistant_name}
            onChange={(e) => set('assistant_name', e.target.value)}
            placeholder="Ej: Sofía, asistente de ISWO"
            disabled={!canEdit}
          />
        </Field>
        <Field
          label="Información del negocio"
          hint="Todo lo que el asistente puede contar: servicios, precios o rangos, proceso, horarios, ubicación, enlaces. No inventa nada que no esté aquí."
        >
          <Textarea
            value={form.business_info}
            onChange={(e) => set('business_info', e.target.value)}
            placeholder={BUSINESS_PLACEHOLDER}
            rows={10}
            disabled={!canEdit}
          />
        </Field>
        <Field label="Preguntas frecuentes (opcional)">
          <Textarea
            value={form.faq}
            onChange={(e) => set('faq', e.target.value)}
            placeholder={FAQ_PLACEHOLDER}
            rows={5}
            disabled={!canEdit}
          />
        </Field>
        <Field label="Tono de las respuestas">
          <Textarea value={form.tone} onChange={(e) => set('tone', e.target.value)} rows={2} disabled={!canEdit} />
        </Field>
        <Field label="Qué debe averiguar para calificar al lead">
          <Textarea
            value={form.qualification}
            onChange={(e) => set('qualification', e.target.value)}
            rows={2}
            disabled={!canEdit}
          />
        </Field>
        <Field label="Cuándo pasar la conversación a un asesor">
          <Textarea
            value={form.handoff_rules}
            onChange={(e) => set('handoff_rules', e.target.value)}
            rows={3}
            disabled={!canEdit}
          />
        </Field>

        {canEdit ? (
          <div className="flex flex-col gap-2 sm:flex-row sm:justify-end">
            <Button variant="outline" onClick={() => setForm(toForm(config))} disabled={!dirty || saveMutation.isPending}>
              Descartar cambios
            </Button>
            <Button
              onClick={() => {
                const { enabled: _enabled, ...rest } = form
                saveMutation.mutate(rest)
              }}
              disabled={!dirty || saveMutation.isPending}
            >
              {saveMutation.isPending && <Spinner className="mr-2" />}
              Guardar
            </Button>
          </div>
        ) : (
          <p className="text-xs text-muted-foreground">Solo un administrador puede cambiar el asistente.</p>
        )}
      </CardContent>
    </Card>
  )
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <Label>{label}</Label>
      {children}
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

/** Chat de prueba: usa la configuración guardada, no envía nada ni toca el CRM. */
function TestChat({ disabled }: { disabled: boolean }) {
  const [turns, setTurns] = useState<(ChatTurn & { tools?: AiToolCall[] })[]>([])
  const [draft, setDraft] = useState('')
  const endRef = useRef<HTMLDivElement>(null)

  const testMutation = useMutation({
    mutationFn: (history: ChatTurn[]) => testAiAgent(history),
    onSuccess: (res) => setTurns((t) => [...t, { role: 'assistant', content: res.reply, tools: res.toolCalls }]),
    onError: (err) => toast.error(formatRailsError(err, 'El asistente no pudo responder')),
  })

  useEffect(() => endRef.current?.scrollIntoView({ block: 'end' }), [turns, testMutation.isPending])

  const send = () => {
    const text = draft.trim()
    if (!text) return
    const next = [...turns, { role: 'user' as const, content: text }]
    setTurns(next)
    setDraft('')
    testMutation.mutate(next.map(({ role, content }) => ({ role, content })))
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between gap-2">
          <CardTitle className="flex items-center gap-2 text-base">
            <Sparkles className="size-4" />
            Probar el asistente
          </CardTitle>
          <Button variant="ghost" size="sm" onClick={() => setTurns([])} disabled={turns.length === 0}>
            <RotateCcw className="mr-1.5 size-3.5" />
            Reiniciar
          </Button>
        </div>
        <CardDescription>
          Escribe como si fueras un cliente. Usa la configuración guardada; no envía nada ni cambia el CRM.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="h-80 space-y-2 overflow-y-auto rounded-md border bg-muted/40 p-3">
          {turns.length === 0 && (
            <p className="py-10 text-center text-sm text-muted-foreground">Ej: «Hola, ¿cuánto cuesta la ISO 9001?»</p>
          )}
          {turns.map((t, i) => (
            <div key={i} className={cn('flex', t.role === 'user' ? 'justify-start' : 'justify-end')}>
              <div
                className={cn(
                  'max-w-[85%] rounded-lg px-3 py-2 text-sm shadow-sm',
                  t.role === 'user' ? 'border bg-card' : 'bg-primary/20',
                )}
              >
                <p className="whitespace-pre-wrap break-words">{t.content || '—'}</p>
                {t.tools && t.tools.length > 0 && (
                  <div className="mt-1.5 flex flex-wrap gap-1">
                    {t.tools.map((tool, j) => (
                      <span key={j} className="rounded bg-background/70 px-1.5 py-0.5 text-[10px] text-muted-foreground" title={tool.result}>
                        {TOOL_LABELS[tool.name] ?? tool.name}
                        {tool.name === 'calificar_lead' && typeof tool.arguments.temperatura === 'string'
                          ? `: ${temperatureLabel(tool.arguments.temperatura)}`
                          : ''}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            </div>
          ))}
          {testMutation.isPending && (
            <div className="flex justify-end">
              <span className="rounded-lg bg-primary/10 px-3 py-2 text-xs text-muted-foreground">Escribiendo…</span>
            </div>
          )}
          <div ref={endRef} />
        </div>
        <div className="flex gap-2">
          <Input
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                send()
              }
            }}
            placeholder={disabled ? 'Falta la clave de OpenAI' : 'Escribe como cliente…'}
            disabled={disabled || testMutation.isPending}
          />
          <Button onClick={send} disabled={disabled || testMutation.isPending || !draft.trim()} aria-label="Enviar">
            <Send className="size-4" />
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}

function temperatureLabel(t: string): string {
  return t === 'hot' ? 'caliente' : t === 'warm' ? 'tibio' : t === 'cold' ? 'frío' : t
}

const RUN_STATUS: Record<string, { label: string; className: string }> = {
  replied: { label: 'Respondió', className: 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300' },
  handoff: { label: 'Pasó a asesor', className: 'bg-sky-500/10 text-sky-700 dark:text-sky-300' },
  skipped: { label: 'No respondió', className: 'bg-muted text-muted-foreground' },
  error: { label: 'Error', className: 'bg-destructive/10 text-destructive' },
}

function ActivityCard() {
  const { data, isLoading } = useQuery({
    queryKey: aiAgentQueryKeys.activity(),
    queryFn: fetchAiAgentActivity,
    refetchInterval: 60_000,
  })
  const cost = data ? estimateCostUsd(data.last30.inputTokens, data.last30.outputTokens) : 0

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base">Actividad</CardTitle>
        {data && (
          <CardDescription>
            Últimos 30 días: {data.last30.replies} respuestas · {data.last30.handoffs} pasadas a asesor
            {data.last30.errors > 0 ? ` · ${data.last30.errors} errores` : ''} · costo aprox. USD {cost.toFixed(2)}
          </CardDescription>
        )}
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <Skeleton className="h-32 w-full" />
        ) : !data || data.runs.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">Todavía no ha respondido ningún chat.</p>
        ) : (
          <ul className="max-h-96 divide-y overflow-y-auto text-sm">
            {data.runs.map((r) => (
              <li key={r.id} className="space-y-1 py-2.5">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate font-medium">{r.contactName ?? 'Contacto'}</span>
                  <Badge className={cn('shrink-0 border-0', RUN_STATUS[r.status]?.className)}>
                    {RUN_STATUS[r.status]?.label ?? r.status}
                  </Badge>
                </div>
                {r.reply && <p className="line-clamp-2 text-xs text-muted-foreground">{r.reply}</p>}
                {r.error && <p className="text-xs text-destructive">{r.error}</p>}
                <p className="text-[11px] text-muted-foreground">
                  {formatRelativeTime(r.createdAt)}
                  {r.toolCalls.length > 0 && ` · ${r.toolCalls.map((t) => TOOL_LABELS[t.name] ?? t.name).join(', ')}`}
                </p>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
