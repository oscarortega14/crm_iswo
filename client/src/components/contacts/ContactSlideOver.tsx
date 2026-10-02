import { originDetail, originKindLabel } from '@/lib/contactOrigins'
import {
  Mail,
  Phone,
  Building2,
  Briefcase,
  MapPin,
  Edit,
  Trash2,
  ExternalLink,
  CreditCard,
  StickyNote,
  Radio,
  Globe,
  FileText,
} from 'lucide-react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Separator } from '@/components/ui/separator'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { ContactActionButtons } from '@/components/opportunities/ContactActionButtons'
import {
  fetchContactDetail,
  getCompanyLabel,
  type ContactLandingOrigin,
  type ContactSummary,
} from '@/lib/contactApi'
import { queryKeys } from '@/lib/queryClient'
import { cn, formatRelativeTime } from '@/lib/utils'

interface ContactSlideOverProps {
  contactId?: string
  contactPreview?: ContactSummary | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onEdit?: (contact: ContactSummary) => void
  onDelete?: (contact: ContactSummary) => void
  canEdit?: boolean
  canDelete?: boolean
}

export function ContactSlideOver({
  contactId,
  contactPreview,
  open,
  onOpenChange,
  onEdit,
  onDelete,
  canEdit = true,
  canDelete = false,
}: ContactSlideOverProps) {
  const navigate = useNavigate()

  const { data: contactDetail, isLoading: detailLoading } = useQuery({
    queryKey: queryKeys.contacts.detail(contactId || ''),
    queryFn: () => fetchContactDetail(contactId!),
    enabled: open && !!contactId,
    staleTime: 0,
  })

  const contact = contactDetail ?? contactPreview ?? null

  if (!open || !contactId) return null

  if (!contact && detailLoading) {
    return (
      <Sheet open={open} onOpenChange={onOpenChange}>
        <SheetContent className="w-full sm:max-w-lg p-6">
          <Skeleton className="h-16 w-16 rounded-full mb-4" />
          <Skeleton className="h-6 w-48 mb-2" />
          <Skeleton className="h-32 w-full" />
        </SheetContent>
      </Sheet>
    )
  }

  if (!contact) return null

  const email = contact.email !== '-' ? contact.email : undefined
  const phone = contact.phone !== '-' ? contact.phone : undefined

  const goToOpportunities = () => {
    onOpenChange(false)
    void navigate({
      to: '/opportunities',
      search: { view: 'kanban', contact: contact.id },
    })
  }

  const createOpportunityForContact = () => {
    onOpenChange(false)
    void navigate({
      to: '/opportunities',
      search: { view: 'kanban', contact: contact.id, add: true },
    })
  }

  const openLandingLeads = (origin: ContactLandingOrigin) => {
    onOpenChange(false)
    void navigate({
      to: '/opportunities',
      search: {
        view: 'kanban',
        landing: origin.landing_page_id,
        ...(origin.opportunity_id ? { selected: origin.opportunity_id } : {}),
      },
    })
  }

  const landingOrigins = contact.landingOrigins ?? []

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full sm:max-w-lg p-0">
        <SheetHeader className="p-6 pb-0">
          <div className="flex items-start justify-between">
            <div>
                <SheetTitle className="text-xl">{contact.fullName}</SheetTitle>
                {contact.position !== '-' && (
                  <p className="text-sm text-muted-foreground">{contact.position}</p>
                )}
                <div className="flex gap-1 mt-2 flex-wrap">
                  <Badge variant="secondary" className="text-xs">
                    {contact.kind === 'company' ? 'Empresa' : 'Persona'}
                  </Badge>
                  {contact.sourceLabel ? (
                    <Badge variant="outline" className="text-xs">
                      {contact.sourceLabel}
                    </Badge>
                  ) : null}
                </div>
            </div>
          </div>

          {(canEdit || canDelete) && (
            <div className="flex gap-2 mt-4">
              {canEdit && (
                <Button variant="outline" size="sm" className="flex-1" onClick={() => onEdit?.(contact)}>
                  <Edit className="mr-2 h-4 w-4" />
                  Editar contacto
                </Button>
              )}
              {canDelete && (
                <Button
                  variant="outline"
                  size="sm"
                  className={cn('text-destructive hover:text-destructive', !canEdit && 'flex-1')}
                  onClick={() => onDelete?.(contact)}
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              )}
            </div>
          )}
        </SheetHeader>

        <Separator className="my-4" />

        <ScrollArea className="h-[calc(100vh-220px)]">
          <div className="px-6 space-y-6 pb-6">
            {(phone || email) && (
              <div>
                <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-2">
                  Contactar
                </h3>
                <ContactActionButtons phone={phone} email={email} />
              </div>
            )}

            <div className="space-y-4">
              <h3 className="text-sm font-medium text-foreground">Información del contacto</h3>
              <div className="space-y-3">
                {email && (
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                      <Mail className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">Email</p>
                      <a href={`mailto:${email}`} className="text-sm hover:underline">
                        {email}
                      </a>
                    </div>
                  </div>
                )}

                {phone && (
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                      <Phone className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">Teléfono</p>
                      <a href={`tel:${phone}`} className="text-sm hover:underline font-mono">
                        {phone}
                      </a>
                    </div>
                  </div>
                )}

                {getCompanyLabel(contact.company) !== '-' && (
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                      <Building2 className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">
                        {contact.kind === 'company' ? 'Razón social' : 'Empresa'}
                      </p>
                      <p className="text-sm">{getCompanyLabel(contact.company)}</p>
                    </div>
                  </div>
                )}

                {contact.position !== '-' && contact.kind !== 'company' && (
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                      <Briefcase className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">Cargo</p>
                      <p className="text-sm">{contact.position}</p>
                    </div>
                  </div>
                )}

                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                    <MapPin className="h-4 w-4 text-muted-foreground" />
                  </div>
                  <div>
                    <p className="text-xs text-muted-foreground">Ubicación</p>
                    <p className="text-sm">
                      {[contact.city, contact.country].filter(Boolean).join(', ') || 'Sin datos'}
                    </p>
                  </div>
                </div>

                {contact.documentId && (
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                      <CreditCard className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">
                        {contact.kind === 'company' ? 'NIT' : 'Cédula'}
                      </p>
                      <p className="text-sm font-mono">{contact.documentId}</p>
                    </div>
                  </div>
                )}

                {(contact.origins?.length || contact.sourceLabel) && (
                  <div className="flex items-start gap-3">
                    <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted">
                      <Radio className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div className="min-w-0">
                      <p className="text-xs text-muted-foreground">
                        {(contact.origins?.length ?? 0) > 1 ? 'Orígenes del lead' : 'Origen del lead'}
                      </p>
                      {contact.origins?.length ? (
                        <ul className="space-y-0.5">
                          {contact.origins.map((o, i) => (
                            <li key={`${o.kind}-${o.label ?? ''}-${i}`} className="text-sm">
                              <span className="font-medium">{originKindLabel(o.kind)}</span>
                              {originDetail(o) && <span className="text-muted-foreground"> · {originDetail(o)}</span>}
                              {o.at && (
                                <span className="text-xs text-muted-foreground"> · {formatRelativeTime(o.at)}</span>
                              )}
                            </li>
                          ))}
                        </ul>
                      ) : (
                        <p className="text-sm">{contact.sourceLabel}</p>
                      )}
                    </div>
                  </div>
                )}

                {contact.lastContactedAt && (
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted">
                      <Phone className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">Último contacto</p>
                      <p className="text-sm">{formatRelativeTime(contact.lastContactedAt)}</p>
                    </div>
                  </div>
                )}

                {contact.notes && (
                  <div className="flex items-start gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted mt-0.5">
                      <StickyNote className="h-4 w-4 text-muted-foreground" />
                    </div>
                    <div>
                      <p className="text-xs text-muted-foreground">Notas</p>
                      <p className="text-sm whitespace-pre-wrap">{contact.notes}</p>
                    </div>
                  </div>
                )}
              </div>
            </div>

            {landingOrigins.length > 0 && (
              <>
                <Separator />
                <div className="space-y-2">
                  <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide flex items-center gap-1.5">
                    <Globe className="size-3.5" />
                    Envíos desde landings
                  </p>
                  <ul className="space-y-2">
                    {landingOrigins.map((origin) => (
                      <li
                        key={origin.id}
                        className="rounded-md border border-emerald-500/20 bg-emerald-500/5 px-3 py-2 text-sm"
                      >
                        <p className="font-medium truncate">
                          {origin.landing_title || origin.landing_slug || 'Landing'}
                        </p>
                        {origin.created_at && (
                          <p className="text-xs text-muted-foreground mt-0.5">
                            {formatRelativeTime(origin.created_at)}
                          </p>
                        )}
                        <Button
                          type="button"
                          variant="link"
                          className="h-auto p-0 mt-1 text-xs"
                          onClick={() => openLandingLeads(origin)}
                        >
                          <FileText className="size-3 mr-1 inline" />
                          Ver lead en Oportunidades
                        </Button>
                      </li>
                    ))}
                  </ul>
                </div>
              </>
            )}

            <Separator />
            <div className="space-y-2">
              <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                Oportunidades
              </p>
              {(contact.opportunitiesCount ?? 0) > 0 ? (
                <Button
                  type="button"
                  variant="outline"
                  className="w-full gap-2"
                  onClick={goToOpportunities}
                >
                  <ExternalLink className="size-4" />
                  Ver en Oportunidades
                  <span className="ml-auto text-xs font-mono tabular-nums">
                    ({contact.opportunitiesCount})
                  </span>
                </Button>
              ) : (
                <p className="text-sm text-muted-foreground">
                  Este contacto aún no tiene leads en el pipeline. Créalo desde el botón de abajo.
                </p>
              )}
              <Button
                type="button"
                className="w-full gap-2"
                onClick={createOpportunityForContact}
              >
                <ExternalLink className="size-4" />
                {contact.opportunitiesCount > 0
                  ? 'Agregar otra oportunidad'
                  : 'Agregar a Oportunidades'}
              </Button>
            </div>
          </div>
        </ScrollArea>
      </SheetContent>
    </Sheet>
  )
}
