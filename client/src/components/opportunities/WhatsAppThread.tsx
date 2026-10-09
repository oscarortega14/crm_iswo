import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuthStore } from '@/stores/auth'
import { Send, Phone, Video, Trash2, Check, CheckCheck, AlertCircle, MessageSquareText, FileText, Download, ArrowLeft, ChevronDown, Bot, BotOff } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { format } from 'date-fns'
import { es } from 'date-fns/locale'
import { cn, normalizePhoneForWhatsAppDial } from '@/lib/utils'
import { toast } from 'sonner'
import api, { formatRailsError } from '@/lib/api'
import { queryKeys } from '@/lib/queryClient'
import { fetchWhatsappTemplates } from '@/lib/whatsappTemplatesApi'

/** WhatsApp cierra la ventana de servicio 24h después del último mensaje del contacto. */
const SERVICE_WINDOW_MS = 24 * 60 * 60 * 1000

export type ThreadMessage = {
  id: string
  content: string
  timestamp: string
  isOutgoing: boolean
  /** Proveedor: whatsapp_cloud | openwa */
  provider?: string
  status: 'pending' | 'queued' | 'sent' | 'delivered' | 'read' | 'failed'
  errorMessage?: string
  mediaUrl?: string
  /** Solo en mensajes de plantilla (content viene vacío: el texto real que
   * aprobó Meta no se guarda en el CRM) — para mostrar algo en vez de una
   * burbuja en blanco. */
  templateName?: string
  templateParams?: string[]
  /** Lo envió el asistente IA o una automatización (no una persona). */
  automated?: boolean
}

type MediaKind = 'image' | 'audio' | 'video' | 'file'

function inferMediaKind(url: string): MediaKind {
  const ext = url.split('?')[0].split('.').pop()?.toLowerCase() ?? ''
  if (['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(ext)) return 'image'
  if (['mp3', 'ogg', 'opus', 'm4a', 'wav', 'aac'].includes(ext)) return 'audio'
  if (['mp4', 'webm', 'mov'].includes(ext)) return 'video'
  return 'file'
}

function MediaPreview({ url }: { url: string }) {
  const kind = inferMediaKind(url)

  if (kind === 'image') {
    return (
      <a href={url} target="_blank" rel="noopener noreferrer" className="mb-1.5 block">
        <img src={url} alt="Imagen adjunta" className="max-h-64 w-auto rounded-md object-cover" />
      </a>
    )
  }
  if (kind === 'audio') {
    return (
      <audio controls className="mb-1.5 h-9 max-w-full">
        <source src={url} />
      </audio>
    )
  }
  if (kind === 'video') {
    return <video controls className="mb-1.5 max-h-64 w-auto rounded-md" src={url} />
  }
  return (
    <a
      href={url}
      target="_blank"
      rel="noopener noreferrer"
      className="mb-1.5 flex items-center gap-1.5 text-sm underline underline-offset-2"
    >
      <FileText className="size-4 shrink-0" />
      <span className="truncate">Documento adjunto</span>
      <Download className="size-3.5 shrink-0" />
    </a>
  )
}

interface WhatsAppThreadProps {
  /** Hilo dentro de una oportunidad (OpportunitySlideOver) — comportamiento original. */
  opportunityId?: string
  /** Hilo standalone por contacto (bandeja de entrada /whatsapp), sin oportunidad. */
  contactId?: string
  contactName: string
  contactPhone: string
  messages: ThreadMessage[]
  /** true mientras se carga el hilo por primera vez (o al cambiar de conversación) —
   * muestra un skeleton en vez de "No hay mensajes aún" para evitar el parpadeo. */
  isLoading?: boolean
  /** false para viewer: oculta el input de envío (la policy ya lo bloquea en backend). */
  canSend?: boolean
  /** Borrar hilo completo — solo disponible en modo oportunidad (no hay endpoint standalone). */
  canDelete?: boolean
  /** Si se pasa, muestra una flecha "volver" (solo visible en mobile, lg:hidden) que
   * llama esto — en /whatsapp vuelve a la lista de conversaciones sin reseleccionar. */
  onBack?: () => void
  /** Tras «Eliminar conversación» (p. ej. volver a la lista en la bandeja). */
  onDeleted?: () => void
  /** Estado del asistente en este chat (solo bandeja). Si se pasa onToggleAutomation, muestra el botón. */
  automationPaused?: boolean
  onToggleAutomation?: () => void
  /** El asistente está encendido en general; si no, el botón dice «Asistente apagado». */
  assistantActive?: boolean
}

export function WhatsAppThread({
  opportunityId,
  contactId,
  contactName,
  contactPhone,
  messages,
  isLoading = false,
  canSend: canSendProp = true,
  canDelete = Boolean(opportunityId),
  onBack,
  onDeleted,
  automationPaused = false,
  onToggleAutomation,
  assistantActive = false,
}: WhatsAppThreadProps) {
  const queryClient = useQueryClient()
  const canManageIntegrations = useAuthStore((s) => s.isAdmin() || s.isManager())
  const [draft, setDraft] = useState('')
  const sendUrl = opportunityId
    ? `/opportunities/${opportunityId}/whatsapp_messages`
    : `/whatsapp_conversations/${contactId}/send_message`
  const messagesKey = opportunityId
    ? queryKeys.opportunities.messages(opportunityId)
    : queryKeys.whatsappConversations.messages(contactId ?? '')
  /** Si el contacto no tiene teléfono en CRM, el usuario puede escribir el destino aquí. */
  const [manualTo, setManualTo] = useState('')

  const toNumber = useMemo(() => {
    const raw = manualTo.trim() || contactPhone.trim()
    return normalizePhoneForWhatsAppDial(raw)
  }, [contactPhone, manualTo])

  const canSend = canSendProp && toNumber.replace(/\D/g, '').length >= 10

  /** Último mensaje entrante — si pasaron >24h (o nunca escribió), Meta rechaza texto libre. */
  const lastInboundAt = useMemo(() => {
    const inbound = messages.filter((m) => !m.isOutgoing)
    if (inbound.length === 0) return null
    return inbound.reduce<string>((latest, m) => (m.timestamp > latest ? m.timestamp : latest), inbound[0].timestamp)
  }, [messages])
  const serviceWindowOpen = !!lastInboundAt && Date.now() - new Date(lastInboundAt).getTime() < SERVICE_WINDOW_MS

  // Colapsado por defecto salvo que haga falta de entrada (fuera de la
  // ventana de 24h, sin plantilla no se puede escribir nada) — libera
  // bastante alto de pantalla en mobile, donde ya cuesta ver la
  // conversación. Una vez que el usuario lo toca, queda como lo dejó.
  const [templatePanelOpen, setTemplatePanelOpen] = useState(() => !serviceWindowOpen)

  const [templateId, setTemplateId] = useState('')
  const [templateVars, setTemplateVars] = useState<string[]>([])

  const { data: templates = [] } = useQuery({
    queryKey: queryKeys.whatsappTemplates.all,
    queryFn: () => fetchWhatsappTemplates(true),
    staleTime: 5 * 60 * 1000,
  })
  const selectedTemplate = templates.find((t) => t.id === templateId) ?? null

  const authIssueMessage = messages
    .filter((m) => m.status === 'failed' && m.isOutgoing)
    .reduce<string | null>((found, m) => {
      if (found) return found
      const err = m.errorMessage ?? ''
      if (
        err.includes('Authenticate') ||
        err.includes('Authentication Error') ||
        err.includes('invalid username') ||
        err.includes('rechazó la API Key') ||
        err.includes('Credenciales') ||
        err.includes('credentials')
      ) {
        return err
      }
      return null
    }, null)

  const clearMutation = useMutation({
    mutationFn: async () => {
      await api.delete(
        opportunityId
          ? `/opportunities/${opportunityId}/whatsapp_messages`
          : `/whatsapp_conversations/${contactId}/messages`,
      )
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: messagesKey })
      void queryClient.invalidateQueries({ queryKey: queryKeys.whatsappConversations.all })
      toast.success('Conversación eliminada')
      onDeleted?.()
    },
    onError: (e: unknown) => toast.error(formatRailsError(e)),
  })

  const sendMutation = useMutation({
    mutationFn: async (body: string) => {
      const res = await api.post(sendUrl, { to_number: toNumber, body })
      return res.data
    },
    // Optimista: el mensaje se pinta al toque, antes de que responda el backend.
    // El envío real es asíncrono (WhatsappDeliveryJob en background) — el estado
    // final (sent/delivered/failed) llega solo con el próximo poll del hilo.
    onMutate: async (body: string) => {
      await queryClient.cancelQueries({ queryKey: messagesKey })
      const previous = queryClient.getQueryData<ThreadMessage[]>(messagesKey)
      const optimisticMessage: ThreadMessage = {
        id: `optimistic-${Date.now()}`,
        content: body,
        timestamp: new Date().toISOString(),
        isOutgoing: true,
        status: 'pending',
      }
      queryClient.setQueryData<ThreadMessage[]>(messagesKey, (old) => [...(old ?? []), optimisticMessage])
      setDraft('')
      return { previous }
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: messagesKey })
    },
    onError: (e: unknown, _body, context) => {
      if (context?.previous) queryClient.setQueryData(messagesKey, context.previous)
      toast.error(formatRailsError(e))
    },
  })

  const sendTemplateMutation = useMutation({
    mutationFn: async () => {
      const res = await api.post<{
        data?: { attributes?: { status?: string; error_message?: string | null } }
      }>(sendUrl, {
        to_number: toNumber,
        whatsapp_template_id: templateId,
        template_params: templateVars,
      })
      return res.data
    },
    onSuccess: (payload) => {
      const attrs = payload?.data?.attributes
      if (attrs?.status === 'failed') {
        toast.error(attrs.error_message?.trim() || 'Meta rechazó la plantilla. Revisa el nombre y el idioma.')
      } else {
        toast.success('Plantilla enviada — ya puedes seguir la conversación con texto libre')
      }
      setTemplateId('')
      setTemplateVars([])
      void queryClient.invalidateQueries({ queryKey: messagesKey })
    },
    onError: (e: unknown) => toast.error(formatRailsError(e)),
  })

  const handleSend = () => {
    const text = draft.trim()
    if (!text || !canSend) return
    sendMutation.mutate(text)
  }

  // Auto-scroll al último mensaje: al cambiar de conversación, al recibir uno
  // nuevo por poll, o al enviar uno propio. El contenedor es un div nativo
  // con overflow-y-auto (no ScrollArea de Radix) — su manejo interno del
  // scrollbar custom pisaba el scrollTop seteado a mano, así que el mensaje
  // nuevo llegaba pero había que bajar la barra manualmente para verlo.
  // El doble requestAnimationFrame espera a que el layout del mensaje nuevo
  // (y las imágenes/adjuntos, si los hay) ya esté pintado antes de mover el
  // scroll, para no quedarse corto.
  const viewportRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = viewportRef.current
    if (!el) return
    let raf2 = 0
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => {
        el.scrollTop = el.scrollHeight
      })
    })
    return () => {
      cancelAnimationFrame(raf1)
      cancelAnimationFrame(raf2)
    }
  }, [contactId, opportunityId, messages.length])

  const handleSelectTemplate = (id: string) => {
    setTemplateId(id)
    const tpl = templates.find((t) => t.id === id)
    setTemplateVars(tpl ? tpl.variableLabels.map(() => '') : [])
  }

  const canSendTemplate = canSend && !!selectedTemplate && templateVars.every((v) => v.trim())

  const getStatusIcon = (status: ThreadMessage['status'], outgoing: boolean) => {
    if (!outgoing) return null
    switch (status) {
      case 'sent':
      case 'queued':
      case 'pending':
        return <Check className="h-3 w-3 text-muted-foreground" />
      case 'delivered':
        return <CheckCheck className="h-3 w-3 text-muted-foreground" />
      case 'read':
        return <CheckCheck className="h-3 w-3 text-primary" />
      case 'failed':
        return <span className="text-[10px] text-destructive">!</span>
      default:
        return <Check className="h-3 w-3 text-muted-foreground" />
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden border-0 sm:rounded-lg sm:border">
      {authIssueMessage && (
        <div className="shrink-0 border-b border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          <div className="flex gap-2">
            <AlertCircle className="mt-0.5 size-4 shrink-0" />
            <div className="space-y-1">
              <p className="font-medium text-foreground">
                Error de credenciales al enviar mensajes.
              </p>
              {canManageIntegrations ? (
                <p>
                  Revisa las credenciales en{' '}
                  <Link
                    to="/settings/integrations"
                    className="font-medium underline underline-offset-2 text-primary"
                  >
                    Ajustes → Integraciones
                  </Link>
                  {': '}
                  {authIssueMessage.trim().slice(0, 160)}
                </p>
              ) : (
                <p>Contacta al administrador para corregir las credenciales del proveedor de mensajería.</p>
              )}
            </div>
          </div>
        </div>
      )}
      <div className="flex shrink-0 items-center justify-between px-4 py-3 bg-primary text-primary-foreground">
        <div className="flex items-center gap-3 min-w-0">
          {onBack && (
            <Button
              variant="ghost"
              size="icon"
              className="-ml-2 shrink-0 text-primary-foreground hover:bg-primary-foreground/15 lg:hidden"
              type="button"
              onClick={onBack}
              aria-label="Volver a conversaciones"
            >
              <ArrowLeft className="h-5 w-5" />
            </Button>
          )}
          <div className="min-w-0">
            <p className="font-medium truncate">{contactName}</p>
            <p className="text-xs text-primary-foreground/80 truncate">
              {contactPhone.trim() ? contactPhone : 'Sin teléfono en contacto'}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          {onToggleAutomation && !assistantActive && (
            <span
              className="hidden items-center gap-1.5 text-xs text-primary-foreground/70 sm:flex"
              title="El asistente IA está apagado para toda la empresa (Ajustes → Asistente IA)."
            >
              <BotOff className="h-4 w-4" />
              Asistente apagado
            </span>
          )}
          {onToggleAutomation && assistantActive && (
            <Button
              variant="ghost"
              size="sm"
              className="gap-1.5 text-primary-foreground hover:bg-primary-foreground/15"
              type="button"
              onClick={onToggleAutomation}
              title={
                automationPaused
                  ? 'El asistente no responde en este chat. Tócalo para que vuelva a responder.'
                  : 'El asistente responde en este chat. Tócalo para atenderlo tú.'
              }
            >
              {automationPaused ? <BotOff className="h-4 w-4" /> : <Bot className="h-4 w-4" />}
              <span className="hidden text-xs sm:inline">{automationPaused ? 'Asistente en pausa' : 'Asistente activo'}</span>
            </Button>
          )}
          <Button variant="ghost" size="icon" className="text-primary-foreground hover:bg-primary-foreground/15" type="button">
            <Video className="h-5 w-5" />
          </Button>
          <Button variant="ghost" size="icon" className="text-primary-foreground hover:bg-primary-foreground/15" type="button">
            <Phone className="h-5 w-5" />
          </Button>
          {canDelete && (
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  className="text-primary-foreground hover:bg-destructive/80 hover:text-white"
                  type="button"
                  disabled={clearMutation.isPending || messages.length === 0}
                  title="Eliminar conversación"
                >
                  <Trash2 className="h-5 w-5" />
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent>
                <AlertDialogHeader>
                  <AlertDialogTitle>¿Eliminar toda la conversación?</AlertDialogTitle>
                  <AlertDialogDescription>
                    Se eliminarán del CRM los {messages.length} mensajes de este hilo (en el celular del cliente
                    no se borran). Esta acción no se puede deshacer.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel>Cancelar</AlertDialogCancel>
                  <AlertDialogAction
                    className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                    onClick={() => clearMutation.mutate()}
                  >
                    Eliminar
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          )}
        </div>
      </div>

      <div
        ref={viewportRef}
        className="min-h-0 flex-1 overflow-y-auto border-x border-border/50 bg-muted/40 p-4 dark:bg-card/30"
      >
        <div className="space-y-2">
          {isLoading ? (
            <div className="space-y-3 py-2">
              <Skeleton className="h-10 w-2/3 rounded-lg" />
              <Skeleton className="ml-auto h-10 w-1/2 rounded-lg" />
              <Skeleton className="h-14 w-3/4 rounded-lg" />
            </div>
          ) : messages.length === 0 ? (
            <p className="text-center text-sm text-muted-foreground py-8">No hay mensajes aún</p>
          ) : (
            messages.map((msg, index) => {
              const showDate =
                index === 0 ||
                format(new Date(msg.timestamp), 'yyyy-MM-dd') !==
                  format(new Date(messages[index - 1].timestamp), 'yyyy-MM-dd')

              return (
                <div key={msg.id}>
                  {showDate && (
                    <div className="flex justify-center my-4">
                      <span className="rounded-full bg-card/90 px-3 py-1 text-xs text-muted-foreground shadow-sm">
                        {format(new Date(msg.timestamp), 'dd MMMM yyyy', { locale: es })}
                      </span>
                    </div>
                  )}
                  <div className={cn('flex', msg.isOutgoing ? 'justify-end' : 'justify-start')}>
                    <div
                      className={cn(
                        'max-w-[80%] px-3 py-2 rounded-lg shadow-sm',
                        msg.isOutgoing
                          ? 'rounded-br-none bg-primary/20 text-foreground dark:bg-primary/25'
                          : 'rounded-bl-none border border-border/60 bg-card text-foreground'
                      )}
                    >
                    {msg.mediaUrl && <MediaPreview url={msg.mediaUrl} />}
                    {msg.content ? (
                      <p className="text-sm whitespace-pre-wrap break-words">{msg.content}</p>
                    ) : msg.templateName ? (
                      <p className="flex items-center gap-1.5 text-sm italic text-muted-foreground">
                        <MessageSquareText className="size-3.5 shrink-0" />
                        Plantilla: {msg.templateName}
                        {msg.templateParams && msg.templateParams.length > 0
                          ? ` (${msg.templateParams.join(', ')})`
                          : ''}
                      </p>
                    ) : null}
                    {msg.isOutgoing && msg.status === 'failed' && msg.errorMessage ? (
                      <p className="text-[11px] text-destructive mt-1 break-words" title={msg.errorMessage}>
                        {msg.errorMessage}
                      </p>
                    ) : null}
                    <div className="flex items-center justify-end gap-1 mt-1">
                        {msg.isOutgoing && msg.automated && (
                          <span className="flex items-center gap-0.5 text-[10px] text-muted-foreground" title="Enviado automáticamente">
                            <Bot className="size-3" />
                            IA ·
                          </span>
                        )}
                        <span className="text-[10px] text-muted-foreground">
                          {format(new Date(msg.timestamp), 'HH:mm')}
                        </span>
                        {getStatusIcon(msg.status, msg.isOutgoing)}
                      </div>
                    </div>
                  </div>
                </div>
              )
            })
          )}
        </div>
      </div>

      {canSendProp && !contactPhone.trim() && (
        <div className="shrink-0 border-t border-border/60 px-4 py-2">
          <label className="text-xs font-medium text-muted-foreground" htmlFor="wa-dest">
            Destino (E.164 o móvil CO)
          </label>
          <Input
            id="wa-dest"
            value={manualTo}
            onChange={(e) => setManualTo(e.target.value)}
            placeholder="+573001234567 o 3001234567"
            className="mt-1"
            disabled={sendMutation.isPending}
          />
        </div>
      )}

      {canSendProp && templates.length > 0 && (
        <div className="shrink-0 border-t border-border/60 bg-muted/30">
          <button
            type="button"
            className="flex w-full items-center gap-2 px-3 py-2 text-left"
            onClick={() => setTemplatePanelOpen((v) => !v)}
            aria-expanded={templatePanelOpen}
          >
            <MessageSquareText className="size-3.5 shrink-0 text-muted-foreground" />
            <span className="min-w-0 flex-1 truncate text-xs font-medium text-muted-foreground">
              {serviceWindowOpen ? 'Enviar plantilla' : 'Iniciar con plantilla (fuera de ventana 24h)'}
            </span>
            <ChevronDown
              className={cn(
                'size-3.5 shrink-0 text-muted-foreground transition-transform',
                templatePanelOpen && 'rotate-180',
              )}
            />
          </button>
          {templatePanelOpen && (
          <div className="flex flex-wrap items-center gap-2 px-3 pb-2">
            <Select value={templateId} onValueChange={handleSelectTemplate}>
              <SelectTrigger className="h-8 flex-1 min-w-[160px] text-xs">
                <SelectValue placeholder="Elegir plantilla…" />
              </SelectTrigger>
              <SelectContent>
                {templates.map((t) => (
                  <SelectItem key={t.id} value={t.id}>
                    {t.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {selectedTemplate?.variableLabels.map((label, i) => (
              <Input
                key={i}
                value={templateVars[i] ?? ''}
                onChange={(e) =>
                  setTemplateVars((vars) => vars.map((v, idx) => (idx === i ? e.target.value : v)))
                }
                placeholder={label}
                className="h-8 flex-1 min-w-[120px] text-xs"
              />
            ))}
            <Button
              size="sm"
              variant="secondary"
              className="h-8 shrink-0"
              disabled={!canSendTemplate || sendTemplateMutation.isPending}
              onClick={() => sendTemplateMutation.mutate()}
            >
              {sendTemplateMutation.isPending ? 'Enviando…' : 'Enviar plantilla'}
            </Button>
          </div>
          )}
        </div>
      )}

      {canSendProp && (
        <div className="flex shrink-0 items-center gap-2 border-t bg-muted/50 p-3">
          <Input
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            placeholder={
              canSend ? 'Escribe un mensaje…' : 'Indica un número válido arriba o en el contacto'
            }
            className="flex-1"
            disabled={!canSend}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                handleSend()
              }
            }}
          />
          <Button
            size="icon"
            type="button"
            disabled={!canSend || !draft.trim()}
            onClick={handleSend}
          >
            <Send className="h-4 w-4" />
          </Button>
        </div>
      )}
    </div>
  )
}
