# CRM ISWO — Backend API

CRM white-label, multi-tenant y configurable para ISWO y sus verticales (Mi Casita, Libranzas y futuras). Construido como **Rails 8.1.3 API-only**, consumido por un frontend **React + TanStack** independiente. Basado en RFC-001.

---

## 1. Stack técnico

| Capa                  | Tecnología                         | Notas                                                        |
| --------------------- | ---------------------------------- | ------------------------------------------------------------ |
| Runtime               | Ruby 4.0.0                         | MRI                                                          |
| Framework             | Rails 8.1.3 (`--api`)              | Sin asset pipeline, sin views                                |
| Base de datos         | PostgreSQL ≥ 15                    | Extensiones `pg_trgm`, `pgcrypto`, `btree_gist`              |
| Cache                 | **Solid Cache** (sobre PostgreSQL) | Sin Redis; base `cache` en `config/cache.yml`               |
| Background jobs       | **Solid Queue + Mission Control**  | Sin Redis; dashboard en `/jobs`. Scheduler en `config/recurring.yml` |
| Multi-tenancy         | `acts_as_tenant`                   | Scope transparente por `tenant_id`                           |
| Autenticación         | Devise + `devise-jwt`              | JWT 15 min + refresh token 7 días (httpOnly cookie)          |
| Autorización          | Pundit                             | Policies por modelo, scopes por rol                          |
| Audit log             | Tablas propias (`AuditLogger`)     | `opportunity_logs` + `audit_events`; sin gema `audited`      |
| Cifrado               | `lockbox` + `blind_index`          | Tokens de integraciones (Meta, Google, Twilio)               |
| Soft-delete           | `discard`                          | Columna `discarded_at` en modelos core                       |
| Serialización API     | `jsonapi-serializer`               | Salida JSON:API para el SPA                                  |
| Paginación            | `pagy`                             | Ligero, headers estándar                                     |
| Búsqueda / filtros    | `ransack`                          | Query strings seguros en endpoints de listados               |
| Exportación           | `caxlsx_rails` + CSV nativo        | Generación en job de Solid Queue, link firmado               |
| HTTP client           | `faraday` + `faraday-retry`        | Integraciones Meta/Google/Twilio                             |
| Teléfonos             | `phonelib`                         | Normalización E.164 para detección de duplicados             |
| CORS                  | `rack-cors`                        | Whitelist dinámica por tenant                                |
| Testing               | RSpec + FactoryBot + Faker         | Shoulda matchers, WebMock, SimpleCov                         |

Frontend (repo separado): React 19 + Vite + TanStack Query + TanStack Router + TanStack Table + shadcn/ui. Consume los endpoints bajo `/api/v1`.

---

## 2. Requisitos del sistema

- Ruby 4.0.0 (gestionar con `rbenv` o `mise`)
- PostgreSQL 15+ con `pg_trgm`, `pgcrypto`, `btree_gist`
- **Sin Redis**: jobs y caché corren sobre PostgreSQL (Solid Queue + Solid Cache)
- Node 20+ (solo para el SPA en `client/`; la API es API-only)

---

## 3. Setup local

```bash
# 1. Clonar e instalar dependencias
git clone <repo> crm_iswo && cd crm_iswo
bundle install

# 2. Configurar variables
cp .env.example .env
# editar .env con credenciales locales

# 3. Preparar la base
bin/rails db:create db:migrate db:seed

# 4. Levantar Rails con los workers de Solid Queue en el mismo proceso (sin Redis)
SOLID_QUEUE_IN_PUMA=true bin/rails s
#   …o, para correr los jobs en un proceso aparte:
#   bin/jobs            # en otra terminal
#   bin/rails s
```

El API queda escuchando en `http://localhost:3000/api/v1`. El dashboard de jobs (Mission Control, Solid Queue) en `http://localhost:3000/jobs`.

### Variables de entorno clave (`.env.example`)

```
DATABASE_URL=postgres://postgres:postgres@localhost:5432/crm_iswo_development
# Sin Redis: Solid Queue/Solid Cache usan la misma PostgreSQL

DEVISE_JWT_SECRET_KEY=<generar con `bin/rails secret`>
# Obligatorias en producción (el arranque falla si faltan):
LOCKBOX_MASTER_KEY=<generar con `Lockbox.generate_key`>
BLIND_INDEX_MASTER_KEY=<generar con `SecureRandom.hex(32)`>   # o reutiliza LOCKBOX_MASTER_KEY explícita

CORS_ALLOWED_ORIGINS=http://localhost:3000

# Integraciones (por tenant normalmente, pero defaults aquí)
META_APP_SECRET=
GOOGLE_ADS_DEVELOPER_TOKEN=
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
WHATSAPP_PROVIDER=twilio   # twilio | cloud_api

AWS_REGION=us-east-1   # también usado por SES
MAIL_FROM=no-reply@crm.iswo.com.co

# Claude — temperatura de leads (POST /opportunities/:id/classify)
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=claude-haiku-4-5-20251001
ANTHROPIC_AUTO_CLASSIFY_TEMPERATURE=false
```

---

## 4. Estructura del proyecto

Monorepo con dos paquetes: `api/` (Rails) y `client/` (React).

```
crm_iswo/
├── .gitignore
├── README.md
│
├── api/                                   # Rails 8.1 API-only
│   ├── app/
│   │   ├── controllers/
│   │   │   └── api/v1/…                  # Controladores RESTful JSON
│   │   │       └── webhooks/             # Meta Ads, Google Ads, WhatsApp
│   │   ├── models/                       # 21 modelos AR (ver §7)
│   │   ├── policies/                     # Pundit policies por modelo
│   │   ├── serializers/                  # JSON:API serializers
│   │   ├── services/                     # Lógica de dominio reutilizable
│   │   │   ├── opportunities/
│   │   │   │   ├── duplicate_detector.rb
│   │   │   │   └── lead_importer.rb
│   │   │   ├── whatsapp/message_sender.rb
│   │   │   └── ads/
│   │   │       ├── meta_lead_processor.rb
│   │   │       └── google_lead_processor.rb
│   │   ├── jobs/                         # 15 jobs (recordatorios, webhooks, ads, exports, duplicados…)
│   │   │   ├── reminder_notification_job.rb
│   │   │   ├── webhook_processor_job.rb
│   │   │   ├── ad_sync_job.rb
│   │   │   ├── export_generation_job.rb
│   │   │   └── whatsapp_delivery_job.rb
│   │   └── mailers/
│   ├── config/
│   │   ├── initializers/
│   │   │   ├── acts_as_tenant.rb
│   │   │   ├── cors.rb
│   │   │   └── devise_jwt.rb
│   │   ├── recurring.yml                 # Scheduler de Solid Queue (jobs cron)
│   │   ├── queue.yml                      # Config de Solid Queue
│   │   ├── routes.rb
│   │   └── application.rb
│   ├── db/
│   │   ├── migrate/                      # 40 migraciones (ver §6)
│   │   ├── schema.rb
│   │   └── seeds.rb
│   ├── spec/                             # RSpec
│   ├── .env.example
│   ├── docs/DEPLOY_DOKKU.md               # Deploy a Dokku (EC2) + GitHub Actions
│   ├── Dockerfile
│   └── Gemfile
│
└── client/                               # React 19 + Vite (repo separado pendiente)
    └── …
```

---

## 5. Arquitectura multi-tenant

- **Estrategia:** subdominio + `tenant_id` en todas las tablas de negocio.
- Resolución: middleware inspecciona `request.subdomain` → busca `Tenant` por `slug` → `ActsAsTenant.with_tenant(tenant) { ... }`.
- Fallback: header `X-Tenant-Slug` para herramientas internas y tests.
- Todas las consultas quedan auto-scopeadas; escribir fuera de scope lanza `ActsAsTenant::Errors::NoTenantSet`.
- El admin global (super-usuario ISWO) **está implementado**: es el admin del tenant plataforma `"iswo"`, autorizado por `IswoPlatformAuthorizable` sobre el namespace `/api/v1/admin/*` (p. ej. onboarding de tenants), con bypass de scope vía `ActsAsTenant.without_tenant { ... }` y auditoría. No es una tabla separada.

### Dominios de ejemplo

| Tenant     | Subdominio                         |
| ---------- | ---------------------------------- |
| ISWO       | `iswo.crm.iswo.com.co`             |
| Mi Casita  | `micasita.crm.iswo.com.co`         |
| Libranzas  | `libranzas.crm.iswo.com.co`        |

---

## 6. Migraciones (orden de ejecución)

Todas las migraciones usan `ActiveRecord::Migration[8.1]`. La tabla lista las **20 migraciones núcleo (F1)**; a partir de ahí el esquema evolucionó con migraciones incrementales (notifications, campos por tenant, temperatura, cifrado PII Fase 2, RLS Fase 3, etc.) hasta **40 en total**. La fuente de verdad es `db/schema.rb`. Orden por timestamp:

| # | Archivo                                                       | Descripción                                             |
| - | ------------------------------------------------------------- | ------------------------------------------------------- |
| 01 | `20260419000001_enable_extensions.rb`                        | `pg_trgm`, `pgcrypto`, `btree_gist`                     |
| 02 | `20260419000002_create_tenants.rb`                           | Raíz multi-tenant                                       |
| 03 | `20260419000003_create_jwt_denylists.rb`                     | Revocación de JWTs                                      |
| 04 | `20260419000004_create_users.rb`                             | Devise + rol + tenant                                   |
| 05 | `20260419000005_create_lead_sources.rb`                      | Orígenes de lead por tenant                             |
| 06 | `20260419000006_create_pipelines.rb`                         | Embudos configurables                                   |
| 07 | `20260419000007_create_pipeline_stages.rb`                   | Etapas ordenadas por `position`                         |
| 08 | `20260419000008_create_bant_criteria.rb`                     | Pesos BANT por tenant                                   |
| 09 | `20260419000009_create_contacts.rb`                          | Personas y empresas + índices GIN para duplicados       |
| 10 | `20260419000010_create_opportunities.rb`                     | Tabla central del dominio                               |
| 11 | `20260419000011_create_opportunity_logs.rb`                  | Audit log específico de oportunidades                   |
| 12 | `20260419000012_create_reminders.rb`                         | Recordatorios multi-canal                               |
| 13 | `20260419000013_create_duplicate_flags.rb`                   | Colisiones detectadas y su resolución                   |
| 14 | `20260419000014_create_referral_networks.rb`                 | Árbol self-referencial de consultores                   |
| 15 | `20260419000015_create_landing_pages.rb`                     | Páginas GrapeJS                                         |
| 16 | `20260419000016_create_landing_form_submissions.rb`          | Captura de leads desde landings                         |
| 17 | `20260419000017_create_ad_integrations.rb`                   | Credenciales cifradas Meta/Google/Twilio                |
| 18 | `20260419000018_create_whatsapp_messages.rb`                 | Log bidireccional                                       |
| 19 | `20260419000019_create_exports.rb`                           | Exportaciones auditadas                                 |
| 20 | `20260419000020_create_audit_events.rb`                      | Audit log global (login, cambios de rol, etc.)          |

Detalles de índices y constraints en cada archivo.

---

## 7. Modelos y relaciones (resumen)

### Diagrama entidad-relación

```mermaid
erDiagram
    TENANTS ||--o{ USERS : "agrupa"
    TENANTS ||--o{ PIPELINES : "configura"
    TENANTS ||--o{ CONTACTS : "almacena"
    TENANTS ||--o{ LEAD_SOURCES : "define"
    TENANTS ||--o{ LANDING_PAGES : "publica"
    TENANTS ||--o{ AD_INTEGRATIONS : "conecta"
    TENANTS ||--o{ EXPORTS : "audita"

    PIPELINES ||--o{ PIPELINE_STAGES : "tiene"

    CONTACTS ||--o{ OPPORTUNITIES : "genera"
    PIPELINE_STAGES ||--o{ OPPORTUNITIES : "agrupa por etapa"
    USERS ||--o{ OPPORTUNITIES : "es dueño de"
    LEAD_SOURCES ||--o{ OPPORTUNITIES : "origina"

    OPPORTUNITIES ||--o{ OPPORTUNITY_LOGS : "audita cambios en"
    OPPORTUNITIES ||--o{ REMINDERS : "agenda"
    OPPORTUNITIES ||--o{ WHATSAPP_MESSAGES : "conversa por"
    OPPORTUNITIES ||--o{ DUPLICATE_FLAGS : "marca colisiones"

    USERS ||--o{ REMINDERS : "recibe"
    USERS ||--o{ REFERRAL_NETWORKS : "refiere"
    USERS ||--o{ DUPLICATE_FLAGS : "detecta"
    USERS ||--o{ EXPORTS : "ejecuta"

    LANDING_PAGES ||--o{ LANDING_FORM_SUBMISSIONS : "captura"
    LANDING_FORM_SUBMISSIONS ||--o| CONTACTS : "crea"
    LANDING_FORM_SUBMISSIONS ||--o| OPPORTUNITIES : "crea"

    TENANTS {
        bigint id PK
        string name
        string slug "subdominio del tenant"
        jsonb settings
        string timezone
        boolean active
    }

    USERS {
        bigint id PK
        bigint tenant_id FK
        string email
        string encrypted_password
        string name
        string phone
        string role "admin|manager|consultant|viewer"
        boolean active
        datetime last_sign_in_at
    }

    PIPELINES {
        bigint id PK
        bigint tenant_id FK
        string name
        string description
        boolean is_default
        boolean active
    }

    PIPELINE_STAGES {
        bigint id PK
        bigint pipeline_id FK
        string name
        int position
        int probability "0-100"
        boolean closed_won
        boolean closed_lost
    }

    CONTACTS {
        bigint id PK
        bigint tenant_id FK
        string kind "person|company"
        string first_name
        string last_name
        string company_name
        string email
        string phone_e164
        string phone_normalized
        string document_id
        bigint owner_user_id FK
    }

    OPPORTUNITIES {
        bigint id PK
        bigint tenant_id FK
        bigint contact_id FK
        bigint pipeline_id FK
        bigint pipeline_stage_id FK
        bigint owner_user_id FK
        bigint lead_source_id FK
        string title
        decimal estimated_value
        string currency
        int bant_score
        boolean qualified
        string status "new|contacted|qualified|proposal|won|lost"
        datetime last_activity_at
        date expected_close_on
    }

    OPPORTUNITY_LOGS {
        bigint id PK
        bigint tenant_id FK
        bigint opportunity_id FK
        bigint user_id FK
        string action "create|update|stage_change|assign|merge|export|note"
        jsonb changes
        text note
        datetime created_at
    }

    REMINDERS {
        bigint id PK
        bigint tenant_id FK
        bigint opportunity_id FK
        bigint user_id FK
        datetime remind_at
        string channel "email|whatsapp|in_app"
        string status "pending|sent|failed|done"
        text message
        datetime sent_at
    }

    DUPLICATE_FLAGS {
        bigint id PK
        bigint tenant_id FK
        bigint opportunity_id FK
        bigint duplicate_of_opportunity_id FK
        bigint detected_by_user_id FK
        bigint resolved_by_user_id FK
        string matched_on "phone|email|both"
        string resolution "pending|reassigned|merged|ignored"
        datetime resolved_at
    }

    REFERRAL_NETWORKS {
        bigint id PK
        bigint tenant_id FK
        bigint referrer_user_id FK
        bigint referred_user_id FK
        int depth
        boolean active
    }

    LEAD_SOURCES {
        bigint id PK
        bigint tenant_id FK
        string name
        string kind "web|whatsapp|meta|google|manual|referral"
        jsonb config
    }

    LANDING_PAGES {
        bigint id PK
        bigint tenant_id FK
        string slug
        string title
        boolean published
        jsonb content "estructura GrapeJS"
        string thumbnail_url
        datetime published_at
    }

    LANDING_FORM_SUBMISSIONS {
        bigint id PK
        bigint landing_page_id FK
        bigint contact_id FK
        bigint opportunity_id FK
        jsonb payload
        string ip
        string user_agent
        datetime created_at
    }

    AD_INTEGRATIONS {
        bigint id PK
        bigint tenant_id FK
        string provider "meta|google|twilio|whatsapp_cloud"
        jsonb credentials_encrypted
        string status
        datetime last_sync_at
    }

    WHATSAPP_MESSAGES {
        bigint id PK
        bigint tenant_id FK
        bigint opportunity_id FK
        bigint contact_id FK
        string direction "in|out"
        string provider_message_id
        string from_number
        string to_number
        text body
        string status
        datetime sent_at
    }

    EXPORTS {
        bigint id PK
        bigint tenant_id FK
        bigint user_id FK
        string format "csv|xlsx"
        jsonb filters
        string status
        string file_url
        datetime expires_at
    }
```

### Core

- **Tenant** — raíz. `has_many` virtualmente todo. Único por `slug`.
- **User** — Devise + rol (`admin|manager|consultant|viewer`). `belongs_to :tenant`. `has_many :owned_opportunities`, `:reminders`, `:exports`, `:outgoing_referrals`, `:incoming_referrals`.
- **JwtDenylist** — revocación de tokens (no scoped a tenant).

### Configuración comercial

- **Pipeline** — `belongs_to :tenant`, `has_many :pipeline_stages, :opportunities`. Uno puede ser `is_default: true`.
- **PipelineStage** — `belongs_to :pipeline`. Ordenadas por `position`. Booleanos `closed_won` / `closed_lost`.
- **BantCriterion** — un registro por tenant con los pesos y umbral de calificación.
- **LeadSource** — orígenes configurables por tenant (web, whatsapp, meta, google, manual, referral).

### Contactos y oportunidades

- **Contact** — persona o empresa (`kind`). Teléfono normalizado E.164 para duplicate detection. Índice GIN trigram sobre `phone_normalized` y `lower(email)`.
- **Opportunity** — centro del dominio. `belongs_to` contact/pipeline/pipeline_stage/owner_user/lead_source. Enum `status`. Campo `bant_score` (0-100).
- **OpportunityLog** — audit propio: `action` enum (create/update/stage_change/assign/merge/export/note), `changes` jsonb.
- **Reminder** — fecha/hora + canal (email/whatsapp/in_app) + status.
- **DuplicateFlag** — `opportunity_id` (el intento) ↔ `duplicate_of_opportunity_id` (el ganador). Resolución: pending/reassigned/merged/ignored.

### Red de consultores

- **ReferralNetwork** — `referrer_user_id` → `referred_user_id`. Cachea `depth` para queries rápidos. Con validación anti self-referral y unicidad del par.

### Canales e integraciones

- **LandingPage** — `content` jsonb (estructura GrapeJS). Único por `(tenant_id, slug)`.
- **LandingFormSubmission** — crea Contact + Opportunity en un service.
- **AdIntegration** — credenciales cifradas con Lockbox.
- **WhatsappMessage** — direction in/out, `provider_message_id` único por proveedor.

### Operación y seguridad

- **Export** — estado + link firmado con TTL. Auditado.
- **AuditEvent** — audit log global (login, cambio de rol, activación de tenant, etc.).

---

## 8. Enums (resumen)

| Modelo          | Atributo      | Valores                                                            |
| --------------- | ------------- | ------------------------------------------------------------------ |
| User            | `role`        | `admin`, `manager`, `consultant`, `viewer`                         |
| Contact         | `kind`        | `person`, `company`                                                |
| Opportunity     | `status`      | `new_lead`, `contacted`, `qualified`, `proposal`, `won`, `lost`    |
| OpportunityLog  | `action`      | `create`, `update`, `stage_change`, `assign`, `merge`, `export`, `note` |
| Reminder        | `channel`     | `email`, `whatsapp`, `in_app`                                      |
| Reminder        | `status`      | `pending`, `sent`, `failed`, `done`                                |
| DuplicateFlag   | `matched_on`  | `phone`, `email`, `both`                                           |
| DuplicateFlag   | `resolution`  | `pending`, `reassigned`, `merged`, `ignored`                       |
| LeadSource      | `kind`        | `web`, `whatsapp`, `meta`, `google`, `manual`, `referral`          |
| WhatsappMessage | `direction`   | `in`, `out`                                                        |
| AdIntegration   | `provider`    | `meta`, `google`, `twilio`, `whatsapp_cloud`                       |
| Export          | `format`      | `csv`, `xlsx`                                                      |
| Export          | `status`      | `queued`, `running`, `succeeded`, `failed`, `expired`              |

Convención: enum almacenado como `string` en DB (nunca integer) para facilitar cambios, debug y queries legibles.

---

## 9. Autenticación y autorización

### Flujo de login (SPA React)

1. `POST /api/v1/sessions` con `{ email, password }` sobre subdominio del tenant.
2. Backend valida, devuelve `access_token` (JWT 15 min) en body y setea `refresh_token` (httpOnly, Secure, SameSite=Lax) con TTL 7 días.
3. Frontend manda `Authorization: Bearer <access_token>` en cada request.
4. Al expirar, llama `POST /api/v1/sessions/refresh` — usa la cookie y devuelve un access nuevo.
5. `DELETE /api/v1/sessions` agrega el JTI a `jwt_denylists`.

### RBAC con Pundit

- `admin` — control total del tenant.
- `manager` — todo excepto gestión de usuarios y configuración crítica.
- `consultant` — sus propias oportunidades y contactos; la red de referidos se consulta en `/network` (árbol según `network_depth`), no en el pipeline compartido.
- `viewer` — solo lectura.

Toda policy hereda de `ApplicationPolicy` y aplica scope por `tenant_id` automático (redundante con acts_as_tenant, defensa en profundidad).

---

## 10. Background jobs (Solid Queue)

Jobs sobre **Solid Queue** (tablas `solid_queue_*` en PostgreSQL, sin Redis).
Config del worker en `config/queue.yml`; tareas recurrentes en `config/recurring.yml`.
Correr con `SOLID_QUEUE_IN_PUMA=true bin/rails s` (workers dentro de Puma) o `bin/jobs`
en un proceso aparte. Setup inicial: `bundle exec rails solid:setup`.

Tareas recurrentes (`config/recurring.yml`):

| Job | Cola | Frecuencia |
|-----|------|-----------|
| `ReminderNotificationJob` | critical | cada minuto (recordatorios vencidos) |
| `ReminderUpcomingNotificationJob` | critical | cada minuto (avisos "por vencer") |
| `AdSyncJob` | integrations | cada 15 min |
| `CleanupExportsJob` | low | 3am diario |
| `RefreshDuplicateCacheJob` | low | 4am diario |
| `DailyBriefingJob` | low | 7am diario |
| `clear_solid_queue_finished_jobs` (solo prod) | — | cada hora |

Otros jobs clave (encolados bajo demanda): `WebhookProcessorJob` (ingesta Meta/Google/WhatsApp),
`ExportGenerationJob` (CSV/XLSX a storage), `WhatsappDeliveryJob`, `DuplicateResolutionJob`,
`LandingSubmissionProcessorJob`, `OpportunityTemperatureClassifyJob`, `UploadGoogleConversionJob`.

Dashboard **Mission Control Jobs** montado en `/jobs`, protegido con HTTP Basic en producción.

---

## 11. Seguridad (ISO 27001:2022)

| Control                    | Implementación                                              |
| -------------------------- | ----------------------------------------------------------- |
| A.5.12 Clasificación       | Campos PII etiquetados en modelo; logs con `filter_parameters` |
| A.5.34 Privacidad          | Scopes RBAC + `acts_as_tenant`                              |
| A.8.2 Accesos              | `role` en users + Pundit policies                           |
| A.8.11 Enmascaramiento     | `Rails.application.config.filter_parameters += [:phone, :email, :password, :token]` |
| A.8.16 Monitoreo           | `opportunity_logs` + `audit_events` 100% CRUD               |
| A.8.28 Codificación segura | Secretos en `.env` / Rails credentials; nada hardcoded      |
| A.6.8 Incidentes           | Rate limiting con `rack-attack` (implementado: auth, webhooks, password reset) |
| A.7.10 Medios              | Exportaciones con URL firmada + `expires_at`                |

---

## 12. Testing

```bash
bundle exec rspec                          # todo
bundle exec rspec spec/models              # modelos
bundle exec rspec spec/services            # servicios
bundle exec rspec spec/requests/api/v1     # endpoints
```

Convenciones:

- Cada modelo tiene spec con: validaciones, asociaciones, enums, scopes y multi-tenancy.
- Requests specs cubren happy path + RBAC por rol.
- Integraciones externas (Meta, Google, Twilio) mockeadas con WebMock.

---

## 13. Convenciones de código

- Nombres en inglés snake_case (tablas, columnas, clases).
- Comentarios y documentación de negocio en español.
- Rubocop omakase (`rubocop-rails-omakase`).
- `annotaterb` para anotar modelos con el schema.
- Services devuelven objetos de resultado propios (`Struct` con predicados como `.duplicate?` / `.ai_used?`); no se usa `dry-monads`.
- Controladores delgados; lógica en services; queries en scopes.

---

## 14. Roadmap (copiado del RFC)

| Fase | Entregables                                                                 | Duración |
| ---- | --------------------------------------------------------------------------- | -------- |
| F1   | Oportunidades, pipeline, contactos, recordatorios, detección de duplicados  | 6 sem    |
| F2   | Árbol de referidos, visibilidad por profundidad                             | 3 sem    |
| F3   | WhatsApp, Meta Ads webhook, Google Ads Conversion API                       | 4 sem    |
| F4   | Editor WYSIWYG, landing por subdominio, métricas                            | 3 sem    |
| F5   | Config Mi Casita, módulo Libranzas, onboarding de tenants                   | 2 sem    |

---

## 15. Comandos útiles

```bash
bin/rails db:migrate                           # migraciones
bin/rails db:migrate:status                    # estado
bin/rails db:rollback STEP=1                   # rollback
bin/rails c                                    # consola
bin/jobs                                       # worker de Solid Queue
bundle exec annotaterb models                  # anotar modelos
bundle exec rubocop -A                         # auto-fix estilo
```

---

## 16. Decisiones abiertas pendientes del RFC

- **D1 Landing builder:** GrapeJS en el SPA como primera iteración.
- **D2 WhatsApp:** Twilio en F3, dejar adapter listo para API Oficial.
- **D3 Multi-tenant:** subdominio (resolución por `request.subdomain`).
- **D4 Scoring:** BANT configurable en F1. IA fuera de scope MVP.
- **D5 Emails:** AWS SES — se aprovecha la infra AWS ya existente (S3 para exports) en lugar de Postmark.
