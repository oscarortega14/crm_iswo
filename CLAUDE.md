# CRM ISWO — Guía de desarrollo

## Comandos operativos (rake)

> Los antiguos comandos slash `/analizar-pipeline`, `/agregar-lead`, etc. y la carpeta
> `.claude/` fueron eliminados del repo. La API de Claude sigue usándose solo vía
> `ANTHROPIC_API_KEY` (en `api/.env`), que alimenta el clasificador IA del CRM (`AiClassifier`).

**Staging (RFC §9):** `cd api && bundle exec rails staging:preflight` — checklist pre-producción (infra, Solid Queue, integraciones).

**Jobs (Solid Queue):** `SOLID_QUEUE_IN_PUMA=true bin/rails s` o `bin/jobs` — sin Redis. UI: `http://localhost:3000/jobs`

**Seguridad Fase 1 (Opción 1 infra):** `cd api && bundle exec rails security:infra` — HTTPS, SSL PostgreSQL, secretos, CORS. Ver `api/docs/SECURITY_FASE1.md`.

**Pre-producción RFC §7:** `cd api && bundle exec rails prod:security_dry_run` — valida `deploy.yml` + simula `security:infra`. Checklist: `api/docs/PRODUCTION_CHECKLIST.md`.

**Seguridad Fase 2 (Opción 2 PII):** `db:migrate` → `CONTACT_PII_MIGRATING=true security:encrypt_contacts` → `security:pii`. Ver `api/docs/SECURITY_FASE2.md`.

**Seguridad Fase 3 (RLS PostgreSQL):** `db:migrate` → `DB_RLS_ENABLED=true security:rls`. Ver `api/docs/SECURITY_FASE3.md`.

Los comandos rake requieren la base configurada; el servidor Rails corre en `localhost:3000`.

---

## Alcance global del CRM (todos los tenants y roles)

Cualquier cambio de producto o técnico debe aplicarse **en todo el CRM**, no en un tenant
ni rol aislado:

| Capa | Regla |
|------|--------|
| **Multi-tenant** | `ActsAsTenant` + `current_tenant` en API; sin IDs de tenant fijos en código. Cada tenant ve solo sus datos. |
| **Roles** | Comportamiento explícito para `admin`, `manager`, `consultant` y `viewer` donde aplique: Pundit en API; en la SPA filtro de nav (`roles` en `settingsNav`) **y** guard de ruta en `beforeLoad` (`requireRole` / `requireSettingsRole`) — ambos deben espejar el mismo rol. |
| **Caché SPA** | Claves de React Query con alcance `getAuthQueryScope()` (`subdomain:user:id`) al invalidar o listar datos sensibles. |
| **Exportaciones (RFC §6.7)** | Pantalla `/exports`: solo admin/manager (export + import masivo). Consultor importa contactos desde `/contacts`; no exporta ni ve historial async. |
| **Consultores** | Scope propio en contactos/oportunidades. Red F2 solo en `/network` (`network_depth` = árbol); pipeline no comparte opps entre referidos. Sin pantalla `/exports`. |

Si un feature solo funciona para un rol o tenant, es un bug salvo excepción documentada en el RFC.

---

## Decisiones de arquitectura

### AiClassifier — clasificación de temperatura (RFC §3.2)

`api/app/services/opportunities/ai_classifier.rb` usa Claude Haiku para clasificar
la temperatura de un lead (`cold` / `warm` / `hot`) con un razonamiento y una
sugerencia de siguiente acción.

**El RFC §3.2 pone "IA predictiva para scoring automático de leads" fuera del MVP.**
Esta feature **no viola** esa restricción porque:

- **No sustituye el scoring BANT** (que es el único scoring de *calificación* automático del sistema).
- Clasifica **temperatura**, no calificación BANT — son dos dimensiones distintas.
- Si `ANTHROPIC_API_KEY` no está configurada, cae a reglas deterministas sin IA.

**Modos de disparo:** existe el endpoint manual `POST /api/v1/opportunities/:id/classify`,
pero además hay **auto-clasificación de temperatura activada por defecto** al guardar/editar
el dossier del lead (controlada por `ANTHROPIC_AUTO_CLASSIFY_TEMPERATURE`, que cae a `true`
si no se define; ver `AiClassifier.auto_classify_enabled?`). Sigue sin ser scoring de
calificación, así que el matiz temperatura ≠ BANT se mantiene.

En el historial de actividad el log queda con `action: "classify"`, distinguible
de los cambios de etapa o de score BANT.

---

### Auto-avance de etapa por eventos (RFC §6.1)

`Opportunities::StageAutomation` mueve oportunidades según la regla
`pipeline_stages.auto_rule = { trigger: … }`, configurable por admin en
**Settings → Pipelines** (un disparador por pipeline; nunca en etapas ganada/perdida).

| Disparador | Origen |
|---|---|
| `whatsapp_outbound` | `WhatsappMessage` saliente con contacto al pasar a `sent/delivered/read` (un 131047 no avanza; avisos de recordatorio al consultor van con `contact: nil` y se ignoran) |
| `whatsapp_inbound` | `WhatsappMessage` entrante al crearse |
| `bant_qualified` | `BantScorer#call_and_persist!` cuando el score supera el umbral por primera vez |

Reglas: solo hacia adelante, solo opps `kept` abiertas y en etapa no terminal, y
**lo manual manda** (si el último `stage_change` fue un retroceso hecho por un
usuario, no se re-avanza hasta otro movimiento manual). Sin oportunidad en el
mensaje → aplica a todas las abiertas del contacto.

Log `stage_change` con `note: "Avance automático: <motivo>"`, `changes_data.trigger`
y notificación in-app al dueño. `Tenants::Onboarder` siembra `Contactada ←
whatsapp_outbound` y `Calificada ← bant_qualified` (verticales: solo BANT); la
migración `AddAutoRuleToPipelineStages` precargó `bant_qualified` en las etapas
"Calificada" existentes, así que el auto-avance BANT ya no depende del nombre.

---

### Campos personalizados por vertical (RFC F5)

`TenantFieldDefinition` permite definir campos extra por tenant sin modificar
el esquema central. Los valores se guardan en `custom_fields` (JSONB) de
`opportunities` y `contacts`.

`Tenants::Onboarder` siembra los campos automáticamente según el slug:
- `"libranzas"` → 8 campos (empleador, NIT, tipo, salario, plazo, cuota, descuento, entidad)
- `"micasita"` / `"mi_casita"` → 7 campos (tipo inmueble, estrato, ciudad, barrio, valor, crédito hipotecario, área)

Los admins pueden gestionar campos desde **Settings → Campos** sin deploy.

---

### Audit log 100% CRUD (RFC §9)

`app/services/audit_logger.rb` centraliza la persistencia en `AuditEvent` con
`LogSanitizer` aplicado a toda la metadata. Los controladores y concerns llaman
a `AuditLogger.record!` / `record_entity!` en lugar de `AuditEvent.create!`
directo.

`app/controllers/concerns/auditable.rb` incluido en `BaseController`. Registra
`create`, `update` y `destroy` automáticamente en `AuditEvent` para todas las
entidades, sin tocar cada controlador individualmente.

**Cómo funciona:**
- `after_action` solo dispara en respuestas 2xx — los errores no se auditan.
- Detecta el record por convención (`controller_name.singularize` → `@contact`,
  `@user`, `@lead_source`, etc.).
- Tras un `create` exitoso el ivar debe estar asignado (`@reminder = reminder`)
  antes del render — si no, el `after_action` no encuentra el record.
- Controladores con ivar no convencional declaran `auditable_resource :nombre`:
  `PipelineStages→:stage`, `LandingPages→:landing`, `BantCriteria→:criterion`,
  `ReferralNetworks→:edge`, `TenantFieldDefinitions→:definition`.
- Campos sensibles (`email`, `phone`, `credentials`, etc.) se redactan como
  `[REDACTED]` en el diff de updates (clave completa, vía `LogSanitizer`).
- Falla silenciosamente (`rescue StandardError` + `logger.warn`) — nunca tumba
  la petición HTTP.

**Controladores excluidos** (tienen auditoría propia o son de solo lectura):
`opportunities` (usa `opportunity_logs`), `sessions`, `ad_integrations`,
`exports`, `dashboard`, `searches`, `notifications`, `audit_events`.

**Sistema de auditoría dual:**
- `opportunity_logs` — trazabilidad comercial detallada de oportunidades
  (stage_change, assign, merge, BANT, classify, notas).
- `audit_events` — CRUD de todas las demás entidades + eventos de sistema
  (login, import, integraciones).

---

### Multi-tenancy (RFC D3)

Se resolvió usando **ambas** estrategias:
- Subdominio (`micasita.crm.iswo.com.co`) resuelto por `TenantResolver`.
- Header HTTP `X-Tenant-Slug` como fallback para clientes que no soporten subdominios.

---

### Admin UI — React SPA en lugar de Slim (RFC §5)

El RFC §5 propone **React** para la app principal y **Slim (SSR en Rails)** para
módulos admin internos. En la implementación se adoptó **frontend único en React**
para todo el producto, incluida la administración por tenant.

**Decisión:** Slim **descartado** a favor de la SPA en `client/`. Rails corre como
**API-only** (`config.api_only = true`); no hay vistas `.slim` ni asset pipeline
de admin en el backend.

**Cobertura funcional del RFC (admin):** equivalente vía React + `/api/v1`, con
RBAC Pundit y la misma sesión JWT que el resto del CRM:

| Módulo admin RFC | Ruta SPA |
|------------------|----------|
| General (días sin actividad, profundidad de red) | `/settings/general` |
| Pipelines / etapas | `/settings/pipelines` |
| BANT / stale days | `/settings/bant` |
| Campos por tenant | `/settings/fields` |
| Usuarios | `/settings/users` |
| Integraciones (Meta, Google, WhatsApp) | `/settings/integrations` |
| Lead sources | `/settings/lead-sources` |
| Landings + GrapeJS | `/landings` (admin/manager editan; staff consulta) |
| Exportaciones | `/exports` |
| Duplicados | `/duplicates` |
| Auditoría | `/settings/audit` |
| Onboarding de tenants | `/settings/tenant-onboarding` |

**Excepción operativa (no producto):** Mission Control Jobs en `/jobs` — UI de Solid Queue,
protegida con HTTP Basic en producción.

**Por qué no implementar Slim:** evita duplicar pantallas, auth y permisos;
alinea el producto con referentes HubSpot/GoHighLevel (una sola app web); el MVP
exige *vistas admin*, no *Slim* como tecnología obligatoria.

**Conformidad RFC:** desviación **documentada** — actualizar RFC-001 §5 en una
revisión de producto si se requiere cumplimiento literal del stack tabulado.

---

### Recordatorios — entrega antes de marcar `sent` (RFC §6.4)

`ReminderNotificationJob` solo marca `status=sent` **después** de confirmar entrega:

| Canal | Destinatario al vencer |
|-------|------------------------|
| **in_app** | Campana in-app del consultor asignado |
| **email** | Correo al consultor + campana in-app |
| **whatsapp** | WhatsApp al `User#phone` del consultor + campana in-app (nunca al lead) |

Solo **admin, manager y consultant** pueden crear/recibir recordatorios (`viewer` excluido).

---

### Notificaciones in-app (RFC §6.4)

El RFC menciona push in-app; la implementación MVP usa **polling** en
`NotificationDropdown` (`refetchInterval` 60s + `refetchOnWindowFocus`). No hay
WebSocket/ActionCable aún — desviación aceptada para MVP; latencia máxima ~60s.

---

### Enmascaramiento en logs (ISO A.8.11)

`LogSanitizer.redact` enmascara email, teléfonos y credenciales en
`opportunity_logs.changes_data`. `Auditable` y `AuditLogger` redactan metadata
sensible en `audit_events`.

---

### Exportaciones — cifrado en reposo (RFC §6.7 / ISO A.7.10)

`Exports::Storage` centraliza la persistencia de archivos async:

| Entorno | Almacenamiento | Acceso |
|---------|----------------|--------|
| **Producción** | S3 privado + SSE (`AES256` o `aws:kms` con `AWS_KMS_KEY_ID`) | Presigned URL **bajo demanda** (15 min) vía `GET /exports/:id/download` |
| **Desarrollo** | `storage/exports/` cifrado con **Lockbox** (`.enc`) | Solo endpoint autenticado; descifra en memoria |

- `file_url` en DB guarda referencia interna (`s3://…` o `local://encrypted`), no URLs públicas.
- `ExportSerializer` siempre expone `/api/v1/exports/:id/download` al SPA.
- `CleanupExportsJob` borra objetos S3 y archivos `.enc` al expirar (7 días).
- Export sync (`ExportDownloadable`) sigue siendo stream directo sin persistir disco.

Variables: `AWS_S3_BUCKET`, `AWS_REGION`, opcional `AWS_KMS_KEY_ID`, `LOCKBOX_MASTER_KEY`.

---

### Landings públicas — subdominio por tenant (RFC §6.5)

**Producción:** `https://{tenant}.crm.iswo.com.co/{slug}` — tenant por subdominio,
sin prefijo `/l/`.

**Desarrollo:** mismo modelo con `{tenant}.localhost:3001/{slug}` (Vite `host: true`).
Fallback legacy: `http://localhost:3001/l/{slug}?tenant={tenant}`.

| Capa | Comportamiento |
|------|----------------|
| **SPA** | Ruta `/$slug` en subdominio; redirige a `/l/$slug` en localhost plano |
| **API** | `TenantResolver` + header `X-Tenant-Slug`; CORS acepta `*.localhost` |
| **Admin** | `LandingPage#public_url` y UI copian URL con subdominio |

Opcional: `LANDING_PUBLIC_HOST` / `VITE_LANDING_PUBLIC_HOST` para override (ngrok, staging).
