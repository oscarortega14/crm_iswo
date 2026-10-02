import { useMemo, useState } from 'react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Spinner } from '@/components/ui/spinner'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { cn, formatRelativeTime } from '@/lib/utils'
import {
  fetchCampaignRecipients,
  type DeliveryResult,
  type WhatsappCampaign,
} from '@/lib/whatsappCampaignsApi'

export const DELIVERY_LABELS: Record<DeliveryResult, string> = {
  pending: 'Pendiente',
  sent: 'Enviado',
  delivered: 'Entregado',
  read: 'Leído',
  failed: 'Falló',
  skipped: 'Omitido',
}

export const DELIVERY_BADGE: Record<DeliveryResult, string> = {
  pending: 'bg-muted text-muted-foreground',
  sent: 'bg-sky-500/10 text-sky-700 dark:text-sky-300',
  delivered: 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300',
  read: 'bg-emerald-600/15 text-emerald-800 dark:text-emerald-200',
  failed: 'bg-destructive/10 text-destructive',
  skipped: 'bg-amber-500/10 text-amber-700 dark:text-amber-300',
}

type Filter = 'all' | 'failed' | 'skipped' | 'ok'

const FILTERS: { value: Filter; label: string }[] = [
  { value: 'all', label: 'Todos' },
  { value: 'failed', label: 'Fallidos' },
  { value: 'skipped', label: 'Omitidos' },
  { value: 'ok', label: 'Entregados / leídos' },
]

/**
 * Resultado de una campaña destinatario por destinatario: qué le llegó a quién
 * (según Meta) y por qué falló u omitió cada uno.
 */
export function WhatsappCampaignDetailDialog({
  campaign,
  onOpenChange,
}: {
  campaign: WhatsappCampaign | null
  onOpenChange: (open: boolean) => void
}) {
  const [filter, setFilter] = useState<Filter>('all')

  const { data, isLoading, fetchNextPage, hasNextPage, isFetchingNextPage } = useInfiniteQuery({
    queryKey: ['whatsappCampaigns', 'recipients', campaign?.id],
    queryFn: ({ pageParam }) => fetchCampaignRecipients(campaign!.id, pageParam),
    initialPageParam: 1,
    getNextPageParam: (last, pages) => (last.hasMore ? pages.length + 1 : undefined),
    enabled: Boolean(campaign),
    refetchInterval: campaign?.status === 'running' ? 15_000 : false,
  })

  const rows = useMemo(() => {
    const all = data?.pages.flatMap((p) => p.rows) ?? []
    if (filter === 'all') return all
    if (filter === 'ok') return all.filter((r) => r.result === 'delivered' || r.result === 'read')
    return all.filter((r) => r.result === filter)
  }, [data, filter])

  return (
    <Dialog
      open={campaign != null}
      onOpenChange={(open) => {
        if (!open) setFilter('all')
        onOpenChange(open)
      }}
    >
      <DialogContent className="flex max-h-[85vh] flex-col sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{campaign?.name}</DialogTitle>
          <DialogDescription>
            Resultado real de cada envío según WhatsApp. Plantilla: {campaign?.whatsappTemplateName}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-wrap gap-1.5">
          {FILTERS.map((f) => (
            <Button
              key={f.value}
              size="sm"
              variant={filter === f.value ? 'default' : 'outline'}
              className="h-7 text-xs"
              onClick={() => setFilter(f.value)}
            >
              {f.label}
            </Button>
          ))}
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto rounded-md border">
          {isLoading ? (
            <div className="space-y-2 p-3">
              {Array.from({ length: 4 }).map((_, i) => (
                <Skeleton key={i} className="h-12 w-full" />
              ))}
            </div>
          ) : rows.length === 0 ? (
            <p className="p-8 text-center text-sm text-muted-foreground">
              {filter === 'all' ? 'Esta campaña no tiene destinatarios.' : 'Nadie en este grupo.'}
            </p>
          ) : (
            <ul className="divide-y">
              {rows.map((r) => (
                <li key={r.id} className="grid gap-1 px-3 py-2.5 text-sm">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="truncate font-medium">{r.contactName}</p>
                      {r.toNumber && <p className="text-xs text-muted-foreground">{r.toNumber}</p>}
                    </div>
                    <Badge className={cn('shrink-0 border-0', DELIVERY_BADGE[r.result])}>
                      {DELIVERY_LABELS[r.result]}
                    </Badge>
                  </div>
                  {r.reason && (r.result === 'failed' || r.result === 'skipped') && (
                    <p
                      className={cn(
                        'break-words text-xs',
                        r.result === 'failed' ? 'text-destructive' : 'text-amber-700 dark:text-amber-300',
                      )}
                    >
                      {r.reason}
                    </p>
                  )}
                  {(r.readAt || r.deliveredAt || r.sentAt) && (
                    <p className="text-[11px] text-muted-foreground">
                      {r.readAt
                        ? `Leído ${formatRelativeTime(r.readAt)}`
                        : r.deliveredAt
                          ? `Entregado ${formatRelativeTime(r.deliveredAt)}`
                          : `Enviado ${formatRelativeTime(r.sentAt!)}`}
                    </p>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>

        {hasNextPage && (
          <Button variant="outline" size="sm" onClick={() => void fetchNextPage()} disabled={isFetchingNextPage}>
            {isFetchingNextPage && <Spinner className="mr-2" />}
            Cargar más
          </Button>
        )}
      </DialogContent>
    </Dialog>
  )
}
