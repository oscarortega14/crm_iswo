# Arquitectura de dominio — API + SPA (Vercel)

El frontend (`crm_iswo_front`) se despliega en Vercel, separado de este backend
(Rails, Dokku en EC2). Este documento explica cómo se reparte el dominio
`iswocrm.com` entre ambos y por qué, para que la auth por cookie httpOnly
siga funcionando.

## Reparto de dominio

| Host | Sirve | Infraestructura |
|---|---|---|
| `iswocrm.com` (apex) | API (`/api/v1/*`), mailer links | Este backend, Dokku (EC2), ver `DEPLOY_DOKKU.md` |
| `app.iswocrm.com` | SPA (login, CRM) | Vercel |
| `{tenant}.iswocrm.com` (wildcard) | Landing pages públicas por tenant | Vercel (mismo build del SPA) |

## Por qué el front no puede ir en `*.vercel.app`

El refresh token es una cookie `httponly` (`app/controllers/concerns/refresh_token_cookies.rb`)
con `same_site: :lax`. Esa política **sí permite** que la cookie viaje en
peticiones fetch/XHR cross-*origin* — pero solo si ambos hosts comparten el
mismo *site* (dominio registrable). `app.iswocrm.com` y `iswocrm.com`
comparten site (`iswocrm.com`); un dominio Vercel por defecto
(`algo.vercel.app`) sería un site distinto y el navegador **no enviaría la
cookie**, rompiendo el refresh de sesión en silencio.

Por eso el front debe desplegarse con **dominio custom** en Vercel
(`app.iswocrm.com`), nunca solo en el subdominio `*.vercel.app`.

## Resolución de tenant

`app/controllers/concerns/tenant_resolver.rb` resuelve el tenant en este orden:

1. Header `X-Tenant-Slug` (lo manda el SPA en cada request, ver `src/lib/api.ts` del front) — así el SPA autenticado (`app.iswocrm.com`, sin subdominio de tenant) igual puede identificar el tenant.
2. Subdominio (`{tenant}.iswocrm.com`) — usado por las landing pages públicas, que sí viven en el subdominio del tenant.

Por esto el SPA principal **no necesita** correr en un subdominio wildcard;
solo las landing pages lo requieren.

## Variables de entorno relevantes (GitHub Actions → `dokku config:set`)

```
APP_HOST=iswocrm.com
CORS_ALLOWED_ORIGINS=https://iswocrm.com,https://app.iswocrm.com
```

`APP_HOST` alimenta tanto el link de mailer (`config/environments/production.rb`)
como el fallback de URL pública de landing (`app/models/landing_page.rb#public_base_url`)
y el regex de CORS para subdominios de tenant (`config/initializers/cors.rb`).

## DNS necesario

- `iswocrm.com` (apex) → A al Elastic IP del EC2 (servidor Dokku)
- `app.iswocrm.com` → CNAME a Vercel
- `*.iswocrm.com` → CNAME a Vercel (landings por tenant)

## Contraparte en el front

Ver `README.md` del repo `crm_iswo_front`, sección "Despliegue en Vercel".

## Setup del backend en Dokku

Ver [`docs/DEPLOY_DOKKU.md`](./DEPLOY_DOKKU.md) — creación de la app, Postgres,
dominio/SSL y el workflow de GitHub Actions que despliega en cada push a `main`.

## Historial

Hasta 2026-07, el dominio planeado era `crm.iswo.com.co` (con el segmento
`crm` reservado como label especial en la resolución de subdominio). Se migró
a `iswocrm.com` — el label `"crm"` reservado en `tenant_resolver.rb` y en
`landingUrls.ts` (front) se eliminó por quedar vestigial del esquema anterior.
