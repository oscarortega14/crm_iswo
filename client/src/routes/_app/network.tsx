import { createFileRoute } from '@tanstack/react-router'
import { requireRole } from '@/lib/authGuards'
import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Search,
  Network as NetworkIcon,
  User,
  ZoomIn,
  ZoomOut,
  Maximize2,
  Plus,
  Trash2,
  ArrowRight,
  PowerOff,
  Power,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Dialog,
  DialogContent,
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
import { cn } from '@/lib/utils'
import api, { formatRailsError } from '@/lib/api'
import { jsonApiPrimaryList, mapUserResource } from '@/lib/opportunityApi'
import {
  createReferralEdge,
  deleteReferralEdge,
  fetchReferralNetworkList,
  fetchReferralTree,
  referralNetworkErrorMessage,
  setReferralEdgeActive,
  type ReferralTreePayload,
  type ReferralTreeUser,
} from '@/lib/referralNetworkApi'
import {
  getAuthQueryScope,
  invalidateReferralNetworkQueries,
  queryKeys,
} from '@/lib/queryClient'
import { tenantHasModule } from '@/lib/tenantModules'
import { useAuthStore, useTenant } from '@/stores/auth'
import { toast } from 'sonner'
import { AppPageShell } from '@/components/layout/AppPageShell'
import { PageHeader } from '@/components/layout/PageHeader'
import { statGridClass } from '@/lib/layoutClasses'

export const Route = createFileRoute('/_app/network')({
  beforeLoad: () => requireRole('admin', 'manager', 'consultant'),
  component: NetworkPage,
})

interface ConsultantNode {
  id: string
  name: string
  role: string
  active: boolean
  connections: string[]
  treeDepth: number
  x?: number
  y?: number
}

function initialsFromName(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (parts.length >= 2) return `${parts[0][0] ?? ''}${parts[parts.length - 1][0] ?? ''}`.toUpperCase()
  if (parts.length === 1 && parts[0].length >= 2) return parts[0].slice(0, 2).toUpperCase()
  return '?'
}

function roleColor(role: string, active: boolean): string {
  if (!active) return 'fill-muted-foreground/40'
  switch (role) {
    case 'admin':    return 'fill-indigo-500'
    case 'manager':  return 'fill-violet-500'
    case 'consultant': return 'fill-sky-500'
    default:         return 'fill-slate-400'
  }
}

function roleBadgeVariant(role: string): 'default' | 'secondary' | 'outline' {
  switch (role) {
    case 'admin':    return 'default'
    case 'manager':  return 'secondary'
    default:         return 'outline'
  }
}

type UserStub = {
  id: number
  name: string
  role: string
  active: boolean
  treeDepth: number
}

function buildConsultantNodes(payload: ReferralTreePayload): ConsultantNode[] {
  const byId = new Map<string, UserStub>()

  const upsertFull = (u: ReferralTreeUser, depth: number) => {
    const key = String(u.id)
    const prev = byId.get(key)
    const treeDepth = prev ? Math.min(prev.treeDepth, depth) : depth
    byId.set(key, {
      id: u.id,
      name: u.name || prev?.name || '',
      role: u.role || prev?.role || '',
      active: typeof u.active === 'boolean' ? u.active : (prev?.active ?? true),
      treeDepth,
    })
  }

  const touchId = (id: number, depth: number) => {
    const key = String(id)
    const prev = byId.get(key)
    const treeDepth = prev ? Math.min(prev.treeDepth, depth) : depth
    byId.set(key, {
      id,
      name: prev?.name ?? '',
      role: prev?.role ?? '',
      active: prev?.active ?? true,
      treeDepth,
    })
  }

  if (payload.root) upsertFull(payload.root, 0)

  const adjacency = new Map<string, Set<string>>()
  const addConn = (a: string, b: string) => {
    if (a === b) return
    if (!adjacency.has(a)) adjacency.set(a, new Set())
    if (!adjacency.has(b)) adjacency.set(b, new Set())
    adjacency.get(a)!.add(b)
    adjacency.get(b)!.add(a)
  }

  for (const edge of payload.edges) {
    addConn(String(edge.referrer_id), String(edge.referred_id))
    if (edge.referred) upsertFull(edge.referred, edge.depth)
    else touchId(edge.referred_id, edge.depth)
    touchId(edge.referrer_id, Math.max(0, edge.depth - 1))
  }

  const ids = new Set<string>()
  if (payload.root) ids.add(String(payload.root.id))
  for (const e of payload.edges) {
    ids.add(String(e.referrer_id))
    ids.add(String(e.referred_id))
  }

  const nodes: ConsultantNode[] = []
  for (const idStr of ids) {
    const stub = byId.get(idStr)
    const root = payload.root
    const resolved =
      stub ||
      (root && String(root.id) === idStr
        ? { id: root.id, name: root.name, role: root.role, active: root.active, treeDepth: 0 }
        : { id: Number(idStr), name: '', role: '', active: true, treeDepth: 0 })
    nodes.push({
      id: idStr,
      name: resolved.name,
      role: resolved.role,
      active: resolved.active,
      treeDepth: resolved.treeDepth,
      connections: Array.from(adjacency.get(idStr) ?? []),
    })
  }

  return nodes.sort((a, b) => a.treeDepth - b.treeDepth || a.name.localeCompare(b.name))
}

function layoutNodes(nodes: ConsultantNode[]): ConsultantNode[] {
  const byDepth = new Map<number, ConsultantNode[]>()
  for (const n of nodes) {
    const d = n.treeDepth
    if (!byDepth.has(d)) byDepth.set(d, [])
    byDepth.get(d)!.push(n)
  }
  const depths = [...byDepth.keys()].sort((a, b) => a - b)
  const cx = 400
  const cy = 300

  for (const d of depths) {
    const ring = byDepth.get(d)!
    const radius = d === 0 ? 0 : 80 + (d - 1) * 100
    ring.forEach((node, i) => {
      const n = ring.length
      const angleStart = -Math.PI / 2
      const angle =
        n === 1 && d === 0 ? angleStart : angleStart + (i / Math.max(n, 1)) * 2 * Math.PI
      node.x = cx + radius * Math.cos(angle)
      node.y = cy + radius * Math.sin(angle)
    })
  }
  return nodes
}

// Deduplica aristas para no dibujar A→B y B→A dos veces
function uniqueEdges(nodes: ConsultantNode[]): Array<{ a: ConsultantNode; b: ConsultantNode }> {
  const seen = new Set<string>()
  const result: Array<{ a: ConsultantNode; b: ConsultantNode }> = []
  const byId = new Map(nodes.map((n) => [n.id, n]))
  for (const node of nodes) {
    for (const connId of node.connections) {
      const key = [node.id, connId].sort().join('-')
      if (seen.has(key)) continue
      seen.add(key)
      const other = byId.get(connId)
      if (other) result.push({ a: node, b: other })
    }
  }
  return result
}

function NetworkPage() {
  const currentUser = useAuthStore((s) => s.user)
  const tenant      = useTenant()
  const authScope = getAuthQueryScope()
  const hasNetworkModule = tenantHasModule(tenant, 'network')
  const qc = useQueryClient()
  const canPickRoot = currentUser?.role === 'admin' || currentUser?.role === 'manager'
  const canCreate   = canPickRoot
  const canDelete   = currentUser?.role === 'admin'
  const isConsultant = currentUser?.role === 'consultant'

  // RFC F2: profundidad del árbol de referidos (default 3); no amplía el pipeline CRM
  const networkDepth: number = (tenant?.settings?.network_depth as number | undefined) ?? 3

  const [searchTerm, setSearchTerm]     = useState('')
  const [zoom, setZoom]                 = useState(1)
  const [selectedNode, setSelectedNode] = useState<ConsultantNode | null>(null)
  const [rootUserId, setRootUserId]     = useState<string | null>(null)
  const [treeDepth, setTreeDepth]       = useState(5)
  const [addOpen, setAddOpen]           = useState(false)
  const [addReferrer, setAddReferrer]   = useState('')
  const [addReferred, setAddReferred]   = useState('')
  const [deleteEdge, setDeleteEdge]     = useState<{ id: string; name: string } | null>(null)

  // Lista de usuarios para el picker (admin/manager)
  const { data: staffUsers } = useQuery({
    enabled: Boolean(authScope) && canPickRoot && hasNetworkModule,
    queryKey: queryKeys.users.list({ q: '', forReferralPicker: true }),
    queryFn: async () => {
      const response = await api.get('/users', { params: { items: 500 } })
      return jsonApiPrimaryList(response.data)
        .filter((r) => r.id)
        .map(mapUserResource)
    },
  })

  // Árbol para visualizar
  const {
    data: treePayload,
    isLoading: treeLoading,
    isError: treeError,
    error: treeQueryError,
    refetch,
  } = useQuery({
    queryKey: queryKeys.referralNetworks.tree(authScope, rootUserId, treeDepth),
    queryFn: () => fetchReferralTree({ rootUserId, depth: treeDepth }),
    enabled: Boolean(authScope) && hasNetworkModule,
    staleTime: 0,
    refetchOnWindowFocus: true,
  })

  // Listado plano de aristas para obtener IDs (necesarios para eliminar)
  const { data: edgeList } = useQuery({
    enabled: Boolean(authScope) && canDelete && hasNetworkModule,
    queryKey: queryKeys.referralNetworks.list(authScope),
    queryFn: fetchReferralNetworkList,
    staleTime: 0,
  })

  // Mapa pair → edge_id para saber qué borrar
  const edgeIdByPair = useMemo(() => {
    const m = new Map<string, string>()
    for (const e of edgeList ?? []) {
      if (e.referrer && e.referred) {
        m.set(`${e.referrer.id}_${e.referred.id}`, e.id)
        m.set(`${e.referred.id}_${e.referrer.id}`, e.id)
      }
    }
    return m
  }, [edgeList])

  // Actualizar network_depth del tenant (solo admin)
  const depthMutation = useMutation({
    mutationFn: async (depth: number) =>
      api.patch('/tenant', { tenant: { settings: { ...tenant?.settings, network_depth: depth } } }),
    onSuccess: () => {
      toast.success('Profundidad de visibilidad actualizada')
      void qc.invalidateQueries({ queryKey: queryKeys.tenant })
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo actualizar')),
  })

  // Crear relación
  const createMutation = useMutation({
    mutationFn: ({ referrerId, referredId }: { referrerId: string; referredId: string }) =>
      createReferralEdge(referrerId, referredId),
    onSuccess: () => {
      toast.success('Relación de referido creada')
      void invalidateReferralNetworkQueries(qc)
      setAddOpen(false)
      setAddReferrer('')
      setAddReferred('')
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo crear la relación')),
  })

  // Eliminar relación
  const deleteMutation = useMutation({
    mutationFn: deleteReferralEdge,
    onSuccess: () => {
      toast.success('Relación eliminada')
      void invalidateReferralNetworkQueries(qc)
      setDeleteEdge(null)
      setSelectedNode(null)
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo eliminar la relación')),
  })

  // Activar / desactivar relación
  const toggleActiveMutation = useMutation({
    mutationFn: ({ edgeId, active }: { edgeId: string; active: boolean }) =>
      setReferralEdgeActive(edgeId, active),
    onSuccess: (_, { active }) => {
      toast.success(active ? 'Conexión activada' : 'Conexión desactivada')
      void invalidateReferralNetworkQueries(qc)
    },
    onError: (err) => toast.error(formatRailsError(err, 'No se pudo actualizar la conexión')),
  })

  const graphNodes = useMemo(() => {
    if (!treePayload) return [] as ConsultantNode[]
    if (!treePayload.root && !(treePayload.edges?.length)) return [] as ConsultantNode[]
    return layoutNodes(buildConsultantNodes(treePayload))
  }, [treePayload])

  const filteredNodes = useMemo(() => {
    const q = searchTerm.trim().toLowerCase()
    if (!q) return graphNodes
    return graphNodes.filter(
      (n) => n.name.toLowerCase().includes(q) || n.role.toLowerCase().includes(q),
    )
  }, [graphNodes, searchTerm])

  const edges = useMemo(() => uniqueEdges(filteredNodes), [filteredNodes])

  const stats = useMemo(() => {
    const n = graphNodes.length
    const e = Math.round(graphNodes.reduce((acc, node) => acc + node.connections.length, 0) / 2)
    const maxDepth = graphNodes.reduce((m, node) => Math.max(m, node.treeDepth), 0)
    return { consultants: n, links: e, maxDepth }
  }, [graphNodes])

  useEffect(() => {
    if (!treeError || !treeQueryError) return
    toast.error(referralNetworkErrorMessage(treeQueryError))
  }, [treeError, treeQueryError])

  const isLoading = treeLoading

  if (!hasNetworkModule) {
    return (
      <AppPageShell>
        <PageHeader
          title="Red de referidos"
          description="El módulo de red de referidos no está activo en la configuración de este tenant."
        />
      </AppPageShell>
    )
  }

  return (
    <AppPageShell contentClassName="gap-6">
      <PageHeader
        title="Red de referidos"
        description="Árbol de consultores enlazados por referencias."
      >
        {canCreate && (
          <Button size="sm" className="gap-2" onClick={() => setAddOpen(true)}>
            <Plus className="size-4" />
            Nueva conexión
          </Button>
        )}
      </PageHeader>

      {/* Controles admin */}
      {canPickRoot && (
        <div className="flex flex-wrap items-end gap-3 sm:gap-4">
          <div className="min-w-0 flex-1 space-y-1.5 sm:min-w-[220px] sm:flex-none">
            <label className="text-sm font-medium">Raíz del árbol</label>
            <Select
              value={rootUserId ?? '__me__'}
              onValueChange={(v) => { setRootUserId(v === '__me__' ? null : v); setSelectedNode(null) }}
            >
              <SelectTrigger>
                <SelectValue placeholder="Seleccionar usuario raíz" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__me__">
                  Mi red ({currentUser?.name ?? currentUser?.email ?? 'yo'})
                </SelectItem>
                {staffUsers
                  ?.filter((u) => u.name || u.email || u.id)
                  .sort((a, b) => a.name.localeCompare(b.name))
                  .map((u) => (
                    <SelectItem key={u.id} value={u.id}>
                      {u.name || u.email || `Usuario ${u.id}`}
                      {u.role ? ` · ${u.role}` : ''}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <label className="text-sm font-medium">Profundidad</label>
            <Select
              value={String(treeDepth)}
              onValueChange={(v) => { setTreeDepth(Number(v)); setSelectedNode(null) }}
              disabled={!rootUserId}
            >
              <SelectTrigger className="w-[120px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {[2, 3, 5, 7, 10].map((d) => (
                  <SelectItem key={d} value={String(d)}>{d} niveles</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
      )}

      {/* RFC F2: Visibilidad por profundidad */}
      <Card className="border-dashed">
        <CardContent className="pt-4 pb-3">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div className="flex items-center gap-3">
              <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-indigo-500/10">
                <NetworkIcon className="h-4 w-4 text-indigo-600" />
              </div>
              <div>
                <p className="text-sm font-medium">Profundidad del árbol (RFC F2)</p>
                <p className="text-xs text-muted-foreground">
                  {isConsultant
                    ? 'En Oportunidades ves tus leads y los de tu red (solo lectura). Aquí el árbol muestra hasta '
                    : 'Los consultores ven sus oportunidades y las de su red (solo lectura) en el pipeline. El árbol muestra hasta '}
                  <strong>
                    {networkDepth} {networkDepth === 1 ? 'nivel' : 'niveles'}
                  </strong>{' '}
                  de referidos{networkDepth === 0 ? ' (solo tú en el árbol)' : ''}.
                  {canDelete && !isConsultant && ' Ajusta la profundidad para todo el tenant.'}
                </p>
              </div>
            </div>
            {canDelete && (
              <div className="flex items-center gap-2">
                <span className="text-sm text-muted-foreground">Profundidad:</span>
                <Select
                  value={String(networkDepth)}
                  onValueChange={(v) => depthMutation.mutate(Number(v))}
                  disabled={depthMutation.isPending}
                >
                  <SelectTrigger className="w-[110px] h-8 text-sm">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {[0, 1, 2, 3, 4, 5, 7, 10].map((d) => (
                      <SelectItem key={d} value={String(d)}>{d} nivel{d !== 1 ? 'es' : ''}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            )}
          </div>
        </CardContent>
      </Card>

      {/* Stats */}
      <div className={`${statGridClass} md:grid-cols-3`}>
        {[
          { icon: User, label: 'Consultores', value: stats.consultants, color: 'bg-sky-500/10 text-sky-600' },
          { icon: NetworkIcon, label: 'Relaciones', value: stats.links, color: 'bg-violet-500/10 text-violet-600' },
          { icon: Maximize2, label: 'Nivel máximo', value: stats.maxDepth, color: 'bg-muted text-muted-foreground' },
        ].map(({ icon: Icon, label, value, color }) => (
          <Card key={label}>
            <CardContent className="pt-4">
              <div className="flex items-center gap-3">
                <div className={cn('flex h-9 w-9 items-center justify-center rounded-lg', color)}>
                  <Icon className="h-4 w-4" />
                </div>
                <div>
                  <p className="text-xl font-semibold">{value}</p>
                  <p className="text-xs text-muted-foreground">{label}</p>
                </div>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      {/* Buscador + controles de zoom */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div className="relative w-full sm:w-auto">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por nombre o rol…"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full pl-9 sm:w-56"
          />
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Actualizar
          </Button>
          <Button variant="outline" size="icon" onClick={() => setZoom((z) => Math.max(0.4, z - 0.15))}>
            <ZoomOut className="h-4 w-4" />
          </Button>
          <span className="text-sm text-muted-foreground w-12 text-center">{Math.round(zoom * 100)}%</span>
          <Button variant="outline" size="icon" onClick={() => setZoom((z) => Math.min(2.5, z + 0.15))}>
            <ZoomIn className="h-4 w-4" />
          </Button>
          <Button variant="outline" size="icon" onClick={() => setZoom(1)}>
            <Maximize2 className="h-4 w-4" />
          </Button>
        </div>
      </div>

      {/* Grafo + detalle */}
      <div className="grid grid-cols-1 lg:grid-cols-4 gap-4">
        <Card className="lg:col-span-3">
          <CardContent className="p-0">
            {isLoading ? (
              <div className="h-[520px] flex items-center justify-center">
                <Skeleton className="h-full w-full" />
              </div>
            ) : treeError ? (
              <div className="h-[240px] flex flex-col items-center justify-center gap-2 p-6 text-center">
                <p className="text-sm text-destructive">
                  {referralNetworkErrorMessage(treeQueryError)}
                </p>
                <Button variant="outline" size="sm" onClick={() => void refetch()}>Reintentar</Button>
              </div>
            ) : graphNodes.length === 0 ? (
              <div className="h-[240px] flex flex-col items-center justify-center gap-3 p-6 text-center text-muted-foreground text-sm">
                <NetworkIcon className="size-10 opacity-30" />
                <p>No hay referidos registrados bajo esta raíz.</p>
                {canCreate && (
                  <Button size="sm" variant="outline" onClick={() => setAddOpen(true)}>
                    <Plus className="size-4 mr-2" /> Crear primera conexión
                  </Button>
                )}
              </div>
            ) : (
              <div className="relative h-[520px] overflow-hidden rounded-lg bg-muted/20">
                <svg
                  className="w-full h-full select-none"
                  style={{ transform: `scale(${zoom})`, transformOrigin: 'center center' }}
                  viewBox="0 0 800 600"
                  preserveAspectRatio="xMidYMid meet"
                >
                  <defs>
                    <marker id="arrow" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto">
                      <path d="M0,0 L0,6 L6,3 z" className="fill-border" />
                    </marker>
                  </defs>

                  {/* Aristas */}
                  {edges.map(({ a, b }) => {
                    const dx = (b.x ?? 0) - (a.x ?? 0)
                    const dy = (b.y ?? 0) - (a.y ?? 0)
                    const len = Math.sqrt(dx * dx + dy * dy) || 1
                    const ra = a.treeDepth === 0 ? 22 : 18
                    const rb = b.treeDepth === 0 ? 22 : 18
                    const x1 = (a.x ?? 0) + (dx / len) * ra
                    const y1 = (a.y ?? 0) + (dy / len) * ra
                    const x2 = (b.x ?? 0) - (dx / len) * (rb + 6)
                    const y2 = (b.y ?? 0) - (dy / len) * (rb + 6)
                    return (
                      <line
                        key={`${a.id}-${b.id}`}
                        x1={x1} y1={y1} x2={x2} y2={y2}
                        strokeOpacity={0.35}
                        strokeWidth={1.5}
                        className="stroke-foreground"
                        markerEnd="url(#arrow)"
                      />
                    )
                  })}

                  {/* Nodos */}
                  {filteredNodes.map((node) => {
                    const r = node.treeDepth === 0 ? 22 : 18
                    const isSelected = selectedNode?.id === node.id
                    return (
                      <g
                        key={node.id}
                        transform={`translate(${node.x ?? 0}, ${node.y ?? 0})`}
                        className="cursor-pointer"
                        onClick={() => setSelectedNode(isSelected ? null : node)}
                      >
                        {isSelected && (
                          <circle r={r + 5} className="fill-none stroke-foreground" strokeWidth={2} strokeDasharray="4 2" />
                        )}
                        <circle r={r} className={cn(roleColor(node.role, node.active))} />
                        <text
                          textAnchor="middle"
                          dominantBaseline="central"
                          className="fill-white font-semibold pointer-events-none"
                          style={{ fontSize: node.treeDepth === 0 ? 11 : 9 }}
                        >
                          {initialsFromName(node.name || `?`)}
                        </text>
                        <text
                          y={r + 14}
                          textAnchor="middle"
                          className="fill-foreground pointer-events-none"
                          style={{ fontSize: 10 }}
                        >
                          {(node.name || node.id).length > 12
                            ? `${(node.name || node.id).slice(0, 12)}…`
                            : node.name || node.id}
                        </text>
                        <title>{[node.name, node.role ? `(${node.role})` : ''].filter(Boolean).join(' ')}</title>
                      </g>
                    )
                  })}
                </svg>

                {/* Leyenda */}
                <div className="absolute bottom-3 left-3 flex gap-3 bg-background/80 backdrop-blur-sm rounded-lg px-3 py-2 text-xs">
                  {[
                    { color: 'bg-indigo-500', label: 'Admin' },
                    { color: 'bg-violet-500', label: 'Gerente' },
                    { color: 'bg-sky-500',    label: 'Consultor' },
                    { color: 'bg-muted-foreground/40', label: 'Inactivo' },
                  ].map(({ color, label }) => (
                    <div key={label} className="flex items-center gap-1.5">
                      <div className={cn('h-2.5 w-2.5 rounded-full', color)} />
                      <span className="text-muted-foreground">{label}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </CardContent>
        </Card>

        {/* Panel de detalle */}
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm font-medium">Detalle</CardTitle>
          </CardHeader>
          <CardContent>
            {selectedNode ? (
              <div className="space-y-4">
                <div className="min-w-0">
                  <h3 className="font-medium text-sm truncate">{selectedNode.name || `Usuario ${selectedNode.id}`}</h3>
                  <div className="flex gap-1 mt-0.5 flex-wrap">
                    <Badge variant={roleBadgeVariant(selectedNode.role)} className="text-xs">
                      {selectedNode.role || 'sin rol'}
                    </Badge>
                    {!selectedNode.active && (
                      <Badge variant="destructive" className="text-xs">Inactivo</Badge>
                    )}
                  </div>
                </div>

                <div>
                  <p className="text-xs text-muted-foreground mb-2">
                    Conexiones ({selectedNode.connections.length})
                  </p>
                  <div className="space-y-1 max-h-52 overflow-y-auto">
                    {selectedNode.connections.map((connId) => {
                      const other = graphNodes.find((n) => n.id === connId)
                      if (!other) return null
                      const edgeId = edgeIdByPair.get(`${selectedNode.id}_${connId}`)
                        || edgeIdByPair.get(`${connId}_${selectedNode.id}`)
                      const edge = edgeId ? edgeList?.find((e) => e.id === edgeId) : undefined
                      const isActive = edge?.active ?? true
                      return (
                        <div
                          key={connId}
                          className="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-muted group"
                        >
                          <button
                            type="button"
                            className="flex items-center gap-2 flex-1 text-left"
                            onClick={() => setSelectedNode(other)}
                          >
                            <ArrowRight className="h-3 w-3 shrink-0 text-muted-foreground" />
                            <span className={cn('text-sm truncate', !isActive && 'text-muted-foreground line-through')}>
                              {other.name || `Usuario ${other.id}`}
                            </span>
                            {!isActive && (
                              <span className="text-[10px] text-muted-foreground shrink-0">(inactiva)</span>
                            )}
                          </button>
                          {canDelete && edgeId && (
                            <>
                              <button
                                type="button"
                                title={isActive ? 'Desactivar conexión' : 'Activar conexión'}
                                className="opacity-0 group-hover:opacity-100 transition-opacity text-muted-foreground hover:text-foreground"
                                onClick={() => toggleActiveMutation.mutate({ edgeId, active: !isActive })}
                              >
                                {isActive
                                  ? <PowerOff className="h-3.5 w-3.5" />
                                  : <Power className="h-3.5 w-3.5 text-emerald-600" />
                                }
                              </button>
                              <button
                                type="button"
                                className="opacity-0 group-hover:opacity-100 text-destructive hover:text-destructive/80 transition-opacity"
                                onClick={() => setDeleteEdge({ id: edgeId, name: other.name || other.id })}
                              >
                                <Trash2 className="h-3.5 w-3.5" />
                              </button>
                            </>
                          )}
                        </div>
                      )
                    })}
                  </div>
                </div>
              </div>
            ) : (
              <div className="text-center py-8">
                <NetworkIcon className="h-10 w-10 mx-auto text-muted-foreground/40" />
                <p className="text-sm text-muted-foreground mt-2">
                  Selecciona un nodo en el gráfico
                </p>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Dialog: Nueva conexión */}
      <Dialog open={addOpen} onOpenChange={setAddOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Nueva conexión de referido</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 pt-2">
            <div className="space-y-1.5">
              <label className="text-sm font-medium">Referente (quien refiere)</label>
              <Select value={addReferrer} onValueChange={setAddReferrer}>
                <SelectTrigger>
                  <SelectValue placeholder="Seleccionar usuario..." />
                </SelectTrigger>
                <SelectContent>
                  {staffUsers
                    ?.sort((a, b) => a.name.localeCompare(b.name))
                    .map((u) => (
                      <SelectItem key={u.id} value={u.id} disabled={u.id === addReferred}>
                        {u.name || u.email} · {u.role}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <label className="text-sm font-medium">Referido (quien fue referido)</label>
              <Select value={addReferred} onValueChange={setAddReferred}>
                <SelectTrigger>
                  <SelectValue placeholder="Seleccionar usuario..." />
                </SelectTrigger>
                <SelectContent>
                  {staffUsers
                    ?.sort((a, b) => a.name.localeCompare(b.name))
                    .map((u) => (
                      <SelectItem key={u.id} value={u.id} disabled={u.id === addReferrer}>
                        {u.name || u.email} · {u.role}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
            </div>
            <Button
              className="w-full"
              disabled={!addReferrer || !addReferred || createMutation.isPending}
              onClick={() => createMutation.mutate({ referrerId: addReferrer, referredId: addReferred })}
            >
              {createMutation.isPending ? 'Guardando…' : 'Crear relación'}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {/* AlertDialog: confirmar eliminación */}
      <AlertDialog open={!!deleteEdge} onOpenChange={(o) => { if (!o) setDeleteEdge(null) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar esta conexión?</AlertDialogTitle>
            <AlertDialogDescription>
              Se eliminará la relación de referido con <strong>{deleteEdge?.name}</strong>. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive hover:bg-destructive/90"
              onClick={() => deleteEdge && deleteMutation.mutate(deleteEdge.id)}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppPageShell>
  )
}
