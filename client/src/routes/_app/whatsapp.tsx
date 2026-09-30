import { useEffect, useMemo, useRef, useState } from 'react'
import { createFileRoute, useSearch } from '@tanstack/react-router'
import { useQuery, useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { z } from 'zod'
import { MessageCircle, Bell, BellOff } from 'lucide-react'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { ConversationList, type InboxScope } from '@/components/inbox/ConversationList'
import { WhatsAppThread, type ThreadMessage } from '@/components/opportunities/WhatsAppThread'
import { WhatsappTemplatesPanel } from '@/components/whatsapp/WhatsappTemplatesPanel'
import { WhatsappCampaignsPanel } from '@/components/whatsapp/WhatsappCampaignsPanel'
import { useAuthStore } from '@/stores/auth'
import { getAuthQueryScope, queryKeys } from '@/lib/queryClient'
import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList } from '@/lib/opportunityApi'
import {
  fetchConversations,
  markConversationRead,
  setConversationAutomation,
  type ConversationRow,
} from '@/lib/whatsappInboxApi'
import { toast } from 'sonner'
import {
  isSoundEnabled,
  setSoundEnabled,
  unlockAudioOnFirstInteraction,
} from '@/lib/notificationSound'

const whatsappSearchSchema = z.object({
  contact: z.string().optional(),
  tab: z.enum(['inbox', 'templates', 'campaigns']).optional(),
})

export const Route = createFileRoute('/_app/whatsapp')({
  validateSearch: whatsappSearchSchema,
  component: WhatsappPage,
})

const THREAD_STATUSES: ThreadMessage['status'][] = ['pending', 'queued', 'sent', 'delivered', 'read', 'failed']

function mapThreadMessages(body: unknown): ThreadMessage[] {
  return jsonApiPrimaryList(body)
    .map((r): ThreadMessage => {
      const a = r.attributes ?? {}
      const dir = String(a.direction ?? 'in')
      const st = String(a.status ?? 'sent')
      return {
        id: String(r.id ?? ''),
        content: String(a.body ?? ''),
        timestamp: String(a.created_at ?? ''),
        isOutgoing: dir === 'out',
        provider: String(a.provider ?? ''),
        status: (THREAD_STATUSES.includes(st as ThreadMessage['status']) ? st : 'sent') as ThreadMessage['status'],
        errorMessage:
          typeof a.error_message === 'string' && a.error_message.trim() ? String(a.error_message) : undefined,
        mediaUrl: typeof a.media_url === 'string' && a.media_url.trim() ? String(a.media_url) : undefined,
        templateName:
          typeof a.template_name === 'string' && a.template_name.trim() ? String(a.template_name) : undefined,
        templateParams: Array.isArray(a.template_params) ? a.template_params.map((p) => String(p)) : undefined,
        automated: a.automated === true,
      }
    })
    .sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime())
}

function WhatsappPage() {
  const search = useSearch({ from: '/_app/whatsapp' })
  const navigate = Route.useNavigate()
  const queryClient = useQueryClient()
  const role = useAuthStore((s) => s.user?.role)
  const currentUserId = useAuthStore((s) => s.user?.id)
  const authScope = getAuthQueryScope()
  const canSeeAll = role !== 'consultant'
  const canSend = role !== 'viewer'
  const canManageTemplates = role === 'admin' || role === 'manager'

  const activeTab =
    (search.tab === 'templates' || search.tab === 'campaigns') && canManageTemplates ? search.tab : 'inbox'

  const [scope, setScope] = useState<InboxScope>(canSeeAll ? 'all' : 'mine')
  const [searchText, setSearchText] = useState('')
  const [soundEnabled, setSoundEnabledState] = useState(() => isSoundEnabled())

  const toggleSound = () => {
    const next = !soundEnabled
    setSoundEnabled(next)
    setSoundEnabledState(next)
    unlockAudioOnFirstInteraction()
  }

  // Bandeja paginada (items:50/página) — con más de 50 conversaciones en un
  // tenant (p. ej. tras una campaña masiva) la carga inicial ya no alcanza
  // a traerlas todas, así que se acumulan páginas con "Cargar más" en vez
  // de perder las conversaciones más antiguas silenciosamente.
  const {
    data: listPages,
    isLoading,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
  } = useInfiniteQuery({
    queryKey: queryKeys.whatsappConversations.list(authScope, { scope }),
    queryFn: ({ pageParam }) => fetchConversations({ scope, page: pageParam }),
    initialPageParam: 1,
    getNextPageParam: (lastPage) => {
      const p = lastPage.pagination
      return p && p.page < p.pages ? p.page + 1 : undefined
    },
    enabled: Boolean(authScope),
    // Los mensajes nuevos refrescan la lista al instante vía AppLayout (stats
    // cada 10 s → invalidate). Este poll es solo de respaldo (p. ej. cambios de
    // dueño o de etapa) y no corre en segundo plano.
    refetchInterval: 60_000,
    refetchOnWindowFocus: true,
  })

  const conversations = useMemo(() => {
    const byContact = new Map<string, ConversationRow>()
    for (const page of listPages?.pages ?? []) {
      for (const c of page.conversations) byContact.set(c.contactId, c)
    }
    return Array.from(byContact.values())
  }, [listPages])

  // El sonido de mensaje nuevo vive en AppLayout (suena en cualquier pantalla).
  const selected = useMemo(
    () => conversations.find((c) => c.contactId === search.contact) ?? null,
    [conversations, search.contact],
  )

  // Auto-selecciona la primera conversación solo en la carga inicial (nunca
  // más después) — si no, al volver a la lista en mobile (botón "atrás",
  // que limpia el contact de la URL) esto reseleccionaba la primera de
  // nuevo al toque y era imposible ver la lista.
  const hasAutoSelectedRef = useRef(false)
  useEffect(() => {
    if (search.contact) hasAutoSelectedRef.current = true
  }, [search.contact])
  useEffect(() => {
    if (!search.contact && conversations.length > 0 && !hasAutoSelectedRef.current) {
      hasAutoSelectedRef.current = true
      void navigate({ search: { ...search, contact: conversations[0].contactId }, replace: true })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search.contact, conversations, navigate])

  const { data: threadMessages, isLoading: threadLoading } = useQuery({
    queryKey: queryKeys.whatsappConversations.messages(selected?.contactId ?? ''),
    queryFn: async () => {
      const response = await api.get('/whatsapp_messages', { params: { contact_id: selected?.contactId } })
      return mapThreadMessages(response.data)
    },
    enabled: Boolean(selected?.contactId),
    // Entrantes nuevos llegan vía AppLayout (invalidate); este poll cubre los
    // cambios de estado de lo enviado (entregado / leído) y solo con la pestaña visible.
    refetchInterval: 5000,
  })

  const markReadMutation = useMutation({
    mutationFn: (contactId: string) => markConversationRead(contactId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.whatsappConversations.all })
    },
  })

  // Pausar / reanudar el asistente en el chat abierto (un asesor toma el control).
  const automationMutation = useMutation({
    mutationFn: (c: ConversationRow) => setConversationAutomation(c.contactId, !c.automationPaused),
    onSuccess: (_data, c) => {
      toast.success(
        c.automationPaused
          ? 'El asistente vuelve a responder en este chat'
          : 'Listo: el asistente ya no responde en este chat, lo atiendes tú',
      )
      void queryClient.invalidateQueries({ queryKey: queryKeys.whatsappConversations.all })
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo cambiar el asistente de este chat')),
  })

  // Con la pestaña oculta, un mensaje que llega a la conversación abierta no
  // se marca leído (nadie lo vio): queda como no leído hasta volver.
  const [pageVisible, setPageVisible] = useState(
    () => typeof document === 'undefined' || document.visibilityState === 'visible',
  )
  useEffect(() => {
    const onVisibility = () => setPageVisible(document.visibilityState === 'visible')
    document.addEventListener('visibilitychange', onVisibility)
    return () => document.removeEventListener('visibilitychange', onVisibility)
  }, [])

  useEffect(() => {
    if (pageVisible && activeTab === 'inbox' && selected && selected.unreadCount > 0) {
      markReadMutation.mutate(selected.contactId)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected?.contactId, selected?.unreadCount, pageVisible, activeTab])

  return (
    <AppPageShell className="h-full min-h-0" contentClassName="flex h-full min-h-0 flex-col gap-2 p-2 sm:gap-4 lg:p-6">
      <PageHeader
        title="WhatsApp"
        description="Bandeja de entrada, plantillas y todo lo relacionado con WhatsApp, en un solo lugar (RFC §6.6)."
      >
        <Button
          size="sm"
          variant="outline"
          className="gap-1.5"
          onClick={toggleSound}
          title={soundEnabled ? 'Desactivar sonido de mensaje nuevo' : 'Activar sonido de mensaje nuevo'}
        >
          {soundEnabled ? <Bell className="size-3.5" /> : <BellOff className="size-3.5" />}
          <span className="hidden sm:inline">{soundEnabled ? 'Sonido activado' : 'Sonido desactivado'}</span>
        </Button>
      </PageHeader>

      <Tabs
        value={activeTab}
        onValueChange={(value) =>
          void navigate({ search: { ...search, tab: value as 'inbox' | 'templates' | 'campaigns' } })
        }
        className="flex min-h-0 flex-1 flex-col"
      >
        <TabsList className={canManageTemplates ? '' : 'hidden'}>
          <TabsTrigger value="inbox">Bandeja de entrada</TabsTrigger>
          {canManageTemplates && <TabsTrigger value="templates">Plantillas</TabsTrigger>}
          {canManageTemplates && <TabsTrigger value="campaigns">Campañas</TabsTrigger>}
        </TabsList>

        <TabsContent value="inbox" className="flex min-h-0 flex-1 flex-col">
          <div className="flex min-h-0 flex-1 overflow-hidden border-0 sm:rounded-lg sm:border">
            <ConversationList
              conversations={conversations}
              isLoading={isLoading}
              activeContactId={selected?.contactId ?? null}
              onSelect={(contactId) => void navigate({ search: { ...search, contact: contactId } })}
              scope={scope}
              onScopeChange={setScope}
              canSeeAll={canSeeAll}
              search={searchText}
              onSearchChange={setSearchText}
              hasMore={Boolean(hasNextPage)}
              isLoadingMore={isFetchingNextPage}
              onLoadMore={() => void fetchNextPage()}
              // Mobile: se ve la lista O el hilo, nunca los dos apretados en la
              // misma pantalla angosta. Desde lg: siempre lado a lado.
              className={selected ? 'hidden lg:flex' : 'flex'}
            />

            <div className={`min-h-0 flex-1 flex-col p-0 sm:p-3 lg:flex ${selected ? 'flex' : 'hidden'}`}>
              {selected ? (
                <WhatsAppThread
                  contactId={selected.contactId}
                  contactName={selected.contactName ?? 'Sin nombre'}
                  contactPhone={selected.contactPhone ?? ''}
                  messages={threadMessages ?? []}
                  isLoading={threadLoading}
                  canSend={canSend}
                  // Admin/manager o el dueño del contacto (el backend exige lo mismo).
                  canDelete={
                    role === 'admin' ||
                    role === 'manager' ||
                    (role === 'consultant' && selected.ownerUserId === String(currentUserId ?? ''))
                  }
                  onDeleted={() => void navigate({ search: { ...search, contact: undefined } })}
                  onBack={() => void navigate({ search: { ...search, contact: undefined } })}
                  automationPaused={selected.automationPaused}
                  onToggleAutomation={canSend ? () => automationMutation.mutate(selected) : undefined}
                />
              ) : (
                <div className="hidden flex-1 flex-col items-center justify-center gap-2 text-muted-foreground lg:flex">
                  <MessageCircle className="size-10" />
                  <p className="text-sm">Selecciona una conversación para ver el hilo</p>
                </div>
              )}
            </div>
          </div>
        </TabsContent>

        {canManageTemplates && (
          <TabsContent value="templates" className="overflow-y-auto">
            <WhatsappTemplatesPanel />
          </TabsContent>
        )}

        {canManageTemplates && (
          <TabsContent value="campaigns" className="overflow-y-auto">
            <WhatsappCampaignsPanel />
          </TabsContent>
        )}
      </Tabs>
    </AppPageShell>
  )
}
