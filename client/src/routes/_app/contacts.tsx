import { createFileRoute, useSearch, useRouter } from '@tanstack/react-router'
import { useEffect, useMemo, useState } from 'react'
import { z } from 'zod'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Plus,
  Search,
  Building2,
  User,
  Mail,
  Phone,
  Briefcase,
  MoreHorizontal,
  ChevronLeft,
  ChevronRight,
  RefreshCw,
  Filter,
  Trash2,
  Upload,
  MessageCircle,
  MessageCircleOff,
  MailX,
} from 'lucide-react'
import { Checkbox } from '@/components/ui/checkbox'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
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
import { Skeleton } from '@/components/ui/skeleton'
import { toast } from 'sonner'
import { ContactSlideOver } from '@/components/contacts/ContactSlideOver'
import { ContactDialog } from '@/components/contacts/ContactDialog'
import { ContactImportDialog } from '@/components/contacts/ContactImportDialog'
import {
  ContactEditDialog,
  contactEditInitialFromSummary,
} from '@/components/contacts/ContactEditDialog'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAuthStore, useUser, useUserRole } from '@/stores/auth'
import api, { formatRailsError } from '@/lib/api'
import { ContactsQuickMetrics } from '@/components/contacts/ContactsQuickMetrics'
import {
  bulkDeleteContacts,
  bulkMarkWhatsappOptIn,
  bulkMarkWhatsappOptOut,
  bulkSetEmailOptOut,
  EMAIL_OPT_OUT_LABELS,
  contactListErrorMessage,
  deleteContact,
  fetchAllContacts,
  fetchContactsList,
  fetchContactStats,
  getCompanyLabel,
  type ContactSegment,
  type ContactWhatsappConsent,
  WHATSAPP_CONSENT_LABELS,
  type ContactSummary,
} from '@/lib/contactApi'
import { jsonApiPrimaryList, mapUserResource } from '@/lib/opportunityApi'
import { getAuthQueryScope, invalidateContactsQueries, queryKeys } from '@/lib/queryClient'
import { tenantHasModule } from '@/lib/tenantModules'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'

const contactsSearchSchema = z.object({
  selected: z.string().optional(),
  owner: z.string().optional(),
  segment: z.enum(['clients', 'prospects', 'hot_leads', 'stale']).optional(),
  consent: z.enum(['confirmed', 'opted_out', 'unconfirmed', 'none']).optional(),
})

export const Route = createFileRoute('/_app/contacts')({
  validateSearch: contactsSearchSchema,
  component: ContactsPage,
})

type ContactRow = ContactSummary

function ContactsPage() {
  const queryClient = useQueryClient()
  const tenant = useAuthStore((s) => s.tenant)
  const authScope = getAuthQueryScope()
  const hasContactsModule = tenantHasModule(tenant, 'contacts')
  const userRole = useUserRole()
  const currentUser = useUser()
  const searchFromUrl = useSearch({ from: '/_app/contacts' })
  const navigate = Route.useNavigate()
  const router = useRouter()
  const [searchInput, setSearchInput] = useState('')
  const [debouncedQ, setDebouncedQ] = useState('')
  const [activeTab, setActiveTab] = useState<'contacts' | 'companies'>('contacts')
  const selectedId = searchFromUrl.selected
  const [isCreateDialogOpen, setIsCreateDialogOpen] = useState(false)
  const [editingContact, setEditingContact] = useState<ContactRow | null>(null)
  const [isEditDialogOpen, setIsEditDialogOpen] = useState(false)
  const [currentPage, setCurrentPage] = useState(1)
  const [companyPage, setCompanyPage] = useState(1)
  const pageSize = 10
  const [confirmDeleteContact, setConfirmDeleteContact] = useState<ContactRow | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [confirmBulkDelete, setConfirmBulkDelete] = useState(false)
  const [confirmBulkOptIn, setConfirmBulkOptIn] = useState(false)
  const [confirmBulkOptOut, setConfirmBulkOptOut] = useState(false)
  const [importDialogOpen, setImportDialogOpen] = useState(false)
  const [selectingAllOptIn, setSelectingAllOptIn] = useState(false)

  const handleRefresh = async () => {
    setRefreshing(true)
    await invalidateContactsQueries(queryClient)
    setRefreshing(false)
  }

  const segmentLabels: Record<ContactSegment, string> = {
    clients: 'Clientes',
    prospects: 'Prospectos',
    hot_leads: 'Leads calientes',
    stale: 'Sin actividad',
  }

  const showOwnerFilter = userRole === 'admin' || userRole === 'manager'
  const canImportContacts =
    userRole === 'admin' || userRole === 'manager' || userRole === 'consultant'
  const canCreateContact = canImportContacts

  useEffect(() => {
    const t = window.setTimeout(() => setDebouncedQ(searchInput.trim()), 350)
    return () => window.clearTimeout(t)
  }, [searchInput])

  useEffect(() => {
    setCurrentPage(1)
    setCompanyPage(1)
  }, [debouncedQ, searchFromUrl.owner, searchFromUrl.segment, searchFromUrl.consent])

  const { data: contactStats, isLoading: statsLoading } = useQuery({
    queryKey: queryKeys.contacts.stats(authScope),
    queryFn: fetchContactStats,
    enabled: Boolean(authScope) && hasContactsModule,
    staleTime: 0,
    refetchOnWindowFocus: true,
  })

  const { data: users = [] } = useQuery({
    queryKey: queryKeys.users.all,
    queryFn: async () => {
      const response = await api.get('/users')
      return jsonApiPrimaryList(response.data)
        .filter((r) => r.id)
        .map(mapUserResource)
    },
    enabled: showOwnerFilter && Boolean(authScope),
    staleTime: 60_000,
  })

  const listFiltersPerson = useMemo(
    () => ({
      q: debouncedQ.length >= 2 ? debouncedQ : undefined,
      kind: 'person' as const,
      owner_id: searchFromUrl.owner,
      segment: searchFromUrl.segment,
      whatsapp_consent: searchFromUrl.consent,
      page: currentPage,
      items: pageSize,
    }),
    [debouncedQ, searchFromUrl.owner, searchFromUrl.segment, searchFromUrl.consent, currentPage],
  )

  const listFiltersCompany = useMemo(
    () => ({
      q: debouncedQ.length >= 2 ? debouncedQ : undefined,
      kind: 'company' as const,
      owner_id: searchFromUrl.owner,
      segment: searchFromUrl.segment,
      whatsapp_consent: searchFromUrl.consent,
      page: companyPage,
      items: pageSize,
    }),
    [debouncedQ, searchFromUrl.owner, searchFromUrl.segment, searchFromUrl.consent, companyPage],
  )

  const handleSegmentChange = (segment: ContactSegment | undefined) => {
    void navigate({ search: (prev) => ({ ...prev, segment }) })
  }

  const {
    data: contactsData,
    isLoading: isLoadingContacts,
    isError: contactsError,
    error: contactsQueryError,
    refetch: refetchContacts,
  } = useQuery({
    queryKey: queryKeys.contacts.list(authScope, listFiltersPerson),
    queryFn: () => fetchContactsList(listFiltersPerson),
    enabled: Boolean(authScope) && hasContactsModule,
    staleTime: 0,
    refetchOnWindowFocus: true,
  })

  const {
    data: companiesData,
    isLoading: isLoadingCompanies,
    isError: companiesError,
    error: companiesQueryError,
    refetch: refetchCompanies,
  } = useQuery({
    queryKey: queryKeys.contacts.list(authScope, listFiltersCompany),
    queryFn: () => fetchContactsList(listFiltersCompany),
    enabled: Boolean(authScope) && hasContactsModule && activeTab === 'companies',
    staleTime: 0,
    refetchOnWindowFocus: true,
  })

  const selectedPreview = useMemo(() => {
    if (!selectedId) return null
    return (
      contactsData?.contacts.find((c) => c.id === selectedId) ??
      companiesData?.contacts.find((c) => c.id === selectedId) ??
      null
    )
  }, [selectedId, contactsData, companiesData])

  const handleContactClick = (contact: ContactRow) => {
    void navigate({ search: (prev) => ({ ...prev, selected: contact.id }) })
  }

  const totalPages = contactsData?.totalPages ?? 1
  const companyTotalPages = companiesData?.totalPages ?? 1
  const canDeleteContacts = userRole === 'admin'
  const canManageWhatsappOptIn = userRole === 'admin' || userRole === 'manager'
  const canSelectContacts = canDeleteContacts || canManageWhatsappOptIn

  const canEditContact = (contact: ContactRow) => {
    if (userRole === 'viewer') return false
    if (contact.canEdit === true) return true
    if (userRole === 'admin' || userRole === 'manager') return true
    return String(contact.ownerId ?? '') === String(currentUser?.id ?? '')
  }

  const openEditDialog = (contact: ContactRow) => {
    if (!canEditContact(contact)) {
      toast.error('No tienes permiso para editar este contacto')
      return
    }
    setEditingContact(contact)
    setIsEditDialogOpen(true)
  }

  const deleteContactMutation = useMutation({
    mutationFn: async (contact: ContactRow) => deleteContact(contact.id),
    onSuccess: async () => {
      await invalidateContactsQueries(queryClient)
      toast.success('Contacto eliminado')
      setConfirmDeleteContact(null)
      void navigate({ search: (prev) => ({ ...prev, selected: undefined }) })
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudo eliminar el contacto'))
    },
  })

  const handleDeleteContact = (contact: ContactRow) => {
    if (!canDeleteContacts) {
      toast.error('Solo un administrador puede eliminar contactos')
      return
    }
    setConfirmDeleteContact(contact)
  }

  const bulkDeleteMutation = useMutation({
    mutationFn: () => bulkDeleteContacts(Array.from(selectedIds)),
    onSuccess: (result) => {
      toast.success(`${result.deleted} contacto(s) eliminado(s)`)
      setSelectedIds(new Set())
      setConfirmBulkDelete(false)
      void invalidateContactsQueries(queryClient)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudieron eliminar los contactos'))
    },
  })

  const bulkOptInMutation = useMutation({
    mutationFn: () => bulkMarkWhatsappOptIn(Array.from(selectedIds)),
    onSuccess: (result) => {
      toast.success(
        result.marked > 0
          ? `${result.marked} contacto(s) marcado(s) con opt-in de WhatsApp`
          : 'Los contactos seleccionados ya tenían opt-in',
      )
      if (result.skippedOptedOut > 0) {
        toast.info(`${result.skippedOptedOut} contacto(s) no autorizaron WhatsApp y se dejaron sin opt-in`)
      }
      setSelectedIds(new Set())
      setConfirmBulkOptIn(false)
      void invalidateContactsQueries(queryClient)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudo marcar el opt-in de WhatsApp'))
    },
  })

  const emailOptOutMutation = useMutation({
    mutationFn: ({ ids, optedOut }: { ids: string[]; optedOut: boolean }) => bulkSetEmailOptOut(ids, optedOut),
    onSuccess: (result, { optedOut }) => {
      if (optedOut) {
        toast.success('Listo: ya no recibirá campañas de correo')
      } else if (result.marked > 0) {
        toast.success('Listo: vuelve a recibir campañas de correo')
      } else {
        toast.error('No se puede reactivar: la baja la pidió el contacto o su correo rebotó')
      }
      void invalidateContactsQueries(queryClient)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudo actualizar la baja de correos'))
    },
  })

  const bulkOptOutMutation = useMutation({
    mutationFn: () => bulkMarkWhatsappOptOut(Array.from(selectedIds)),
    onSuccess: (result) => {
      toast.success(
        result.marked > 0
          ? `${result.marked} contacto(s) marcado(s) como "No autoriza WhatsApp"`
          : 'Los contactos seleccionados ya estaban marcados como "No autoriza"',
      )
      setSelectedIds(new Set())
      setConfirmBulkOptOut(false)
      void invalidateContactsQueries(queryClient)
    },
    onError: (err: unknown) => {
      toast.error(formatRailsError(err, 'No se pudo registrar que no autoriza WhatsApp'))
    },
  })

  const currentContacts = contactsData?.contacts ?? []
  const allOnPageSelected =
    currentContacts.length > 0 && currentContacts.every((c) => selectedIds.has(c.id))
  const someOnPageSelected = currentContacts.some((c) => selectedIds.has(c.id))

  const setContactSelected = (id: string, selected: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (selected) next.add(id)
      else next.delete(id)
      return next
    })
  }

  const setAllOnPageSelected = (selected: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      currentContacts.forEach((c) => {
        if (selected) next.add(c.id)
        else next.delete(c.id)
      })
      return next
    })
  }

  /** Trae TODOS los contactos que matchean los filtros activos (no solo la página
   * actual) y abre el diálogo de confirmación de opt-in ya con los que faltan
   * seleccionados — evita marcar opt-in de a 10 en 10. */
  const handleSelectAllWithoutOptIn = async () => {
    setSelectingAllOptIn(true)
    try {
      const all = await fetchAllContacts({
        q: listFiltersPerson.q,
        kind: 'person',
        owner_id: listFiltersPerson.owner_id,
        segment: listFiltersPerson.segment,
        whatsapp_consent: listFiltersPerson.whatsapp_consent,
      })
      const withoutOptIn = all.filter((c) => !c.whatsappOptedIn && !c.whatsappOptedOut).map((c) => c.id)
      if (withoutOptIn.length === 0) {
        toast.info('Todos los contactos (con los filtros actuales) ya tienen opt-in de WhatsApp')
        return
      }
      setSelectedIds(new Set(withoutOptIn))
      setConfirmBulkOptIn(true)
    } catch (err) {
      toast.error(formatRailsError(err, 'No se pudieron cargar los contactos'))
    } finally {
      setSelectingAllOptIn(false)
    }
  }


  if (!hasContactsModule) {
    return (
      <AppPageShell>
        <PageHeader
          title="Contactos"
          description="El módulo de contactos no está activo en la configuración de este tenant."
        />
      </AppPageShell>
    )
  }

  return (
    <AppPageShell contentClassName="gap-8">
      <PageHeader
        title="Contactos"
        description={
          userRole === 'consultant'
            ? 'Tus contactos y los vinculados a tus oportunidades. Puedes importar desde Excel (RFC §6.7).'
            : 'Solo datos del contacto. Pipeline, temperatura y valor en Oportunidades.'
        }
      >
        <Button
          size="sm"
          variant="outline"
          className="gap-1.5"
          onClick={handleRefresh}
          disabled={refreshing}
          title="Actualizar contactos"
        >
          <RefreshCw className={`size-3.5 ${refreshing ? 'animate-spin' : ''}`} />
          <span className="hidden sm:inline">Actualizar</span>
        </Button>
        {canManageWhatsappOptIn && activeTab === 'contacts' && (
          <Button
            size="sm"
            variant="outline"
            className="gap-1.5"
            onClick={() => void handleSelectAllWithoutOptIn()}
            disabled={selectingAllOptIn}
            title="Marca opt-in de WhatsApp a todos los contactos que coinciden con el filtro actual, sin límite de página"
          >
            <MessageCircle className={`size-3.5 ${selectingAllOptIn ? 'animate-pulse' : ''}`} />
            <span className="hidden sm:inline">
              {selectingAllOptIn ? 'Buscando...' : 'Marcar opt-in a todos'}
            </span>
          </Button>
        )}
        {canImportContacts && (
          <>
            <Button
              size="sm"
              variant="outline"
              className="gap-1.5"
              onClick={() => setImportDialogOpen(true)}
              title="Importar contactos desde Excel"
            >
              <Upload className="size-3.5" />
              <span className="hidden sm:inline">Importar</span>
            </Button>
            {canCreateContact && (
              <Button size="sm" className="shadow-sm" onClick={() => setIsCreateDialogOpen(true)}>
                <Plus className="mr-2 h-4 w-4" />
                Nuevo contacto
              </Button>
            )}
          </>
        )}
      </PageHeader>

      <ContactsQuickMetrics
        stats={contactStats}
        activeSegment={searchFromUrl.segment}
        isLoading={statsLoading}
        onSegmentChange={handleSegmentChange}
      />

      {searchFromUrl.segment && (
        <p className="text-sm text-muted-foreground -mt-4">
          Filtrando por: <span className="font-medium text-foreground">{segmentLabels[searchFromUrl.segment]}</span>
          {searchFromUrl.segment === 'stale' && contactStats?.stale_days != null && (
            <span> (sin actividad hace más de {contactStats.stale_days} días)</span>
          )}
          <button
            type="button"
            className="ml-2 text-primary hover:underline"
            onClick={() => handleSegmentChange(undefined)}
          >
            Quitar filtro
          </button>
        </p>
      )}

      {/* Tabs */}
      <Tabs value={activeTab} onValueChange={(v) => setActiveTab(v as 'contacts' | 'companies')}>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <TabsList>
            <TabsTrigger value="contacts" className="gap-2">
              <User className="h-4 w-4" />
              Contactos
            </TabsTrigger>
            <TabsTrigger value="companies" className="gap-2">
              <Building2 className="h-4 w-4" />
              Empresas
            </TabsTrigger>
          </TabsList>

          <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto">
            <Select
              value={searchFromUrl.consent ?? '__all__'}
              onValueChange={(v) =>
                navigate({
                  search: (prev) => ({
                    ...prev,
                    consent: v === '__all__' ? undefined : (v as ContactWhatsappConsent),
                  }),
                })
              }
            >
              <SelectTrigger className="h-9 min-w-0 flex-1 text-sm sm:w-[190px] sm:flex-none" aria-label="Consentimiento WhatsApp">
                <SelectValue placeholder="WhatsApp" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__all__">WhatsApp: todos</SelectItem>
                {(Object.keys(WHATSAPP_CONSENT_LABELS) as ContactWhatsappConsent[]).map((key) => (
                  <SelectItem key={key} value={key}>
                    {WHATSAPP_CONSENT_LABELS[key]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {showOwnerFilter && (
              <Select
                value={searchFromUrl.owner ?? '__all__'}
                onValueChange={(v) =>
                  navigate({ search: (prev) => ({ ...prev, owner: v === '__all__' ? undefined : v }) })
                }
              >
                <SelectTrigger className="h-9 min-w-0 flex-1 text-sm sm:w-[150px] sm:flex-none" aria-label="Consultor">
                  <SelectValue placeholder="Consultor" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__all__">Todos</SelectItem>
                  {users.map((u) => (
                    <SelectItem key={u.id} value={u.id}>
                      {u.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
            {searchFromUrl.owner && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-9 text-xs gap-1"
                onClick={() => navigate({ search: (prev) => ({ ...prev, owner: undefined }) })}
              >
                <Filter className="size-3" />
                Limpiar filtro
              </Button>
            )}
            <div className="relative w-full sm:w-auto">
              <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                placeholder="Buscar (mín. 2 letras)..."
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
                className="w-full pl-9 sm:w-64"
              />
            </div>
          </div>
        </div>

        <TabsContent value="contacts" className="mt-4">
          {/* Barra de acción masiva */}
          {selectedIds.size > 0 && canSelectContacts && (
            <div className="mb-2 flex items-center gap-3 rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-2">
              <span className="text-sm font-medium">
                {selectedIds.size} contacto(s) seleccionado(s)
              </span>
              {canManageWhatsappOptIn && (
                <Button
                  size="sm"
                  variant="outline"
                  className="gap-1.5"
                  onClick={() => setConfirmBulkOptIn(true)}
                >
                  <MessageCircle className="size-3.5" />
                  Marcar opt-in WhatsApp
                </Button>
              )}
              {canManageWhatsappOptIn && (
                <Button
                  size="sm"
                  variant="outline"
                  className="gap-1.5"
                  onClick={() => setConfirmBulkOptOut(true)}
                >
                  <MessageCircleOff className="size-3.5" />
                  No autoriza WhatsApp
                </Button>
              )}
              {canDeleteContacts && (
                <Button
                  size="sm"
                  variant="destructive"
                  className={canManageWhatsappOptIn ? 'gap-1.5' : 'ml-auto gap-1.5'}
                  onClick={() => setConfirmBulkDelete(true)}
                >
                  <Trash2 className="size-3.5" />
                  Eliminar seleccionados
                </Button>
              )}
              <Button
                size="sm"
                variant="ghost"
                className={canManageWhatsappOptIn && !canDeleteContacts ? 'ml-auto' : undefined}
                onClick={() => setSelectedIds(new Set())}
              >
                Cancelar
              </Button>
            </div>
          )}

          <Card>
            <CardContent className="p-0">
              {contactsError ? (
                <div className="p-6 space-y-3">
                  <p className="text-sm text-destructive">
                    {contactListErrorMessage(contactsQueryError)}
                  </p>
                  <Button type="button" variant="outline" size="sm" onClick={() => void refetchContacts()}>
                    Reintentar
                  </Button>
                </div>
              ) : isLoadingContacts ? (
                <ContactsTableSkeleton />
              ) : (
                <>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        {canSelectContacts && (
                          <TableHead className="w-10">
                            <Checkbox
                              checked={
                                allOnPageSelected
                                  ? true
                                  : someOnPageSelected
                                    ? 'indeterminate'
                                    : false
                              }
                              onCheckedChange={(checked) =>
                                setAllOnPageSelected(checked === true)
                              }
                              onClick={(e) => e.stopPropagation()}
                              aria-label="Seleccionar todos"
                            />
                          </TableHead>
                        )}
                        <TableHead>Nombre</TableHead>
                        <TableHead className="hidden md:table-cell">Email</TableHead>
                        <TableHead className="hidden md:table-cell">Telefono</TableHead>
                        <TableHead className="hidden md:table-cell">Empresa</TableHead>
                        <TableHead className="hidden md:table-cell">Cargo</TableHead>
                        <TableHead className="hidden md:table-cell">Origen</TableHead>
                        <TableHead>WhatsApp</TableHead>
                        <TableHead className="w-10"></TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(contactsData?.contacts.length ?? 0) === 0 ? (
                        <TableRow>
                          <TableCell
                            colSpan={canSelectContacts ? 9 : 8}
                            className="h-32 text-center text-sm text-muted-foreground"
                          >
                            {debouncedQ.length >= 2 || searchFromUrl.owner || searchFromUrl.segment
                              ? 'No hay contactos con los filtros aplicados.'
                              : 'No hay contactos registrados. Crea el primero con «Nuevo contacto».'}
                          </TableCell>
                        </TableRow>
                      ) : null}
                      {contactsData?.contacts.map((contact) => (
                        <TableRow
                          key={contact.id}
                          className={selectedIds.has(contact.id) ? 'bg-muted/40 cursor-pointer' : 'cursor-pointer'}
                          onClick={() => handleContactClick(contact)}
                        >
                          {canSelectContacts && (
                            <TableCell
                              className="w-10"
                              onClick={(e) => e.stopPropagation()}
                            >
                              <Checkbox
                                checked={selectedIds.has(contact.id)}
                                onCheckedChange={(checked) =>
                                  setContactSelected(contact.id, checked === true)
                                }
                                onClick={(e) => e.stopPropagation()}
                                aria-label={`Seleccionar ${contact.fullName}`}
                              />
                            </TableCell>
                          )}
                          <TableCell className="whitespace-normal md:whitespace-nowrap">
                            <span className="font-medium">{contact.fullName}</span>
                            {contact.phone && (
                              <span className="block text-xs text-muted-foreground md:hidden">{contact.phone}</span>
                            )}
                          </TableCell>
                          <TableCell className="hidden md:table-cell">
                            <div className="flex items-center gap-2 text-muted-foreground">
                              <Mail className="h-3 w-3" />
                              {contact.email}
                              {contact.emailOptedOut && (
                                <Badge
                                  className="gap-1 bg-amber-500/10 text-amber-700 hover:bg-amber-500/10 text-xs dark:text-amber-300"
                                  title={
                                    contact.emailOptOutSource
                                      ? EMAIL_OPT_OUT_LABELS[contact.emailOptOutSource]
                                      : 'No recibe campañas de correo'
                                  }
                                >
                                  <MailX className="size-3" />
                                  Sin correos
                                </Badge>
                              )}
                            </div>
                          </TableCell>
                          <TableCell className="hidden md:table-cell">
                            <div className="flex items-center gap-2 text-muted-foreground">
                              <Phone className="h-3 w-3" />
                              {contact.phone}
                            </div>
                          </TableCell>
                          <TableCell className="hidden md:table-cell">
                            <div className="flex items-center gap-2">
                              <Building2 className="h-3 w-3 text-muted-foreground" />
                              {getCompanyLabel(contact.company)}
                            </div>
                          </TableCell>
                          <TableCell className="hidden md:table-cell">
                            <div className="flex items-center gap-2">
                              <Briefcase className="h-3 w-3 text-muted-foreground" />
                              {contact.position ?? '-'}
                            </div>
                          </TableCell>
                          <TableCell className="hidden md:table-cell">
                            {contact.sourceLabel ? (
                              <Badge variant="outline" className="text-xs">
                                {contact.sourceLabel}
                              </Badge>
                            ) : (
                              <span className="text-xs text-muted-foreground">—</span>
                            )}
                          </TableCell>
                          <TableCell>
                            {contact.whatsappOptedOut ? (
                              <Badge
                                className="gap-1 bg-destructive/10 text-destructive hover:bg-destructive/10 text-xs"
                                title={
                                  contact.whatsappOptOutAt
                                    ? `No autorizó WhatsApp el ${new Date(contact.whatsappOptOutAt).toLocaleDateString('es-CO')}`
                                    : 'No autorizó WhatsApp'
                                }
                              >
                                <MessageCircleOff className="size-3" />
                                No autorizó
                              </Badge>
                            ) : contact.whatsappOptedIn && contact.whatsappOptInSource === 'reply_confirm' ? (
                              <Badge
                                className="gap-1 bg-green-600/15 text-green-700 hover:bg-green-600/15 text-xs"
                                title={
                                  contact.whatsappOptInAt
                                    ? `Confirmó "Sí" por WhatsApp el ${new Date(contact.whatsappOptInAt).toLocaleDateString('es-CO')}`
                                    : 'Confirmó "Sí" por WhatsApp'
                                }
                              >
                                <MessageCircle className="size-3" />
                                Confirmó Sí
                              </Badge>
                            ) : contact.whatsappOptedIn ? (
                              <Badge className="gap-1 bg-green-600/10 text-green-700 hover:bg-green-600/10 text-xs">
                                <MessageCircle className="size-3" />
                                Opt-in
                              </Badge>
                            ) : (
                              <span className="text-xs text-muted-foreground">Sin opt-in</span>
                            )}
                          </TableCell>
                          <TableCell>
                            <DropdownMenu>
                              <DropdownMenuTrigger asChild onClick={(e) => e.stopPropagation()}>
                                <Button variant="ghost" size="icon" className="h-8 w-8">
                                  <MoreHorizontal className="h-4 w-4" />
                                </Button>
                              </DropdownMenuTrigger>
                              <DropdownMenuContent align="end">
                                {canEditContact(contact) && (
                                  <DropdownMenuItem
                                    onClick={(e) => {
                                      e.stopPropagation()
                                      openEditDialog(contact)
                                    }}
                                  >
                                    Editar
                                  </DropdownMenuItem>
                                )}
                                <DropdownMenuItem
                                  onClick={(e) => {
                                    e.stopPropagation()
                                    void router.navigate({
                                      to: '/opportunities',
                                      search: { view: 'table', contact: contact.id },
                                    })
                                  }}
                                >
                                  Ir a Oportunidades
                                </DropdownMenuItem>
                                {canManageWhatsappOptIn && !contact.whatsappOptedIn && !contact.whatsappOptedOut && (
                                  <DropdownMenuItem
                                    onClick={(e) => {
                                      e.stopPropagation()
                                      setSelectedIds(new Set([contact.id]))
                                      setConfirmBulkOptIn(true)
                                    }}
                                  >
                                    Marcar opt-in WhatsApp
                                  </DropdownMenuItem>
                                )}
                                {canManageWhatsappOptIn && !contact.whatsappOptedOut && (
                                  <DropdownMenuItem
                                    onClick={(e) => {
                                      e.stopPropagation()
                                      setSelectedIds(new Set([contact.id]))
                                      setConfirmBulkOptOut(true)
                                    }}
                                  >
                                    No autoriza WhatsApp
                                  </DropdownMenuItem>
                                )}
                                {canManageWhatsappOptIn && contact.email && !contact.emailOptedOut && (
                                  <DropdownMenuItem
                                    onClick={(e) => {
                                      e.stopPropagation()
                                      emailOptOutMutation.mutate({ ids: [contact.id], optedOut: true })
                                    }}
                                  >
                                    No quiere correos
                                  </DropdownMenuItem>
                                )}
                                {canManageWhatsappOptIn && contact.emailOptOutSource === 'manual' && (
                                  <DropdownMenuItem
                                    onClick={(e) => {
                                      e.stopPropagation()
                                      emailOptOutMutation.mutate({ ids: [contact.id], optedOut: false })
                                    }}
                                  >
                                    Reactivar correos
                                  </DropdownMenuItem>
                                )}
                                {canDeleteContacts && (
                                  <DropdownMenuItem
                                    className="text-destructive"
                                    onClick={(e) => {
                                      e.stopPropagation()
                                      handleDeleteContact(contact)
                                    }}
                                  >
                                    Eliminar
                                  </DropdownMenuItem>
                                )}
                              </DropdownMenuContent>
                            </DropdownMenu>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>

                  {/* Pagination */}
                  <div className="flex items-center justify-between border-t px-4 py-3">
                    <p className="text-sm text-muted-foreground">
                      Mostrando {((currentPage - 1) * pageSize) + 1} - {Math.min(currentPage * pageSize, contactsData?.total ?? 0)} de {contactsData?.total ?? 0} contactos
                    </p>
                    <div className="flex items-center gap-2">
                      <Button 
                        variant="outline" 
                        size="sm"
                        disabled={currentPage === 1}
                        onClick={() => setCurrentPage(p => p - 1)}
                      >
                        <ChevronLeft className="h-4 w-4" />
                      </Button>
                      <span className="text-sm">
                        Pagina {currentPage} de {totalPages}
                      </span>
                      <Button 
                        variant="outline" 
                        size="sm"
                        disabled={currentPage === totalPages}
                        onClick={() => setCurrentPage(p => p + 1)}
                      >
                        <ChevronRight className="h-4 w-4" />
                      </Button>
                    </div>
                  </div>
                </>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="companies" className="mt-4">
          <Card>
            <CardContent className="p-0">
              {companiesError ? (
                <div className="p-6 space-y-3">
                  <p className="text-sm text-destructive">
                    {contactListErrorMessage(companiesQueryError)}
                  </p>
                  <Button type="button" variant="outline" size="sm" onClick={() => void refetchCompanies()}>
                    Reintentar
                  </Button>
                </div>
              ) : isLoadingCompanies ? (
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 p-4">
                  {Array.from({ length: 6 }).map((_, i) => (
                    <Card key={i}>
                      <CardHeader>
                        <Skeleton className="h-6 w-32" />
                        <Skeleton className="h-4 w-24" />
                      </CardHeader>
                      <CardContent>
                        <Skeleton className="h-4 w-full" />
                        <Skeleton className="h-4 w-3/4 mt-2" />
                      </CardContent>
                    </Card>
                  ))}
                </div>
              ) : (
                <>
                  <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 p-4">
                    {(companiesData?.contacts.length ?? 0) === 0 ? (
                      <div className="col-span-full flex flex-col items-center justify-center py-12 text-center text-sm text-muted-foreground">
                        <Building2 className="size-10 mb-3 opacity-50" />
                        <p>No hay empresas registradas con los filtros actuales.</p>
                      </div>
                    ) : (
                      companiesData?.contacts.map((company) => {
                        const secondaryLine = company.sourceLabel?.trim()
                          ? `Origen: ${company.sourceLabel.trim()}`
                          : [company.city, company.country].filter(Boolean).join(', ') ||
                            (company.email && company.email !== '-' ? company.email : '')
                        return (
                          <Card
                            key={company.id}
                            role="button"
                            tabIndex={0}
                            className="hover:border-primary/50 cursor-pointer transition-colors"
                            onClick={() => handleContactClick(company)}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter' || e.key === ' ') {
                                e.preventDefault()
                                handleContactClick(company)
                              }
                            }}
                          >
                            <CardHeader className="pb-2">
                              <div className="flex items-start justify-between gap-2">
                                <div className="flex items-center gap-3 min-w-0">
                                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary/10">
                                    <Building2 className="h-5 w-5 text-primary" />
                                  </div>
                                  <div className="min-w-0">
                                    <CardTitle className="text-base truncate">{company.fullName}</CardTitle>
                                    {secondaryLine ? (
                                      <p className="text-sm text-muted-foreground truncate" title={secondaryLine}>
                                        {secondaryLine}
                                      </p>
                                    ) : null}
                                  </div>
                                </div>
                                <DropdownMenu>
                                  <DropdownMenuTrigger asChild onClick={(e) => e.stopPropagation()}>
                                    <Button variant="ghost" size="icon" className="h-8 w-8 shrink-0">
                                      <MoreHorizontal className="h-4 w-4" />
                                    </Button>
                                  </DropdownMenuTrigger>
                                  <DropdownMenuContent align="end">
                                    {canEditContact(company) && (
                                      <DropdownMenuItem
                                        onClick={(e) => {
                                          e.stopPropagation()
                                          openEditDialog(company)
                                        }}
                                      >
                                        Editar
                                      </DropdownMenuItem>
                                    )}
                                    {canDeleteContacts && (
                                      <DropdownMenuItem
                                        className="text-destructive"
                                        onClick={(e) => {
                                          e.stopPropagation()
                                          handleDeleteContact(company)
                                        }}
                                      >
                                        Eliminar
                                      </DropdownMenuItem>
                                    )}
                                  </DropdownMenuContent>
                                </DropdownMenu>
                              </div>
                            </CardHeader>
                            <CardContent>
                              <div className="flex flex-wrap gap-2">
                                <Badge variant="secondary">Empresa</Badge>
                              </div>
                            </CardContent>
                          </Card>
                        )
                      })
                    )}
                  </div>

                  {(companiesData?.contacts.length ?? 0) > 0 && (
                    <div className="flex items-center justify-between border-t px-4 py-3">
                      <p className="text-sm text-muted-foreground">
                        Mostrando {(companyPage - 1) * pageSize + 1} -{' '}
                        {Math.min(companyPage * pageSize, companiesData?.total ?? 0)} de{' '}
                        {companiesData?.total ?? 0} empresas
                      </p>
                      <div className="flex items-center gap-2">
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={companyPage === 1}
                          onClick={() => setCompanyPage((p) => p - 1)}
                        >
                          <ChevronLeft className="h-4 w-4" />
                        </Button>
                        <span className="text-sm">
                          Página {companyPage} de {companyTotalPages}
                        </span>
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={companyPage >= companyTotalPages}
                          onClick={() => setCompanyPage((p) => p + 1)}
                        >
                          <ChevronRight className="h-4 w-4" />
                        </Button>
                      </div>
                    </div>
                  )}
                </>
              )}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      {/* Contact Slide Over */}
      <ContactSlideOver
        contactId={selectedId}
        contactPreview={selectedPreview}
        open={!!selectedId}
        onOpenChange={(open) => {
          if (!open) void navigate({ search: (prev) => ({ ...prev, selected: undefined }) })
        }}
        onEdit={(c) => {
          if (canEditContact(c)) openEditDialog(c)
        }}
        canEdit={selectedPreview ? canEditContact(selectedPreview) : false}
        onDelete={canDeleteContacts ? (c) => handleDeleteContact(c) : undefined}
        canDelete={canDeleteContacts}
      />

      {/* Create Contact Dialog */}
      <ContactImportDialog open={importDialogOpen} onOpenChange={setImportDialogOpen} />

      <ContactDialog
        open={isCreateDialogOpen}
        onOpenChange={setIsCreateDialogOpen}
        onCreated={() => {
          setCurrentPage(1)
          setSearchInput('')
          setDebouncedQ('')
        }}
      />

      <AlertDialog
        open={confirmBulkDelete}
        onOpenChange={(o) => { if (!o) setConfirmBulkDelete(false) }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Eliminar {selectedIds.size} contacto(s)</AlertDialogTitle>
            <AlertDialogDescription>
              Esta acción no se puede deshacer. Se eliminarán también las oportunidades vinculadas a estos contactos.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90"
              onClick={() => bulkDeleteMutation.mutate()}
            >
              Eliminar {selectedIds.size} contacto(s)
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog
        open={confirmBulkOptIn}
        onOpenChange={(o) => { if (!o) setConfirmBulkOptIn(false) }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Marcar opt-in de WhatsApp — {selectedIds.size} contacto(s)</AlertDialogTitle>
            <AlertDialogDescription>
              Confirma que estos contactos dieron su consentimiento para recibir mensajes de
              WhatsApp por un medio verificado fuera del sistema (cliente existente, permiso
              presencial o telefónico, etc). No marques opt-in sin ese consentimiento real: Meta
              puede restringir o banear el número de WhatsApp si detecta envíos sin permiso.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction onClick={() => bulkOptInMutation.mutate()}>
              Confirmar opt-in
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog
        open={confirmBulkOptOut}
        onOpenChange={(o) => { if (!o) setConfirmBulkOptOut(false) }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>No autoriza WhatsApp — {selectedIds.size} contacto(s)</AlertDialogTitle>
            <AlertDialogDescription>
              Registra que estos contactos dijeron que NO quieren recibir mensajes de WhatsApp (por
              teléfono, email, en persona…). Se les quita el opt-in y quedan fuera de todas las
              campañas, incluidas las de solicitud de autorización. Solo vuelven a quedar habilitados
              si ellos mismos responden "Sí" por WhatsApp.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction onClick={() => bulkOptOutMutation.mutate()}>
              Registrar "No autoriza"
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog
        open={!!confirmDeleteContact}
        onOpenChange={(o) => { if (!o) setConfirmDeleteContact(null) }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Eliminar contacto</AlertDialogTitle>
            <AlertDialogDescription>
              ¿Eliminar a <strong>{confirmDeleteContact?.fullName}</strong>? Esta acción no se puede deshacer y eliminará también sus oportunidades vinculadas.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90"
              onClick={() => { if (confirmDeleteContact) deleteContactMutation.mutate(confirmDeleteContact) }}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <ContactEditDialog
        contactId={editingContact?.id ?? null}
        initialData={editingContact ? contactEditInitialFromSummary(editingContact) : undefined}
        open={isEditDialogOpen}
        onOpenChange={(open) => {
          setIsEditDialogOpen(open)
          if (!open) setEditingContact(null)
        }}
        onSaved={(updated) => {
          if (editingContact?.id === updated.id) {
            setEditingContact(updated)
          }
        }}
      />
    </AppPageShell>
  )
}

function ContactsTableSkeleton() {
  return (
    <div className="p-4 space-y-4">
      {Array.from({ length: 5 }).map((_, i) => (
        <div key={i} className="flex items-center gap-4">
          <Skeleton className="h-8 w-8 rounded-full" />
          <Skeleton className="h-4 w-32" />
          <Skeleton className="h-4 w-40" />
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-16" />
        </div>
      ))}
    </div>
  )
}
