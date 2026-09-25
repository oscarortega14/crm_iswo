// User & Auth Types
export type UserRole = 'admin' | 'manager' | 'consultant' | 'viewer'

export interface User {
  id: string
  email: string
  name: string
  role: UserRole
  avatar_url?: string
  phone?: string
  active: boolean
  last_sign_in_at?: string
  created_at: string
  updated_at: string
}

export interface AuthPayload {
  user: User
  access_token: string
  exp: number
}

export interface TenantSettings {
  stale_days?: number
  /** RFC F2: profundidad de visibilidad de la red para consultores (default 3) */
  network_depth?: number
  show_bant?: boolean
  modules?: string[]
  [key: string]: unknown
}

export interface Tenant {
  id: string
  name: string
  subdomain: string
  logo_url?: string
  primary_color: string
  currency: string
  timezone: string
  settings?: TenantSettings
  created_at: string
}

// Opportunity Types
export type OpportunityStatus = 'new_lead' | 'contacted' | 'qualified' | 'proposal' | 'won' | 'lost'
export type OpportunityTemperature = 'cold' | 'warm' | 'hot'

export interface Opportunity {
  id: string
  title?: string
  contact_id?: string
  contact_name: string
  contact_email?: string
  contact_phone?: string
  company_name?: string
  contact_city?: string
  contact_last_contacted_at?: string
  lead_source_label?: string
  estimated_value: number
  currency: string
  stage_id: string
  stage?: PipelineStage
  pipeline_id: string
  owner_id: string
  owner?: User
  bant_budget: number
  bant_authority: number
  bant_need: number
  bant_timeline: number
  bant_score: number
  source_id?: string
  source?: LeadSource
  status: OpportunityStatus
  temperature: OpportunityTemperature
  qualified?: boolean
  notes?: string
  last_activity_at?: string
  expected_close_on?: string
  reminder_due_at?: string
  custom_fields?: Record<string, unknown>
  from_network?: boolean
  /** RFC §6.3 — consultor: solo lectura en opps de la red */
  network_read_only?: boolean
  created_at: string
  updated_at: string
}

// Tenant Field Definition Types (F5 — Verticales)
export type FieldType = 'text' | 'number' | 'select' | 'date' | 'boolean' | 'currency'
export type FieldEntity = 'opportunity' | 'contact'

export interface TenantFieldDefinition {
  id: string
  key: string
  label: string
  field_type: FieldType
  options: string[]
  required: boolean
  entity: FieldEntity
  position: number
  active: boolean
}

export interface OpportunityLog {
  id: string
  action: string
  changes_data?: Record<string, { from: unknown; to: unknown }>
  note?: string
  author_name?: string
  user?: User
  created_at: string
}

// Pipeline Types
export interface Pipeline {
  id: string
  name: string
  description?: string
  is_default: boolean
  active: boolean
  stages: PipelineStage[]
  created_at: string
  updated_at: string
}

export interface PipelineStage {
  id: string
  pipeline_id: string
  name: string
  position: number
  probability: number
  is_closed_won: boolean
  is_closed_lost: boolean
  color?: string
  /** Disparador de auto-avance (Opportunities::StageAutomation); null = manual. */
  auto_trigger?: StageAutoTrigger | null
}

export type StageAutoTrigger = 'whatsapp_outbound' | 'whatsapp_inbound' | 'bant_qualified'

// Contact Types
export type ContactKind = 'person' | 'company'

export interface Contact {
  id: string
  name: string
  email?: string
  phone?: string
  kind: ContactKind
  company_name?: string
  owner_id: string
  owner?: User
  opportunities_count: number
  last_activity_at?: string
  created_at: string
  updated_at: string
}

// Reminder Types
export type ReminderChannel = 'email' | 'whatsapp' | 'in_app'
export type ReminderStatus = 'pending' | 'sent' | 'failed' | 'done'

export interface Reminder {
  id: string
  opportunity_id: string
  opportunity?: Opportunity
  user_id: string
  user?: User
  channel: ReminderChannel
  status: ReminderStatus
  subject?: string
  message: string
  remind_at: string
  sent_at?: string
  overdue?: boolean
  seconds_until?: number
  created_at: string
}

// WhatsApp Types
export type WhatsAppMessageDirection = 'in' | 'out'
export type WhatsAppMessageStatus = 'sent' | 'delivered' | 'read' | 'failed'

export interface WhatsAppMessage {
  id: string
  opportunity_id: string
  direction: WhatsAppMessageDirection
  content: string
  status: WhatsAppMessageStatus
  created_at: string
}

// Duplicate Flag Types
export type DuplicateFlagResolution = 'pending' | 'merged' | 'reassigned' | 'ignored'

export interface DuplicateFlag {
  id: string
  opportunity_a_id: string
  opportunity_a?: Opportunity
  opportunity_b_id: string
  opportunity_b?: Opportunity
  resolution: DuplicateFlagResolution
  resolved_by_id?: string
  resolved_by?: User
  resolved_at?: string
  created_at: string
}

// Export Types
export type ExportStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'expired'
export type ExportFormat = 'csv' | 'xlsx'

export interface Export {
  id: string
  user_id: string
  user?: User
  format: ExportFormat
  status: ExportStatus
  filters: Record<string, unknown>
  download_url?: string
  expires_at?: string
  created_at: string
}

// Integration Types
export type IntegrationType = 'meta_ads' | 'google_ads' | 'whatsapp' | 'twilio'
export type IntegrationStatus = 'connected' | 'disconnected' | 'error'

export interface Integration {
  id: string
  type: IntegrationType
  status: IntegrationStatus
  credentials: Record<string, string>
  webhook_url?: string
  last_sync_at?: string
  created_at: string
  updated_at: string
}

// Lead Source Types
export type LeadSourceKind = 'web' | 'whatsapp' | 'meta' | 'google' | 'manual' | 'referral'

export interface LeadSource {
  id: string
  name: string
  kind: LeadSourceKind
  active: boolean
  opportunities_count: number
  created_at: string
}

// Landing Page Types
export interface LandingPage {
  id: string
  title: string
  slug: string
  content: string
  is_published: boolean
  thumbnail_url?: string
  visits_count: number
  leads_count: number
  created_at: string
  updated_at: string
}

// Audit Log Types
export interface AuditLog {
  id: string
  user_id: string
  user?: User
  action: string
  resource_type: string
  resource_id: string
  ip_address: string
  metadata?: Record<string, unknown>
  created_at: string
}

// Network Types
export interface NetworkNode {
  id: string
  name: string
  avatar_url?: string
  opportunities_won: number
  depth: number
}

export interface NetworkEdge {
  source: string
  target: string
  referral_count: number
}

// Search Types
export interface SearchResult {
  type: 'contact' | 'opportunity' | 'page'
  id: string
  title: string
  subtitle?: string
  url: string
}

// API Response Types
export interface ApiResponse<T> {
  data: T
  meta?: {
    total: number
    page: number
    per_page: number
  }
}

export interface ApiError {
  errors: Array<{
    status: string
    code: string
    title: string
    detail: string
    source?: { pointer?: string; parameter?: string }
  }>
}

// Notification Types
export interface Notification {
  id: string
  type: 'reminder_due' | 'stage_change' | 'new_lead' | 'duplicate_found'
  title: string
  message: string
  opportunity_id?: string
  read_at?: string
  created_at: string
}
