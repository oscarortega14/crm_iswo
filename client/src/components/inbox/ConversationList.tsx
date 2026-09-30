import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import { useState } from 'react'
import { Search, Inbox } from 'lucide-react'
import { ConversationListItem } from './ConversationListItem'
import type { ConversationRow } from '@/lib/whatsappInboxApi'
import { cn } from '@/lib/utils'

export type InboxScope = 'mine' | 'unassigned' | 'all'

export function ConversationList({
  conversations,
  isLoading,
  activeContactId,
  onSelect,
  scope,
  onScopeChange,
  canSeeAll,
  search,
  onSearchChange,
  hasMore = false,
  isLoadingMore = false,
  onLoadMore,
  className,
}: {
  conversations: ConversationRow[]
  isLoading: boolean
  activeContactId: string | null
  onSelect: (contactId: string) => void
  scope: InboxScope
  onScopeChange: (scope: InboxScope) => void
  canSeeAll: boolean
  search: string
  onSearchChange: (value: string) => void
  /** Hay más conversaciones en el servidor que no se cargaron todavía
   * (más de una página) — ver /whatsapp, que pagina con useInfiniteQuery. */
  hasMore?: boolean
  isLoadingMore?: boolean
  onLoadMore?: () => void
  /** Controla si el panel se muestra en mobile — en /whatsapp se oculta
   * (`hidden lg:flex`) cuando hay una conversación abierta, para que en
   * pantallas chicas se vea el hilo de a uno por vez, no los dos apretados. */
  className?: string
}) {
  const [filter, setFilter] = useState<'all' | 'unread' | 'awaiting'>('all')
  const unreadOnly = filter === 'unread'
  const unreadTotal = conversations.filter((c) => c.unreadCount > 0).length
  const awaitingTotal = conversations.filter((c) => c.awaitingReply).length

  const q = search.trim().toLowerCase()
  const filtered = conversations.filter((c) => {
    // La conversación abierta se mantiene visible aunque se acabe de marcar
    // como leída — si no, desaparecería del filtro "No leídos" al abrirla.
    if (unreadOnly && c.unreadCount === 0 && c.contactId !== activeContactId) return false
    if (filter === 'awaiting' && !c.awaitingReply && c.contactId !== activeContactId) return false
    if (!q) return true
    return (
      c.contactName?.toLowerCase().includes(q) ||
      c.contactPhone?.toLowerCase().includes(q) ||
      c.lastMessageBody?.toLowerCase().includes(q)
    )
  })

  return (
    <div className={cn('flex h-full min-h-0 w-full max-w-[320px] shrink-0 flex-col border-r', className)}>
      <div className="shrink-0 space-y-3 border-b p-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
            placeholder="Buscar conversación..."
            className="h-8 pl-8 text-sm"
          />
        </div>
        <Tabs value={scope} onValueChange={(v) => onScopeChange(v as InboxScope)}>
          <TabsList className="grid w-full grid-cols-3">
            <TabsTrigger value="mine" className="text-xs">Mías</TabsTrigger>
            <TabsTrigger value="unassigned" className="text-xs">Sin asignar</TabsTrigger>
            <TabsTrigger value="all" disabled={!canSeeAll} className="text-xs">Todas</TabsTrigger>
          </TabsList>
        </Tabs>
        <div className="flex gap-1.5" role="group" aria-label="Filtrar por estado de lectura">
          <Button
            size="sm"
            variant={filter === 'all' ? 'secondary' : 'outline'}
            className="h-7 flex-1 px-2 text-xs"
            aria-pressed={filter === 'all'}
            onClick={() => setFilter('all')}
          >
            Todas
          </Button>
          <Button
            size="sm"
            variant={unreadOnly ? 'secondary' : 'outline'}
            className="h-7 flex-1 gap-1.5 px-2 text-xs"
            aria-pressed={unreadOnly}
            onClick={() => setFilter('unread')}
          >
            No leídas
            {unreadTotal > 0 && (
              <span className="rounded-full bg-primary px-1.5 text-[10px] leading-4 text-primary-foreground">
                {unreadTotal}
              </span>
            )}
          </Button>
          <Button
            size="sm"
            variant={filter === 'awaiting' ? 'secondary' : 'outline'}
            className="h-7 flex-1 gap-1.5 px-2 text-xs"
            aria-pressed={filter === 'awaiting'}
            onClick={() => setFilter('awaiting')}
            title="Dijeron «Sí» y todavía nadie del equipo les ha escrito"
          >
            Autorizaron
            {awaitingTotal > 0 && (
              <span className="rounded-full bg-emerald-600 px-1.5 text-[10px] leading-4 text-white">
                {awaitingTotal}
              </span>
            )}
          </Button>
        </div>
      </div>

      <ScrollArea className="min-h-0 flex-1">
        {isLoading ? (
          <div className="space-y-3 p-3">
            {Array.from({ length: 5 }).map((_, i) => (
              <div key={i} className="flex items-center gap-3">
                <Skeleton className="size-9 rounded-full" />
                <div className="flex-1 space-y-1.5">
                  <Skeleton className="h-3.5 w-2/3" />
                  <Skeleton className="h-3 w-full" />
                </div>
              </div>
            ))}
          </div>
        ) : filtered.length === 0 ? (
          <div className="flex flex-col items-center gap-2 px-4 py-12 text-center text-muted-foreground">
            <Inbox className="size-8" />
            <p className="text-sm">
              {unreadOnly
                ? 'No hay conversaciones sin leer'
                : filter === 'awaiting'
                  ? 'Nadie está esperando respuesta después de autorizar'
                  : scope === 'unassigned'
                  ? 'No hay leads sin asignar'
                  : 'No hay conversaciones'}
            </p>
          </div>
        ) : (
          <>
            {filtered.map((c) => (
              <ConversationListItem
                key={c.contactId}
                conversation={c}
                active={c.contactId === activeContactId}
                onClick={() => onSelect(c.contactId)}
              />
            ))}
            {hasMore && (
              <div className="p-3">
                <Button
                  variant="outline"
                  size="sm"
                  className="w-full"
                  disabled={isLoadingMore}
                  onClick={onLoadMore}
                >
                  {isLoadingMore ? 'Cargando…' : 'Cargar más conversaciones'}
                </Button>
              </div>
            )}
          </>
        )}
      </ScrollArea>
    </div>
  )
}
