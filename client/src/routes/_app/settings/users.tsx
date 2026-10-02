import { createFileRoute } from '@tanstack/react-router'
import { requireAdmin } from '@/lib/authGuards'
import { useEffect, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Copy, MoreHorizontal, Shield, Mail, Search, UserPlus, RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
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
  DropdownMenuSeparator,
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { Spinner } from '@/components/ui/spinner'
import { toast } from 'sonner'
import type { UserRole } from '@/types'
import { formatDate } from '@/lib/utils'
import { isPlatformTenant } from '@/lib/platformTenant'
import {
  createUser,
  deleteUser,
  fetchUsersList,
  requestUserPasswordReset,
  setUserActive,
  updateUserRole,
  userApiErrorMessage,
} from '@/lib/userApi'
import { queryKeys } from '@/lib/queryClient'
import { useAuthStore, useTenant } from '@/stores/auth'

const COMMERCIAL_ROLES: UserRole[] = ['admin', 'manager', 'consultant', 'viewer']

type CreateSuccess = {
  name: string
  email: string
  passwordGenerated: boolean
  temporaryPassword: string | null
}

function copyText(label: string, value: string) {
  void navigator.clipboard.writeText(value).then(
    () => toast.success(`${label} copiado`),
    () => toast.error('No se pudo copiar'),
  )
}

export const Route = createFileRoute('/_app/settings/users')({
  beforeLoad: () => {
    requireAdmin()
  },
  component: UsersSettingsPage,
})

function UsersSettingsPage() {
  const queryClient = useQueryClient()
  const currentUser = useAuthStore((s) => s.user)
  const tenant = useTenant()
  const isPlatform = isPlatformTenant(tenant)
  const isAdmin = currentUser?.role === 'admin'

  const [searchTerm, setSearchTerm] = useState('')
  const [debouncedQ, setDebouncedQ] = useState('')
  const [roleFilter, setRoleFilter] = useState<'all' | UserRole>('all')
  const [activeFilter, setActiveFilter] = useState<'all' | 'true' | 'false'>('all')
  useEffect(() => {
    const id = window.setTimeout(() => setDebouncedQ(searchTerm.trim()), 350)
    return () => window.clearTimeout(id)
  }, [searchTerm])

  const [isInviteDialogOpen, setIsInviteDialogOpen] = useState(false)
  const [inviteName, setInviteName] = useState('')
  const [inviteEmail, setInviteEmail] = useState('')
  const [invitePhone, setInvitePhone] = useState('')
  const [inviteRole, setInviteRole] = useState<UserRole>(isPlatform ? 'admin' : 'consultant')
  const [invitePassword, setInvitePassword] = useState('')
  const [createSuccess, setCreateSuccess] = useState<CreateSuccess | null>(null)
  const [confirmDeleteUser, setConfirmDeleteUser] = useState<{ id: string; name: string } | null>(
    null,
  )

  const listFilters = { q: debouncedQ, role: roleFilter, active: activeFilter, items: 200 }

  const {
    data: users = [],
    isLoading,
    isError,
    error,
    refetch,
    isRefetching,
  } = useQuery({
    queryKey: queryKeys.users.list(listFilters),
    queryFn: () => fetchUsersList(listFilters),
  })

  const invalidateUsers = () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.users.all })
  }

  const inviteUserMutation = useMutation({
    mutationFn: (payload: {
      name: string
      email: string
      phone: string
      role: UserRole
      password?: string
    }) =>
      createUser({
        name: payload.name,
        email: payload.email,
        phone: payload.phone,
        role: payload.role,
        password: payload.password,
      }),
    onSuccess: (result) => {
      invalidateUsers()
      setCreateSuccess({
        name: result.user.name,
        email: result.user.email,
        passwordGenerated: result.passwordGenerated,
        temporaryPassword: result.temporaryPassword,
      })
      setIsInviteDialogOpen(false)
      setInviteName('')
      setInviteEmail('')
      setInvitePhone('')
      setInviteRole(isPlatform ? 'admin' : 'consultant')
      setInvitePassword('')
      if (!result.passwordGenerated) {
        toast.success('Usuario creado correctamente.')
      }
    },
    onError: (err: unknown) =>
      toast.error(userApiErrorMessage(err, 'Error al crear el usuario')),
  })

  const changeRoleMutation = useMutation({
    mutationFn: ({ userId, role }: { userId: string; role: UserRole }) =>
      updateUserRole(userId, role),
    onSuccess: () => {
      invalidateUsers()
      toast.success('Rol actualizado')
    },
    onError: (err: unknown) =>
      toast.error(userApiErrorMessage(err, 'Error al actualizar el rol')),
  })

  const removeUserMutation = useMutation({
    mutationFn: deleteUser,
    onSuccess: () => {
      invalidateUsers()
      toast.success('Usuario eliminado')
      setConfirmDeleteUser(null)
    },
    onError: (err: unknown) =>
      toast.error(userApiErrorMessage(err, 'Error al eliminar el usuario')),
  })

  const toggleActiveMutation = useMutation({
    mutationFn: ({ userId, active }: { userId: string; active: boolean }) =>
      setUserActive(userId, active),
    onSuccess: (_, vars) => {
      invalidateUsers()
      toast.success(vars.active ? 'Usuario activado' : 'Usuario desactivado')
    },
    onError: (err: unknown) =>
      toast.error(userApiErrorMessage(err, 'Error al cambiar el estado del usuario')),
  })

  const resetPasswordMutation = useMutation({
    mutationFn: requestUserPasswordReset,
    onSuccess: () => {
      toast.success('Se enviaron instrucciones para restablecer la contraseña.')
    },
    onError: (err: unknown) =>
      toast.error(userApiErrorMessage(err, 'Error al enviar el correo de restablecimiento')),
  })

  const getRoleBadge = (role: UserRole | string) => {
    switch (role) {
      case 'admin':
        return <Badge className="bg-red-100 text-red-800 hover:bg-red-100">Admin</Badge>
      case 'manager':
        return (
          <Badge className="border border-primary/25 bg-primary/12 text-primary hover:bg-primary/15 dark:border-primary/35 dark:bg-primary/18">
            Manager
          </Badge>
        )
      case 'consultant':
        return <Badge variant="secondary">Consultor</Badge>
      case 'viewer':
        return <Badge variant="outline">Solo lectura</Badge>
      default:
        return <Badge variant="secondary">{role}</Badge>
    }
  }

  const roleCounts = users.reduce(
    (acc, user) => {
      if (user.role === 'admin') acc.admin += 1
      else if (user.role === 'manager') acc.manager += 1
      else if (user.role === 'consultant') acc.consultant += 1
      else if (user.role === 'viewer') acc.viewer += 1
      return acc
    },
    { admin: 0, manager: 0, consultant: 0, viewer: 0 },
  )

  const roleMenuItems: { role: UserRole; label: string }[] = isPlatform
    ? [{ role: 'admin', label: 'Rol: Admin plataforma' }]
    : [
        { role: 'admin', label: 'Rol: Admin' },
        { role: 'manager', label: 'Rol: Manager' },
        { role: 'consultant', label: 'Rol: Consultor' },
        { role: 'viewer', label: 'Rol: Solo lectura' },
      ]

  const pageTitle = isPlatform ? 'Operadores de plataforma' : 'Usuarios'
  const pageDescription = isPlatform
    ? 'Administradores del tenant super-admin con acceso a onboarding, auditoría y gestión de tenants.'
    : 'Usuarios del tenant (listado en vivo desde el servidor).'

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div>
          <h2 className="text-lg font-medium">{pageTitle}</h2>
          <p className="hidden text-sm text-muted-foreground sm:block">{pageDescription}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()} disabled={isRefetching}>
            <RefreshCw className={`mr-2 h-4 w-4 ${isRefetching ? 'animate-spin' : ''}`} />
            Recargar
          </Button>
          {isAdmin && (
            <Button size="sm" onClick={() => setIsInviteDialogOpen(true)}>
              <UserPlus className="mr-2 h-4 w-4" />
              {isPlatform ? 'Nuevo operador' : 'Invitar usuario'}
            </Button>
          )}
        </div>
      </div>

      <div className="flex flex-col gap-3 md:flex-row md:items-center">
        <div className="relative w-full md:max-w-sm">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por nombre o correo..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="pl-9"
          />
        </div>
        {!isPlatform && (
          <Select value={roleFilter} onValueChange={(v) => setRoleFilter(v as 'all' | UserRole)}>
            <SelectTrigger className="w-full md:w-52">
              <SelectValue placeholder="Filtrar por rol" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos los roles</SelectItem>
              <SelectItem value="admin">Admin</SelectItem>
              <SelectItem value="manager">Manager</SelectItem>
              <SelectItem value="consultant">Consultor</SelectItem>
              <SelectItem value="viewer">Solo lectura</SelectItem>
            </SelectContent>
          </Select>
        )}
        <Select value={activeFilter} onValueChange={(v) => setActiveFilter(v as 'all' | 'true' | 'false')}>
          <SelectTrigger className="w-full md:w-44">
            <SelectValue placeholder="Estado" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos</SelectItem>
            <SelectItem value="true">Activos</SelectItem>
            <SelectItem value="false">Inactivos</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <Card>
        <CardContent className="p-0">
          {isError && (
            <div className="p-6 text-sm">
              <p className="text-destructive">
                No se pudo cargar la lista: {userApiErrorMessage(error, 'error desconocido')}
              </p>
              <Button className="mt-3" size="sm" variant="outline" onClick={() => void refetch()}>
                Reintentar
              </Button>
            </div>
          )}
          {!isError && isLoading ? (
            <div className="p-4 space-y-4">
              {Array.from({ length: 4 }).map((_, i) => (
                <div key={i} className="flex items-center gap-4">
                  <Skeleton className="h-10 w-10 rounded-full" />
                  <div className="space-y-2">
                    <Skeleton className="h-4 w-32" />
                    <Skeleton className="h-3 w-48" />
                  </div>
                </div>
              ))}
            </div>
          ) : !isError ? (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Usuario</TableHead>
                  <TableHead>Rol</TableHead>
                  <TableHead className="hidden md:table-cell">Estado</TableHead>
                  <TableHead className="hidden md:table-cell">Registro</TableHead>
                  <TableHead className="hidden md:table-cell">Último acceso</TableHead>
                  <TableHead className="w-10"></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {users.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={6} className="text-center text-muted-foreground py-10">
                      No hay usuarios que coincidan con la búsqueda.
                    </TableCell>
                  </TableRow>
                ) : (
                  users.map((user) => {
                    const isSelf = currentUser?.id === user.id
                    return (
                      <TableRow key={user.id}>
                        <TableCell className="whitespace-normal md:whitespace-nowrap">
                          <div className="min-w-0">
                            <p className="font-medium">
                              {user.name}
                              {isSelf && (
                                <span className="ml-2 text-xs text-muted-foreground">(tú)</span>
                              )}
                            </p>
                            <p className="break-all text-sm text-muted-foreground md:break-normal">{user.email}</p>
                            {!user.active && (
                              <Badge variant="secondary" className="mt-1 md:hidden">
                                Inactivo
                              </Badge>
                            )}
                          </div>
                        </TableCell>
                        <TableCell>{getRoleBadge(user.role)}</TableCell>
                        <TableCell className="hidden md:table-cell">
                          {user.active ? (
                            <Badge variant="outline" className="border-primary/35 text-primary">
                              Activo
                            </Badge>
                          ) : (
                            <Badge variant="secondary">Inactivo</Badge>
                          )}
                        </TableCell>
                        <TableCell className="hidden md:table-cell text-muted-foreground">
                          {user.created_at ? formatDate(user.created_at) : '—'}
                        </TableCell>
                        <TableCell className="hidden md:table-cell text-muted-foreground">
                          {user.last_sign_in_at ? formatDate(user.last_sign_in_at) : 'Nunca'}
                        </TableCell>
                        <TableCell>
                          {isAdmin && (
                            <DropdownMenu>
                              <DropdownMenuTrigger asChild>
                                <Button variant="ghost" size="icon" className="h-8 w-8">
                                  <MoreHorizontal className="h-4 w-4" />
                                </Button>
                              </DropdownMenuTrigger>
                              <DropdownMenuContent align="end">
                                {roleMenuItems.map((item) => (
                                  <DropdownMenuItem
                                    key={item.role}
                                    onClick={() =>
                                      changeRoleMutation.mutate({ userId: user.id, role: item.role })
                                    }
                                    disabled={user.role === item.role}
                                  >
                                    <Shield className="mr-2 h-4 w-4" />
                                    {item.label}
                                  </DropdownMenuItem>
                                ))}
                                <DropdownMenuSeparator />
                                <DropdownMenuItem
                                  onClick={() =>
                                    toggleActiveMutation.mutate({
                                      userId: user.id,
                                      active: !user.active,
                                    })
                                  }
                                  disabled={toggleActiveMutation.isPending || isSelf}
                                >
                                  {user.active ? 'Desactivar usuario' : 'Activar usuario'}
                                </DropdownMenuItem>
                                <DropdownMenuSeparator />
                                <DropdownMenuItem
                                  onClick={() => resetPasswordMutation.mutate(user.id)}
                                  disabled={resetPasswordMutation.isPending}
                                >
                                  <Mail className="mr-2 h-4 w-4" />
                                  Enviar restablecimiento de contraseña
                                </DropdownMenuItem>
                                <DropdownMenuSeparator />
                                {!isSelf && (
                                  <DropdownMenuItem
                                    className="text-destructive"
                                    onClick={() =>
                                      setConfirmDeleteUser({ id: user.id, name: user.name })
                                    }
                                  >
                                    Eliminar usuario
                                  </DropdownMenuItem>
                                )}
                              </DropdownMenuContent>
                            </DropdownMenu>
                          )}
                        </TableCell>
                      </TableRow>
                    )
                  })
                )}
              </TableBody>
            </Table>
          ) : null}
        </CardContent>
      </Card>

      {isPlatform ? (
        <Card>
          <CardContent className="pt-4">
            <p className="text-xs text-muted-foreground">Administradores plataforma</p>
            <p className="text-2xl font-semibold">{roleCounts.admin}</p>
            <p className="text-xs text-muted-foreground mt-1">
              Total en listado: {users.length} · Activos: {users.filter((u) => u.active).length}
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Card>
            <CardContent className="pt-4">
              <p className="text-xs text-muted-foreground">Admins</p>
              <p className="text-2xl font-semibold">{roleCounts.admin}</p>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-4">
              <p className="text-xs text-muted-foreground">Managers</p>
              <p className="text-2xl font-semibold">{roleCounts.manager}</p>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-4">
              <p className="text-xs text-muted-foreground">Consultores</p>
              <p className="text-2xl font-semibold">{roleCounts.consultant}</p>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-4">
              <p className="text-xs text-muted-foreground">Solo lectura</p>
              <p className="text-2xl font-semibold">{roleCounts.viewer}</p>
            </CardContent>
          </Card>
        </div>
      )}

      <Card>
        <CardContent className="pt-6">
          <h3 className="font-medium mb-4">Descripción de roles</h3>
          {isPlatform ? (
            <div className="rounded-lg border p-3 text-sm">
              <div className="mb-2">{getRoleBadge('admin')}</div>
              <p className="text-muted-foreground">
                Acceso al tenant plataforma: onboarding de empresas, auditoría global y gestión de
                operadores. No usa el CRM comercial (contactos, oportunidades, etc.).
              </p>
            </div>
          ) : (
            <div className="grid gap-3 text-sm md:grid-cols-2">
              <div className="rounded-lg border p-3">
                <div className="mb-2">{getRoleBadge('admin')}</div>
                <p className="text-muted-foreground">
                  Acceso completo; puede gestionar usuarios y configuración del tenant.
                </p>
              </div>
              <div className="rounded-lg border p-3">
                <div className="mb-2">{getRoleBadge('manager')}</div>
                <p className="text-muted-foreground">
                  Ve y edita oportunidades y contactos del tenant; gestiona usuarios con límites de
                  política.
                </p>
              </div>
              <div className="rounded-lg border p-3">
                <div className="mb-2">{getRoleBadge('consultant')}</div>
                <p className="text-muted-foreground">
                  Trabaja sus oportunidades y contactos asignados; importa contactos desde Excel.
                </p>
              </div>
              <div className="rounded-lg border p-3">
                <div className="mb-2">{getRoleBadge('viewer')}</div>
                <p className="text-muted-foreground">Solo lectura.</p>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      <AlertDialog
        open={!!confirmDeleteUser}
        onOpenChange={(open) => {
          if (!open) setConfirmDeleteUser(null)
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar usuario?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará permanentemente a «{confirmDeleteUser?.name}» del tenant. Sus
              oportunidades asignadas quedarán sin responsable. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90 text-destructive-foreground"
              onClick={() => confirmDeleteUser && removeUserMutation.mutate(confirmDeleteUser.id)}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <Dialog open={isInviteDialogOpen} onOpenChange={setIsInviteDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{isPlatform ? 'Nuevo operador de plataforma' : 'Invitar usuario'}</DialogTitle>
            <DialogDescription>
              {isPlatform
                ? 'Crea un administrador del tenant super-admin. Si no indicas contraseña, se genera una temporal que solo verás una vez.'
                : 'Crea el usuario en el tenant; se genera una contraseña provisional si no la indicas.'}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="invite-name">Nombre completo</Label>
              <Input
                id="invite-name"
                value={inviteName}
                onChange={(e) => setInviteName(e.target.value)}
                placeholder="María López"
                autoComplete="name"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="invite-email">Correo</Label>
              <Input
                id="invite-email"
                type="email"
                value={inviteEmail}
                onChange={(e) => setInviteEmail(e.target.value)}
                placeholder={isPlatform ? 'ops@empresa.com' : 'usuario@empresa.com'}
                autoComplete="email"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="invite-phone">Teléfono (opcional)</Label>
              <Input
                id="invite-phone"
                type="tel"
                value={invitePhone}
                onChange={(e) => setInvitePhone(e.target.value)}
                placeholder="+57 300 123 4567"
                autoComplete="tel"
              />
            </div>
            {!isPlatform && (
              <div className="space-y-2">
                <Label htmlFor="invite-role">Rol</Label>
                <Select value={inviteRole} onValueChange={(v) => setInviteRole(v as UserRole)}>
                  <SelectTrigger id="invite-role">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {COMMERCIAL_ROLES.map((role) => (
                      <SelectItem key={role} value={role}>
                        {role === 'admin'
                          ? 'Admin'
                          : role === 'manager'
                            ? 'Manager'
                            : role === 'consultant'
                              ? 'Consultor'
                              : 'Solo lectura'}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="invite-password">Contraseña (opcional)</Label>
              <Input
                id="invite-password"
                type="password"
                value={invitePassword}
                onChange={(e) => setInvitePassword(e.target.value)}
                placeholder="Dejar vacío para generar automáticamente"
                autoComplete="new-password"
              />
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setIsInviteDialogOpen(false)}>
              Cancelar
            </Button>
            <Button
              type="button"
              onClick={() =>
                inviteUserMutation.mutate({
                  name: inviteName,
                  email: inviteEmail,
                  phone: invitePhone,
                  role: isPlatform ? 'admin' : inviteRole,
                  password: invitePassword.trim() || undefined,
                })
              }
              disabled={!inviteName.trim() || !inviteEmail.trim() || inviteUserMutation.isPending}
            >
              {inviteUserMutation.isPending && <Spinner className="mr-2" />}
              Crear usuario
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={createSuccess != null} onOpenChange={(open) => !open && setCreateSuccess(null)}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Usuario creado</DialogTitle>
            <DialogDescription>
              Guarda las credenciales. La contraseña generada solo se muestra una vez.
            </DialogDescription>
          </DialogHeader>
          {createSuccess && (
            <div className="space-y-3 text-sm">
              <div>
                <p className="text-muted-foreground">Nombre</p>
                <p className="font-medium">{createSuccess.name}</p>
              </div>
              <div className="flex items-center justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-muted-foreground">Correo</p>
                  <p className="font-mono truncate">{createSuccess.email}</p>
                </div>
                <Button
                  type="button"
                  variant="outline"
                  size="icon-sm"
                  onClick={() => copyText('Correo', createSuccess.email)}
                >
                  <Copy className="size-4" />
                </Button>
              </div>
              {createSuccess.passwordGenerated && createSuccess.temporaryPassword && (
                <div className="flex items-center justify-between gap-2 rounded-md border bg-muted/50 p-3">
                  <div className="min-w-0">
                    <p className="text-muted-foreground">Contraseña generada</p>
                    <p className="font-mono break-all">{createSuccess.temporaryPassword}</p>
                  </div>
                  <Button
                    type="button"
                    variant="outline"
                    size="icon-sm"
                    onClick={() =>
                      copyText('Contraseña', createSuccess.temporaryPassword!)
                    }
                  >
                    <Copy className="size-4" />
                  </Button>
                </div>
              )}
            </div>
          )}
          <DialogFooter>
            <Button type="button" onClick={() => setCreateSuccess(null)}>
              Cerrar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
