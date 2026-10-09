import { createFileRoute } from '@tanstack/react-router'
import { requireSettingsRole } from '@/lib/authGuards'
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Trash2, Edit, Globe, MessageCircle, BarChart2, Search, Hand, Users } from 'lucide-react'
import { isAxiosError } from 'axios'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Label } from '@/components/ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'
import type { LeadSource, LeadSourceKind } from '@/types'
import api from '@/lib/api'
import { jsonApiPrimaryList } from '@/lib/opportunityApi'
import { queryKeys } from '@/lib/queryClient'
import { useAuthStore } from '@/stores/auth'

export const Route = createFileRoute('/_app/settings/lead-sources')({
  beforeLoad: () => requireSettingsRole('admin', 'manager'),
  component: LeadSourcesSettingsPage,
})

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const KIND_META: Record<LeadSourceKind, { label: string; icon: React.ComponentType<{ className?: string }>; color: string }> = {
  web:      { label: 'Web / Landing',  icon: Globe,          color: 'bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300' },
  whatsapp: { label: 'WhatsApp',       icon: MessageCircle,  color: 'bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300' },
  meta:     { label: 'Meta Ads',       icon: BarChart2,      color: 'bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300' },
  google:   { label: 'Google Ads',     icon: Search,         color: 'bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300' },
  manual:   { label: 'Manual',         icon: Hand,           color: 'bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300' },
  referral: { label: 'Referido',       icon: Users,          color: 'bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300' },
}

const KINDS = Object.keys(KIND_META) as LeadSourceKind[]

function apiMessage(err: unknown): string {
  if (isAxiosError(err)) {
    const d = err.response?.data
    if (d && typeof d === 'object') {
      const msg = (d as { message?: string }).message
      if (typeof msg === 'string' && msg) return msg
    }
    return err.message || 'Error en la petición'
  }
  return err instanceof Error ? err.message : 'Error desconocido'
}

function mapLeadSource(r: { id?: string; attributes?: Record<string, unknown> }): LeadSource {
  const a = r.attributes ?? {}
  return {
    id:                 String(r.id ?? ''),
    name:               String(a.name ?? ''),
    kind:               (a.kind as LeadSourceKind) ?? 'manual',
    active:             Boolean(a.active ?? true),
    opportunities_count: Number(a.opportunities_count ?? 0),
    created_at:         String(a.created_at ?? ''),
  }
}

// ---------------------------------------------------------------------------
// Página
// ---------------------------------------------------------------------------
function LeadSourcesSettingsPage() {
  const queryClient = useQueryClient()
  const isAdmin   = useAuthStore((s) => s.isAdmin())
  const canManage = useAuthStore((s) => s.isAdmin() || s.isManager())
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editingSource, setEditingSource] = useState<LeadSource | null>(null)
  const [formName, setFormName] = useState('')
  const [formKind, setFormKind] = useState<LeadSourceKind>('web')
  const [confirmDeleteSource, setConfirmDeleteSource] = useState<LeadSource | null>(null)

  const { data: sources = [], isLoading } = useQuery({
    queryKey: queryKeys.leadSources.all,
    queryFn: async () => {
      const res = await api.get('/lead_sources')
      return jsonApiPrimaryList(res.data).filter((r) => r.id).map(mapLeadSource)
    },
  })

  const invalidate = () => queryClient.invalidateQueries({ queryKey: queryKeys.leadSources.all })

  const saveMutation = useMutation({
    mutationFn: async (body: { name: string; kind: LeadSourceKind }) => {
      if (editingSource) {
        await api.patch(`/lead_sources/${editingSource.id}`, { lead_source: body })
      } else {
        await api.post('/lead_sources', { lead_source: { ...body, active: true } })
      }
    },
    onSuccess: () => {
      invalidate()
      toast.success(editingSource ? 'Fuente actualizada' : 'Fuente creada')
      closeDialog()
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const toggleActiveMutation = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }) => {
      await api.patch(`/lead_sources/${id}`, { lead_source: { active } })
    },
    onSuccess: () => invalidate(),
    onError: (err) => toast.error(apiMessage(err)),
  })

  const deleteMutation = useMutation({
    mutationFn: async (id: string) => {
      await api.delete(`/lead_sources/${id}`)
    },
    onSuccess: () => {
      invalidate()
      toast.success('Fuente eliminada')
      setConfirmDeleteSource(null)
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const openCreate = () => {
    setEditingSource(null)
    setFormName('')
    setFormKind('web')
    setDialogOpen(true)
  }

  const openEdit = (source: LeadSource) => {
    setEditingSource(source)
    setFormName(source.name)
    setFormKind(source.kind)
    setDialogOpen(true)
  }

  const closeDialog = () => {
    setDialogOpen(false)
    setEditingSource(null)
    setFormName('')
    setFormKind('web')
  }

  const grouped = KINDS.map((kind) => ({
    kind,
    meta: KIND_META[kind],
    items: sources.filter((s) => s.kind === kind),
  })).filter((g) => g.items.length > 0)

  const ungrouped = sources.filter((s) => !KINDS.includes(s.kind))

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div>
          <h2 className="text-lg font-medium">Fuentes de Lead</h2>
          <p className="hidden text-sm text-muted-foreground sm:block">
            Define los orígenes de tus oportunidades. Se asignan al registrar o importar leads.
          </p>
        </div>
        {canManage && (
          <Button size="sm" onClick={openCreate}>
            <Plus className="mr-2 h-4 w-4" />
            Nueva fuente
          </Button>
        )}
      </div>

      {/* Lista */}
      {isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-14 w-full rounded-lg" />
          ))}
        </div>
      ) : sources.length === 0 ? (
        <div className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
          No hay fuentes configuradas. Crea la primera para poder asignar origen a tus leads.
        </div>
      ) : (
        <div className="space-y-6">
          {grouped.map(({ kind, meta, items }) => {
            const Icon = meta.icon
            return (
              <div key={kind} className="space-y-2">
                <div className="flex items-center gap-2">
                  <Icon className="h-4 w-4 text-muted-foreground" />
                  <span className="text-sm font-medium text-muted-foreground">{meta.label}</span>
                </div>
                <div className="space-y-1">
                  {items.map((source) => (
                    <SourceRow
                      key={source.id}
                      source={source}
                      meta={meta}
                      canManage={canManage}
                      canDelete={isAdmin}
                      onEdit={() => openEdit(source)}
                      onToggle={(active) => toggleActiveMutation.mutate({ id: source.id, active })}
                      onDelete={() => setConfirmDeleteSource(source)}
                    />
                  ))}
                </div>
              </div>
            )
          })}
          {ungrouped.length > 0 && (
            <div className="space-y-1">
              {ungrouped.map((source) => (
                <SourceRow
                  key={source.id}
                  source={source}
                  meta={KIND_META.manual}
                  canManage={canManage}
                  canDelete={isAdmin}
                  onEdit={() => openEdit(source)}
                  onToggle={(active) => toggleActiveMutation.mutate({ id: source.id, active })}
                  onDelete={() => setConfirmDeleteSource(source)}
                />
              ))}
            </div>
          )}
        </div>
      )}

      {/* AlertDialog: eliminar fuente */}
      <AlertDialog open={!!confirmDeleteSource} onOpenChange={(open) => { if (!open) setConfirmDeleteSource(null) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar fuente de lead?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará «{confirmDeleteSource?.name}». Las oportunidades existentes perderán su fuente asignada. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90 text-destructive-foreground"
              onClick={() => confirmDeleteSource && deleteMutation.mutate(confirmDeleteSource.id)}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Dialog crear/editar */}
      <Dialog open={dialogOpen} onOpenChange={(open) => { if (!open) closeDialog() }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{editingSource ? 'Editar fuente' : 'Nueva fuente de lead'}</DialogTitle>
            <DialogDescription>
              {editingSource
                ? 'Cambia el nombre o el canal de esta fuente.'
                : 'Define un nombre descriptivo y el canal de origen.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="sourceName">Nombre</Label>
              <Input
                id="sourceName"
                value={formName}
                onChange={(e) => setFormName(e.target.value)}
                placeholder="Ej: Meta Ads — Campaña Black Friday"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="sourceKind">Canal</Label>
              <Select value={formKind} onValueChange={(v) => setFormKind(v as LeadSourceKind)}>
                <SelectTrigger id="sourceKind">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {KINDS.map((k) => {
                    const KIcon = KIND_META[k].icon
                    return (
                      <SelectItem key={k} value={k}>
                        <span className="flex items-center gap-2">
                          <KIcon className="h-4 w-4" />
                          {KIND_META[k].label}
                        </span>
                      </SelectItem>
                    )
                  })}
                </SelectContent>
              </Select>
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={closeDialog}>
              Cancelar
            </Button>
            <Button
              onClick={() => saveMutation.mutate({ name: formName.trim(), kind: formKind })}
              disabled={!formName.trim() || saveMutation.isPending}
            >
              {saveMutation.isPending && <Spinner className="mr-2" />}
              {editingSource ? 'Guardar' : 'Crear'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Fila de fuente
// ---------------------------------------------------------------------------
type SourceRowProps = {
  source: LeadSource
  meta: { label: string; color: string }
  canManage: boolean
  canDelete: boolean
  onEdit: () => void
  onToggle: (active: boolean) => void
  onDelete: () => void
}

function SourceRow({ source, meta, canManage, canDelete, onEdit, onToggle, onDelete }: SourceRowProps) {
  return (
    <div className="group flex items-center justify-between rounded-lg border bg-card px-4 py-3 transition-colors hover:border-border">
      <div className="flex items-center gap-3 min-w-0">
        <Badge className={`shrink-0 text-xs font-normal ${meta.color}`} variant="outline">
          {meta.label}
        </Badge>
        <span className={`text-sm truncate ${!source.active ? 'text-muted-foreground line-through' : ''}`}>
          {source.name}
        </span>
        {source.opportunities_count > 0 && (
          <span className="shrink-0 text-xs text-muted-foreground">
            {source.opportunities_count} {source.opportunities_count === 1 ? 'oportunidad' : 'oportunidades'}
          </span>
        )}
      </div>

      <div className="flex items-center gap-3 shrink-0 ml-4">
        {canManage && (
          <Switch
            checked={source.active}
            onCheckedChange={onToggle}
            aria-label={source.active ? 'Desactivar fuente' : 'Activar fuente'}
          />
        )}
        {canManage && (
          <div className="flex items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100">
            <Button variant="ghost" size="icon" className="h-7 w-7" onClick={onEdit}>
              <Edit className="h-3.5 w-3.5" />
            </Button>
            {canDelete && (
              <Button
                variant="ghost"
                size="icon"
                className="h-7 w-7 text-destructive hover:text-destructive"
                onClick={onDelete}
              >
                <Trash2 className="h-3.5 w-3.5" />
              </Button>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
