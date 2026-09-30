import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import type { OpportunityOwnershipFilter } from '@/lib/opportunityOwnership'

interface OpportunityOwnershipToolbarProps {
  value: OpportunityOwnershipFilter
  onChange: (value: OpportunityOwnershipFilter) => void
  counts: { all: number; own: number; network: number }
  showOwnFilter?: boolean
}

export function OpportunityOwnershipToolbar({
  value,
  onChange,
  counts,
  showOwnFilter = true,
}: OpportunityOwnershipToolbarProps) {
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-lg border border-border/60 bg-muted/20 px-3 py-2 sm:px-4 sm:py-2.5">
      <Tabs
        value={value}
        onValueChange={(next) => onChange(next as OpportunityOwnershipFilter)}
      >
        <TabsList className="h-8">
          <TabsTrigger value="all" className="h-7 px-3 text-xs">
            Todas ({counts.all})
          </TabsTrigger>
          {showOwnFilter ? (
            <TabsTrigger value="own" className="h-7 px-3 text-xs">
              Propias ({counts.own})
            </TabsTrigger>
          ) : null}
          <TabsTrigger value="network" className="h-7 px-3 text-xs">
            Red ({counts.network})
          </TabsTrigger>
        </TabsList>
      </Tabs>
      <p className="hidden text-xs text-muted-foreground sm:block">
        Las oportunidades de consultores referidos se muestran en solo lectura.
      </p>
    </div>
  )
}
