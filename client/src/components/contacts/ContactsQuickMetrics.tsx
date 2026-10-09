import { Flame, PhoneOff, Target, UserCheck } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { cn } from '@/lib/utils'
import type { ContactQuickStats, ContactSegment } from '@/lib/contactApi'

const METRICS: {
  key: ContactSegment
  label: string
  emoji: string
  icon: typeof UserCheck
  iconClass: string
  activeRing: string
}[] = [
  {
    key: 'clients',
    label: 'Clientes',
    emoji: '🟢',
    icon: UserCheck,
    iconClass: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-400',
    activeRing: 'ring-emerald-500/40 border-emerald-500/50',
  },
  {
    key: 'prospects',
    label: 'Prospectos',
    emoji: '🟡',
    icon: Target,
    iconClass: 'bg-amber-500/15 text-amber-600 dark:text-amber-400',
    activeRing: 'ring-amber-500/40 border-amber-500/50',
  },
  {
    key: 'hot_leads',
    label: 'Leads calientes',
    emoji: '🔥',
    icon: Flame,
    iconClass: 'bg-red-500/15 text-red-600 dark:text-red-400',
    activeRing: 'ring-red-500/40 border-red-500/50',
  },
  {
    key: 'stale',
    label: 'Sin actividad',
    emoji: '📞',
    icon: PhoneOff,
    iconClass: 'bg-sky-500/15 text-sky-600 dark:text-sky-400',
    activeRing: 'ring-sky-500/40 border-sky-500/50',
  },
]

interface ContactsQuickMetricsProps {
  stats?: ContactQuickStats
  activeSegment?: ContactSegment
  isLoading?: boolean
  onSegmentChange: (segment: ContactSegment | undefined) => void
}

export function ContactsQuickMetrics({
  stats,
  activeSegment,
  isLoading,
  onSegmentChange,
}: ContactsQuickMetricsProps) {
  const valueFor = (key: ContactSegment) => {
    if (!stats) return '—'
    switch (key) {
      case 'clients':
        return stats.clients
      case 'prospects':
        return stats.prospects
      case 'hot_leads':
        return stats.hot_leads
      case 'stale':
        return stats.stale
    }
  }

  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      {METRICS.map(({ key, label, emoji, icon: Icon, iconClass, activeRing }) => {
        const active = activeSegment === key
        return (
          <Card
            key={key}
            role="button"
            tabIndex={0}
            className={cn(
              'cursor-pointer gap-0 py-0 transition-all hover:shadow-md sm:py-6',
              active && `ring-2 ${activeRing}`,
            )}
            onClick={() => onSegmentChange(active ? undefined : key)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault()
                onSegmentChange(active ? undefined : key)
              }
            }}
          >
            <CardContent className="px-3 py-3 sm:px-6 sm:pt-4 sm:pb-3">
              <div className="flex items-center gap-2.5 sm:gap-3">
                <div
                  className={cn(
                    'flex h-8 w-8 shrink-0 items-center justify-center rounded-lg sm:h-10 sm:w-10',
                    iconClass,
                  )}
                >
                  <Icon className="h-4 w-4 sm:h-5 sm:w-5" aria-hidden />
                </div>
                <div className="min-w-0">
                  <p className="text-xl font-semibold tabular-nums sm:text-2xl">
                    {isLoading ? '…' : valueFor(key)}
                  </p>
                  <p className="text-xs leading-tight text-muted-foreground sm:truncate">
                    <span className="mr-1" aria-hidden>
                      {emoji}
                    </span>
                    {label}
                  </p>
                </div>
              </div>
            </CardContent>
          </Card>
        )
      })}
    </div>
  )
}
