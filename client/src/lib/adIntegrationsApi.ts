import api from '@/lib/api'
import {
  jsonApiPrimaryList,
  jsonApiPrimaryOne,
  type JsonApiResource,
} from '@/lib/opportunityApi'

/** Coincide con `AdIntegration::PROVIDERS` en el API */
export type AdIntegrationProvider = 'meta' | 'google' | 'whatsapp_cloud' | 'openwa'

export type AdIntegrationStatus = 'active' | 'paused' | 'error' | 'revoked'

export interface AdIntegration {
  id: string
  provider: AdIntegrationProvider
  account_identifier: string | null
  status: AdIntegrationStatus
  metadata: Record<string, unknown>
  last_sync_at: string | null
  last_error_at: string | null
  last_error_message: string | null
  healthy: boolean
  has_credentials: boolean
  created_at?: string
  updated_at?: string
}

function mapAdIntegration(resource: JsonApiResource): AdIntegration {
  const a = resource.attributes ?? {}
  const provider = String(a.provider ?? '') as AdIntegrationProvider
  const status = String(a.status ?? 'paused') as AdIntegrationStatus
  return {
    id: String(resource.id ?? ''),
    provider,
    account_identifier:
      a.account_identifier != null && String(a.account_identifier).length > 0
        ? String(a.account_identifier)
        : null,
    status,
    metadata: typeof a.metadata === 'object' && a.metadata != null ? (a.metadata as Record<string, unknown>) : {},
    last_sync_at: a.last_sync_at != null ? String(a.last_sync_at) : null,
    last_error_at: a.last_error_at != null ? String(a.last_error_at) : null,
    last_error_message:
      a.last_error_message != null ? String(a.last_error_message) : null,
    healthy: Boolean(a.healthy),
    has_credentials: Boolean(a.has_credentials),
    created_at: a.created_at != null ? String(a.created_at) : undefined,
    updated_at: a.updated_at != null ? String(a.updated_at) : undefined,
  }
}

/** Expuesto en GET /ad_integrations → meta.integration_webhooks (generado en servidor; sin mocks). */
export interface IntegrationWebhookUrls {
  base_url: string
  meta_verify_get: string
  meta_leads_post: string
  google_leads_post: string
  whatsapp_cloud_verify_get: string
  whatsapp_cloud_post: string
  whatsapp_openwa_post: string
}

export interface AdIntegrationsIndexResult {
  integrations: AdIntegration[]
  webhookUrls: IntegrationWebhookUrls | null
}

export async function fetchAdIntegrations(): Promise<AdIntegrationsIndexResult> {
  const res = await api.get('/ad_integrations', { params: { items: 50 } })
  const raw = res.data?.meta?.integration_webhooks
  const webhookUrls =
    raw != null && typeof raw === 'object' && typeof (raw as IntegrationWebhookUrls).base_url === 'string'
      ? (raw as IntegrationWebhookUrls)
      : null
  return {
    integrations: jsonApiPrimaryList(res.data).map(mapAdIntegration),
    webhookUrls,
  }
}

export async function fetchAdIntegration(id: string): Promise<AdIntegration | null> {
  const res = await api.get(`/ad_integrations/${id}`)
  const one = jsonApiPrimaryOne(res.data)
  return one ? mapAdIntegration(one) : null
}

export interface CreateAdIntegrationPayload {
  provider: AdIntegrationProvider
  account_identifier?: string | null
  credentials: Record<string, string>
  metadata?: Record<string, unknown>
  status?: AdIntegrationStatus
}

export async function createAdIntegration(
  payload: CreateAdIntegrationPayload,
): Promise<AdIntegration> {
  const res = await api.post('/ad_integrations', {
    ad_integration: {
      provider: payload.provider,
      account_identifier: payload.account_identifier ?? undefined,
      credentials: payload.credentials,
      metadata: payload.metadata ?? {},
      status: payload.status ?? 'active',
    },
  })
  const one = jsonApiPrimaryOne(res.data)
  if (!one) throw new Error('Respuesta inválida al crear integración')
  return mapAdIntegration(one)
}

export async function updateAdIntegration(
  id: string,
  payload: Partial<{
    account_identifier: string | null
    credentials: Record<string, string>
    metadata: Record<string, unknown>
    status: AdIntegrationStatus
  }>,
): Promise<AdIntegration> {
  const body = Object.fromEntries(
    Object.entries(payload).filter(([, v]) => v !== undefined),
  ) as Record<string, unknown>
  const res = await api.patch(`/ad_integrations/${id}`, {
    ad_integration: body,
  })
  const one = jsonApiPrimaryOne(res.data)
  if (!one) throw new Error('Respuesta inválida al actualizar integración')
  return mapAdIntegration(one)
}

export async function destroyAdIntegration(id: string): Promise<void> {
  await api.delete(`/ad_integrations/${id}`)
}

export async function disableAdIntegration(id: string): Promise<void> {
  await api.post(`/ad_integrations/${id}/disable`)
}

/** POST — actualiza last_sync_at si OK; 422 con recurso serializado si falla la prueba real */
export async function testAdIntegrationConnection(id: string): Promise<AdIntegration> {
  const res = await api.post(`/ad_integrations/${id}/test_connection`, undefined, {
    validateStatus: (status) => (status >= 200 && status < 300) || status === 422,
  })
  const one = jsonApiPrimaryOne(res.data)
  if (!one) throw new Error('Respuesta inválida tras probar conexión')
  const mapped = mapAdIntegration(one)
  if (res.status === 422) {
    const raw = res.data as { message?: string }
    const detail =
      typeof raw?.message === 'string' && raw.message.trim()
        ? raw.message
        : 'La prueba de conexión falló. Revisa las credenciales o variables del servidor (p. ej. Google OAuth).'
    throw new Error(detail)
  }
  return mapped
}
