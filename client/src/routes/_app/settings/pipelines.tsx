import { createFileRoute } from '@tanstack/react-router'
import { requireSettingsRole } from '@/lib/authGuards'
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  DndContext,
  closestCenter,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core'
import {
  SortableContext,
  horizontalListSortingStrategy,
  useSortable,
  arrayMove,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import {
  Plus,
  MoreHorizontal,
  GripVertical,
  Edit,
  Trash2,
  Check,
  Star,
  Power,
  PowerOff,
  Zap,
} from 'lucide-react'
import { isAxiosError } from 'axios'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import { Spinner } from '@/components/ui/spinner'
import { Checkbox } from '@/components/ui/checkbox'
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
} from '@/components/ui/alert-dialog'
import { toast } from 'sonner'
import type { Pipeline, PipelineStage, StageAutoTrigger } from '@/types'
import { cn } from '@/lib/utils'
import { STAGE_AUTO_TRIGGER_LABELS, isStageAutoTrigger } from '@/lib/opportunityVisuals'
import api from '@/lib/api'
import { queryKeys } from '@/lib/queryClient'
import { jsonApiPrimaryList, mapPipelineResource } from '@/lib/opportunityApi'

export const Route = createFileRoute('/_app/settings/pipelines')({
  beforeLoad: () => requireSettingsRole('admin'),
  component: PipelinesSettingsPage,
})

function apiMessage(err: unknown): string {
  if (isAxiosError(err)) {
    const d = err.response?.data
    if (d && typeof d === 'object') {
      const details = (d as { details?: Record<string, string[] | string> }).details
      if (details && typeof details === 'object') {
        const parts: string[] = []
        for (const v of Object.values(details)) {
          if (Array.isArray(v)) parts.push(...v.filter((x) => typeof x === 'string'))
          else if (typeof v === 'string') parts.push(v)
        }
        if (parts.length) return parts.join('. ')
      }
      const msg = (d as { message?: string }).message
      if (typeof msg === 'string' && msg) return msg
    }
    return err.message || 'Error en la petición'
  }
  return err instanceof Error ? err.message : 'Error desconocido'
}

function maxStagePosition(stages: PipelineStage[]): number {
  if (!stages.length) return -1
  let max = -1
  for (const s of stages) {
    const p = Number(s.position)
    const n = Number.isFinite(p) ? Math.floor(p) : Number.NaN
    if (!Number.isFinite(n)) continue
    if (n > max) max = n
  }
  return max
}

// ---------------------------------------------------------------------------
// SortableStage — pill individual con handle de arrastre
// ---------------------------------------------------------------------------
type SortableStageProps = {
  stage: PipelineStage
  pipeline: Pipeline
  onEdit: (pipeline: Pipeline, stage: PipelineStage) => void
  onDelete: (pipelineId: string, stageId: string, stageName: string) => void
}

function SortableStage({ stage, pipeline, onEdit, onDelete }: SortableStageProps) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: stage.id })

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.5 : 1,
    zIndex: isDragging ? 10 : undefined,
  }

  return (
    <div
      ref={setNodeRef}
      style={style}
      className="group flex items-center gap-2 rounded-md border bg-background px-3 py-1.5 transition-colors hover:border-primary/50"
    >
      <span
        {...attributes}
        {...listeners}
        className="cursor-grab touch-none text-muted-foreground active:cursor-grabbing"
        aria-label="Arrastrar para reordenar"
      >
        <GripVertical className="h-3 w-3" />
      </span>
      <div
        className="h-2 w-2 shrink-0 rounded-full"
        style={{ backgroundColor: stage.color || '#94A3B8' }}
      />
      <span className="text-sm">{stage.name}</span>
      {(stage.is_closed_won || stage.is_closed_lost) && (
        <Badge variant="outline" className="text-[10px]">
          {stage.is_closed_won ? 'Ganada' : 'Perdida'}
        </Badge>
      )}
      {stage.auto_trigger && (
        <Badge
          variant="secondary"
          className="gap-0.5 text-[10px]"
          title={`Avance automático: ${STAGE_AUTO_TRIGGER_LABELS[stage.auto_trigger]}`}
        >
          <Zap className="h-2.5 w-2.5" />
          Auto
        </Badge>
      )}
      <div className="ml-2 flex items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100">
        <Button
          variant="ghost"
          size="icon"
          className="h-5 w-5"
          type="button"
          onClick={() => onEdit(pipeline, stage)}
        >
          <Edit className="h-3 w-3" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="h-5 w-5 text-destructive hover:text-destructive"
          type="button"
          onClick={() => onDelete(pipeline.id, stage.id, stage.name)}
        >
          <Trash2 className="h-3 w-3" />
        </Button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Página principal
// ---------------------------------------------------------------------------
function PipelinesSettingsPage() {
  const queryClient = useQueryClient()
  const [selectedPipeline, setSelectedPipeline] = useState<Pipeline | null>(null)
  const [isCreateDialogOpen, setIsCreateDialogOpen] = useState(false)
  const [newPipelineName, setNewPipelineName] = useState('')
  const [newPipelineDescription, setNewPipelineDescription] = useState('')
  const [editPipelineOpen, setEditPipelineOpen] = useState(false)
  const [editPipeline, setEditPipeline] = useState<Pipeline | null>(null)
  const [editPipelineName, setEditPipelineName] = useState('')
  const [editPipelineDescription, setEditPipelineDescription] = useState('')
  const [isStageDialogOpen, setIsStageDialogOpen] = useState(false)
  const [editingStage, setEditingStage] = useState<PipelineStage | null>(null)
  const [newStageName, setNewStageName] = useState('')
  const [newStageColor, setNewStageColor] = useState('#3B82F6')
  const [newStageProbability, setNewStageProbability] = useState(0)
  const [newStageClosedWon, setNewStageClosedWon] = useState(false)
  const [newStageClosedLost, setNewStageClosedLost] = useState(false)
  const [newStageAutoTrigger, setNewStageAutoTrigger] = useState<StageAutoTrigger | 'none'>('none')
  const [confirmDeletePipeline, setConfirmDeletePipeline] = useState<Pipeline | null>(null)
  const [confirmDeleteStage, setConfirmDeleteStage] = useState<{ pipelineId: string; stageId: string; stageName: string } | null>(null)

  const { data: pipelines = [], isLoading } = useQuery({
    queryKey: queryKeys.pipelines.all,
    queryFn: async () => {
      const response = await api.get('/pipelines')
      const rows = jsonApiPrimaryList(response.data)
      return rows.filter((r) => r.id).map(mapPipelineResource)
    },
  })

  const invalidatePipelines = () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.pipelines.all })
    queryClient.invalidateQueries({ queryKey: queryKeys.opportunities.all })
  }

  const createPipelineMutation = useMutation({
    mutationFn: async (payload: { name: string; description: string; is_default: boolean }) => {
      await api.post('/pipelines', {
        pipeline: {
          name: payload.name,
          description: payload.description || undefined,
          is_default: payload.is_default,
        },
      })
    },
    onSuccess: () => {
      invalidatePipelines()
      toast.success('Pipeline creado')
      setIsCreateDialogOpen(false)
      setNewPipelineName('')
      setNewPipelineDescription('')
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const updatePipelineMutation = useMutation({
    mutationFn: async ({ id, name, description }: { id: string; name: string; description: string }) => {
      await api.patch(`/pipelines/${id}`, {
        pipeline: { name, description: description || undefined },
      })
    },
    onSuccess: () => {
      invalidatePipelines()
      toast.success('Pipeline actualizado')
      setEditPipelineOpen(false)
      setEditPipeline(null)
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const toggleActivePipelineMutation = useMutation({
    mutationFn: async ({ id, active }: { id: string; active: boolean }) => {
      await api.patch(`/pipelines/${id}`, { pipeline: { active } })
    },
    onSuccess: (_, vars) => {
      invalidatePipelines()
      toast.success(vars.active ? 'Pipeline activado' : 'Pipeline desactivado')
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const setDefaultMutation = useMutation({
    mutationFn: async (id: string) => {
      await api.patch(`/pipelines/${id}`, { pipeline: { is_default: true } })
    },
    onSuccess: () => {
      invalidatePipelines()
      toast.success('Pipeline predeterminado actualizado')
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const deletePipelineMutation = useMutation({
    mutationFn: async (id: string) => {
      await api.delete(`/pipelines/${id}`)
    },
    onSuccess: () => {
      invalidatePipelines()
      toast.success('Pipeline eliminado')
      setConfirmDeletePipeline(null)
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const saveStageMutation = useMutation({
    mutationFn: async (args: {
      pipelineId: string
      stageId?: string
      body: Record<string, unknown>
    }) => {
      if (args.stageId) {
        await api.patch(`/pipelines/${args.pipelineId}/stages/${args.stageId}`, {
          pipeline_stage: args.body,
        })
      } else {
        await api.post(`/pipelines/${args.pipelineId}/stages`, {
          pipeline_stage: args.body,
        })
      }
    },
    onSuccess: () => {
      invalidatePipelines()
      toast.success(editingStage ? 'Etapa actualizada' : 'Etapa creada')
      setIsStageDialogOpen(false)
      setEditingStage(null)
      setNewStageName('')
      setNewStageColor('#3B82F6')
      setNewStageProbability(0)
      setNewStageClosedWon(false)
      setNewStageClosedLost(false)
      setNewStageAutoTrigger('none')
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const deleteStageMutation = useMutation({
    mutationFn: async ({ pipelineId, stageId }: { pipelineId: string; stageId: string }) => {
      await api.delete(`/pipelines/${pipelineId}/stages/${stageId}`)
    },
    onSuccess: () => {
      invalidatePipelines()
      toast.success('Etapa eliminada')
      setConfirmDeleteStage(null)
    },
    onError: (err) => toast.error(apiMessage(err)),
  })

  const reorderStagesMutation = useMutation({
    mutationFn: async ({
      pipelineId,
      orderedIds,
    }: {
      pipelineId: string
      orderedIds: string[]
    }) => {
      await api.patch(`/pipelines/${pipelineId}/stages/reorder`, { order: orderedIds })
    },
    onSuccess: () => invalidatePipelines(),
    onError: (err) => toast.error(apiMessage(err)),
  })

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
  )

  const handleDragEnd = (pipelineId: string, stages: PipelineStage[], event: DragEndEvent) => {
    const { active, over } = event
    if (!over || active.id === over.id) return

    const oldIndex = stages.findIndex((s) => s.id === active.id)
    const newIndex = stages.findIndex((s) => s.id === over.id)
    if (oldIndex === -1 || newIndex === -1) return

    const reordered = arrayMove(stages, oldIndex, newIndex)
    reorderStagesMutation.mutate({
      pipelineId,
      orderedIds: reordered.map((s) => s.id),
    })
  }

  const colors = [
    '#6B7280',
    '#3B82F6',
    '#8B5CF6',
    '#EC4899',
    '#EF4444',
    '#F59E0B',
    '#10B981',
    '#06B6D4',
  ]

  const openCreateStage = (pipeline: Pipeline) => {
    setSelectedPipeline(pipeline)
    setEditingStage(null)
    setNewStageName('')
    setNewStageColor('#3B82F6')
    setNewStageProbability(0)
    setNewStageClosedWon(false)
    setNewStageClosedLost(false)
    setNewStageAutoTrigger('none')
    setIsStageDialogOpen(true)
  }

  const openEditStage = (pipeline: Pipeline, stage: PipelineStage) => {
    setSelectedPipeline(pipeline)
    setEditingStage(stage)
    setNewStageName(stage.name)
    setNewStageColor(stage.color || '#3B82F6')
    setNewStageProbability(stage.probability ?? 0)
    setNewStageClosedWon(stage.is_closed_won)
    setNewStageClosedLost(stage.is_closed_lost)
    setNewStageAutoTrigger(stage.auto_trigger ?? 'none')
    setIsStageDialogOpen(true)
  }

  const submitStage = () => {
    if (!selectedPipeline || !newStageName.trim()) return
    const stages = selectedPipeline.stages || []
    const maxPos = maxStagePosition(stages)
    const nextPosition = maxPos + 1
    const autoProbability = Math.min(100, Math.max(0, (nextPosition + 1) * 15))
    const isTerminal = newStageClosedWon || newStageClosedLost
    const autoRule = { trigger: !isTerminal && newStageAutoTrigger !== 'none' ? newStageAutoTrigger : '' }

    if (editingStage) {
      saveStageMutation.mutate({
        pipelineId: selectedPipeline.id,
        stageId: editingStage.id,
        body: {
          name: newStageName.trim(),
          color: newStageColor,
          probability: Math.min(100, Math.max(0, Math.floor(newStageProbability))),
          closed_won: newStageClosedWon,
          closed_lost: newStageClosedLost,
          auto_rule: autoRule,
        },
      })
      return
    }

    saveStageMutation.mutate({
      pipelineId: selectedPipeline.id,
      body: {
        name: newStageName.trim(),
        color: newStageColor,
        position: Math.max(0, Math.floor(nextPosition)),
        probability: Math.min(100, Math.max(0, Math.floor(newStageProbability || autoProbability))),
        closed_won: newStageClosedWon,
        closed_lost: newStageClosedLost,
        auto_rule: autoRule,
      },
    })
  }

  /** Un disparador por pipeline: etapa que ya lo usa (excluida la que se edita). */
  const triggerOwner = (trigger: StageAutoTrigger): PipelineStage | undefined =>
    (selectedPipeline?.stages ?? []).find(
      (s) => s.auto_trigger === trigger && s.id !== editingStage?.id,
    )

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-medium">Pipelines</h2>
          <p className="text-sm text-muted-foreground">
            Crea embudos y etapas; aparecerán como opciones al dar de alta oportunidades.
          </p>
        </div>
        <Button size="sm" onClick={() => setIsCreateDialogOpen(true)}>
          <Plus className="mr-2 h-4 w-4" />
          Nuevo pipeline
        </Button>
      </div>

      {isLoading ? (
        <div className="space-y-4">
          {Array.from({ length: 2 }).map((_, i) => (
            <Card key={i}>
              <CardHeader>
                <Skeleton className="h-6 w-32" />
              </CardHeader>
              <CardContent>
                <div className="flex gap-2">
                  {Array.from({ length: 5 }).map((_, j) => (
                    <Skeleton key={j} className="h-8 w-24" />
                  ))}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      ) : pipelines.length === 0 ? (
        <Card>
          <CardContent className="py-8 text-center text-sm text-muted-foreground">
            No hay pipelines. Crea el primero para definir etapas (Nueva, Contactada, etc.).
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-4">
          {pipelines.map((pipeline) => {
            const sortedStages = [...(pipeline.stages || [])].sort(
              (a, b) => a.position - b.position
            )
            return (
              <Card key={pipeline.id} className={cn(!pipeline.active && 'opacity-60')}>
                <CardHeader className="pb-3">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <CardTitle className="text-base">{pipeline.name}</CardTitle>
                      {pipeline.is_default && <Badge variant="secondary">Por defecto</Badge>}
                      {!pipeline.active && <Badge variant="outline" className="text-muted-foreground">Inactivo</Badge>}
                    </div>
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button variant="ghost" size="icon" className="h-8 w-8">
                          <MoreHorizontal className="h-4 w-4" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem
                          onClick={() => {
                            setEditPipeline(pipeline)
                            setEditPipelineName(pipeline.name)
                            setEditPipelineDescription(pipeline.description ?? '')
                            setEditPipelineOpen(true)
                          }}
                        >
                          <Edit className="mr-2 h-4 w-4" />
                          Editar pipeline
                        </DropdownMenuItem>
                        {!pipeline.is_default && (
                          <DropdownMenuItem
                            onClick={() => setDefaultMutation.mutate(pipeline.id)}
                          >
                            <Star className="mr-2 h-4 w-4" />
                            Establecer como predeterminado
                          </DropdownMenuItem>
                        )}
                        <DropdownMenuItem
                          onClick={() =>
                            toggleActivePipelineMutation.mutate({ id: pipeline.id, active: !pipeline.active })
                          }
                        >
                          {pipeline.active
                            ? <><PowerOff className="mr-2 h-4 w-4" />Desactivar</>
                            : <><Power className="mr-2 h-4 w-4" />Activar</>
                          }
                        </DropdownMenuItem>
                        <DropdownMenuItem
                          className="text-destructive"
                          onClick={() => setConfirmDeletePipeline(pipeline)}
                        >
                          <Trash2 className="mr-2 h-4 w-4" />
                          Eliminar pipeline
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </div>
                  <CardDescription>
                    {sortedStages.length} etapa{sortedStages.length !== 1 ? 's' : ''}
                    {pipeline.description && (
                      <span className="block text-xs text-muted-foreground/80 mt-0.5">{pipeline.description}</span>
                    )}
                  </CardDescription>
                </CardHeader>
                <CardContent>
                  <DndContext
                    sensors={sensors}
                    collisionDetection={closestCenter}
                    onDragEnd={(event) => handleDragEnd(pipeline.id, sortedStages, event)}
                  >
                    <SortableContext
                      items={sortedStages.map((s) => s.id)}
                      strategy={horizontalListSortingStrategy}
                    >
                      <div className="flex flex-wrap gap-2">
                        {sortedStages.map((stage) => (
                          <SortableStage
                            key={stage.id}
                            stage={stage}
                            pipeline={pipeline}
                            onEdit={openEditStage}
                            onDelete={(pipelineId, stageId, stageName) =>
                              setConfirmDeleteStage({ pipelineId, stageId, stageName })
                            }
                          />
                        ))}
                        <Button
                          variant="outline"
                          size="sm"
                          className="h-8"
                          type="button"
                          onClick={() => openCreateStage(pipeline)}
                        >
                          <Plus className="mr-1 h-3 w-3" />
                          Agregar etapa
                        </Button>
                      </div>
                    </SortableContext>
                  </DndContext>
                </CardContent>
              </Card>
            )
          })}
        </div>
      )}

      {/* Dialog: crear pipeline */}
      <Dialog open={isCreateDialogOpen} onOpenChange={setIsCreateDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Nuevo pipeline</DialogTitle>
            <DialogDescription>
              Un pipeline agrupa etapas (columnas del Kanban). El primero puede marcarse como
              predeterminado.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="pipelineName">Nombre</Label>
              <Input
                id="pipelineName"
                value={newPipelineName}
                onChange={(e) => setNewPipelineName(e.target.value)}
                placeholder="Ej: Ventas"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="pipelineDesc">Descripción</Label>
              <Input
                id="pipelineDesc"
                value={newPipelineDescription}
                onChange={(e) => setNewPipelineDescription(e.target.value)}
                placeholder="Opcional — describe el propósito del pipeline"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setIsCreateDialogOpen(false)}>
              Cancelar
            </Button>
            <Button
              onClick={() =>
                createPipelineMutation.mutate({
                  name: newPipelineName.trim(),
                  description: newPipelineDescription.trim(),
                  is_default: pipelines.length === 0,
                })
              }
              disabled={!newPipelineName.trim() || createPipelineMutation.isPending}
            >
              {createPipelineMutation.isPending && <Spinner className="mr-2" />}
              Crear
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Dialog: editar pipeline */}
      <Dialog open={editPipelineOpen} onOpenChange={setEditPipelineOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Editar pipeline</DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="editPipelineName">Nombre</Label>
              <Input
                id="editPipelineName"
                value={editPipelineName}
                onChange={(e) => setEditPipelineName(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="editPipelineDesc">Descripción</Label>
              <Input
                id="editPipelineDesc"
                value={editPipelineDescription}
                onChange={(e) => setEditPipelineDescription(e.target.value)}
                placeholder="Opcional"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditPipelineOpen(false)}>
              Cancelar
            </Button>
            <Button
              disabled={!editPipelineName.trim() || !editPipeline || updatePipelineMutation.isPending}
              onClick={() => {
                if (editPipeline) {
                  updatePipelineMutation.mutate({
                    id: editPipeline.id,
                    name: editPipelineName.trim(),
                    description: editPipelineDescription.trim(),
                  })
                }
              }}
            >
              {updatePipelineMutation.isPending && <Spinner className="mr-2" />}
              Guardar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* AlertDialog: eliminar pipeline */}
      <AlertDialog open={!!confirmDeletePipeline} onOpenChange={(open) => { if (!open) setConfirmDeletePipeline(null) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar pipeline?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará «{confirmDeletePipeline?.name}» y todas sus etapas. El pipeline no debe tener oportunidades activas. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90 text-destructive-foreground"
              onClick={() => confirmDeletePipeline && deletePipelineMutation.mutate(confirmDeletePipeline.id)}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* AlertDialog: eliminar etapa */}
      <AlertDialog open={!!confirmDeleteStage} onOpenChange={(open) => { if (!open) setConfirmDeleteStage(null) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar etapa?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará la etapa «{confirmDeleteStage?.stageName}». Las oportunidades en esta etapa quedarán sin etapa asignada.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90 text-destructive-foreground"
              onClick={() =>
                confirmDeleteStage &&
                deleteStageMutation.mutate({
                  pipelineId: confirmDeleteStage.pipelineId,
                  stageId: confirmDeleteStage.stageId,
                })
              }
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Dialog: crear/editar etapa */}
      <Dialog open={isStageDialogOpen} onOpenChange={setIsStageDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{editingStage ? 'Editar etapa' : 'Nueva etapa'}</DialogTitle>
            <DialogDescription>
              {editingStage
                ? 'Nombre, color y tipo de cierre (opcional).'
                : `Etapa en «${selectedPipeline?.name}».`}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="stageName">Nombre</Label>
              <Input
                id="stageName"
                value={newStageName}
                onChange={(e) => setNewStageName(e.target.value)}
                placeholder="Ej: Calificación"
              />
            </div>
            <div className="space-y-2">
              <Label>Color</Label>
              <div className="flex flex-wrap gap-2">
                {colors.map((color) => (
                  <button
                    key={color}
                    type="button"
                    className={cn(
                      'h-8 w-8 rounded-md border-2 transition-all',
                      newStageColor === color
                        ? 'scale-110 border-foreground'
                        : 'border-transparent hover:scale-105'
                    )}
                    style={{ backgroundColor: color }}
                    onClick={() => setNewStageColor(color)}
                  >
                    {newStageColor === color && <Check className="mx-auto h-4 w-4 text-white" />}
                  </button>
                ))}
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="stageProbability">Probabilidad de cierre (%)</Label>
              <Input
                id="stageProbability"
                type="number"
                min={0}
                max={100}
                value={newStageProbability}
                onChange={(e) =>
                  setNewStageProbability(Math.min(100, Math.max(0, Number(e.target.value))))
                }
                placeholder="0 – 100"
              />
            </div>
            <div className="flex flex-col gap-3 rounded-md border p-3">
              <p className="text-xs font-medium text-muted-foreground">Opciones de etapa final</p>
              <label className="flex cursor-pointer items-center gap-2 text-sm">
                <Checkbox
                  checked={newStageClosedWon}
                  onCheckedChange={(v) => {
                    const on = v === true
                    setNewStageClosedWon(on)
                    if (on) setNewStageClosedLost(false)
                  }}
                />
                Cierre ganado (oportunidad ganada)
              </label>
              <label className="flex cursor-pointer items-center gap-2 text-sm">
                <Checkbox
                  checked={newStageClosedLost}
                  onCheckedChange={(v) => {
                    const on = v === true
                    setNewStageClosedLost(on)
                    if (on) setNewStageClosedWon(false)
                  }}
                />
                Cierre perdido
              </label>
            </div>
            {!newStageClosedWon && !newStageClosedLost && (
              <div className="space-y-2">
                <Label htmlFor="stageAutoTrigger" className="flex items-center gap-1.5">
                  <Zap className="h-3.5 w-3.5" />
                  Avance automático
                </Label>
                <Select
                  value={newStageAutoTrigger}
                  onValueChange={(v) => setNewStageAutoTrigger(isStageAutoTrigger(v) ? v : 'none')}
                >
                  <SelectTrigger id="stageAutoTrigger">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="none">Manual (sin regla)</SelectItem>
                    {(Object.keys(STAGE_AUTO_TRIGGER_LABELS) as StageAutoTrigger[]).map((trigger) => {
                      const owner = triggerOwner(trigger)
                      return (
                        <SelectItem key={trigger} value={trigger} disabled={Boolean(owner)}>
                          {STAGE_AUTO_TRIGGER_LABELS[trigger]}
                          {owner ? ` (usado en «${owner.name}»)` : ''}
                        </SelectItem>
                      )
                    })}
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  La oportunidad entra sola a esta etapa cuando ocurre el evento. Solo avanza, nunca
                  retrocede ni cierra negocios, y respeta los retrocesos hechos a mano.
                </p>
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setIsStageDialogOpen(false)}>
              Cancelar
            </Button>
            <Button
              onClick={submitStage}
              disabled={!newStageName.trim() || saveStageMutation.isPending}
            >
              {saveStageMutation.isPending && <Spinner className="mr-2" />}
              {editingStage ? 'Guardar' : 'Agregar'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
