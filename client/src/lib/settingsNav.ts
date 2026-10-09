import type { LucideIcon } from 'lucide-react'
import {
  LayoutDashboard,
  Target,
  Users,
  Bell,
  Share2,
  Copy,
  Download,
  Globe,
  Settings,
  GitBranch,
  Megaphone,
  UserCog,
  Plug,
  Gauge,
  ListChecks,
  FileSearch,
  Building2,
  MessageCircle,
  Mail,
  Bot,
} from 'lucide-react'
import type { Tenant, UserRole } from '@/types'
import { isPlatformTenant } from '@/lib/platformTenant'
import { tenantHasModule, tenantShowBant, type TenantModule } from '@/lib/tenantModules'

export type MainNavItem = {
  href: string
  label: string
  icon: LucideIcon
  roles: UserRole[]
  module?: TenantModule
}

export type SettingsNavItem = {
  href: string
  label: string
  title: string
  description: string
  icon: LucideIcon
  roles: UserRole[]
  /** Oculto en tenant plataforma super-admin (RFC F5). */
  commercialOnly?: boolean
  visible?: (tenant: Tenant | null | undefined) => boolean
}

/** Orden del sidebar super-admin (RFC F5). */
const PLATFORM_SETTINGS_ORDER = [
  '/settings/tenant-onboarding',
  '/settings/users',
  '/settings/audit',
] as const

const PLATFORM_SIDEBAR_LABELS: Partial<Record<(typeof PLATFORM_SETTINGS_ORDER)[number], string>> = {
  '/settings/tenant-onboarding': 'Tenants',
  '/settings/users': 'Operadores',
  '/settings/audit': 'Auditoría',
}

export type SidebarSections = {
  isPlatform: boolean
  main: MainNavItem[]
  sections: { label: string; items: SettingsNavItem[] }[]
}

export const MAIN_NAV_ITEMS: MainNavItem[] = [
  {
    href: '/',
    label: 'Dashboard',
    icon: LayoutDashboard,
    roles: ['admin', 'manager', 'consultant', 'viewer'],
  },
  {
    href: '/opportunities',
    label: 'Oportunidades',
    icon: Target,
    roles: ['admin', 'manager', 'consultant', 'viewer'],
    module: 'opportunities',
  },
  {
    href: '/contacts',
    label: 'Contactos',
    icon: Users,
    roles: ['admin', 'manager', 'consultant', 'viewer'],
    module: 'contacts',
  },
  {
    href: '/whatsapp',
    label: 'WhatsApp',
    icon: MessageCircle,
    roles: ['admin', 'manager', 'consultant', 'viewer'],
  },
  {
    href: '/email',
    label: 'Email marketing',
    icon: Mail,
    roles: ['admin', 'manager'],
  },
  {
    href: '/reminders',
    label: 'Recordatorios',
    icon: Bell,
    roles: ['admin', 'manager', 'consultant'],
    module: 'reminders',
  },
  {
    href: '/network',
    label: 'Red de referidos',
    icon: Share2,
    roles: ['admin', 'manager', 'consultant'],
    module: 'network',
  },
  {
    href: '/duplicates',
    label: 'Duplicados',
    icon: Copy,
    roles: ['admin', 'manager', 'consultant'],
    module: 'opportunities',
  },
  {
    href: '/exports',
    label: 'Exportaciones',
    icon: Download,
    roles: ['admin', 'manager'],
    module: 'exports',
  },
  {
    href: '/landings',
    label: 'Landing pages',
    icon: Globe,
    roles: ['admin', 'manager', 'consultant', 'viewer'],
    module: 'landings',
  },
]

export const SETTINGS_NAV_ITEMS: SettingsNavItem[] = [
  {
    href: '/settings/general',
    label: 'General',
    title: 'General',
    description: 'Días sin actividad y profundidad de la red de referidos',
    icon: Settings,
    roles: ['admin'],
    commercialOnly: true,
  },
  {
    href: '/settings/pipelines',
    label: 'Pipelines',
    title: 'Pipelines y etapas',
    description: 'Embudos comerciales y etapas del Kanban',
    icon: GitBranch,
    roles: ['admin'],
    commercialOnly: true,
    visible: (tenant) => tenantHasModule(tenant, 'pipeline'),
  },
  {
    href: '/settings/lead-sources',
    label: 'Fuentes de lead',
    title: 'Fuentes de lead',
    description: 'Orígenes de oportunidades y landings',
    icon: Megaphone,
    roles: ['admin', 'manager'],
    commercialOnly: true,
    visible: (tenant) => tenantHasModule(tenant, 'opportunities'),
  },
  {
    href: '/settings/users',
    label: 'Usuarios',
    title: 'Usuarios',
    description: 'Invitaciones, roles y acceso al CRM',
    icon: UserCog,
    roles: ['admin'],
    visible: (t) => !isPlatformTenant(t),
  },
  {
    href: '/settings/users',
    label: 'Operadores',
    title: 'Operadores de plataforma',
    description: 'Administradores del tenant super-admin',
    icon: UserCog,
    roles: ['admin'],
    visible: (t) => isPlatformTenant(t),
  },
  {
    href: '/settings/integrations',
    label: 'Integraciones',
    title: 'Integraciones',
    description: 'Meta, Google Ads y WhatsApp Business',
    icon: Plug,
    roles: ['admin', 'manager'],
    commercialOnly: true,
  },
  {
    href: '/settings/ai-agent',
    label: 'Asistente IA',
    title: 'Asistente IA de WhatsApp',
    description: 'Responde, califica y pasa al asesor por WhatsApp',
    icon: Bot,
    roles: ['admin', 'manager'],
    commercialOnly: true,
  },
  {
    href: '/settings/bant',
    label: 'BANT',
    title: 'Calificación BANT',
    description: 'Pesos, umbral de calificación y días sin actividad',
    icon: Gauge,
    roles: ['admin'],
    commercialOnly: true,
    visible: (tenant) => tenantShowBant(tenant),
  },
  {
    href: '/settings/fields',
    label: 'Campos',
    title: 'Campos personalizados',
    description: 'Definiciones por contacto y oportunidad',
    icon: ListChecks,
    roles: ['admin'],
    commercialOnly: true,
  },
  {
    href: '/settings/audit',
    label: 'Auditoría',
    title: 'Registro de auditoría',
    description: 'Bitácora inmutable de acciones en el tenant',
    icon: FileSearch,
    roles: ['admin', 'manager'],
    visible: (t) => !isPlatformTenant(t),
  },
  {
    href: '/settings/audit',
    label: 'Auditoría',
    title: 'Auditoría de plataforma',
    description: 'Onboarding de tenants y actividad de operadores super-admin',
    icon: FileSearch,
    roles: ['admin'],
    visible: (t) => isPlatformTenant(t),
  },
  {
    href: '/settings/tenant-onboarding',
    label: 'Tenants',
    title: 'Tenants',
    description: 'Alta, activación y administración de empresas cliente',
    icon: Building2,
    roles: ['admin'],
    visible: (tenant) => isPlatformTenant(tenant),
  },
]

function roleAllowed(role: UserRole | undefined, allowed: UserRole[]): boolean {
  return Boolean(role && allowed.includes(role))
}

export function filterMainNav(
  items: MainNavItem[],
  role: UserRole | undefined,
  tenant: Tenant | null | undefined,
): MainNavItem[] {
  if (isPlatformTenant(tenant)) {
    return []
  }

  return items.filter((item) => {
    if (!roleAllowed(role, item.roles)) return false
    if (item.module && !tenantHasModule(tenant, item.module)) return false
    return true
  })
}

export function filterSettingsNav(
  role: UserRole | undefined,
  tenant: Tenant | null | undefined,
): SettingsNavItem[] {
  const platform = isPlatformTenant(tenant)
  const items = SETTINGS_NAV_ITEMS.filter((item) => {
    if (!roleAllowed(role, item.roles)) return false
    if (platform && item.commercialOnly) return false
    if (item.visible && !item.visible(tenant)) return false
    return true
  })

  if (!platform) return items

  const order = PLATFORM_SETTINGS_ORDER as readonly string[]
  return items
    .slice()
    .sort((a, b) => order.indexOf(a.href) - order.indexOf(b.href))
    .map((item) => ({
      ...item,
      label: PLATFORM_SIDEBAR_LABELS[item.href as keyof typeof PLATFORM_SIDEBAR_LABELS] ?? item.label,
    }))
}

/** Sidebar principal + secciones (comercial vs plataforma). */
export function getSidebarSections(
  role: UserRole | undefined,
  tenant: Tenant | null | undefined,
): SidebarSections {
  const platform = isPlatformTenant(tenant)
  const main = filterMainNav(MAIN_NAV_ITEMS, role, tenant)
  const settings = filterSettingsNav(role, tenant)

  if (platform) {
    return {
      isPlatform: true,
      main: [],
      sections: settings.length ? [{ label: 'Plataforma', items: settings }] : [],
    }
  }

  return {
    isPlatform: false,
    main,
    sections: settings.length ? [{ label: 'Configuración', items: settings }] : [],
  }
}
