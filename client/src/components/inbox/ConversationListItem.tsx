import { Badge } from '@/components/ui/badge'
import { cn, formatRelativeTime } from '@/lib/utils'
import { useAuthStore } from '@/stores/auth'
import { ClaimLeadButton } from './ClaimLeadButton'
import type { ConversationRow } from '@/lib/whatsappInboxApi'

function initials(name: string | null): string {
  const trimmed = (name ?? '').trim()
  if (!trimmed) return '?'
  const parts = trimmed.split(/\s+/)
  return (parts[0]?.[0] ?? '').concat(parts[1]?.[0] ?? '').toUpperCase() || trimmed[0]!.toUpperCase()
}

export function ConversationListItem({
  conversation,
  active,
  onClick,
}: {
  conversation: ConversationRow
  active: boolean
  onClick: () => void
}) {
  const role = useAuthStore((s) => s.user?.role)
  const canClaim = role != null && role !== 'viewer' && conversation.bucket === 'unassigned'
  const name = conversation.contactName?.trim() || conversation.contactPhone || 'Sin nombre'
  const preview = conversation.lastMessageDirection === 'out' ? `Tú: ${conversation.lastMessageBody ?? ''}` : conversation.lastMessageBody ?? ''
  const unread = conversation.unreadCount > 0

  return (
    // div en vez de <button>: contiene el botón "Tomar lead" y anidar
    // <button> dentro de <button> es HTML inválido.
    <div
      role="button"
      tabIndex={0}
      onClick={onClick}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onClick()
        }
      }}
      aria-label={unread ? `${name}, ${conversation.unreadCount} mensaje(s) sin leer` : name}
      className={cn(
        'relative flex w-full cursor-pointer items-start gap-3 border-b px-3 py-3 text-left transition-colors hover:bg-muted/60',
        unread && !active && 'bg-primary/5',
        active && 'bg-muted',
      )}
    >
      {/* Barra lateral: distingue no leídos de un vistazo aunque la lista sea larga. */}
      {unread && <span aria-hidden className="absolute inset-y-0 left-0 w-1 bg-primary" />}
      <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-medium text-primary">
        {initials(conversation.contactName)}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center justify-between gap-2">
          <p className={cn('truncate text-sm text-foreground', unread ? 'font-semibold' : 'font-medium')}>{name}</p>
          <span className={cn('shrink-0 text-[11px]', unread ? 'font-semibold text-primary' : 'text-muted-foreground')}>
            {formatRelativeTime(conversation.lastMessageAt)}
          </span>
        </div>
        <div className="mt-0.5 flex items-center justify-between gap-2">
          <p className={cn('truncate text-xs', unread ? 'font-medium text-foreground' : 'text-muted-foreground')}>
            {preview || 'Sin mensajes'}
          </p>
          {unread && (
            <Badge className="h-5 shrink-0 rounded-full px-1.5 text-[10px]">{conversation.unreadCount}</Badge>
          )}
        </div>
        <div className="mt-1 flex flex-wrap items-center gap-1">
          {conversation.bucket === 'unassigned' && (
            <Badge variant="outline" className="h-4 px-1.5 text-[10px] text-amber-600 border-amber-300">
              Sin asignar
            </Badge>
          )}
          {conversation.opportunityStage && (
            <Badge variant="secondary" className="h-4 px-1.5 text-[10px]">
              {conversation.opportunityStage}
            </Badge>
          )}
        </div>
        {canClaim && (
          <div className="mt-2">
            <ClaimLeadButton contactId={conversation.contactId} />
          </div>
        )}
      </div>
    </div>
  )
}
