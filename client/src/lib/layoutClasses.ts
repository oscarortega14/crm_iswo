/**
 * Rejilla de tarjetas de resumen (KPIs): en celular van de a 2 por fila y
 * compactas (sin el relleno de 24 px de `Card`); si el número de tarjetas es
 * impar, la última ocupa toda la fila. Desde `md` cada página agrega sus
 * columnas (p. ej. `md:grid-cols-4`) y las tarjetas recuperan su relleno.
 *
 * String plano (no `cn`) para que tailwind-merge no descarte las variantes.
 */
export const statGridClass =
  'grid grid-cols-2 gap-3 md:gap-4 ' +
  'max-md:[&>[data-slot=card]]:gap-2 max-md:[&>[data-slot=card]]:py-3 ' +
  'max-md:[&_[data-slot=card-header]]:px-3 max-md:[&_[data-slot=card-content]]:px-3 ' +
  'max-md:[&_[data-slot=card-content]]:pt-0 ' +
  'max-md:[&>*:last-child:nth-child(odd)]:col-span-2'
