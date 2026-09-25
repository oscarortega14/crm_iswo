import { useMemo, useState } from 'react'
import {
  useReactTable,
  getCoreRowModel,
  getSortedRowModel,
  getFilteredRowModel,
  getPaginationRowModel,
  flexRender,
  createColumnHelper,
  type SortingState,
  type ColumnFiltersState,
  type VisibilityState,
} from '@tanstack/react-table'
import { ArrowUpDown, ChevronDown, Settings2 } from 'lucide-react'
import { Checkbox } from '@/components/ui/checkbox'
import {
  cn,
  formatCurrency,
  formatRelativeTime,
  getBantScoreColor,
  getStatusColor,
  formatStatusLabel,
} from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { OpportunityLeadRow } from '@/components/opportunities/OpportunityLeadRow'
import { OpportunityOwnershipBadge } from '@/components/opportunities/OpportunityOwnershipBadge'
import { formatStageTimePain, getStageEmoji } from '@/lib/opportunityVisuals'
import type { Opportunity } from '@/types'
import { TemperatureBadge } from '@/components/opportunities/TemperatureBadge'
const COLUMN_LABELS: Record<string, string> = {
  contact_name:    'Contacto',
  temperature:     'Temperatura',
  ownership:       'Origen',
  estimated_value: 'Valor',
  stage:           'Etapa',
  bant_score:      'BANT',
  status:          'Estado',
  owner:           'Propietario',
  last_activity_at:'Última actividad',
}

interface OpportunitiesTableProps {
  opportunities: Opportunity[]
  onSelectOpportunity: (id: string) => void
  /** Muestra checkboxes de selección (acciones en lote: mover etapa, eliminar). */
  selectable?: boolean
  /** Filas que el usuario puede seleccionar (p.ej. consultor: solo propias). */
  isRowSelectable?: (opportunity: Opportunity) => boolean
  selectedIds?: Set<string>
  onSelectionChange?: (id: string, selected: boolean) => void
  onSelectAllOnPage?: (selected: boolean, pageIds: string[]) => void
}

const columnHelper = createColumnHelper<Opportunity>()

export function OpportunitiesTable({
  opportunities,
  onSelectOpportunity,
  selectable = false,
  isRowSelectable,
  selectedIds,
  onSelectionChange,
  onSelectAllOnPage,
}: OpportunitiesTableProps) {
  const [sorting, setSorting] = useState<SortingState>([])
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([])
  const [columnVisibility, setColumnVisibility] = useState<VisibilityState>({
    id: false,
    pipeline_id: false,
    owner_id: false,
  })

  const columns = useMemo(
    () => [
      columnHelper.accessor('id', {
        header: 'ID',
        cell: (info) => <span className="font-mono text-xs">{info.getValue()}</span>,
      }),
      columnHelper.accessor('contact_name', {
        header: ({ column }) => (
          <Button
            variant="ghost"
            size="sm"
            className="-ml-3 h-8"
            onClick={() => column.toggleSorting(column.getIsSorted() === 'asc')}
          >
            Contacto
            <ArrowUpDown className="ml-2 size-4" />
          </Button>
        ),
        cell: (info) => {
          const row = info.row.original
          return (
            <div className="flex flex-col gap-1 min-w-0 max-w-[220px]">
              <OpportunityLeadRow
                size="md"
                className="min-w-0"
                contactName={info.getValue()}
                customFields={row.custom_fields}
                propertyTitle={row.title}
              />
              {row.company_name && (
                <span className="text-xs text-muted-foreground">
                  {row.company_name}
                </span>
              )}
            </div>
          )
        },
      }),
      columnHelper.accessor('temperature', {
        header: 'Temp.',
        cell: (info) => (
          <TemperatureBadge temperature={info.getValue() ?? 'cold'} showLabel />
        ),
      }),
      columnHelper.display({
        id: 'ownership',
        header: 'Origen',
        cell: ({ row }) => (
          <OpportunityOwnershipBadge opportunity={row.original} showLabel />
        ),
      }),
      columnHelper.accessor('estimated_value', {
        header: ({ column }) => (
          <Button
            variant="ghost"
            size="sm"
            className="-ml-3 h-8"
            onClick={() => column.toggleSorting(column.getIsSorted() === 'asc')}
          >
            Valor
            <ArrowUpDown className="ml-2 size-4" />
          </Button>
        ),
        cell: (info) => (
          <span className="font-mono">
            {formatCurrency(info.getValue(), info.row.original.currency)}
          </span>
        ),
      }),
      columnHelper.accessor('stage', {
        header: 'Etapa',
        cell: (info) => {
          const stage = info.getValue()
          const row = info.row.original
          if (!stage) return null
          const pain = formatStageTimePain(row.updated_at)
          return (
            <span
              className={cn(
                'inline-flex items-center gap-1 text-xs tabular-nums',
                pain.urgent ? 'font-semibold text-amber-600 dark:text-amber-400' : 'text-muted-foreground',
              )}
              title={stage.name}
            >
              <span aria-hidden>{getStageEmoji(stage.name)}</span>
              <span>{pain.label}</span>
            </span>
          )
        },
      }),
      columnHelper.accessor('bant_score', {
        header: ({ column }) => (
          <Button
            variant="ghost"
            size="sm"
            className="-ml-3 h-8"
            onClick={() => column.toggleSorting(column.getIsSorted() === 'asc')}
          >
            BANT
            <ArrowUpDown className="ml-2 size-4" />
          </Button>
        ),
        cell: (info) => {
          const score = info.getValue()
          return (
            <Badge className={cn('font-mono', getBantScoreColor(score))}>
              {score}
            </Badge>
          )
        },
      }),
      columnHelper.accessor('status', {
        header: 'Estado',
        cell: (info) => (
          <Badge variant="secondary" className={cn(getStatusColor(info.getValue()))}>
            {formatStatusLabel(info.getValue())}
          </Badge>
        ),
      }),
      columnHelper.accessor('owner', {
        header: 'Propietario',
        cell: (info) => {
          const owner = info.getValue()
          if (!owner) return null
          return (
            <span className="text-sm truncate max-w-[140px]">{owner.name}</span>
          )
        },
      }),
      columnHelper.accessor('last_activity_at', {
        header: ({ column }) => (
          <Button
            variant="ghost"
            size="sm"
            className="-ml-3 h-8"
            onClick={() => column.toggleSorting(column.getIsSorted() === 'asc')}
          >
            Última actividad
            <ArrowUpDown className="ml-2 size-4" />
          </Button>
        ),
        cell: (info) => {
          const date = info.getValue()
          return date ? (
            <span className="text-sm text-muted-foreground">
              {formatRelativeTime(date)}
            </span>
          ) : (
            <span className="text-sm text-muted-foreground">-</span>
          )
        },
      }),
    ],
    [],
  )

  const table = useReactTable({
    data: opportunities,
    columns,
    state: { sorting, columnFilters, columnVisibility },
    onSortingChange: setSorting,
    onColumnFiltersChange: setColumnFilters,
    onColumnVisibilityChange: setColumnVisibility,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getPaginationRowModel: getPaginationRowModel(),
  })

  const pageRows = table.getRowModel().rows
  const canSelectRow = (opp: Opportunity) => !isRowSelectable || isRowSelectable(opp)
  const pageIds = pageRows.filter((r) => canSelectRow(r.original)).map((r) => r.original.id)
  const allOnPageSelected =
    selectable &&
    pageIds.length > 0 &&
    pageIds.every((id) => selectedIds?.has(id))
  const someOnPageSelected =
    selectable && pageIds.some((id) => selectedIds?.has(id))

  return (
    <div className="flex flex-col h-full">
      {/* Toolbar */}
      <div className="flex items-center gap-2 px-4 py-3 border-b lg:px-6">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="outline" size="sm" className="ml-auto gap-1.5">
              <Settings2 className="size-4" />
              Columnas
              <ChevronDown className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            {table
              .getAllColumns()
              .filter((column) => column.getCanHide())
              .map((column) => (
                <DropdownMenuCheckboxItem
                  key={column.id}
                  checked={column.getIsVisible()}
                  onCheckedChange={(value) => column.toggleVisibility(!!value)}
                >
                  {COLUMN_LABELS[column.id] ?? column.id}
                </DropdownMenuCheckboxItem>
              ))}
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      {/* Table */}
      <div className="flex-1 overflow-auto">
        <table className="w-full">
          <thead className="sticky top-0 bg-background border-b">
            {table.getHeaderGroups().map((headerGroup) => (
              <tr key={headerGroup.id}>
                {selectable && (
                  <th className="h-10 w-10 px-2 text-left align-middle">
                    <Checkbox
                      checked={
                        allOnPageSelected ? true : someOnPageSelected ? 'indeterminate' : false
                      }
                      onCheckedChange={(checked) =>
                        onSelectAllOnPage?.(checked === true, pageIds)
                      }
                      onClick={(e) => e.stopPropagation()}
                      disabled={pageIds.length === 0}
                      aria-label="Seleccionar página"
                    />
                  </th>
                )}
                {headerGroup.headers.map((header) => (
                  <th
                    key={header.id}
                    className="h-10 px-4 text-left align-middle font-medium text-muted-foreground text-sm"
                  >
                    {header.isPlaceholder
                      ? null
                      : flexRender(
                          header.column.columnDef.header,
                          header.getContext()
                        )}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {table.getRowModel().rows.length === 0 ? (
              <tr>
                <td
                  colSpan={columns.length + (selectable ? 1 : 0)}
                  className="h-24 text-center text-muted-foreground"
                >
                  No hay oportunidades
                </td>
              </tr>
            ) : (
              pageRows.map((row) => (
                <tr
                  key={row.id}
                  onClick={() => onSelectOpportunity(row.original.id)}
                  className={cn(
                    'border-b cursor-pointer hover:bg-muted/50 transition-colors',
                    selectedIds?.has(row.original.id) && 'bg-muted/40',
                    row.original.status === 'lost' && 'opacity-50 bg-muted/20',
                    row.original.status === 'won'  && 'bg-green-50/40 dark:bg-green-950/20',
                  )}
                >
                  {selectable && (
                    <td
                      className="w-10 px-2 py-3 align-middle"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <Checkbox
                        checked={selectedIds?.has(row.original.id) ?? false}
                        disabled={!canSelectRow(row.original)}
                        onCheckedChange={(checked) =>
                          onSelectionChange?.(row.original.id, checked === true)
                        }
                        aria-label={`Seleccionar ${row.original.contact_name}`}
                      />
                    </td>
                  )}
                  {row.getVisibleCells().map((cell) => (
                    <td key={cell.id} className="px-4 py-3 align-middle">
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      <div className="flex items-center justify-between px-4 py-3 border-t lg:px-6">
        <p className="text-sm text-muted-foreground">
          {table.getFilteredRowModel().rows.length} oportunidad(es)
        </p>
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => table.previousPage()}
            disabled={!table.getCanPreviousPage()}
          >
            Anterior
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => table.nextPage()}
            disabled={!table.getCanNextPage()}
          >
            Siguiente
          </Button>
        </div>
      </div>
    </div>
  )
}
