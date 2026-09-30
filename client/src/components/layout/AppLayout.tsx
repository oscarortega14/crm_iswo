import { useState, useEffect, useMemo, useRef } from 'react'
import { Link, useLocation, useRouter } from '@tanstack/react-router'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Menu,
  X,
  Search,
  Moon,
  Sun,
  LogOut,
  ChevronDown,
  UserRound,
  Building2,
  MoreHorizontal,
} from 'lucide-react'
import { TenantLogoMark } from '@/components/brand/TenantLogoMark'
import { resolveKnownBrandSlug } from '@/lib/tenantBrand'
import { useTenant, useUser } from '@/stores/auth'
import { useTheme } from '@/components/common/ThemeProvider'
import {
  getAuthQueryScope,
  queryKeys,
} from '@/lib/queryClient'
import { logoutSession } from '@/lib/authSession'
import { fetchDuplicateFlagsStats } from '@/lib/duplicateFlagsApi'
import { fetchReminderStats } from '@/lib/reminderApi'
import { fetchConversationStats } from '@/lib/whatsappInboxApi'
import {
  isNewInboundMessage,
  playNewMessageSound,
  unlockAudioOnFirstInteraction,
} from '@/lib/notificationSound'
import { tenantHasModule } from '@/lib/tenantModules'
import { canUseReminders } from '@/lib/reminderChannels'
import { filterMainNav, getSidebarSections, MAIN_NAV_ITEMS } from '@/lib/settingsNav'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Separator } from '@/components/ui/separator'
import { CommandPalette } from '@/components/common/CommandPalette'
import { NotificationDropdown } from '@/components/common/NotificationDropdown'
import { PageAmbientBackground } from '@/components/layout/PageAmbientBackground'
import { UserProfileDialog } from '@/components/common/UserProfileDialog'

interface AppLayoutProps {
  children: React.ReactNode
}

const MOBILE_PRIMARY_COUNT = 4

export function AppLayout({ children }: AppLayoutProps) {
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [commandOpen, setCommandOpen] = useState(false)
  const [profileOpen, setProfileOpen] = useState(false)
  const [logoBroken, setLogoBroken] = useState(false)
  const location = useLocation()
  const { setTheme, resolvedTheme } = useTheme()
  const user = useUser()
  const tenant = useTenant()
  const router = useRouter()

  useEffect(() => {
    setLogoBroken(false)
  }, [tenant?.logo_url, tenant?.subdomain])

  const logout = () => {
    logoutSession()
    void router.navigate({ to: '/login', replace: true })
  }

  const authScope = getAuthQueryScope()
  const hasRemindersModule = tenantHasModule(tenant, 'reminders')
  const canUseRemindersModule = hasRemindersModule && canUseReminders(user?.role)
  const hasOpportunities = tenantHasModule(tenant, 'opportunities')
  const canPollDuplicateStats =
    user?.role === 'admin' || user?.role === 'manager' || user?.role === 'consultant'

  const { data: reminderStats } = useQuery({
    queryKey: queryKeys.reminders.stats(authScope),
    queryFn: fetchReminderStats,
    enabled: Boolean(authScope) && canUseRemindersModule,
    refetchInterval: 60_000,
    refetchOnWindowFocus: true,
  })
  const pendingRemindersCount = reminderStats?.pending

  const { data: duplicateStats } = useQuery({
    queryKey: queryKeys.duplicateFlags.stats(authScope),
    queryFn: fetchDuplicateFlagsStats,
    enabled: Boolean(authScope) && hasOpportunities && canPollDuplicateStats,
    refetchInterval: 60_000,
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: true,
  })

  // WhatsApp: consulta liviana cada 10 s en TODA la app (también con la pestaña
  // en segundo plano). Cuando llega un mensaje entrante nuevo suena el aviso y se
  // refresca la bandeja/los hilos abiertos — la bandeja ya no recarga la lista
  // completa en cada poll.
  const queryClient = useQueryClient()
  const { data: inboxStats } = useQuery({
    queryKey: queryKeys.whatsappConversations.stats(authScope),
    queryFn: fetchConversationStats,
    enabled: Boolean(authScope),
    refetchInterval: 10_000,
    refetchIntervalInBackground: true,
    refetchOnWindowFocus: true,
  })

  useEffect(() => {
    unlockAudioOnFirstInteraction()
  }, [])

  const lastInboundIdRef = useRef<number | null | undefined>(undefined)
  useEffect(() => {
    if (!inboxStats) return
    const latest = inboxStats.latestInboundId
    const previous = lastInboundIdRef.current
    lastInboundIdRef.current = latest
    if (!isNewInboundMessage(previous, latest)) return
    playNewMessageSound()
    void queryClient.invalidateQueries({
      queryKey: queryKeys.whatsappConversations.all,
      predicate: (q) => q.queryKey[1] !== 'stats',
    })
    void queryClient.invalidateQueries({ queryKey: queryKeys.opportunities.all, predicate: (q) => q.queryKey[1] === 'messages' })
  }, [inboxStats, queryClient])

  const mainNavBase = useMemo(
    () => filterMainNav(MAIN_NAV_ITEMS, user?.role, tenant),
    [user?.role, tenant],
  )

  const navItemsWithBadges = useMemo(
    () =>
      mainNavBase.map((item) => ({
        ...item,
        badge:
          item.href === '/reminders'
            ? pendingRemindersCount
            : item.href === '/duplicates'
              ? duplicateStats?.pending
              : item.href === '/whatsapp'
                ? inboxStats?.unread
                : undefined,
      })),
    [mainNavBase, pendingRemindersCount, duplicateStats?.pending, inboxStats?.unread],
  )

  const sidebar = useMemo(
    () => getSidebarSections(user?.role, tenant),
    [user?.role, tenant],
  )
  const platformTenant = sidebar.isPlatform

  const mobileNavItems = useMemo(() => {
    if (platformTenant) {
      return sidebar.sections.flatMap((section) =>
        section.items.map((item) => ({
          href: item.href,
          label: item.label,
          icon: item.icon,
          badge: undefined as number | undefined,
        })),
      )
    }
    return navItemsWithBadges
  }, [platformTenant, sidebar.sections, navItemsWithBadges])

  const mobilePrimary = mobileNavItems.slice(0, MOBILE_PRIMARY_COUNT)
  const mobileMore = mobileNavItems.slice(MOBILE_PRIMARY_COUNT)

  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.key === 'k' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        setCommandOpen((open) => !open)
      }
    }
    document.addEventListener('keydown', down)
    return () => document.removeEventListener('keydown', down)
  }, [])

  // Esc cierra el menú lateral.
  useEffect(() => {
    if (!sidebarOpen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setSidebarOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [sidebarOpen])

  useEffect(() => {
    setSidebarOpen(false)
  }, [location.pathname])

  const renderNavLink = (
    item: (typeof navItemsWithBadges)[number],
    onNavigate?: () => void,
  ) => {
    const isActive = location.pathname === item.href
    return (
      <Link
        key={item.href}
        to={item.href}
        onClick={onNavigate}
        className={cn(
          'flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
          isActive
            ? 'bg-sidebar-accent text-sidebar-accent-foreground'
            : 'text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground',
        )}
      >
        <item.icon className="size-4 shrink-0" />
        <span className="truncate">{item.label}</span>
        {item.badge !== undefined && item.badge > 0 && (
          <Badge variant="destructive" className="ml-auto h-5 min-w-5 px-1.5 text-xs">
            {item.badge}
          </Badge>
        )}
      </Link>
    )
  }

  return (
    <div className="flex h-screen overflow-hidden bg-background">
      {sidebarOpen && (
        <div
          className="fixed inset-0 z-40 bg-black/50"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Menú lateral: oculto por defecto en todas las pantallas; se abre con «Menú». */}
      <aside
        id="app-sidebar"
        aria-label="Menú principal"
        aria-hidden={!sidebarOpen}
        inert={!sidebarOpen}
        className={cn(
          'fixed inset-y-0 left-0 z-50 flex w-60 min-h-0 flex-col overflow-hidden border-r bg-sidebar shadow-xl transition-transform duration-200',
          sidebarOpen ? 'translate-x-0' : '-translate-x-full',
        )}
      >
        <div className="flex h-14 shrink-0 items-center gap-2 border-b px-4">
          <Link
            to={platformTenant ? '/settings/tenant-onboarding' : '/'}
            className="flex min-w-0 flex-1 items-center gap-2 rounded-md outline-none ring-sidebar-ring focus-visible:ring-2"
            onClick={() => setSidebarOpen(false)}
          >
          {tenant?.logo_url && !logoBroken ? (
            <img
              src={tenant.logo_url}
              alt={tenant.name}
              className="h-8 w-auto max-w-[120px] object-contain"
              loading="eager"
              decoding="async"
              onError={() => setLogoBroken(true)}
            />
          ) : resolveKnownBrandSlug(tenant) ? (
            <TenantLogoMark tenant={tenant} size="sm" />
          ) : (
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-primary text-primary-foreground">
              <Building2 className="size-4" />
            </div>
          )}
          <div className="min-w-0 flex-1">
            <span className="block font-semibold text-sidebar-foreground truncate">
              {tenant?.name || 'CRM ISWO'}
            </span>
            {platformTenant && (
              <span className="block text-[10px] font-medium uppercase tracking-wider text-muted-foreground truncate">
                Consola de plataforma
              </span>
            )}
          </div>
          </Link>
          <Button
            variant="ghost"
            size="icon-sm"
            className="ml-auto"
            onClick={() => setSidebarOpen(false)}
            aria-label="Cerrar menú"
          >
            <X className="size-4" />
          </Button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden overscroll-contain">
          <nav className="flex flex-col gap-1 px-3 py-4 pb-6">
            {navItemsWithBadges.map((item) => renderNavLink(item))}

            {sidebar.sections.map((section) => (
              <div key={section.label}>
                {(navItemsWithBadges.length > 0 || section !== sidebar.sections[0]) && (
                  <Separator className="my-3" />
                )}
                <span className="px-3 py-2 text-xs font-medium text-muted-foreground uppercase tracking-wider">
                  {section.label}
                </span>
                {section.items.map((item) => {
                  const isActive = location.pathname === item.href
                  return (
                    <Link
                      key={item.href}
                      to={item.href}
                      className={cn(
                        'flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
                        isActive
                          ? 'bg-sidebar-accent text-sidebar-accent-foreground'
                          : 'text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground',
                      )}
                    >
                      <item.icon className="size-4 shrink-0" />
                      <span className="truncate">{item.label}</span>
                    </Link>
                  )
                })}
              </div>
            ))}
          </nav>
        </div>

        <div className="shrink-0 border-t p-3">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button className="flex w-full items-center gap-3 rounded-md px-2 py-1.5 text-sm hover:bg-sidebar-accent transition-colors">
                <div className="flex-1 text-left truncate">
                  <p className="font-medium text-sidebar-foreground truncate">{user?.name}</p>
                  <p className="text-xs text-muted-foreground truncate">{user?.email}</p>
                </div>
                <ChevronDown className="size-4 text-muted-foreground" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-56">
              <DropdownMenuItem onClick={() => setProfileOpen(true)}>
                <UserRound className="size-4 mr-2" />
                Mi perfil
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => setTheme(resolvedTheme === 'dark' ? 'light' : 'dark')}>
                {resolvedTheme === 'dark' ? (
                  <>
                    <Sun className="size-4 mr-2" />
                    Modo claro
                  </>
                ) : (
                  <>
                    <Moon className="size-4 mr-2" />
                    Modo oscuro
                  </>
                )}
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={logout} className="text-destructive focus:text-destructive">
                <LogOut className="size-4 mr-2" />
                Cerrar sesión
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </aside>

      <div className="flex flex-1 flex-col overflow-hidden">
        <header className="flex h-14 items-center gap-4 border-b bg-background px-4">
          <Button
            variant="ghost"
            className="h-9 gap-2 px-2 lg:px-3"
            onClick={() => setSidebarOpen(true)}
            aria-label="Abrir menú"
            aria-controls="app-sidebar"
            aria-expanded={sidebarOpen}
          >
            <Menu className="size-5" />
            <span className="hidden text-sm font-medium lg:inline">Menú</span>
          </Button>

          <button
            onClick={() => setCommandOpen(true)}
            className="flex flex-1 items-center gap-2 rounded-md border bg-muted/50 px-3 py-1.5 text-sm text-muted-foreground max-w-md hover:bg-muted transition-colors"
          >
            <Search className="size-4" />
            <span className="hidden sm:inline">Buscar...</span>
            <kbd className="ml-auto hidden rounded border bg-background px-1.5 py-0.5 text-xs font-mono sm:inline">
              ⌘K
            </kbd>
          </button>

          <div className="flex items-center gap-2">
            <NotificationDropdown />
          </div>
        </header>

        <main className="relative flex-1 overflow-auto pb-16 lg:pb-0">
          <PageAmbientBackground />
          {children}
        </main>
      </div>

      <CommandPalette open={commandOpen} onOpenChange={setCommandOpen} />
      <UserProfileDialog open={profileOpen} onOpenChange={setProfileOpen} />

      <nav className="fixed bottom-0 left-0 right-0 z-40 flex h-16 items-center justify-around border-t bg-background lg:hidden">
        {mobilePrimary.map((item) => {
          const isActive = location.pathname === item.href
          return (
            <Link
              key={item.href}
              to={item.href}
              className={cn(
                'flex flex-col items-center gap-1 px-2 py-2 min-w-0 flex-1',
                isActive ? 'text-primary' : 'text-muted-foreground',
              )}
            >
              <div className="relative">
                <item.icon className="size-5" />
                {item.badge !== undefined && item.badge > 0 && (
                  <span className="absolute -right-1.5 -top-1.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] text-white">
                    {item.badge}
                  </span>
                )}
              </div>
              <span className="text-[10px] truncate max-w-full">{item.label.split(' ')[0]}</span>
            </Link>
          )
        })}
        {mobileMore.length > 0 && (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                type="button"
                className={cn(
                  'flex flex-col items-center gap-1 px-2 py-2 min-w-0 flex-1',
                  mobileMore.some((i) => location.pathname === i.href)
                    ? 'text-primary'
                    : 'text-muted-foreground',
                )}
              >
                <MoreHorizontal className="size-5" />
                <span className="text-[10px]">Más</span>
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-52 mb-2">
              {mobileMore.map((item) => (
                <DropdownMenuItem key={item.href} asChild>
                  <Link to={item.href} className="flex items-center gap-2">
                    <item.icon className="size-4" />
                    {item.label}
                    {item.badge !== undefined && item.badge > 0 && (
                      <Badge variant="destructive" className="ml-auto h-5 min-w-5 px-1 text-xs">
                        {item.badge}
                      </Badge>
                    )}
                  </Link>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </nav>
    </div>
  )
}
