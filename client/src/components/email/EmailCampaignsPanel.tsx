import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, BarChart3, CalendarClock, Copy, Pause, Pencil, Play, Plus, Trash2, X } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { formatRailsError } from '@/lib/api'
import { cn } from '@/lib/utils'
import {
  deleteEmailCampaign,
  emailCampaignAction,
  emailQueryKeys,
  fetchEmailCampaign,
  fetchEmailCampaigns,
  type EmailCampaign,
  type EmailCampaignStatus,
  type EmailResult,
} from '@/lib/emailMarketingApi'
import { EmailCampaignEditor } from './EmailCampaignEditor'
import { EMAIL_RESULT_BADGE, EMAIL_RESULT_LABELS, EmailCampaignResultsDialog } from './EmailCampaignResultsDialog'

const STATUS_LABELS: Record<EmailCampaignStatus, string> = {
  draft: 'Borrador',
  scheduled: 'Programada',
  running: 'Enviando',
  paused: 'Pausada',
  completed: 'Completada',
  canceled: 'Cancelada',
}

const STATUS_VARIANTS: Record<EmailCampaignStatus, 'outline' | 'default' | 'secondary' | 'destructive'> = {
  draft: 'outline',
  scheduled: 'secondary',
  running: 'default',
  paused: 'secondary',
  completed: 'outline',
  canceled: 'destructive',
}

const STAT_ORDER: EmailResult[] = [
  'pending',
  'sent',
  'delivered',
  'opened',
  'clicked',
  'unsubscribed',
  'bounced',
  'complained',
  'failed',
  'skipped',
]

type Action = 'launch' | 'pause' | 'resume' | 'cancel' | 'duplicate'

const ACTION_TOASTS: Record<Action, string> = {
  launch: 'Campaña lanzada',
  pause: 'Campaña pausada',
  resume: 'Campaña reanudada',
  cancel: 'Campaña cancelada',
  duplicate: 'Copia creada como borrador',
}

/** Listado de campañas de correo con sus acciones y resultados. */
export function EmailCampaignsPanel({ senderVerified }: { senderVerified: boolean }) {
  const queryClient = useQueryClient()
  /** undefined = editor cerrado; null = campaña nueva. */
  const [editing, setEditing] = useState<EmailCampaign | null | undefined>(undefined)
  const [results, setResults] = useState<EmailCampaign | null>(null)

  const { data: campaigns = [], isLoading } = useQuery({
    queryKey: emailQueryKeys.campaigns(),
    queryFn: fetchEmailCampaigns,
    refetchInterval: (q) => (q.state.data?.some((c) => c.status === 'running') ? 15_000 : 60_000),
  })

  const invalidate = () => queryClient.invalidateQueries({ queryKey: emailQueryKeys.campaigns() })

  const actionMutation = useMutation({
    mutationFn: ({ id, action }: { id: string; action: Action }) => emailCampaignAction(id, action),
    onSuccess: async (campaign, { action }) => {
      toast.success(ACTION_TOASTS[action])
      void invalidate()
      if (action === 'duplicate') setEditing(await fetchEmailCampaign(campaign.id))
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo completar la acción')),
  })

  const deleteMutation = useMutation({
    mutationFn: deleteEmailCampaign,
    onSuccess: () => {
      toast.success('Borrador eliminado')
      void invalidate()
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo eliminar el borrador')),
  })

  // El listado no trae el HTML/diseño: se pide el detalle al abrir el editor.
  const openEditor = async (c: EmailCampaign) => {
    try {
      setEditing(await fetchEmailCampaign(c.id))
    } catch (err) {
      toast.error(formatRailsError(err, 'No se pudo abrir la campaña'))
    }
  }

  const busy = actionMutation.isPending || deleteMutation.isPending

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div>
          <h2 className="text-lg font-medium">Campañas de correo</h2>
          <p className="hidden text-sm text-muted-foreground sm:block">
            Salen desde el dominio de tu empresa. Quien se da de baja, rebota o marca spam no vuelve a recibirlas.
          </p>
        </div>
        <Button size="sm" onClick={() => setEditing(null)}>
          <Plus className="mr-2 h-4 w-4" />
          Nueva campaña
        </Button>
      </div>

      {!senderVerified && (
        <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-4 text-sm text-amber-800 dark:text-amber-200">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          Falta verificar el dominio desde el que salen los correos (pestaña «Remitente»). Puedes preparar borradores
          mientras tanto.
        </div>
      )}

      {isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-16 w-full rounded-lg" />
          ))}
        </div>
      ) : campaigns.length === 0 ? (
        <div className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
          No hay campañas de correo todavía.
        </div>
      ) : (
        <div className="space-y-2">
          {campaigns.map((c) => (
            <CampaignRow
              key={c.id}
              campaign={c}
              busy={busy}
              onEdit={() => void openEditor(c)}
              onAction={(action) => actionMutation.mutate({ id: c.id, action })}
              onDelete={() => deleteMutation.mutate(c.id)}
              onShowResults={() => setResults(c)}
            />
          ))}
        </div>
      )}

      {editing !== undefined && (
        <EmailCampaignEditor
          key={editing?.id ?? 'new'}
          campaign={editing}
          senderVerified={senderVerified}
          onClose={() => {
            setEditing(undefined)
            void invalidate()
          }}
        />
      )}

      <EmailCampaignResultsDialog campaign={results} onOpenChange={(open) => { if (!open) setResults(null) }} />
    </div>
  )
}

function CampaignRow({
  campaign,
  busy,
  onEdit,
  onAction,
  onDelete,
  onShowResults,
}: {
  campaign: EmailCampaign
  busy: boolean
  onEdit: () => void
  onAction: (action: Action) => void
  onDelete: () => void
  onShowResults: () => void
}) {
  const isDraft = campaign.status === 'draft'
  const stats = campaign.resultStats
  const when =
    campaign.status === 'scheduled' && campaign.scheduledAt
      ? `Programada para el ${new Date(campaign.scheduledAt).toLocaleString('es-CO')}`
      : campaign.startedAt
        ? `Iniciada el ${new Date(campaign.startedAt).toLocaleString('es-CO')}`
        : `Creada el ${new Date(campaign.createdAt).toLocaleDateString('es-CO')}`

  return (
    <div className="space-y-3 rounded-lg border bg-card p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <p className="font-medium">{campaign.name}</p>
            <Badge variant={STATUS_VARIANTS[campaign.status]}>{STATUS_LABELS[campaign.status]}</Badge>
          </div>
          <p className="truncate text-xs text-muted-foreground">
            {campaign.subject ? `Asunto: ${campaign.subject}` : 'Sin asunto'} · {when}
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2 sm:shrink-0 sm:justify-end">
          {isDraft && (
            <Button size="sm" onClick={onEdit} disabled={busy}>
              <Pencil className="mr-1.5 h-3.5 w-3.5" />
              Editar y lanzar
            </Button>
          )}
          {!isDraft && campaign.status !== 'scheduled' && (
            <Button size="sm" variant="outline" onClick={onShowResults}>
              <BarChart3 className="mr-1.5 h-3.5 w-3.5" />
              Ver resultados
            </Button>
          )}
          {campaign.status === 'running' && (
            <Button size="sm" variant="outline" onClick={() => onAction('pause')} disabled={busy}>
              <Pause className="mr-1.5 h-3.5 w-3.5" />
              Pausar
            </Button>
          )}
          {campaign.status === 'paused' && (
            <Button size="sm" onClick={() => onAction('resume')} disabled={busy}>
              <Play className="mr-1.5 h-3.5 w-3.5" />
              Reanudar
            </Button>
          )}
          {(campaign.status === 'running' || campaign.status === 'paused' || campaign.status === 'scheduled') && (
            <Button
              size="sm"
              variant="ghost"
              className="text-destructive"
              onClick={() => onAction('cancel')}
              disabled={busy}
            >
              <X className="mr-1.5 h-3.5 w-3.5" />
              Cancelar
            </Button>
          )}
          <Button
            size="sm"
            variant="ghost"
            onClick={() => onAction('duplicate')}
            disabled={busy}
            title="Crear una copia en borrador para editarla y volver a lanzarla"
          >
            <Copy className="mr-1.5 h-3.5 w-3.5" />
            Duplicar
          </Button>
          {isDraft && (
            <Button
              size="sm"
              variant="ghost"
              className="text-destructive"
              onClick={onDelete}
              disabled={busy}
              aria-label="Eliminar borrador"
            >
              <Trash2 className="h-3.5 w-3.5" />
            </Button>
          )}
        </div>
      </div>

      {campaign.status === 'scheduled' && (
        <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <CalendarClock className="size-3.5" />
          La audiencia se calcula en el momento del envío.
        </p>
      )}

      {stats && (
        <div className="flex flex-wrap gap-1.5 text-xs">
          <span className="rounded-md bg-muted px-2 py-1 font-medium tabular-nums">Total {stats.total}</span>
          {STAT_ORDER.filter((k) => stats[k] > 0).map((k) => (
            <span key={k} className={cn('rounded-md px-2 py-1 font-medium tabular-nums', EMAIL_RESULT_BADGE[k])}>
              {EMAIL_RESULT_LABELS[k]} {stats[k]}
            </span>
          ))}
        </div>
      )}
    </div>
  )
}
