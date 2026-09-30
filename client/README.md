# CRM ISWO — Frontend

SPA en React + Vite + TypeScript. UI con Radix + Tailwind v4.

## Requisitos

- **Node >= 20** (ver `.nvmrc`). Node 18 **no funciona**: `@tailwindcss/oxide` requiere Node >= 20 para su binding nativo; con una versión menor, `pnpm install` lo omite en silencio y `vite dev` falla con `Cannot find native binding`.
- **pnpm** (único gestor soportado en este proyecto, no usar `npm` ni `yarn`).
- Backend del CRM corriendo aparte (por defecto se espera en `http://localhost:3000`).

Si usás [nvm](https://github.com/nvm-sh/nvm):

```bash
nvm install   # instala/usa la versión fijada en .nvmrc
nvm use
```

## Instalación

```bash
pnpm install
```

## Variables de entorno

Copiar el ejemplo y ajustar según tu entorno:

```bash
cp .env.example .env
```

| Variable | Descripción |
|---|---|
| `VITE_API_BASE_URL` | Prefijo de las rutas de API (default `/api/v1`) |
| `VITE_BACKEND_ORIGIN` | Origen del backend (default `http://localhost:3000`) |
| `VITE_FRONTEND_PORT` | Puerto donde corre este frontend (default `3001`) |
| `VITE_LANDING_PUBLIC_HOST` | (opcional) URL pública de landings, ej. ngrok, para pruebas de páginas públicas |
| `VITE_TENANT_SLUG` | Slug de tenant por defecto en login / recuperar contraseña (debe existir en la BD) |
| `API_PUBLIC_ORIGIN` | URL pública del backend (ej. ngrok) cuando se prueban integraciones externas |

## Ejecutar en local

```bash
pnpm dev
```

Levanta en `http://localhost:3001` (o el puerto configurado en `VITE_FRONTEND_PORT`). Requiere que el backend esté corriendo en `VITE_BACKEND_ORIGIN`; si no, las llamadas a la API fallan.

## Otros comandos

```bash
pnpm build          # type-check + build de producción
pnpm preview         # sirve el build de producción localmente
pnpm lint            # eslint
pnpm test            # vitest (una corrida)
pnpm test:watch      # vitest en modo watch
pnpm test:coverage   # vitest con reporte de cobertura
```

## Despliegue en Vercel

El backend (`crm_iswo_back`, Rails + Kamal) vive en el apex `iswocrm.com`, en infraestructura propia — no en Vercel. Este SPA se despliega en Vercel bajo un **subdominio custom**, nunca en el `*.vercel.app` por defecto.

### Dominio

| Host | Sirve |
|---|---|
| `app.iswocrm.com` | SPA (login, CRM) — dominio custom del proyecto en Vercel |
| `*.iswocrm.com` (wildcard) | Landing pages públicas por tenant, mismo build |
| `iswocrm.com` (apex) | API — **no** apunta a Vercel |

**Por qué no alcanza con `*.vercel.app`:** la sesión usa una cookie `httponly` de refresh con `same_site: :lax` (ver backend). Esa política permite que la cookie viaje en llamadas cross-*origin* del SPA a la API solo si ambos comparten el mismo *site* (dominio registrable `iswocrm.com`). Si el SPA quedara en `algo.vercel.app`, sería cross-*site* real y el navegador bloquearía la cookie — el refresh de sesión fallaría en silencio. Detalle completo en `docs/DOMAIN_SETUP.md` del repo backend.

### Env vars a configurar en Vercel

```
VITE_API_BASE_URL=https://iswocrm.com/api/v1
VITE_TENANT_SLUG=<slug por defecto si aplica>
```

Son `VITE_*` → quedan embebidas en el bundle público. No poner secretos ahí.

### SPA fallback (routing client-side)

TanStack Router usa browser history. Sin rewrite, refrescar una ruta profunda (`/settings/integrations`) da 404 en Vercel. Falta agregar `vercel.json`:

```json
{
  "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }]
}
```

### Checklist previo al primer deploy

- [ ] Dominio custom `app.iswocrm.com` agregado en el proyecto de Vercel
- [ ] Wildcard `*.iswocrm.com` agregado si las landing pages se sirven desde acá
- [ ] DNS: `app.iswocrm.com` y `*.iswocrm.com` → CNAME a Vercel (apex `iswocrm.com` sigue apuntando al backend)
- [ ] `VITE_API_BASE_URL` seteada en Vercel (Production + Preview)
- [ ] `vercel.json` con SPA fallback agregado
- [ ] En el backend: `CORS_ALLOWED_ORIGINS` incluye `https://app.iswocrm.com` (ver `config/deploy.yml`)
- [ ] `package.json` con `engines.node` fijado (evita que Vercel tome una versión de Node distinta a la de `.nvmrc`)

## Troubleshooting

**`Cannot find native binding` (PostCSS / lightningcss / @tailwindcss/oxide) al correr `pnpm dev`**

Causa casi siempre: Node < 20. Solución:

```bash
nvm install 20
nvm use 20
rm -rf node_modules
pnpm install
```

No usar `npm i` para "arreglarlo" — el proyecto usa pnpm exclusivamente y mezclar lockfiles rompe la resolución de dependencias.
