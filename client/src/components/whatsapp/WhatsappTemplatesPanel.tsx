import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Trash2, Edit, X } from 'lucide-react'
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
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'
import {
  fetchWhatsappTemplates,
  createWhatsappTemplate,
  updateWhatsappTemplate,
  deleteWhatsappTemplate,
  whatsappTemplateErrorMessage,
  type WhatsappTemplate,
} from '@/lib/whatsappTemplatesApi'
import { queryKeys } from '@/lib/queryClient'
import { useAuthStore } from '@/stores/auth'

const emptyForm = {
  name: '',
  metaTemplateName: '',
  language: 'es_CO',
  variableLabels: [] as string[],
  variableNames: [] as string[],
}

/**
 * Gestión del catálogo de plantillas de WhatsApp aprobadas por Meta. Solo
 * admin/manager llegan a este tab (ver visibilidad en la página /whatsapp);
 * el backend igual exige manager_or_admin? para crear/editar.
 */
export function WhatsappTemplatesPanel() {
  const queryClient = useQueryClient()
  const isAdmin = useAuthStore((s) => s.isAdmin())
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editing, setEditing] = useState<WhatsappTemplate | null>(null)
  const [form, setForm] = useState(emptyForm)
  const [confirmDelete, setConfirmDelete] = useState<WhatsappTemplate | null>(null)

  const { data: templates = [], isLoading } = useQuery({
    queryKey: queryKeys.whatsappTemplates.all,
    queryFn: () => fetchWhatsappTemplates(),
  })

  const invalidate = () => queryClient.invalidateQueries({ queryKey: queryKeys.whatsappTemplates.all })

  const saveMutation = useMutation({
    mutationFn: async () => {
      // labels y names se mantienen alineados por índice (fila a fila en el
      // editor); se filtran juntos por si alguna fila quedó con label vacío.
      const rows = form.variableLabels
        .map((label, i) => ({ label: label.trim(), name: (form.variableNames[i] ?? '').trim() }))
        .filter((row) => row.label)
      const body = {
        name: form.name.trim(),
        meta_template_name: form.metaTemplateName.trim(),
        language: form.language.trim(),
        variable_labels: rows.map((r) => r.label),
        variable_names: rows.map((r) => r.name),
      }
      if (editing) {
        await updateWhatsappTemplate(editing.id, body)
      } else {
        await createWhatsappTemplate({ ...body, active: true })
      }
    },
    onSuccess: () => {
      invalidate()
      toast.success(editing ? 'Plantilla actualizada' : 'Plantilla creada')
      closeDialog()
    },
    onError: (err) => toast.error(whatsappTemplateErrorMessage(err)),
  })

  const toggleActiveMutation = useMutation({
    mutationFn: ({ id, active }: { id: string; active: boolean }) => updateWhatsappTemplate(id, { active }),
    onSuccess: () => invalidate(),
    onError: (err) => toast.error(whatsappTemplateErrorMessage(err)),
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => deleteWhatsappTemplate(id),
    onSuccess: () => {
      invalidate()
      toast.success('Plantilla eliminada')
      setConfirmDelete(null)
    },
    onError: (err) => toast.error(whatsappTemplateErrorMessage(err)),
  })

  const openCreate = () => {
    setEditing(null)
    setForm(emptyForm)
    setDialogOpen(true)
  }

  const openEdit = (tpl: WhatsappTemplate) => {
    setEditing(tpl)
    setForm({
      name: tpl.name,
      metaTemplateName: tpl.metaTemplateName,
      language: tpl.language,
      variableLabels: [...tpl.variableLabels],
      variableNames: [...tpl.variableNames],
    })
    setDialogOpen(true)
  }

  const closeDialog = () => {
    setDialogOpen(false)
    setEditing(null)
    setForm(emptyForm)
  }

  const addVariable = () =>
    setForm((f) => ({ ...f, variableLabels: [...f.variableLabels, ''], variableNames: [...f.variableNames, ''] }))
  const removeVariable = (i: number) =>
    setForm((f) => ({
      ...f,
      variableLabels: f.variableLabels.filter((_, idx) => idx !== i),
      variableNames: f.variableNames.filter((_, idx) => idx !== i),
    }))
  const setVariable = (i: number, value: string) =>
    setForm((f) => ({ ...f, variableLabels: f.variableLabels.map((v, idx) => (idx === i ? value : v)) }))
  const setVariableName = (i: number, value: string) =>
    setForm((f) => ({ ...f, variableNames: f.variableNames.map((v, idx) => (idx === i ? value : v)) }))

  const canSave = form.name.trim() && form.metaTemplateName.trim() && form.language.trim()

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-medium">Plantillas de WhatsApp</h2>
          <p className="text-sm text-muted-foreground">
            Catálogo de plantillas aprobadas por Meta. Se usan para iniciar conversación con
            leads que aún no han escrito primero (fuera de la ventana de 24h, WhatsApp rechaza
            texto libre con el error 131047 y exige una plantilla pre-aprobada).
          </p>
        </div>
        <Button size="sm" onClick={openCreate}>
          <Plus className="mr-2 h-4 w-4" />
          Nueva plantilla
        </Button>
      </div>

      {isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-14 w-full rounded-lg" />
          ))}
        </div>
      ) : templates.length === 0 ? (
        <div className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
          No hay plantillas registradas. Copia el nombre exacto y el idioma tal como aparecen
          aprobados en Meta Business Suite → WhatsApp Manager → Plantillas de mensajes.
        </div>
      ) : (
        <div className="space-y-1">
          {templates.map((tpl) => (
            <div
              key={tpl.id}
              className="group flex items-center justify-between rounded-lg border bg-card px-4 py-3 transition-colors hover:border-border"
            >
              <div className="flex min-w-0 items-center gap-3">
                <Badge variant="outline" className="shrink-0 text-xs font-normal">
                  {tpl.language}
                </Badge>
                <div className="min-w-0">
                  <p className={`truncate text-sm ${!tpl.active ? 'text-muted-foreground line-through' : ''}`}>
                    {tpl.name}
                  </p>
                  <p className="truncate text-xs text-muted-foreground">
                    {tpl.metaTemplateName}
                    {tpl.variableLabels.length > 0 && ` · ${tpl.variableLabels.length} variable(s)`}
                  </p>
                </div>
              </div>
              <div className="ml-4 flex shrink-0 items-center gap-3">
                <Switch
                  checked={tpl.active}
                  onCheckedChange={(active) => toggleActiveMutation.mutate({ id: tpl.id, active })}
                  aria-label={tpl.active ? 'Desactivar plantilla' : 'Activar plantilla'}
                />
                <div className="flex items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100">
                  <Button variant="ghost" size="icon" className="h-7 w-7" onClick={() => openEdit(tpl)}>
                    <Edit className="h-3.5 w-3.5" />
                  </Button>
                  {isAdmin && (
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7 text-destructive hover:text-destructive"
                      onClick={() => setConfirmDelete(tpl)}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      <AlertDialog open={!!confirmDelete} onOpenChange={(open) => { if (!open) setConfirmDelete(null) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar plantilla?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará «{confirmDelete?.name}». Los mensajes ya enviados con esta plantilla no
              se ven afectados. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => confirmDelete && deleteMutation.mutate(confirmDelete.id)}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <Dialog open={dialogOpen} onOpenChange={(open) => { if (!open) closeDialog() }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{editing ? 'Editar plantilla' : 'Nueva plantilla'}</DialogTitle>
            <DialogDescription>
              El nombre y el idioma deben coincidir exactamente con la plantilla aprobada en Meta —
              un typo hace que Meta rechace el envío.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="tplName">Nombre visible (para el consultor)</Label>
              <Input
                id="tplName"
                value={form.name}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                placeholder="Ej: Primer contacto"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="tplMetaName">Nombre exacto en Meta</Label>
              <Input
                id="tplMetaName"
                value={form.metaTemplateName}
                onChange={(e) => setForm((f) => ({ ...f, metaTemplateName: e.target.value }))}
                placeholder="Ej: primer_contacto"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="tplLanguage">Idioma (código Meta)</Label>
              <Input
                id="tplLanguage"
                value={form.language}
                onChange={(e) => setForm((f) => ({ ...f, language: e.target.value }))}
                placeholder="Ej: es_CO"
              />
            </div>

            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <Label>Variables</Label>
                <Button type="button" variant="outline" size="sm" onClick={addVariable}>
                  <Plus className="mr-1 h-3.5 w-3.5" />
                  Agregar
                </Button>
              </div>
              {form.variableLabels.length === 0 ? (
                <p className="text-xs text-muted-foreground">Sin variables — la plantilla es texto fijo.</p>
              ) : (
                <div className="space-y-2">
                  <p className="text-xs text-muted-foreground">
                    Nombre para mostrar al consultor, y el nombre exacto de la variable en Meta si la
                    plantilla usa el formato nuevo ({'{{primer_nombre}}'}) — déjalo vacío si tu plantilla
                    usa el formato clásico posicional ({'{{1}}'}, {'{{2}}'}...).
                  </p>
                  {form.variableLabels.map((label, i) => (
                    <div key={i} className="flex items-center gap-2">
                      <span className="w-6 shrink-0 text-xs text-muted-foreground">{`{{${i + 1}}}`}</span>
                      <Input
                        value={label}
                        onChange={(e) => setVariable(i, e.target.value)}
                        placeholder="Ej: Nombre del lead"
                      />
                      <Input
                        value={form.variableNames[i] ?? ''}
                        onChange={(e) => setVariableName(i, e.target.value)}
                        placeholder="Ej: primer_nombre (opcional)"
                      />
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="h-8 w-8 shrink-0"
                        onClick={() => removeVariable(i)}
                      >
                        <X className="h-3.5 w-3.5" />
                      </Button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={closeDialog}>
              Cancelar
            </Button>
            <Button onClick={() => saveMutation.mutate()} disabled={!canSave || saveMutation.isPending}>
              {saveMutation.isPending && <Spinner className="mr-2" />}
              {editing ? 'Guardar' : 'Crear'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
