import { useMemo, useState } from 'react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Spinner } from '@/components/ui/spinner'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { cn, formatRelativeTime } from '@/lib/utils'
import {
  emailQueryKeys,
  fetchEmailCampaignRecipients,
  type EmailCampaign,
  type EmailResult,
  type RecipientFilter,
} from '@/lib/emailMarketingApi'

export const EMAIL_RESULT_LABELS: Record<EmailResult, string> = {
  pending: 'Pendiente',
  sent: 'Enviado',
  delivered: 'Entregado',
  opened: 'Abrió',
  clicked: 'Hizo clic',
  bounced: 'Rebotó',
  complained: 'Marcó spam',
  failed: 'Falló',
  skipped: 'Omitido',
  unsubscribed: 'Se dio de baja',
}

export const EMAIL_RESULT_BADGE: Record<EmailResult, string> = {
  pending: 'bg-muted text-muted-foreground',
  sent: 'bg-sky-500/10 text-sky-700 dark:text-sky-300',
  delivered: 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300',
  opened: 'bg-emerald-600/15 text-emerald-800 dark:text-emerald-200',
  clicked: 'bg-violet-500/15 text-violet-700 dark:text-violet-300',
  bounced: 'bg-destructive/10 text-destructive',
  complained: 'bg-destructive/10 text-destructive',
  failed: 'bg-destructive/10 text-destructive',
  skipped: 'bg-amber-500/10 text-amber-700 dark:text-amber-300',
  unsubscribed: 'bg-amber-500/10 text-amber-700 dark:text-amber-300',
}

const FILTERS: { value: RecipientFilter; label: string }[] = [
  { value: 'all', label: 'Todos' },
  { value: 'delivered', label: 'Entregados' },
  { value: 'opened', label: 'Abrieron' },
  { value: 'clicked', label: 'Hicieron clic' },
  { value: 'unsubscribed', label: 'Bajas' },
  { value: 'problems', label: 'Con problemas' },
]

const PROBLEM_RESULTS: EmailResult[] = ['bounced', 'complained', 'failed', 'skipped']

/** Resultado de una campaña de correo, destinatario por destinatario. */
export function EmailCampaignResultsDialog({
  campaign,
  onOpenChange,
}: {
  campaign: EmailCampaign | null
  onOpenChange: (open: boolean) => void
}) {
  const [filter, setFilter] = useState<RecipientFilter>('all')

  const { data, isLoading, fetchNextPage, hasNextPage, isFetchingNextPage } = useInfiniteQuery({
    queryKey: emailQueryKeys.recipients(campaign?.id ?? '', filter),
    queryFn: ({ pageParam }) => fetchEmailCampaignRecipients(campaign!.id, filter, pageParam),
    initialPageParam: 1,
    getNextPageParam: (last, pages) => (last.hasMore ? pages.length + 1 : undefined),
    enabled: Boolean(campaign),
    refetchInterval: campaign?.status === 'running' ? 15_000 : false,
  })

  const rows = useMemo(() => data?.pages.flatMap((p) => p.rows) ?? [], [data])

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
          <DialogDescription>Asunto: {campaign?.subject}</DialogDescription>
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
                      <p className="truncate text-xs text-muted-foreground">{r.email}</p>
                    </div>
                    <Badge className={cn('shrink-0 border-0', EMAIL_RESULT_BADGE[r.result])}>
                      {EMAIL_RESULT_LABELS[r.result]}
                    </Badge>
                  </div>
                  {r.reason && PROBLEM_RESULTS.includes(r.result) && (
                    <p className="break-words text-xs text-destructive">{r.reason}</p>
                  )}
                  {(r.clickedAt || r.openedAt || r.sentAt) && (
                    <p className="text-[11px] text-muted-foreground">
                      {r.clickedAt
                        ? `Clic ${formatRelativeTime(r.clickedAt)}`
                        : r.openedAt
                          ? `Abrió ${formatRelativeTime(r.openedAt)}`
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
