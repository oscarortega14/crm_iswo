import { createFileRoute, Link } from '@tanstack/react-router'
import { requireRole } from '@/lib/authGuards'
import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  Plus,
  Calendar,
  Clock,
  Bell,
  CheckCircle2,
  Circle,
  AlertCircle,
  MoreHorizontal,
  Filter,
  Briefcase,
  RefreshCw,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Checkbox } from '@/components/ui/checkbox'
import { Skeleton } from '@/components/ui/skeleton'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { ReminderDialog } from '@/components/reminders/ReminderDialog'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { formatRailsError } from '@/lib/api'
import {
  completeReminder,
  deleteReminder,
  fetchReminderStats,
  fetchRemindersList,
  reopenReminder,
  reminderListErrorMessage,
  snoozeReminder,
  type ReminderListFilters,
  type ReminderSummary,
} from '@/lib/reminderApi'
import { formatDate, cn } from '@/lib/utils'
import { getAuthQueryScope, invalidateReminderDashboardQueries, queryKeys } from '@/lib/queryClient'
import { tenantHasModule } from '@/lib/tenantModules'
import { useAuthStore } from '@/stores/auth'
import { toast } from 'sonner'

export const Route = createFileRoute('/_app/reminders')({
  beforeLoad: () => requireRole('admin', 'manager', 'consultant'),
  component: RemindersPage,
})

import {
  canUseReminders,
  reminderChannelLabel,
} from '@/lib/reminderChannels'
import { statGridClass } from '@/lib/layoutClasses'

const groupOrder = ['Atrasados', 'Hoy', 'Manana', 'Proximos']

function groupReminder(reminder: ReminderSummary): string {
  const date = new Date(reminder.remindAt)
  const today = new Date()
  const tomorrow = new Date(today)
  tomorrow.setDate(tomorrow.getDate() + 1)
  if (date.toDateString() === today.toDateString()) return 'Hoy'
  if (date.toDateString() === tomorrow.toDateString()) return 'Manana'
  if (date < today && !reminder.completed) return 'Atrasados'
  if (date < today) return 'Atrasados'
  return 'Proximos'
}

function isOverdue(remindAt: string, completed: boolean) {
  return !completed && new Date(remindAt) < new Date()
}

function RemindersPage() {
  const queryClient = useQueryClient()
  const tenant = useAuthStore((s) => s.tenant)
  const user = useAuthStore((s) => s.user)
  const authScope = getAuthQueryScope()
  const hasRemindersModule = tenantHasModule(tenant, 'reminders')
  const canAccess = hasRemindersModule && canUseReminders(user?.role)
  const [isCreateDialogOpen, setIsCreateDialogOpen] = useState(false)
  const [filter, setFilter] = useState<'all' | 'pending' | 'completed'>('pending')
  const [refreshing, setRefreshing] = useState(false)

  const listFilters = useMemo((): ReminderListFilters => {
    const base: ReminderListFilters = { items: 200 }
    if (filter === 'pending') return { ...base, status: 'pending' }
    if (filter === 'completed') return { ...base, status: 'done' }
    return base
  }, [filter])

  const {
    data: listData,
    isLoading,
    isError,
    error,
  } = useQuery({
    queryKey: queryKeys.reminders.list(authScope, listFilters),
    queryFn: () => fetchRemindersList(listFilters),
    enabled: Boolean(authScope) && canAccess,
    staleTime: 0,
    refetchOnWindowFocus: true,
  })

  const { data: stats } = useQuery({
    queryKey: queryKeys.reminders.stats(authScope),
    queryFn: fetchReminderStats,
    enabled: Boolean(authScope) && canAccess,
    staleTime: 0,
    refetchOnWindowFocus: true,
  })

  const reminders = listData?.reminders ?? []

  const groupedReminders = reminders.reduce(
    (acc, r) => {
      const group = groupReminder(r)
      if (!acc[group]) acc[group] = []
      acc[group].push(r)
      return acc
    },
    {} as Record<string, ReminderSummary[]>,
  )

  const invalidate = async () => {
    await invalidateReminderDashboardQueries(queryClient)
  }

  const handleRefresh = async () => {
    setRefreshing(true)
    await invalidate()
    setRefreshing(false)
  }

  const snoozeMutation = useMutation({
    mutationFn: ({ id, minutes }: { id: string; minutes: number }) => snoozeReminder(id, minutes),
    onSuccess: () => {
      void invalidate()
      toast.success('Recordatorio pospuesto')
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo posponer el recordatorio')),
  })

  const toggleCompleteMutation = useMutation({
    mutationFn: async ({ id, completed }: { id: string; completed: boolean }) => {
      if (completed) await completeReminder(id)
      else await reopenReminder(id)
      return { id, completed }
    },
    onSuccess: (data) => {
      void invalidate()
      toast.success(data.completed ? 'Recordatorio completado' : 'Recordatorio reabierto')
    },
    onError: (err: unknown) =>
      toast.error(formatRailsError(err, 'No se pudo actualizar el recordatorio')),
  })

  const deleteMutation = useMutation({
    mutationFn: deleteReminder,
    onSuccess: () => {
      void invalidate()
      toast.success('Recordatorio eliminado')
    },
    onError: (err: unknown) => toast.error(formatRailsError(err, 'No se pudo eliminar el recordatorio')),
  })

  const getStatusBadge = (status: string) => {
    switch (status) {
      case 'done':
        return <Badge variant="success">Completado</Badge>
      case 'failed':
        return <Badge variant="destructive">Fallido</Badge>
      case 'sent':
        return (
          <Badge className="border border-primary/25 bg-primary/12 text-primary dark:border-primary/35 dark:bg-primary/18">
            Enviado
          </Badge>
        )
      default:
        return <Badge variant="secondary">Pendiente</Badge>
    }
  }

  const pendingCount = stats?.pending ?? reminders.filter((r) => !r.completed).length
  const overdueCount =
    stats?.overdue ?? reminders.filter((r) => !r.completed && isOverdue(r.remindAt, r.completed)).length
  const todayCount = stats?.today ?? 0
  const completedCount = stats?.done ?? reminders.filter((r) => r.completed).length

  if (!hasRemindersModule) {
    return (
      <AppPageShell>
        <PageHeader
          title="Recordatorios"
          description="El módulo de recordatorios no está activo en la configuración de este tenant."
        />
      </AppPageShell>
    )
  }

  if (!canAccess) {
    return (
      <AppPageShell>
        <PageHeader
          title="Recordatorios"
          description="Los recordatorios están disponibles solo para administradores, managers y consultores."
        />
      </AppPageShell>
    )
  }

  return (
    <AppPageShell contentClassName="gap-8">
      <PageHeader title="Recordatorios" description="Gestiona tus tareas y recordatorios">
        <Button
          size="sm"
          variant="outline"
          className="gap-1.5"
          onClick={() => void handleRefresh()}
          disabled={refreshing}
          title="Actualizar recordatorios"
        >
          <RefreshCw className={`size-3.5 ${refreshing ? 'animate-spin' : ''}`} />
          <span className="hidden sm:inline">Actualizar</span>
        </Button>
        <Button size="sm" className="shadow-sm" onClick={() => setIsCreateDialogOpen(true)}>
          <Plus className="mr-2 h-4 w-4" />
          Nuevo recordatorio
        </Button>
      </PageHeader>

      <div className={`${statGridClass} md:grid-cols-4`}>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10">
                <Bell className="h-5 w-5 text-primary" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{pendingCount}</p>
                <p className="text-xs text-muted-foreground">Pendientes</p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-red-100">
                <AlertCircle className="h-5 w-5 text-red-500" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{overdueCount}</p>
                <p className="text-xs text-muted-foreground">Atrasados</p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-amber-100">
                <Clock className="h-5 w-5 text-amber-500" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{todayCount}</p>
                <p className="text-xs text-muted-foreground">Para hoy</p>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/15">
                <CheckCircle2 className="h-5 w-5 text-primary" />
              </div>
              <div>
                <p className="text-2xl font-semibold">{completedCount}</p>
                <p className="text-xs text-muted-foreground">Completados</p>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="flex items-center gap-2">
        <Button
          variant={filter === 'pending' ? 'default' : 'outline'}
          size="sm"
          onClick={() => setFilter('pending')}
        >
          <Circle className="mr-2 h-4 w-4" />
          Pendientes
        </Button>
        <Button
          variant={filter === 'completed' ? 'default' : 'outline'}
          size="sm"
          onClick={() => setFilter('completed')}
        >
          <CheckCircle2 className="mr-2 h-4 w-4" />
          Completados
        </Button>
        <Button
          variant={filter === 'all' ? 'default' : 'outline'}
          size="sm"
          onClick={() => setFilter('all')}
        >
          Todos
        </Button>
      </div>

      {isError && (
        <Card className="border-destructive/40">
          <CardContent className="py-6 text-center text-sm text-destructive">
            {reminderListErrorMessage(error)}
          </CardContent>
        </Card>
      )}

      {isLoading ? (
        <RemindersSkeleton />
      ) : (
        <div className="space-y-6">
          {groupOrder.map((group) => {
            const items = groupedReminders[group]
            if (!items?.length) return null

            return (
              <div key={group}>
                <h2
                  className={cn(
                    'text-sm font-medium mb-3',
                    group === 'Atrasados' ? 'text-red-500' : 'text-muted-foreground',
                  )}
                >
                  {group} ({items.length})
                </h2>
                <div className="space-y-2">
                  {items.map((reminder) => (
                    <Card
                      key={reminder.id}
                      className={cn('transition-colors', reminder.completed && 'opacity-60')}
                    >
                      <CardContent className="p-4">
                        <div className="flex items-start gap-3">
                          <Checkbox
                            checked={reminder.completed}
                            onCheckedChange={(checked) => {
                              toggleCompleteMutation.mutate({
                                id: reminder.id,
                                completed: checked as boolean,
                              })
                            }}
                            className="mt-1"
                          />
                          <div className="flex-1 min-w-0">
                            <div className="flex items-start justify-between gap-2">
                              <div>
                                <h3
                                  className={cn(
                                    'font-medium',
                                    reminder.completed && 'line-through',
                                  )}
                                >
                                  {reminder.subject}
                                </h3>
                                {reminder.message && (
                                  <p className="text-sm text-muted-foreground mt-1">
                                    {reminder.message}
                                  </p>
                                )}
                                {reminder.status === 'failed' && reminder.lastError && (
                                  <p className="text-xs text-destructive mt-1">{reminder.lastError}</p>
                                )}
                              </div>
                              <div className="flex items-center gap-2">
                                {getStatusBadge(reminder.status)}
                                <DropdownMenu>
                                  <DropdownMenuTrigger asChild>
                                    <Button variant="ghost" size="icon" className="h-8 w-8">
                                      <MoreHorizontal className="h-4 w-4" />
                                    </Button>
                                  </DropdownMenuTrigger>
                                  <DropdownMenuContent align="end">
                                    {!reminder.completed && (
                                      <DropdownMenuSub>
                                        <DropdownMenuSubTrigger>Posponer</DropdownMenuSubTrigger>
                                        <DropdownMenuSubContent>
                                          {(
                                            [
                                              { label: '15 minutos', minutes: 15 },
                                              { label: '30 minutos', minutes: 30 },
                                              { label: '1 hora', minutes: 60 },
                                              { label: '2 horas', minutes: 120 },
                                            ] as const
                                          ).map((opt) => (
                                            <DropdownMenuItem
                                              key={opt.minutes}
                                              onClick={() =>
                                                snoozeMutation.mutate({
                                                  id: reminder.id,
                                                  minutes: opt.minutes,
                                                })
                                              }
                                            >
                                              {opt.label}
                                            </DropdownMenuItem>
                                          ))}
                                          <DropdownMenuItem
                                            onClick={() => {
                                              const t = new Date()
                                              t.setDate(t.getDate() + 1)
                                              t.setHours(9, 0, 0, 0)
                                              const minutes = Math.round(
                                                (t.getTime() - Date.now()) / 60000,
                                              )
                                              snoozeMutation.mutate({ id: reminder.id, minutes })
                                            }}
                                          >
                                            Mañana (9:00)
                                          </DropdownMenuItem>
                                        </DropdownMenuSubContent>
                                      </DropdownMenuSub>
                                    )}
                                    <DropdownMenuItem
                                      className="text-destructive"
                                      onClick={() => deleteMutation.mutate(reminder.id)}
                                    >
                                      Eliminar
                                    </DropdownMenuItem>
                                  </DropdownMenuContent>
                                </DropdownMenu>
                              </div>
                            </div>

                            <div className="flex flex-wrap items-center gap-4 mt-3 text-sm">
                              <div
                                className={cn(
                                  'flex items-center gap-1',
                                  (reminder.overdue || isOverdue(reminder.remindAt, reminder.completed)) &&
                                    !reminder.completed
                                    ? 'text-red-500'
                                    : 'text-muted-foreground',
                                )}
                              >
                                <Calendar className="h-3 w-3" />
                                {formatDate(reminder.remindAt)}
                              </div>

                              <div className="flex items-center gap-1 text-muted-foreground">
                                <Filter className="h-3 w-3" />
                                {reminderChannelLabel(reminder.channel)}
                              </div>

                              {reminder.opportunityId && (
                                <div className="flex items-center gap-1 text-muted-foreground">
                                  <Briefcase className="h-3 w-3" />
                                  <Link
                                    to="/opportunities"
                                    search={{ selected: reminder.opportunityId }}
                                    className="truncate max-w-[200px] hover:text-primary hover:underline"
                                  >
                                    {reminder.opportunityTitle || 'Ver oportunidad'}
                                  </Link>
                                </div>
                              )}
                            </div>
                          </div>
                        </div>
                      </CardContent>
                    </Card>
                  ))}
                </div>
              </div>
            )
          })}

          {reminders.length === 0 && !isError && (
            <Card>
              <CardContent className="py-12">
                <div className="text-center">
                  <Bell className="h-12 w-12 mx-auto text-muted-foreground/50" />
                  <h3 className="mt-4 text-lg font-medium">No hay recordatorios</h3>
                  <p className="text-sm text-muted-foreground mt-1">
                    Crea un nuevo recordatorio para empezar
                  </p>
                  <Button className="mt-4" onClick={() => setIsCreateDialogOpen(true)}>
                    <Plus className="mr-2 h-4 w-4" />
                    Nuevo Recordatorio
                  </Button>
                </div>
              </CardContent>
            </Card>
          )}
        </div>
      )}

      <ReminderDialog
        open={isCreateDialogOpen}
        onOpenChange={setIsCreateDialogOpen}
        onCreated={() => void invalidate()}
      />
    </AppPageShell>
  )
}

function RemindersSkeleton() {
  return (
    <div className="space-y-4">
      {Array.from({ length: 4 }).map((_, i) => (
        <Card key={i}>
          <CardContent className="p-4">
            <div className="flex items-start gap-3">
              <Skeleton className="h-4 w-4 rounded" />
              <div className="flex-1 space-y-2">
                <Skeleton className="h-5 w-48" />
                <Skeleton className="h-4 w-full" />
                <div className="flex gap-4">
                  <Skeleton className="h-4 w-24" />
                  <Skeleton className="h-4 w-32" />
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
