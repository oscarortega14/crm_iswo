import { describe, expect, it } from 'vitest'
import { mapContactOrigins, originDetail, originKindLabel } from '@/lib/contactOrigins'

describe('contactOrigins', () => {
  it('traduce el tipo de origen y deja pasar los desconocidos', () => {
    expect(originKindLabel('import')).toBe('Importación')
    expect(originKindLabel('web')).toBe('Landing')
    expect(originKindLabel('whatsapp')).toBe('Escribió por WhatsApp')
    expect(originKindLabel('otro')).toBe('otro')
  })

  it('oculta el «inbound» técnico de WhatsApp en el detalle', () => {
    expect(originDetail({ kind: 'whatsapp', label: 'inbound' })).toBeNull()
    expect(originDetail({ kind: 'import', label: 'Excel: base.xlsx' })).toBe('Excel: base.xlsx')
  })

  it('mapea la lista del backend e ignora entradas inválidas', () => {
    expect(
      mapContactOrigins([
        { kind: 'import', label: 'Excel: base.xlsx', at: '2026-09-20T10:00:00Z' },
        { label: 'sin tipo' },
        null,
      ]),
    ).toEqual([{ kind: 'import', label: 'Excel: base.xlsx', at: '2026-09-20T10:00:00Z' }])
    expect(mapContactOrigins(undefined)).toEqual([])
  })
})
