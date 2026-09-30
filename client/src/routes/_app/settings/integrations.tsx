import { createFileRoute } from '@tanstack/react-router'
import { requireSettingsRole } from '@/lib/authGuards'
import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  BarChart3,
  Check,
  Megaphone,
  MessageCircle,
  Settings,
  Loader2,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
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
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { formatRailsError } from '@/lib/api'
import { queryKeys } from '@/lib/queryClient'
import { useAuthStore } from '@/stores/auth'
import type { AdIntegration, AdIntegrationProvider } from '@/lib/adIntegrationsApi'
import {
  fetchAdIntegrations,
  createAdIntegration,
  updateAdIntegration,
  destroyAdIntegration,
  disableAdIntegration,
  testAdIntegrationConnection,
} from '@/lib/adIntegrationsApi'

export const Route = createFileRoute('/_app/settings/integrations')({
  beforeLoad: () => requireSettingsRole('admin', 'manager'),
  component: IntegrationsSettingsPage,
})

type CategoryId = 'ads' | 'messaging'

interface CredentialField {
  key: string
  label: string
  type?: 'password' | 'text'
  placeholder?: string
}

interface ProviderCatalogEntry {
  provider: AdIntegrationProvider
  category: CategoryId
  title: string
  description: string
  icon: LucideIcon
  /** Mapea a `ad_integrations.account_identifier` (p. ej. Page ID, número E.164, phone_number_id) */
  accountIdentifierLabel: string
  accountIdentifierPlaceholder?: string
  accountIdentifierHint?: string
  credentialFields: CredentialField[]
  /** Mapea a `metadata` JSON (p. ej. `form_id` de Google Lead Forms) */
  metadataFields?: CredentialField[]
}

const PROVIDER_CATALOG: ProviderCatalogEntry[] = [
  {
    provider: 'meta',
    category: 'ads',
    title: 'Meta Ads (Lead Forms)',
    description:
      'Las URLs exactas de webhook las muestra el servidor debajo (según el host público del API). El Page ID debe coincidir con entry.id del webhook. Token Graph API para descargar el lead.',
    icon: Megaphone,
    accountIdentifierLabel: 'Page ID de Facebook',
    accountIdentifierPlaceholder: 'ID numérico de la página (Meta Business)',
    accountIdentifierHint:
      'Debe coincidir con el Page ID que Meta envía en el webhook; cópialo desde Meta Business Suite.',
    credentialFields: [
      {
        key: 'access_token',
        label: 'Access token de Graph API',
        type: 'password',
        placeholder: 'EAAG…',
      },
    ],
  },
  {
    provider: 'google',
    category: 'ads',
    title: 'Google Ads (Lead Forms)',
    description:
      'URL de callback según el bloque «URLs de webhook» (servidor). Refresh OAuth; GOOGLE_ADS_* en el servidor para «Probar conexión».',
    icon: BarChart3,
    accountIdentifierLabel: 'Customer ID de Google Ads (opcional)',
    accountIdentifierPlaceholder: 'Formato 123-456-7890 si lo usas',
    accountIdentifierHint:
      'Referencia interna. El webhook empareja por Form ID en metadata.',
    credentialFields: [
      {
        key: 'refresh_token',
        label: 'Refresh token OAuth2',
        type: 'password',
      },
    ],
    metadataFields: [
      {
        key: 'form_id',
        label: 'Form ID (Lead Form Extension)',
        type: 'text',
        placeholder: 'ID del formulario en Google Ads',
      },
    ],
  },
  {
    provider: 'whatsapp_cloud',
    category: 'messaging',
    title: 'WhatsApp Cloud API',
    description:
      'Usa las URLs Cloud del bloque del servidor. Guarda el Phone number ID aquí; debe coincidir con metadata.phone_number_id del payload. El WABA ID (abajo) es necesario para el botón «Sincronizar» del catálogo de plantillas — el access token debe tener el permiso whatsapp_business_management además de whatsapp_business_messaging.',
    icon: MessageCircle,
    accountIdentifierLabel: 'Phone number ID (Meta Cloud API)',
    accountIdentifierPlaceholder: 'Phone number ID en Meta Developer',
    accountIdentifierHint:
      'Visible en Meta Developer → WhatsApp → API Setup. Se usa para enlazar el webhook al tenant.',
    credentialFields: [
      {
        key: 'access_token',
        label: 'Access token (permanente / sistema)',
        type: 'password',
        placeholder:
          'EAAG… (OAuth User token, no el App Secret; sin escribir «Bearer », sin comillas)',
      },
    ],
    metadataFields: [
      {
        key: 'waba_id',
        label: 'WABA ID (WhatsApp Business Account)',
        type: 'text',
        placeholder: '1606763050800373',
      },
    ],
  },
  {
    provider: 'openwa',
    category: 'messaging',
    title: 'OpenWA (self-hosted)',
    description:
      'Servidor WhatsApp open-source auto-alojado. El Session ID debe coincidir con el sessionId que OpenWA envía en cada evento webhook. Configura la URL del webhook en el panel de OpenWA apuntando al endpoint que muestra el servidor.',
    icon: MessageCircle,
    accountIdentifierLabel: 'Session ID de OpenWA',
    accountIdentifierPlaceholder: 'default',
    accountIdentifierHint:
      'Debe coincidir con el campo sessionId del payload de eventos de OpenWA. Cópialo desde el panel de OpenWA.',
    credentialFields: [
      {
        key: 'url',
        label: 'URL del servidor OpenWA',
        type: 'text',
        placeholder: 'https://openwa.miempresa.com',
      },
      {
        key: 'api_key',
        label: 'API Key de OpenWA',
        type: 'password',
        placeholder: 'Clave configurada en el servidor OpenWA',
      },
    ],
  },
]

const CATEGORIES: { id: CategoryId; name: string; icon: LucideIcon }[] = [
  { id: 'ads', name: 'Publicidad y leads', icon: Megaphone },
  { id: 'messaging', name: 'Mensajería', icon: MessageCircle },
]

function WebhookUrlRow({ label, url }: { label: string; url: string }) {
  return (
    <div className="flex flex-col gap-0.5 sm:flex-row sm:items-start sm:gap-2">
      <dt className="shrink-0 text-muted-foreground sm:w-52">{label}</dt>
      <dd className="min-w-0 break-all font-mono text-[11px] text-foreground">{url}</dd>
    </div>
  )
}

function statusBadge(integration: AdIntegration | null) {
  if (!integration) return { label: 'Sin configurar', variant: 'outline' as const }
  if (!integration.has_credentials) return { label: 'Sin credenciales', variant: 'secondary' as const }
  switch (integration.status) {
    case 'active':
      return integration.last_error_at
        ? { label: 'Error', variant: 'destructive' as const }
        : { label: 'Activa', variant: 'default' as const }
    case 'paused':
      return { label: 'Pausada', variant: 'secondary' as const }
    case 'error':
      return { label: 'Error', variant: 'destructive' as const }
    case 'revoked':
      return { label: 'Revocada', variant: 'outline' as const }
    default:
      return { label: integration.status, variant: 'outline' as const }
  }
}

function IntegrationsSettingsPage() {
  const queryClient = useQueryClient()
  const canMutate = useAuthStore((s) => s.isAdmin())
  const canTest = useAuthStore((s) => s.isAdmin() || s.isManager())
  const isAllowed = useAuthStore((s) => s.isAdmin() || s.isManager())

  if (!isAllowed) {
    return (
      <div className="flex flex-col items-center justify-center py-24 gap-3 text-center">
        <p className="text-lg font-medium">Acceso restringido</p>
        <p className="text-sm text-muted-foreground">
          Solo administradores y managers pueden ver las integraciones.
        </p>
      </div>
    )
  }

  const [dialogOpen, setDialogOpen] = useState(false)
  const [dialogCatalog, setDialogCatalog] = useState<ProviderCatalogEntry | null>(null)
  const [dialogIntegration, setDialogIntegration] = useState<AdIntegration | null>(null)
  const [accountIdentifier, setAccountIdentifier] = useState('')
  const [credentialValues, setCredentialValues] = useState<Record<string, string>>({})
  const [metadataValues, setMetadataValues] = useState<Record<string, string>>({})
  const [confirmDeleteIntegration, setConfirmDeleteIntegration] = useState(false)

  const {
    data: integrationsIndex,
    isLoading,
    isError,
    refetch,
    isFetching,
  } = useQuery({
    queryKey: queryKeys.integrations.all,
    queryFn: fetchAdIntegrations,
  })

  const integrations = integrationsIndex?.integrations ?? []
  const webhookUrls = integrationsIndex?.webhookUrls ?? null

  const merged = useMemo(() => {
    return PROVIDER_CATALOG.map((catalog) => ({
      catalog,
      integration: integrations.find((i) => i.provider === catalog.provider) ?? null,
    }))
  }, [integrations])

  const connectedCount = integrations.filter(
    (i) => i.has_credentials && i.status === 'active',
  ).length

  const openDialog = (catalog: ProviderCatalogEntry, integration: AdIntegration | null) => {
    setDialogCatalog(catalog)
    setDialogIntegration(integration)
    setAccountIdentifier(integration?.account_identifier ?? '')
    const credInitial: Record<string, string> = {}
    for (const f of catalog.credentialFields) {
      credInitial[f.key] = ''
    }
    setCredentialValues(credInitial)
    const metaInitial: Record<string, string> = {}
    const md = integration?.metadata && typeof integration.metadata === 'object' ? integration.metadata : {}
    for (const f of catalog.metadataFields ?? []) {
      const raw = md[f.key as keyof typeof md]
      metaInitial[f.key] = raw != null ? String(raw) : ''
    }
    setMetadataValues(metaInitial)
    setDialogOpen(true)
  }

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (!dialogCatalog) throw new Error('Sin proveedor')
      const creds = Object.fromEntries(
        Object.entries(credentialValues).filter(([, v]) => v.trim().length > 0),
      ) as Record<string, string>
      const meta = Object.fromEntries(
        Object.entries(metadataValues).filter(([, v]) => v.trim().length > 0),
      ) as Record<string, string>
      const aid = accountIdentifier.trim()

      if (dialogIntegration) {
        const hasCreds = Object.keys(creds).length > 0
        const hasMeta = Object.keys(meta).length > 0
        if (!hasCreds && !hasMeta) {
          return updateAdIntegration(dialogIntegration.id, {
            account_identifier: aid.length ? aid : null,
          })
        }
        const patch: Parameters<typeof updateAdIntegration>[1] = {
          account_identifier: aid.length ? aid : null,
        }
        if (hasCreds) patch.credentials = creds
        if (hasMeta) patch.metadata = meta
        return updateAdIntegration(dialogIntegration.id, patch)
      }

      if (Object.keys(creds).length === 0) {
        throw new Error('Introduce las credenciales para crear la integración')
      }
      return createAdIntegration({
        provider: dialogCatalog.provider,
        account_identifier: aid.length ? aid : null,
        credentials: creds,
        metadata: Object.keys(meta).length > 0 ? meta : {},
      })
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.integrations.all })
      toast.success('Integración guardada')
      setDialogOpen(false)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudo guardar'))
    },
  })

  const disableMutation = useMutation({
    mutationFn: (id: string) => disableAdIntegration(id),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.integrations.all })
      toast.success('Integración pausada')
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo pausar')),
  })

  const activateMutation = useMutation({
    mutationFn: (id: string) =>
      updateAdIntegration(id, { status: 'active' }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.integrations.all })
      toast.success('Integración reactivada')
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo reactivar')),
  })

  const destroyMutation = useMutation({
    mutationFn: (id: string) => destroyAdIntegration(id),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.integrations.all })
      toast.success('Integración eliminada')
      setConfirmDeleteIntegration(false)
      setDialogOpen(false)
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo eliminar')),
  })

  const testMutation = useMutation({
    mutationFn: (id: string) => testAdIntegrationConnection(id),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.integrations.all })
      toast.success('Conexión correcta')
    },
    onError: (err: unknown) => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.integrations.all })
      toast.error(formatRailsError(err, 'La prueba de conexión falló'))
    },
  })

  const busy =
    saveMutation.isPending ||
    disableMutation.isPending ||
    activateMutation.isPending ||
    destroyMutation.isPending ||
    testMutation.isPending

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-lg font-medium">Integraciones</h2>
          <p className="text-sm text-muted-foreground">
            Canales reales conectados al CRM (Meta, Google Ads, WhatsApp Cloud, OpenWA). Las
            credenciales se almacenan cifradas; no se muestran de nuevo tras guardarlas.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant="secondary">{connectedCount} activas</Badge>
          <Button variant="outline" size="sm" onClick={() => void refetch()} disabled={isFetching}>
            {isFetching ? <Loader2 className="mr-2 size-4 animate-spin" /> : null}
            Actualizar
          </Button>
        </div>
      </div>

      {isError && (
        <p className="text-sm text-destructive">
          No se pudieron cargar las integraciones. ¿Tienes permiso de administrador o manager?
        </p>
      )}

      {!isLoading && !isError && webhookUrls ? (
        <div className="rounded-lg border border-border bg-muted/30 px-4 py-3 text-sm">
          <p className="mb-2 font-medium">URLs de webhook (desde el API — sin datos inventados)</p>
          <p className="mb-3 text-xs text-muted-foreground">
            Configura estas URLs en Meta y Google. En local necesitas ngrok y{' '}
            <code className="rounded bg-muted px-1">API_PUBLIC_ORIGIN</code> en el API apuntando a esa
            URL pública.
          </p>
          <dl className="grid gap-2 text-xs">
            <WebhookUrlRow label="Meta — verificación (GET)" url={webhookUrls.meta_verify_get} />
            <WebhookUrlRow label="Meta — leads (POST)" url={webhookUrls.meta_leads_post} />
            <WebhookUrlRow label="Google — leads (POST)" url={webhookUrls.google_leads_post} />
            <WebhookUrlRow label="WhatsApp Cloud — verificación (GET)" url={webhookUrls.whatsapp_cloud_verify_get} />
            <WebhookUrlRow label="WhatsApp Cloud — mensajes (POST)" url={webhookUrls.whatsapp_cloud_post} />
            <WebhookUrlRow label="OpenWA — mensajes (POST)" url={webhookUrls.whatsapp_openwa_post} />
          </dl>
        </div>
      ) : null}

      {isLoading ? (
        <div className="space-y-6">
          {Array.from({ length: 2 }).map((_, i) => (
            <div key={i}>
              <Skeleton className="mb-4 h-6 w-40" />
              <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                <Skeleton className="h-36 rounded-xl" />
                <Skeleton className="h-36 rounded-xl" />
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className="space-y-8">
          {CATEGORIES.map((cat) => {
            const rows = merged.filter((m) => m.catalog.category === cat.id)
            if (!rows.length) return null
            return (
              <div key={cat.id}>
                <div className="mb-4 flex items-center gap-2">
                  <cat.icon className="size-5 text-muted-foreground" />
                  <h3 className="font-medium">{cat.name}</h3>
                </div>
                <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                  {rows.map(({ catalog, integration }) => {
                    const sb = statusBadge(integration)
                    const isActive = integration?.status === 'active'
                    const hasRow = integration != null
                    const testingThis =
                      testMutation.isPending && testMutation.variables === integration?.id

                    return (
                      <Card
                        key={catalog.provider}
                        className={cn(
                          'transition-colors',
                          hasRow && integration?.status === 'active' && 'border-primary/40',
                          hasRow && integration?.status === 'error' && 'border-destructive/40',
                        )}
                      >
                        <CardHeader className="pb-2">
                          <div className="flex items-start justify-between gap-2">
                            <div className="flex items-start gap-3">
                              <div
                                className={cn(
                                  'flex size-10 shrink-0 items-center justify-center rounded-lg',
                                  hasRow ? 'bg-primary/15 text-primary' : 'bg-muted text-muted-foreground',
                                )}
                              >
                                <catalog.icon className="size-5" />
                              </div>
                              <div>
                                <CardTitle className="text-base">{catalog.title}</CardTitle>
                                <Badge variant={sb.variant} className="mt-1.5 text-[10px]">
                                  {sb.label}
                                </Badge>
                              </div>
                            </div>
                          </div>
                          <CardDescription className="pt-2 text-xs leading-relaxed">
                            {catalog.description}
                          </CardDescription>
                          {integration?.account_identifier ? (
                            <p className="text-[11px] text-muted-foreground">
                              Identificador:{' '}
                              <code className="rounded bg-muted px-1 py-0.5 text-[10px]">
                                {integration.account_identifier}
                              </code>
                            </p>
                          ) : null}
                          {integration?.provider === 'google' &&
                          integration.metadata &&
                          typeof integration.metadata.form_id === 'string' &&
                          integration.metadata.form_id ? (
                            <p className="text-[11px] text-muted-foreground">
                              Form ID (metadata):{' '}
                              <code className="rounded bg-muted px-1 py-0.5 text-[10px]">
                                {integration.metadata.form_id}
                              </code>
                            </p>
                          ) : null}
                          {integration?.last_sync_at ? (
                            <p className="text-[11px] text-muted-foreground">
                              Último sync:{' '}
                              {new Date(integration.last_sync_at).toLocaleString('es-CO', {
                                dateStyle: 'short',
                                timeStyle: 'short',
                              })}
                            </p>
                          ) : null}
                          {integration?.last_error_message ? (
                            <p className="text-[11px] text-destructive line-clamp-2">
                              {integration.last_error_message}
                            </p>
                          ) : null}
                        </CardHeader>
                        <CardContent className="flex flex-col gap-3 pt-0">
                          <div className="flex flex-wrap items-center gap-2">
                            {canMutate && (
                              <Button
                                size="sm"
                                variant={hasRow ? 'outline' : 'default'}
                                onClick={() => openDialog(catalog, integration)}
                              >
                                <Settings className="mr-2 size-4" />
                                {hasRow ? 'Editar credenciales' : 'Configurar'}
                              </Button>
                            )}
                            {canTest && hasRow && (
                              <Button
                                size="sm"
                                variant="secondary"
                                disabled={busy || testMutation.isPending}
                                onClick={() => testMutation.mutate(integration!.id)}
                              >
                                {testingThis ? (
                                  <Spinner className="mr-2 size-4" />
                                ) : (
                                  <Check className="mr-2 size-4" />
                                )}
                                Probar conexión
                              </Button>
                            )}
                          </div>

                          {canMutate && hasRow && (
                            <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 px-3 py-2">
                              <span className="text-xs text-muted-foreground">
                                Pausar sin borrar credenciales
                              </span>
                              <Switch
                                checked={isActive}
                                disabled={busy}
                                onCheckedChange={(checked) => {
                                  if (!integration) return
                                  if (checked) {
                                    activateMutation.mutate(integration.id)
                                  } else {
                                    disableMutation.mutate(integration.id)
                                  }
                                }}
                              />
                            </div>
                          )}

                          {!canMutate && (
                            <p className="text-[11px] text-muted-foreground">
                              Solo administradores pueden crear o editar credenciales. Como manager
                              puedes probar la conexión.
                            </p>
                          )}
                        </CardContent>
                      </Card>
                    )
                  })}
                </div>
              </div>
            )
          })}
        </div>
      )}

      <Dialog open={dialogOpen} onOpenChange={(open) => !open && setDialogOpen(false)}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {dialogIntegration ? 'Editar' : 'Configurar'}{' '}
              {dialogCatalog?.title ?? 'integración'}
            </DialogTitle>
            <DialogDescription>
              Datos reales hacia <code className="text-xs">/api/v1/ad_integrations</code>: credenciales cifradas,
              metadata fusionado en actualizaciones (p. ej. Form ID de Google). Sin mocks.
            </DialogDescription>
          </DialogHeader>

          {dialogCatalog && (
            <div className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="acct">{dialogCatalog.accountIdentifierLabel}</Label>
                <Input
                  id="acct"
                  value={accountIdentifier}
                  onChange={(e) => setAccountIdentifier(e.target.value)}
                  placeholder={dialogCatalog.accountIdentifierPlaceholder}
                />
                {dialogCatalog.accountIdentifierHint ? (
                  <p className="text-xs text-muted-foreground">{dialogCatalog.accountIdentifierHint}</p>
                ) : null}
              </div>
              {(dialogCatalog.metadataFields ?? []).map((field) => (
                <div key={`meta-${field.key}`} className="space-y-2">
                  <Label htmlFor={`meta-${field.key}`}>{field.label}</Label>
                  <Input
                    id={`meta-${field.key}`}
                    type={field.type === 'password' ? 'password' : 'text'}
                    value={metadataValues[field.key] ?? ''}
                    onChange={(e) =>
                      setMetadataValues((prev) => ({
                        ...prev,
                        [field.key]: e.target.value,
                      }))
                    }
                    placeholder={field.placeholder}
                    autoComplete="off"
                  />
                </div>
              ))}
              {dialogCatalog.credentialFields.map((field) => (
                <div key={field.key} className="space-y-2">
                  <Label htmlFor={field.key}>{field.label}</Label>
                  <Input
                    id={field.key}
                    type={field.type === 'password' ? 'password' : 'text'}
                    value={credentialValues[field.key] ?? ''}
                    onChange={(e) =>
                      setCredentialValues((prev) => ({
                        ...prev,
                        [field.key]: e.target.value,
                      }))
                    }
                    placeholder={field.placeholder}
                    autoComplete="off"
                  />
                </div>
              ))}
            </div>
          )}

          <DialogFooter className="flex-col gap-2 sm:flex-row sm:justify-between">
            <div>
              {dialogIntegration && canMutate && (
                <Button
                  type="button"
                  variant="destructive"
                  disabled={busy || destroyMutation.isPending}
                  onClick={() => {
                    setDialogOpen(false)
                    setConfirmDeleteIntegration(true)
                  }}
                >
                  Eliminar
                </Button>
              )}
            </div>
            <div className="flex gap-2">
              <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>
                Cancelar
              </Button>
              {canMutate && (
                <Button
                  type="button"
                  disabled={busy || saveMutation.isPending}
                  onClick={() => saveMutation.mutate()}
                >
                  {saveMutation.isPending && <Spinner className="mr-2 size-4" />}
                  Guardar
                </Button>
              )}
            </div>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* AlertDialog: confirmar eliminación de integración */}
      <AlertDialog
        open={confirmDeleteIntegration}
        onOpenChange={(open) => {
          setConfirmDeleteIntegration(open)
          if (!open && !destroyMutation.isSuccess) {
            setDialogOpen(true)
          }
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar integración?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminarán las credenciales de «{dialogCatalog?.title}» del tenant. Los webhooks existentes dejarán de funcionar. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90 text-destructive-foreground"
              onClick={() => dialogIntegration && destroyMutation.mutate(dialogIntegration.id)}
            >
              {destroyMutation.isPending ? <Spinner className="mr-2 size-4" /> : null}
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
