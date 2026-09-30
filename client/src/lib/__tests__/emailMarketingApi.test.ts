import { describe, expect, it } from 'vitest'
import { mapEmailCampaign } from '@/lib/emailMarketingApi'
import { emailStarterHtml } from '@/components/email/EmailDesignEditor'

describe('mapEmailCampaign', () => {
  it('lee resultados, audiencia y el contenido del detalle', () => {
    const c = mapEmailCampaign({
      id: '3',
      type: 'email_campaign',
      attributes: {
        name: 'Boletín ISO',
        subject: 'Hola {{nombre}}',
        status: 'completed',
        audience_filters: { lead_source_id: '9', kind: 'company' },
        body_html: '<p>Hola</p>',
        body_design: { pages: [] },
        result_stats: { total: 5, delivered: 2, opened: 1, clicked: 1, bounced: 1 },
      },
    })
    expect(c?.audienceFilters).toEqual({ lead_source_id: '9', kind: 'company' })
    expect(c?.bodyHtml).toBe('<p>Hola</p>')
    expect(c?.resultStats).toMatchObject({ total: 5, delivered: 2, opened: 1, clicked: 1, bounced: 1, failed: 0 })
  })

  it('borradores sin resultados ni contenido (listado)', () => {
    const c = mapEmailCampaign({ id: '4', type: 'email_campaign', attributes: { name: 'x', status: 'draft' } })
    expect(c?.resultStats).toBeNull()
    expect(c?.bodyHtml).toBeUndefined()
    expect(c?.scheduledAt).toBeNull()
  })
})

describe('emailStarterHtml', () => {
  it('usa la marca sin inyectar HTML e incluye variables', () => {
    const html = emailStarterHtml('ISWO <script>', '#123456')
    expect(html).toContain('ISWO script')
    expect(html).not.toContain('<script>')
    expect(html).toContain('{{nombre|cliente}}')
    expect(html).toContain('#123456')
  })
})

describe('countriesSummary', () => {
  it('ordena de más a menos y traduce el país', async () => {
    const { countriesSummary } = await import('@/components/campaigns/ContactOriginSelect')
    expect(countriesSummary({ CO: 3, EC: 120 })).toBe('Ecuador 120 · Colombia 3')
    expect(countriesSummary({ '??': 2 })).toBe('Número no válido 2')
  })
})
