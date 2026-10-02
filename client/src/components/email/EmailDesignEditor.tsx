import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react'
import type { Editor } from 'grapesjs'

export interface EmailDesignHandle {
  getProjectData: () => Record<string, unknown>
  /** HTML listo para correo: estilos en línea (preset newsletter + juice). */
  getInlinedHtml: () => string
}

interface Props {
  initialProjectData?: Record<string, unknown>
  /** HTML inicial si no hay proyecto guardado (plantilla base). */
  starterHtml: string
}

/**
 * Editor visual de correos (GrapesJS + preset newsletter, en español).
 * Mismo patrón que GrapeJsEditor de landings, pero con bloques de correo
 * (tablas) y exportación con estilos en línea para Gmail/Outlook.
 */
export const EmailDesignEditor = forwardRef<EmailDesignHandle, Props>(({ initialProjectData, starterHtml }, ref) => {
  const containerRef = useRef<HTMLDivElement>(null)
  const editorRef = useRef<Editor | null>(null)

  useImperativeHandle(ref, () => ({
    getProjectData: () => (editorRef.current?.getProjectData() as Record<string, unknown>) ?? {},
    getInlinedHtml: () => {
      const editor = editorRef.current
      if (!editor) return ''
      return String(editor.runCommand('gjs-get-inlined-html') ?? editor.getHtml())
    },
  }))

  useEffect(() => {
    let editor: Editor | null = null
    let cancelled = false

    ;(async () => {
      const [{ default: grapesjs }, { default: newsletterPlugin }, { default: es }] = await Promise.all([
        import('grapesjs'),
        import('grapesjs-preset-newsletter'),
        import('grapesjs/locale/es.mjs'),
        import('grapesjs/dist/css/grapes.min.css'),
      ])
      if (cancelled || !containerRef.current) return

      editor = grapesjs.init({
        container: containerRef.current,
        plugins: [(e: Editor) => newsletterPlugin(e, { block: (id: string) => ({ label: BLOCK_LABELS[id] ?? id }) })],
        i18n: { locale: 'es', detectLocale: false, messages: { es } },
        storageManager: false,
        height: '100%',
        width: 'auto',
        fromElement: false,
      })

      if (initialProjectData && Object.keys(initialProjectData).length > 0) {
        editor.loadProjectData(initialProjectData as Parameters<Editor['loadProjectData']>[0])
      } else {
        editor.setComponents(starterHtml)
      }

      editorRef.current = editor
    })()

    return () => {
      cancelled = true
      editor?.destroy()
      editorRef.current = null
    }
    // Solo al montar: el diálogo lo monta de nuevo por campaña.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return <div ref={containerRef} className="h-full w-full" />
})

EmailDesignEditor.displayName = 'EmailDesignEditor'

/** Nombres en español de los bloques del preset newsletter. */
const BLOCK_LABELS: Record<string, string> = {
  sect100: '1 columna',
  sect50: '2 columnas',
  sect30: '3 columnas',
  sect37: '2 columnas (30/70)',
  button: 'Botón',
  divider: 'Separador',
  text: 'Texto',
  'text-sect': 'Título y texto',
  image: 'Imagen',
  quote: 'Cita',
  link: 'Enlace',
  'link-block': 'Bloque con enlace',
  'grid-items': 'Tarjetas',
  'list-items': 'Lista',
}

/** Plantilla base: encabezado, saludo con {{nombre}}, texto, botón y firma. */
export function emailStarterHtml(brand: string, color = '#0F172A'): string {
  const safe = brand.replace(/[<>&"]/g, '')
  return `
<table style="width:100%;background-color:#f4f4f5;padding:24px 0;" cellpadding="0" cellspacing="0">
  <tr><td align="center">
    <table style="width:100%;max-width:600px;background-color:#ffffff;border-radius:8px;" cellpadding="0" cellspacing="0">
      <tr><td style="background-color:${color};padding:24px;border-radius:8px 8px 0 0;">
        <h1 style="margin:0;color:#ffffff;font-family:Arial,sans-serif;font-size:22px;">${safe}</h1>
      </td></tr>
      <tr><td style="padding:32px 24px;font-family:Arial,sans-serif;font-size:15px;line-height:24px;color:#27272a;">
        <p style="margin:0 0 16px;">Hola {{nombre|cliente}},</p>
        <p style="margin:0 0 16px;">Escribe aquí el mensaje de tu campaña. Cuéntale a tu cliente qué hay de nuevo y por qué le interesa.</p>
        <p style="margin:24px 0;"><a href="https://" style="display:inline-block;background-color:${color};color:#ffffff;padding:12px 24px;border-radius:6px;text-decoration:none;font-weight:bold;">Quiero saber más</a></p>
        <p style="margin:0;">Un saludo,<br>{{asesor|El equipo de ${safe}}}</p>
      </td></tr>
    </table>
  </td></tr>
</table>`
}
