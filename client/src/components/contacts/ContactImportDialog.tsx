import { useEffect, useRef, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { AlertCircle, CheckCircle2, Download, FileSpreadsheet, Upload } from 'lucide-react'
import { formatRailsError } from '@/lib/api'
import {
  downloadContactImportTemplate,
  importContactsFromFile,
  type ContactImportResult,
} from '@/lib/contactApi'
import { invalidateContactsQueries } from '@/lib/queryClient'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'

interface ContactImportDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

const ACCEPT =
  '.xlsx,.xls,.csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/csv'

export function ContactImportDialog({ open, onOpenChange }: ContactImportDialogProps) {
  const queryClient = useQueryClient()
  const inputRef = useRef<HTMLInputElement>(null)
  const [selectedLabel, setSelectedLabel] = useState<string | null>(null)
  const [importResult, setImportResult] = useState<ContactImportResult | null>(null)

  useEffect(() => {
    if (!open) {
      setSelectedLabel(null)
      setImportResult(null)
      if (inputRef.current) inputRef.current.value = ''
    }
  }, [open])

  const downloadTemplateMutation = useMutation({
    mutationFn: downloadContactImportTemplate,
    onSuccess: () => toast.success('Plantilla Excel descargada'),
    onError: (err: unknown) =>
      toast.error(formatRailsError(err, 'No se pudo descargar la plantilla')),
  })

  const importMutation = useMutation({
    mutationFn: importContactsFromFile,
    onSuccess: async (data) => {
      await invalidateContactsQueries(queryClient)
      setImportResult(data)
      const errCount = data.errors?.length ?? 0
      const warnCount = data.warnings?.length ?? 0
      if (data.created_count > 0 && errCount === 0 && warnCount > 0) {
        toast.warning(
          `Importación lista: ${data.created_count} creado${data.created_count === 1 ? '' : 's'} · ${warnCount} fila${warnCount === 1 ? '' : 's'} con etapa ajustada`,
        )
      } else if (data.created_count > 0 && errCount === 0) {
        toast.success(
          `Importación lista: ${data.created_count} contacto${data.created_count === 1 ? '' : 's'} creado${data.created_count === 1 ? '' : 's'}` +
            (data.skipped_count
              ? ` · ${data.skipped_count} fila${data.skipped_count === 1 ? '' : 's'} vacía${data.skipped_count === 1 ? '' : 's'} omitida${data.skipped_count === 1 ? '' : 's'}`
              : ''),
        )
      } else if (data.created_count === 0 && errCount > 0) {
        toast.error('No se importó ningún contacto. Revisa los errores en el detalle.')
      } else if (errCount > 0) {
        toast.warning(
          `Importación parcial: ${data.created_count} creado${data.created_count === 1 ? '' : 's'}, ${errCount} fila${errCount === 1 ? '' : 's'} con error`,
        )
      } else {
        toast.info('No había filas con datos para importar.')
      }
      setSelectedLabel(null)
      if (inputRef.current) inputRef.current.value = ''
    },
    onError: (err: unknown) =>
      toast.error(formatRailsError(err, 'No se pudo importar el archivo')),
  })

  const onPickFile = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) {
      setSelectedLabel(null)
      return
    }
    setImportResult(null)
    setSelectedLabel(file.name)
  }

  const submitImport = () => {
    const file = inputRef.current?.files?.[0]
    if (!file) {
      toast.error('Selecciona un archivo Excel (.xlsx) o CSV (.csv)')
      return
    }
    importMutation.mutate(file)
  }

  const clearFile = () => {
    setSelectedLabel(null)
    setImportResult(null)
    if (inputRef.current) inputRef.current.value = ''
  }

  const handleClose = () => {
    onOpenChange(false)
  }

  const errCount = importResult?.errors?.length ?? 0
  const warnings = importResult?.warnings ?? []

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex max-h-[min(90vh,640px)] flex-col gap-0 overflow-hidden p-0 sm:max-w-lg">
        <DialogHeader className="shrink-0 border-b px-6 py-4">
          <DialogTitle className="flex items-center gap-2">
            <Upload className="size-4" />
            Importar contactos
          </DialogTitle>
          <DialogDescription>
            Descarga la plantilla, complétala y súbela en Excel (.xlsx) o CSV (.csv).
          </DialogDescription>
        </DialogHeader>

        <ScrollArea className="min-h-0 flex-1 px-6 py-4">
          <div className="space-y-3 pr-3">
            <div className="rounded-md border bg-muted/40 px-3 py-2.5 text-sm text-muted-foreground space-y-1">
              <p>
                <span className="font-medium text-foreground">Columnas:</span>{' '}
                <code className="rounded bg-muted px-1 text-xs">
                  first_name, last_name, email, phone, company, position, city, country, kind, notes,
                  stage
                </code>
              </p>
              <p className="text-xs">
                Primera fila = cabeceras · También en español (nombre, apellido, correo…) ·{' '}
                <code className="text-xs">kind = company</code> para empresas
              </p>
              <p className="text-xs">
                <span className="font-medium text-foreground">stage / etapa:</span> nombre de la etapa
                del pipeline por defecto (ver hoja «Etapas» de la plantilla). Vacía = primera etapa.
              </p>
            </div>

            <div className="flex flex-col gap-3 rounded-md border px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0">
                <p className="text-sm font-medium">Paso 1 — Plantilla</p>
                <p className="text-xs text-muted-foreground">Rellena en Excel y guarda como .xlsx</p>
              </div>
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="shrink-0 gap-1.5 sm:self-center"
                disabled={downloadTemplateMutation.isPending}
                onClick={() => downloadTemplateMutation.mutate()}
              >
                {downloadTemplateMutation.isPending ? (
                  <Spinner className="size-3.5" />
                ) : (
                  <Download className="size-3.5" />
                )}
                Descargar plantilla
              </Button>
            </div>

            <div className="rounded-md border px-4 py-3 space-y-2">
              <p className="text-sm font-medium">Paso 2 — Archivo completado</p>
              <input
                ref={inputRef}
                type="file"
                accept={ACCEPT}
                className="hidden"
                onChange={onPickFile}
              />
              {selectedLabel ? (
                <div className="flex items-center gap-2 rounded-md bg-muted px-3 py-2 text-sm">
                  <FileSpreadsheet className="size-4 shrink-0 text-emerald-500" />
                  <span className="flex-1 truncate text-foreground" title={selectedLabel}>
                    {selectedLabel}
                  </span>
                  <button
                    type="button"
                    aria-label="Quitar archivo"
                    className="shrink-0 text-muted-foreground hover:text-foreground transition-colors"
                    onClick={clearFile}
                  >
                    ✕
                  </button>
                </div>
              ) : (
                <Button
                  type="button"
                  variant="secondary"
                  className="w-full gap-2"
                  onClick={() => inputRef.current?.click()}
                >
                  <FileSpreadsheet className="size-4" />
                  Elegir archivo (.xlsx o .csv)
                </Button>
              )}
            </div>

            {importResult && (
              <div
                className={`rounded-md border px-3 py-2.5 text-sm ${
                  errCount > 0 && importResult.created_count === 0
                    ? 'border-destructive/40 bg-destructive/5'
                    : errCount > 0 || warnings.length > 0
                      ? 'border-amber-500/40 bg-amber-500/5'
                      : 'border-emerald-500/40 bg-emerald-500/5'
                }`}
              >
                <div className="flex items-start gap-2">
                  {errCount > 0 || warnings.length > 0 ? (
                    <AlertCircle className="mt-0.5 size-4 shrink-0 text-amber-600" />
                  ) : (
                    <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-emerald-600" />
                  )}
                  <div className="min-w-0 space-y-1">
                    <p className="font-medium text-foreground">Resultado</p>
                    <ul className="text-muted-foreground text-xs space-y-0.5">
                      <li>
                        <span className="text-foreground">{importResult.created_count}</span> creados
                      </li>
                      {importResult.skipped_count > 0 && (
                        <li>
                          <span className="text-foreground">{importResult.skipped_count}</span> filas
                          vacías omitidas
                        </li>
                      )}
                      {errCount > 0 && (
                        <li>
                          <span className="text-foreground">{errCount}</span> filas con error
                        </li>
                      )}
                      {warnings.length > 0 && (
                        <li>
                          <span className="text-foreground">{warnings.length}</span> importadas en la
                          primera etapa (etapa no reconocida)
                        </li>
                      )}
                    </ul>
                    {errCount > 0 && (
                      <ul className="mt-2 max-h-32 overflow-y-auto rounded border bg-background/80 px-2 py-1.5 text-xs text-foreground">
                        {importResult.errors.map((e) => (
                          <li key={`${e.row}-${e.message}`} className="py-0.5">
                            {e.row > 0 ? (
                              <>
                                Fila <strong>{e.row}</strong>: {e.message}
                              </>
                            ) : (
                              e.message
                            )}
                          </li>
                        ))}
                      </ul>
                    )}
                    {warnings.length > 0 && (
                      <ul className="mt-2 max-h-32 overflow-y-auto rounded border border-amber-500/30 bg-background/80 px-2 py-1.5 text-xs text-foreground">
                        {warnings.map((w) => (
                          <li key={`${w.row}-${w.message}`} className="py-0.5">
                            Fila <strong>{w.row}</strong>: {w.message}
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                </div>
              </div>
            )}
          </div>
        </ScrollArea>

        <DialogFooter className="shrink-0 gap-2 border-t px-6 py-4">
          <Button type="button" variant="ghost" onClick={handleClose}>
            {importResult ? 'Cerrar' : 'Cancelar'}
          </Button>
          <Button
            type="button"
            disabled={importMutation.isPending || (!selectedLabel && !importResult)}
            onClick={() => {
              if (importResult) {
                setImportResult(null)
                inputRef.current?.click()
                return
              }
              void submitImport()
            }}
          >
            {importMutation.isPending ? (
              <>
                <Spinner className="size-4 mr-1" />
                Importando…
              </>
            ) : importResult ? (
              'Importar otro archivo'
            ) : (
              'Importar'
            )}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
