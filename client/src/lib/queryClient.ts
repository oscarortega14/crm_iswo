import { QueryClient } from '@tanstack/react-query'
import { useAuthStore } from '@/stores/auth'

/** Polling en bandeja de duplicados (admin/manager), RFC §6.2 tiempo casi real. */
export const DUPLICATE_FLAGS_POLL_MS = 10_000

/** Alcance de caché por tenant + usuario (evita mezclar datos entre sesiones). */
export function getAuthQueryScope(): string {
  const { user, tenant } = useAuthStore.getState()
  if (!user?.id) return ''
  const slug = tenant?.subdomain?.trim().toLowerCase() || '_'
  return `${slug}:user:${user.id}`
}

/** Vacía la caché de React Query al cambiar de sesión (login/logout). */
export function clearSessionQueryCache(client: QueryClient = queryClient): void {
  client.clear()
}

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      gcTime: 1000 * 60 * 30, // 30 minutes (formerly cacheTime)
      retry: 1,
      refetchOnWindowFocus: false,
    },
    mutations: {
      retry: 0,
    },
  },
})

// Query keys factory
export const queryKeys = {
  // Auth
  tenant: ['tenant'] as const,
  currentUser: ['currentUser'] as const,
  
  // Opportunities
  opportunities: {
    all: ['opportunities'] as const,
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['opportunities', 'list', authScope, filters] as const,
    detail: (id: string) => ['opportunities', 'detail', id] as const,
    logs: (id: string) => ['opportunities', 'logs', id] as const,
    messages: (id: string) => ['opportunities', 'messages', id] as const,
    duplicateCheck: (phone?: string, email?: string) => 
      ['opportunities', 'duplicateCheck', { phone, email }] as const,
  },
  
  // Contacts (authScope — evita mezclar listas/stats entre sesiones)
  contacts: {
    all: ['contacts'] as const,
    stats: (authScope: string) => ['contacts', 'stats', authScope] as const,
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['contacts', 'list', authScope, filters] as const,
    detail: (id: string) => ['contacts', 'detail', id] as const,
  },
  
  // Reminders (authScope — listas/stats por sesión)
  reminders: {
    all: ['reminders'] as const,
    stats: (authScope: string) => ['reminders', 'stats', authScope] as const,
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['reminders', 'list', authScope, filters] as const,
    overdue: (authScope: string) => ['reminders', 'overdue', authScope] as const,
    pending: (authScope: string) => ['reminders', 'pending', authScope] as const,
    byOpportunity: (opportunityId: string) => ['reminders', 'opportunity', opportunityId] as const,
  },
  
  // Pipelines
  pipelines: {
    all: ['pipelines'] as const,
    detail: (id: string) => ['pipelines', 'detail', id] as const,
  },
  
  // Users
  users: {
    all: ['users'] as const,
    list: (filters: Record<string, unknown>) => ['users', 'list', filters] as const,
    detail: (id: string) => ['users', 'detail', id] as const,
  },
  
  // Duplicate Flags (authScope — bandeja y badge por sesión)
  duplicateFlags: {
    all: ['duplicateFlags'] as const,
    stats: (authScope: string) => ['duplicateFlags', 'stats', authScope] as const,
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['duplicateFlags', 'list', authScope, filters] as const,
  },
  
  // Exports
  exports: {
    all: ['exports'] as const,
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['exports', 'list', authScope, filters] as const,
  },

  // WhatsApp inbox (bandeja de entrada de conversaciones)
  whatsappConversations: {
    all: ['whatsappConversations'] as const,
    stats: (authScope: string) => ['whatsappConversations', 'stats', authScope] as const,
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['whatsappConversations', 'list', authScope, filters] as const,
    messages: (contactId: string) => ['whatsappConversations', 'messages', contactId] as const,
  },

  // WhatsApp Templates
  whatsappTemplates: {
    all: ['whatsappTemplates'] as const,
  },

  // Integrations
  integrations: {
    all: ['integrations'] as const,
    detail: (id: string) => ['integrations', 'detail', id] as const,
  },
  
  // Lead Sources
  leadSources: {
    all: ['leadSources'] as const,
  },
  
  // Landing Pages (authScope — listas y métricas por sesión)
  landingPages: {
    all: ['landingPages'] as const,
    list: (authScope: string) => ['landingPages', 'list', authScope] as const,
    detail: (id: string) => ['landingPages', 'detail', id] as const,
    metrics: (authScope: string, id: string, days: number) =>
      ['landingPages', 'metrics', authScope, id, days] as const,
  },
  
  // Audit Logs
  auditLogs: {
    list: (authScope: string, filters: Record<string, unknown>) =>
      ['auditLogs', 'list', authScope, filters] as const,
  },
  
  referralNetworks: {
    all: ['referralNetworks'] as const,
    tree: (authScope: string, rootUserId: string | null, depth: number) =>
      ['referralNetworks', 'tree', authScope, rootUserId ?? 'me', depth] as const,
    list: (authScope: string) => ['referralNetworks', 'list', authScope] as const,
  },
  
  // Dashboard (authScope + pipelineId — RFC caché multi-usuario)
  dashboard: {
    all: (authScope: string) => ['dashboard', authScope] as const,
    briefing: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'briefing', authScope, pipelineId ?? 'all'] as const,
    kpis: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'kpis', authScope, pipelineId ?? 'all'] as const,
    pipeline: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'pipeline', authScope, pipelineId ?? 'default'] as const,
    activity: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'activity', authScope, pipelineId ?? 'all'] as const,
    bantDistribution: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'bantDistribution', authScope, pipelineId ?? 'all'] as const,
    topConsultants: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'topConsultants', authScope, pipelineId ?? 'all'] as const,
    leadSources: (authScope: string, pipelineId?: string) =>
      ['dashboard', 'leadSources', authScope, pipelineId ?? 'all'] as const,
  },
  
  // Search
  search: (query: string) => ['search', query] as const,
  
  // Notifications (authScope — campana global por tenant + usuario)
  notifications: {
    all: ['notifications'] as const,
    unread: (authScope: string) => ['notifications', 'unread', authScope] as const,
  },

  ai: {
    capabilities: ['ai', 'capabilities'] as const,
  },
}

/** Métricas y listas de /contacts (clientes, prospectos, leads calientes, stale). */
export function invalidateContactSegmentMetrics(client: QueryClient) {
  return client.invalidateQueries({ queryKey: queryKeys.contacts.all })
}

/** Tras crear/importar/borrar contactos: listas, stats y dashboard del usuario actual. */
export function invalidateContactsQueries(client: QueryClient) {
  const authScope = getAuthQueryScope()
  return Promise.all([
    invalidateContactSegmentMetrics(client),
    client.invalidateQueries({ queryKey: queryKeys.opportunities.all }),
    authScope
      ? client.invalidateQueries({ queryKey: queryKeys.dashboard.all(authScope) })
      : client.invalidateQueries({ queryKey: ['dashboard'] }),
  ])
}

/** Listado, editor y métricas de /landings tras crear/editar/publicar. */
export async function invalidateLandingPagesQueries(client: QueryClient) {
  await client.invalidateQueries({ queryKey: queryKeys.landingPages.all })
  await client.refetchQueries({ queryKey: queryKeys.landingPages.all, type: 'active' })
}

/** Bandeja /duplicates y badge del nav tras resolver o escanear. */
export function invalidateDuplicateFlagsQueries(client: QueryClient) {
  return client.invalidateQueries({ queryKey: queryKeys.duplicateFlags.all })
}

/** Árbol y listado de /network tras crear/editar/eliminar enlaces. */
export function invalidateReferralNetworkQueries(client: QueryClient) {
  return client.invalidateQueries({ queryKey: queryKeys.referralNetworks.all })
}

/** Campana del header tras crear leads, cambiar etapa, recordatorios, duplicados, etc. */
export function invalidateNotificationsQueries(client: QueryClient) {
  const authScope = getAuthQueryScope()
  if (!authScope) {
    return client.invalidateQueries({ queryKey: queryKeys.notifications.all })
  }
  return client.invalidateQueries({ queryKey: queryKeys.notifications.unread(authScope) })
}

/** Sincroniza bandeja /reminders, badge del nav y briefing/actividad del dashboard (RFC §6.4). */
export function invalidateReminderDashboardQueries(client: QueryClient) {
  const authScope = getAuthQueryScope()
  return Promise.all([
    client.invalidateQueries({ queryKey: queryKeys.reminders.all }),
    client.invalidateQueries({
      queryKey: authScope ? queryKeys.dashboard.all(authScope) : ['dashboard'],
    }),
    invalidateNotificationsQueries(client),
  ])
}
