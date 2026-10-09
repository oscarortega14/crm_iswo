import { cn } from '@/lib/utils'

type PageHeaderProps = {
  title: React.ReactNode
  description?: string
  /** Contenido entre el título y la descripción (p. ej. fecha en el dashboard) */
  belowTitle?: React.ReactNode
  className?: string
  children?: React.ReactNode
}

/**
 * Cabecera de pantalla al estilo del panel principal: título grande, subtítulo y acciones a la derecha.
 */
export function PageHeader({ title, description, belowTitle, className, children }: PageHeaderProps) {
  return (
    <section
      className={cn(
        'flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4',
        className,
      )}
    >
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold tracking-tight text-foreground sm:text-3xl">{title}</h1>
        {belowTitle}
        {description ? (
          // Oculta en mobile: es texto secundario/explicativo, no crítico — en pantallas
          // chicas cuesta más espacio vertical del que vale (ver /whatsapp).
          <p className="hidden max-w-xl text-sm leading-relaxed text-muted-foreground sm:block">
            {description}
          </p>
        ) : null}
      </div>
      {children ? (
        <div className="flex flex-wrap items-center gap-2 sm:pt-1">{children}</div>
      ) : null}
    </section>
  )
}
