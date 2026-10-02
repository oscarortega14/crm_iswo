import { useQuery } from '@tanstack/react-query'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { cn } from '@/lib/utils'
import { getAuthQueryScope } from '@/lib/queryClient'
import { fetchContactOriginOptions } from '@/lib/contactApi'

const ANY = '__any__'

/**
 * Filtro de audiencia «Origen del contacto» (archivo importado, landing,
 * WhatsApp…) para campañas de WhatsApp y de correo. Muestra cuántos
 * contactos llegaron por cada origen.
 */
export function ContactOriginSelect({
  value,
  onChange,
  className,
}: {
  value: string | undefined
  onChange: (value: string | undefined) => void
  className?: string
}) {
  const { data: options = [] } = useQuery({
    queryKey: ['contacts', 'originOptions', getAuthQueryScope()],
    queryFn: fetchContactOriginOptions,
    staleTime: 60_000,
  })

  return (
    <Select value={value ?? ANY} onValueChange={(v) => onChange(v === ANY ? undefined : v)}>
      <SelectTrigger className={cn('min-w-0', className)} aria-label="Origen del contacto">
        <SelectValue placeholder="Origen del contacto" />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={ANY}>Cualquier origen del contacto</SelectItem>
        {options.map((o) => (
          <SelectItem key={o.label} value={o.label}>
            <span className="truncate">{o.label}</span>
            <span className="ml-2 text-xs text-muted-foreground tabular-nums">({o.count})</span>
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

const regionNames = (() => {
  try {
    return new Intl.DisplayNames(['es'], { type: 'region' })
  } catch {
    return null
  }
})()

/** «EC» → «Ecuador»; «??» → «Número no válido». */
export function countryLabel(code: string): string {
  if (code === '??') return 'Número no válido'
  return regionNames?.of(code) ?? code
}

/** Resumen «Ecuador 120 · Colombia 3», del país con más números al de menos. */
export function countriesSummary(countries: Record<string, number>): string {
  return Object.entries(countries)
    .sort((a, b) => b[1] - a[1])
    .map(([code, n]) => `${countryLabel(code)} ${n}`)
    .join(' · ')
}
