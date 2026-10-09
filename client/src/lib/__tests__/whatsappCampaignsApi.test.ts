import { describe, expect, it } from 'vitest'
import { isTemplateLaunchable, mapWhatsappCampaign } from '@/lib/whatsappCampaignsApi'

describe('isTemplateLaunchable', () => {
  it('permite plantillas aprobadas o sin sincronizar (la UI avisa)', () => {
    expect(isTemplateLaunchable('APPROVED')).toBe(true)
    expect(isTemplateLaunchable('approved')).toBe(true)
    expect(isTemplateLaunchable(null)).toBe(true)
  })

  it('bloquea plantillas pendientes, rechazadas o pausadas en Meta', () => {
    for (const s of ['PENDING', 'REJECTED', 'PAUSED', 'DISABLED']) expect(isTemplateLaunchable(s)).toBe(false)
  })
})

describe('mapWhatsappCampaign', () => {
  it('lee el estado de la plantilla y el resultado real (delivery_stats)', () => {
    const c = mapWhatsappCampaign({
      id: '7',
      type: 'whatsapp_campaign',
      attributes: {
        name: 'Seguimiento',
        status: 'completed',
        whatsapp_template_meta_status: 'PENDING',
        delivery_stats: { total: 10, pending: 0, sent: 1, delivered: 3, read: 2, failed: 4, skipped: 0 },
      },
    })
    expect(c?.whatsappTemplateMetaStatus).toBe('PENDING')
    expect(c?.deliveryStats).toEqual({ total: 10, pending: 0, sent: 1, delivered: 3, read: 2, failed: 4, skipped: 0 })
  })

  it('borradores sin resultados → deliveryStats null', () => {
    const c = mapWhatsappCampaign({ id: '8', type: 'whatsapp_campaign', attributes: { status: 'draft', delivery_stats: null } })
    expect(c?.deliveryStats).toBeNull()
    expect(c?.whatsappTemplateMetaStatus).toBeNull()
  })
})
