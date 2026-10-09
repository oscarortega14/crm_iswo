import { createFileRoute } from '@tanstack/react-router'
import { requireSettingsRole } from '@/lib/authGuards'
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Plus, Trash2, GripVertical, Pencil } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Spinner } from '@/components/ui/spinner'
import { Switch } from '@/components/ui/switch'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import api, { formatRailsError } from '@/lib/api'
import { useAuthStore } from '@/stores/auth'
import type { TenantFieldDefinition, FieldType, FieldEntity } from '@/types'

export const Route = createFileRoute('/_app/settings/fields')({
  beforeLoad: () => requireSettingsRole('admin'),
  component: FieldsSettingsPage,
})

const FIELD_TYPE_LABELS: Record<FieldType, string> = {
  text:     'Texto',
  number:   'Número',
  select:   'Selección',
  date:     'Fecha',
  boolean:  'Sí / No',
  currency: 'Monto',
}

interface FieldForm {
  key: string
  label: string
  field_type: FieldType
  entity: FieldEntity
  required: boolean
  options: string
}

const emptyForm = (): FieldForm => ({
  key: '', label: '', field_type: 'text', entity: 'opportunity', required: false, options: '',
})

function mapList(raw: unknown): TenantFieldDefinition[] {
  const items = (raw as { data?: unknown[] })?.data ?? []
  return items.map((item) => {
    const r = item as { id?: string; attributes?: Record<string, unknown> }
    const a = r.attributes ?? {}
    return {
      id:         String(r.id ?? ''),
      key:        String(a.key ?? ''),
      label:      String(a.label ?? ''),
      field_type: (a.field_type as FieldType) ?? 'text',
      options:    Array.isArray(a.options) ? (a.options as string[]) : [],
      required:   Boolean(a.required),
      entity:     (a.entity as FieldEntity) ?? 'opportunity',
      position:   Number(a.position ?? 0),
      active:     Boolean(a.active ?? true),
    }
  })
}

function FieldDialog({
  open,
  onOpenChange,
  initial,
  onSave,
  saving,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  initial: FieldForm
  onSave: (form: FieldForm) => void
  saving: boolean
}) {
  const [form, setForm] = useState<FieldForm>(initial)
  const set = (k: keyof FieldForm, v: unknown) => setForm((f) => ({ ...f, [k as string]: v }))

  // Sync when dialog opens with new initial
  useState(() => { setForm(initial) })

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{initial.key ? 'Editar campo' : 'Nuevo campo'}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Clave interna <span className="text-destructive">*</span></Label>
              <Input
                placeholder="empleador_nit"
                value={form.key}
                onChange={(e) => set('key', e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_'))}
                disabled={!!initial.key}
              />
              <p className="text-[11px] text-muted-foreground">Solo minúsculas y _</p>
            </div>
            <div className="space-y-1.5">
              <Label>Etiqueta <span className="text-destructive">*</span></Label>
              <Input
                placeholder="NIT del Empleador"
                value={form.label}
                onChange={(e) => set('label', e.target.value)}
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Tipo de campo</Label>
              <Select value={form.field_type} onValueChange={(v) => set('field_type', v)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {(Object.keys(FIELD_TYPE_LABELS) as FieldType[]).map((t) => (
                    <SelectItem key={t} value={t}>{FIELD_TYPE_LABELS[t]}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label>Entidad</Label>
              <Select value={form.entity} onValueChange={(v) => set('entity', v)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="opportunity">Oportunidad</SelectItem>
                  <SelectItem value="contact">Contacto</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          {form.field_type === 'select' && (
            <div className="space-y-1.5">
              <Label>Opciones</Label>
              <Input
                placeholder="Opción 1, Opción 2, Opción 3"
                value={form.options}
                onChange={(e) => set('options', e.target.value)}
              />
              <p className="text-[11px] text-muted-foreground">Separadas por coma</p>
            </div>
          )}

          <div className="flex items-center gap-2">
            <Switch
              checked={form.required}
              onCheckedChange={(v) => set('required', v)}
              id="required-switch"
            />
            <Label htmlFor="required-switch" className="cursor-pointer">Campo requerido</Label>
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>Cancelar</Button>
          <Button
            onClick={() => onSave(form)}
            disabled={!form.key || !form.label || saving}
          >
            {saving && <Spinner className="mr-2 size-4" />}
            Guardar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function FieldsSettingsPage() {
  const queryClient = useQueryClient()
  const canEdit = useAuthStore((s) => s.isAdmin())

  const [dialogOpen, setDialogOpen] = useState(false)
  const [editing, setEditing] = useState<TenantFieldDefinition | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<TenantFieldDefinition | null>(null)

  const { data: fields = [], isLoading } = useQuery({
    queryKey: ['tenant_field_definitions'],
    queryFn: async () => {
      const res = await api.get('/tenant_field_definitions', { params: { include_inactive: 'true' } })
      return mapList(res.data)
    },
  })

  const saveMutation = useMutation({
    mutationFn: async (form: FieldForm) => {
      const payload = {
        tenant_field_definition: {
          key:        form.key,
          label:      form.label,
          field_type: form.field_type,
          entity:     form.entity,
          required:   form.required,
          options:    form.field_type === 'select'
            ? form.options.split(',').map((s) => s.trim()).filter(Boolean)
            : [],
        },
      }
      if (editing) {
        return api.patch(`/tenant_field_definitions/${editing.id}`, payload)
      }
      return api.post('/tenant_field_definitions', payload)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tenant_field_definitions'] })
      toast.success(editing ? 'Campo actualizado' : 'Campo creado')
      setDialogOpen(false)
      setEditing(null)
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo guardar el campo')),
  })

  const toggleMutation = useMutation({
    mutationFn: (field: TenantFieldDefinition) =>
      api.patch(`/tenant_field_definitions/${field.id}`, {
        tenant_field_definition: { active: !field.active },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['tenant_field_definitions'] }),
    onError: (err: unknown) => toast.error(formatRailsError(err, 'Error al actualizar')),
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => api.delete(`/tenant_field_definitions/${id}`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tenant_field_definitions'] })
      toast.success('Campo eliminado')
      setDeleteTarget(null)
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo eliminar')),
  })

  const openNew = () => { setEditing(null); setDialogOpen(true) }
  const openEdit = (f: TenantFieldDefinition) => {
    setEditing(f)
    setDialogOpen(true)
  }

  const initialForm = editing
    ? {
        key:        editing.key,
        label:      editing.label,
        field_type: editing.field_type,
        entity:     editing.entity,
        required:   editing.required,
        options:    editing.options.join(', '),
      }
    : emptyForm()

  const opportunityFields = fields.filter((f) => f.entity === 'opportunity')
  const contactFields     = fields.filter((f) => f.entity === 'contact')

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div>
          <h2 className="text-lg font-medium">Campos personalizados</h2>
          <p className="hidden text-sm text-muted-foreground sm:block">
            Define campos extra para tu vertical. Los valores se guardan en cada oportunidad o contacto.
          </p>
        </div>
        {canEdit && (
          <Button size="sm" onClick={openNew}>
            <Plus className="size-4 mr-1.5" />
            Nuevo campo
          </Button>
        )}
      </div>

      {isLoading ? (
        <div className="space-y-3">
          {[1, 2, 3].map((i) => <Skeleton key={i} className="h-14 w-full rounded-lg" />)}
        </div>
      ) : fields.length === 0 ? (
        <div className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
          No hay campos personalizados.{canEdit && ' Crea el primero con el botón de arriba.'}
        </div>
      ) : (
        <div className="space-y-6">
          {[
            { label: 'Oportunidades', items: opportunityFields },
            { label: 'Contactos',     items: contactFields },
          ].filter(({ items }) => items.length > 0).map(({ label, items }) => (
            <div key={label}>
              <p className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-2">
                {label}
              </p>
              <div className="rounded-lg border divide-y">
                {items.map((field) => (
                  <div key={field.id} className="flex items-center gap-3 px-4 py-3">
                    <GripVertical className="size-4 text-muted-foreground/40 shrink-0" />
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="text-sm font-medium truncate">{field.label}</span>
                        <span className="font-mono text-[10px] text-muted-foreground bg-muted px-1.5 py-0.5 rounded">
                          {field.key}
                        </span>
                        <Badge variant="secondary" className="text-[10px] py-0">
                          {FIELD_TYPE_LABELS[field.field_type]}
                        </Badge>
                        {field.required && (
                          <Badge variant="outline" className="text-[10px] py-0 border-amber-400 text-amber-700 dark:text-amber-400">
                            Requerido
                          </Badge>
                        )}
                        {!field.active && (
                          <Badge variant="outline" className="text-[10px] py-0 text-muted-foreground">
                            Inactivo
                          </Badge>
                        )}
                      </div>
                      {field.field_type === 'select' && field.options.length > 0 && (
                        <p className="text-[11px] text-muted-foreground mt-0.5 truncate">
                          {field.options.join(' · ')}
                        </p>
                      )}
                    </div>

                    {canEdit && (
                      <div className="flex items-center gap-1 shrink-0">
                        <Switch
                          checked={field.active}
                          onCheckedChange={() => toggleMutation.mutate(field)}
                          className="scale-90"
                        />
                        <Button
                          variant="ghost" size="icon-sm"
                          onClick={() => openEdit(field)}
                        >
                          <Pencil className="size-3.5" />
                        </Button>
                        <Button
                          variant="ghost" size="icon-sm"
                          className="text-destructive hover:text-destructive"
                          onClick={() => setDeleteTarget(field)}
                        >
                          <Trash2 className="size-3.5" />
                        </Button>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      )}

      <FieldDialog
        open={dialogOpen}
        onOpenChange={(v) => { setDialogOpen(v); if (!v) setEditing(null) }}
        initial={initialForm}
        onSave={(form) => saveMutation.mutate(form)}
        saving={saveMutation.isPending}
      />

      <AlertDialog open={!!deleteTarget} onOpenChange={(v) => !v && setDeleteTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar campo?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará el campo <strong>{deleteTarget?.label}</strong>. Los valores ya
              guardados en oportunidades y contactos no se borran automáticamente.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90"
              onClick={() => deleteTarget && deleteMutation.mutate(deleteTarget.id)}
            >
              {deleteMutation.isPending && <Spinner className="mr-2 size-4" />}
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
