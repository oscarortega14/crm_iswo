import { cn } from '@/lib/utils'

type AppPageShellProps = {
  children: React.ReactNode
  /** Clases del contenedor exterior (p. ej. `h-full` para tablero a altura fija) */
  className?: string
  /** Clases del bloque con padding (p. ej. `space-y-10` en el dashboard) */
  contentClassName?: string
}

/**
 * Contenedor de página alineado con el panel principal: padding lateral y ritmo
 * vertical homogéneo. El espacio de la barra móvil ya lo reserva `<main>` (pb-16
 * en AppLayout); no duplicarlo aquí.
 */
export function AppPageShell({ children, className, contentClassName }: AppPageShellProps) {
  return (
    <div className={cn('relative flex min-h-full flex-col pb-2 lg:pb-6', className)}>
      <div
        className={cn('flex w-full max-w-[100vw] flex-1 flex-col gap-4 p-3 sm:gap-8 sm:p-4 lg:p-6', contentClassName)}
      >
        {children}
      </div>
    </div>
  )
}
