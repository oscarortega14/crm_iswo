import { useEffect, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { CheckCircle2, Clock, Copy, RefreshCw, ShieldCheck, XCircle } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Spinner } from '@/components/ui/spinner'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatRailsError } from '@/lib/api'
import {
  emailQueryKeys,
  refreshEmailSender,
  updateEmailSender,
  verifyEmailSender,
  type EmailSender,
  type EmailSenderStatus,
} from '@/lib/emailMarketingApi'

const STATUS: Record<EmailSenderStatus, { label: string; className: string; icon: typeof Clock }> = {
  not_started: { label: 'Sin verificar', className: 'bg-muted text-muted-foreground', icon: Clock },
  pending: { label: 'Esperando los registros DNS', className: 'bg-amber-500/10 text-amber-700 dark:text-amber-300', icon: Clock },
  verified: { label: 'Verificado', className: 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300', icon: CheckCircle2 },
  failed: { label: 'Falló la verificación', className: 'bg-destructive/10 text-destructive', icon: XCircle },
}

/**
 * Remitente de las campañas: dominio propio de la empresa verificado en AWS
 * SES. El admin lo edita; el manager solo lo consulta.
 */
export function EmailSenderPanel({ sender, canEdit }: { sender: EmailSender; canEdit: boolean }) {
  const queryClient = useQueryClient()
  const [form, setForm] = useState({
    domain: sender.domain ?? '',
    from_local: sender.fromLocal,
    from_name: sender.fromName,
    reply_to: sender.replyTo ?? '',
    address: sender.address ?? '',
  })

  useEffect(() => {
    setForm({
      domain: sender.domain ?? '',
      from_local: sender.fromLocal,
      from_name: sender.fromName,
      reply_to: sender.replyTo ?? '',
      address: sender.address ?? '',
    })
  }, [sender.domain, sender.fromLocal, sender.fromName, sender.replyTo, sender.address])

  const setSender = (next: EmailSender) => queryClient.setQueryData(emailQueryKeys.sender(), next)

  const saveMutation = useMutation({
    mutationFn: () => updateEmailSender(form),
    onSuccess: (next) => {
      setSender(next)
      toast.success('Remitente guardado')
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo guardar el remitente')),
  })

  const verifyMutation = useMutation({
    mutationFn: async () => {
      await updateEmailSender(form)
      return verifyEmailSender()
    },
    onSuccess: (next) => {
      setSender(next)
      toast.success(
        next.status === 'verified' ? '¡Dominio verificado!' : 'Listo: ahora agrega los registros DNS de abajo',
      )
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo iniciar la verificación')),
  })

  const refreshMutation = useMutation({
    mutationFn: refreshEmailSender,
    onSuccess: (next) => {
      setSender(next)
      if (next.status === 'verified') toast.success('¡Dominio verificado! Ya puedes enviar campañas.')
      else toast.info('Todavía no se ven los registros. El DNS puede tardar desde minutos hasta 72 horas.')
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo consultar el estado')),
  })

  const status = STATUS[sender.status]
  const StatusIcon = status.icon
  const busy = saveMutation.isPending || verifyMutation.isPending || refreshMutation.isPending
  const domainChanged = (sender.domain ?? '') !== form.domain.trim().toLowerCase()

  const copy = (text: string) => {
    void navigator.clipboard?.writeText(text)
    toast.success('Copiado')
  }

  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2 text-base">
            Remitente de las campañas
            <Badge className={`gap-1 border-0 ${status.className}`}>
              <StatusIcon className="size-3" />
              {status.label}
            </Badge>
          </CardTitle>
          <CardDescription>
            Los correos salen desde el dominio de tu empresa. Así llegan a la bandeja de entrada y no a spam.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="senderDomain">Dominio</Label>
            <Input
              id="senderDomain"
              value={form.domain}
              onChange={(e) => setForm((f) => ({ ...f, domain: e.target.value }))}
              placeholder="iswo.com.co"
              disabled={!canEdit}
            />
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="senderLocal">Correo que envía</Label>
              <div className="flex items-center gap-1">
                <Input
                  id="senderLocal"
                  value={form.from_local}
                  onChange={(e) => setForm((f) => ({ ...f, from_local: e.target.value }))}
                  placeholder="info"
                  disabled={!canEdit}
                />
                <span className="shrink-0 text-sm text-muted-foreground">@{form.domain || 'dominio'}</span>
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="senderName">Nombre que ve el cliente</Label>
              <Input
                id="senderName"
                value={form.from_name}
                onChange={(e) => setForm((f) => ({ ...f, from_name: e.target.value }))}
                placeholder="ISWO"
                disabled={!canEdit}
              />
            </div>
          </div>
          <div className="space-y-2">
            <Label htmlFor="senderReply">Las respuestas llegan a (opcional)</Label>
            <Input
              id="senderReply"
              type="email"
              value={form.reply_to}
              onChange={(e) => setForm((f) => ({ ...f, reply_to: e.target.value }))}
              placeholder="ventas@iswo.com.co"
              disabled={!canEdit}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="senderAddress">Dirección física (va al pie del correo)</Label>
            <Input
              id="senderAddress"
              value={form.address}
              onChange={(e) => setForm((f) => ({ ...f, address: e.target.value }))}
              placeholder="Calle 00 # 00-00, Bogotá, Colombia"
              disabled={!canEdit}
            />
          </div>

          {canEdit ? (
            <div className="flex flex-col gap-2 sm:flex-row">
              <Button variant="outline" onClick={() => saveMutation.mutate()} disabled={busy}>
                {saveMutation.isPending && <Spinner className="mr-2" />}
                Guardar
              </Button>
              {(sender.status === 'not_started' || domainChanged) && (
                <Button onClick={() => verifyMutation.mutate()} disabled={busy || !form.domain.trim()}>
                  {verifyMutation.isPending ? <Spinner className="mr-2" /> : <ShieldCheck className="mr-2 size-4" />}
                  Verificar dominio
                </Button>
              )}
            </div>
          ) : (
            <p className="text-xs text-muted-foreground">Solo un administrador puede cambiar el remitente.</p>
          )}

          {!sender.trackingEnabled && (
            <p className="rounded-md bg-muted/50 px-3 py-2 text-xs text-muted-foreground">
              Aún no está activo el seguimiento de AWS (entregas, rebotes, aperturas y clics). Los envíos funcionan,
              pero los resultados solo mostrarán «Enviado» hasta que se active.
            </p>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Registros DNS</CardTitle>
          <CardDescription>
            Quien administra el dominio (GoDaddy, Cloudflare, Hostinger…) debe crear estos registros una sola vez.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          {sender.dnsRecords.length === 0 ? (
            <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
              Escribe el dominio y pulsa «Verificar dominio» para ver los registros.
            </p>
          ) : (
            <>
              <ul className="space-y-2">
                {sender.dnsRecords.map((r) => (
                  <li key={r.name} className="space-y-1.5 rounded-md border p-3 text-xs">
                    <div className="flex items-center justify-between gap-2">
                      <Badge variant="outline">{r.type}</Badge>
                      <span className="text-muted-foreground">
                        {r.purpose === 'dkim' ? 'Firma DKIM (obligatorio)' : 'DMARC (recomendado)'}
                      </span>
                    </div>
                    <DnsValue label="Nombre / Host" value={r.name} onCopy={copy} />
                    <DnsValue label="Valor / Apunta a" value={r.value} onCopy={copy} />
                  </li>
                ))}
              </ul>
              {sender.status !== 'verified' && (
                <Button
                  variant="outline"
                  className="w-full"
                  onClick={() => refreshMutation.mutate()}
                  disabled={busy || !canEdit}
                >
                  {refreshMutation.isPending ? <Spinner className="mr-2" /> : <RefreshCw className="mr-2 size-4" />}
                  Ya los agregué, comprobar
                </Button>
              )}
              {sender.checkedAt && (
                <p className="text-center text-[11px] text-muted-foreground">
                  Última comprobación: {new Date(sender.checkedAt).toLocaleString('es-CO')}
                </p>
              )}
            </>
          )}
        </CardContent>
      </Card>
    </div>
  )
}

function DnsValue({ label, value, onCopy }: { label: string; value: string; onCopy: (v: string) => void }) {
  return (
    <div className="flex items-center gap-2">
      <div className="min-w-0 flex-1">
        <p className="text-[11px] text-muted-foreground">{label}</p>
        <p className="break-all font-mono">{value}</p>
      </div>
      <Button variant="ghost" size="icon" className="size-7 shrink-0" onClick={() => onCopy(value)} aria-label={`Copiar ${label}`}>
        <Copy className="size-3.5" />
      </Button>
    </div>
  )
}
