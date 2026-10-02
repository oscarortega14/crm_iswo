# Deploy en Dokku (EC2) — setup + GitHub Actions

Reemplaza al Kamal que traía el scaffold de Rails (nunca se configuró con un
servidor real). El deploy real de este backend es **Dokku**, corriendo en un
EC2 cuyo DNS ya apunta a `iswocrm.com` (ver `docs/DOMAIN_SETUP.md`).

Flujo: push a `main` → GitHub Actions construye la imagen y la sube a GHCR →
se conecta por SSH al EC2 → `dokku git:from-image` despliega esa imagen ya
construida (Dokku no reconstruye nada en el servidor).

## Prerrequisitos (ya cumplidos según lo indicado)

- Dokku instalado en el EC2.
- DNS `iswocrm.com` (apex, registro A) → Elastic IP del EC2.
- Security Group del EC2 con puertos **80 y 443** abiertos entrantes (Let's
  Encrypt valida por HTTP-01 en el 80; Dokku también sirve HTTPS en 443).

No se necesita wildcard DNS ni certificado wildcard para este backend: la API
vive solo en el apex `iswocrm.com`. Los subdominios de tenant (`{tenant}.iswocrm.com`)
los sirve Vercel (frontend/landings), no este backend — ver `docs/DOMAIN_SETUP.md`.

## 1. Crear la app en Dokku (una sola vez, en el EC2)

```bash
dokku apps:create crm-iswo-api
dokku domains:set crm-iswo-api iswocrm.com

# Puerto expuesto por el Dockerfile (Thruster sirve HTTP en 80 dentro del contenedor)
dokku ports:set crm-iswo-api http:80:80 https:443:80
```

## 2. Postgres — plugin dokku-postgres

La app usa 4 bases sobre la misma instancia Postgres (`crm_iswo_production`,
`_cache`, `_queue`, `_cable` — ver `config/database.yml`) y un rol de
aplicación dedicado `crm_iswo` **sin** privilegios de superusuario ni
`BYPASSRLS` (Fase 3 RLS, `docs/SECURITY_FASE3.md`). El rol y las bases que
crea `dokku postgres:link` automáticamente no sirven tal cual para esto —
hay que crearlos a mano una vez:

```bash
# Instala el plugin si no está: sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git postgres
dokku postgres:create crm-iswo-api-db

# Linkear expone DATABASE_URL automático (rol admin generado por el plugin).
# Lo usamos solo para sacar host/puerto/password del owner y luego lo
# quitamos: nuestro database.yml usa host/usuario/clave discretos (DB_HOST,
# CRM_ISWO_DATABASE_PASSWORD), no DATABASE_URL — una sola URL pisaría las 4
# bases con el mismo nombre de base.
dokku postgres:link crm-iswo-api-db crm-iswo-api
dokku config:get crm-iswo-api DATABASE_URL
# → postgres://<owner>:<pass>@<host>:5432/<db>  — anota <owner>, <pass> y <host>
dokku config:unset crm-iswo-api DATABASE_URL

dokku config:set crm-iswo-api DB_HOST=<solo-el-hostname-de-arriba> DB_PORT=5432 DB_SSLMODE=disable
```

⚠️ `DB_HOST` es **solo el hostname** (ej. `dokku-postgres-crm-iswo-api-db`),
nunca `host:puerto/base` completo — es un error fácil de cometer al copiar
del `DATABASE_URL` de arriba. Ver §8.2 si aparece
`could not translate host name "host:5432/db"`.

`DB_SSLMODE=disable` es intencional aquí: Postgres corre en el mismo EC2, en
la red docker privada de Dokku, sin salir a internet — ver la nota en
`docs/SECURITY_FASE1.md`.

### Rol `crm_iswo` + las 4 bases + grants (un solo paso, idempotente)

```bash
dokku postgres:connect crm-iswo-api-db < docs/sql/create_crm_iswo_app_role.sql
```

Antes de correrlo, editar el archivo y reemplazar `CAMBIAR_PASSWORD_FUERTE`
por una contraseña real **alfanumérica** (sin `@ : / # %` — ver §8.2) — esa
misma contraseña es el secret `CRM_ISWO_DATABASE_PASSWORD` de GitHub (§4).
El script crea el rol, las 4 bases y los `GRANT`/`ALTER DEFAULT PRIVILEGES`
de una sola pasada; se puede volver a correr sin error si hace falta
(no recrea nada que ya exista).

### Config vars para migraciones automáticas (owner, una sola vez)

Las migraciones (`db:migrate`) corren automáticamente en cada deploy como el
rol *owner* de Postgres, vía la fase `release` de `Procfile` (ver §6) —
nunca como `crm_iswo`, que no tiene privilegio `CREATE` a propósito. Para eso hace
falta setear, **una sola vez y directo en el servidor** (¡no como secret de
GitHub! — evita que la password del superusuario de Postgres viaje por CI):

```bash
dokku config:set crm-iswo-api \
  DB_OWNER_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production" \
  DB_OWNER_CACHE_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production_cache" \
  DB_OWNER_QUEUE_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production_queue" \
  DB_OWNER_CABLE_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production_cable"
```

Mismo `<owner>`/`<pass>`/`<host>` que anotaste arriba. De nuevo: `<pass>`
alfanumérica, sin caracteres reservados de URI.

## 3. SSH key para GitHub Actions

```bash
# En tu máquina, genera un par de llaves dedicado al deploy (sin passphrase):
ssh-keygen -t ed25519 -f deploy_crm_iswo_api -N ""

# En el EC2, autoriza la pública:
dokku ssh-keys:add github-actions-crm-iswo-api /ruta/a/deploy_crm_iswo_api.pub
```

La llave **privada** (`deploy_crm_iswo_api`, sin la extensión `.pub`) va al
secret `SSH_PRIVATE_KEY` de GitHub (paso 4).

## 4. Configurar GitHub (una sola vez)

En el repo → **Settings → Environments** → crear el Environment `production`
(el workflow `.github/workflows/deploy.yml` lo usa vía `environment: production`,
lo que permite además exigir aprobación manual antes de desplegar si se quiere).

**Secrets** (Environment `production`):

| Secret | Valor |
|---|---|
| `SSH_PRIVATE_KEY` | Llave privada del paso 3 |
| `RAILS_MASTER_KEY` | `config/master.key` real de producción |
| `CRM_ISWO_DATABASE_PASSWORD` | La misma del rol `crm_iswo` (paso 2) |
| `DEVISE_JWT_SECRET_KEY` | `bin/rails secret` (64+ hex) |
| `LOCKBOX_MASTER_KEY` | 64 hex — cifrado integraciones/exports/PII |
| `BLIND_INDEX_MASTER_KEY` | 64 hex, **distinta** de `LOCKBOX_MASTER_KEY` |
| `AWS_ACCESS_KEY_ID` | Usuario IAM con permiso `ses:SendEmail`/`ses:SendRawEmail` (y S3 si aplica a exports) |
| `AWS_SECRET_ACCESS_KEY` | Secret del mismo usuario IAM |
| `ANTHROPIC_API_KEY` | Para `AiClassifier` (opcional; sin ella cae a reglas deterministas) |

**Variables** (Environment `production`):

| Variable | Valor |
|---|---|
| `DOKKU_HOST` | IP/hostname SSH del EC2 (el mismo que resuelve `iswocrm.com`) |
| `APP_HOST` | `iswocrm.com` |
| `CORS_ALLOWED_ORIGINS` | `https://iswocrm.com,https://app.iswocrm.com` |
| `SPA_HOST` | `https://app.iswocrm.com` |
| `AWS_REGION` | Región AWS de la identidad SES verificada (p. ej. `us-east-1`) |

**AWS SES — antes del primer deploy:**

1. Verificar identidad de dominio `iswocrm.com` en SES (DKIM + Return-Path) en la región elegida.
2. Salir de modo *sandbox* SES (si no, solo entrega a destinatarios verificados manualmente).
3. Crear usuario IAM dedicado con política mínima `ses:SendEmail` + `ses:SendRawEmail` (evitar reusar credenciales admin).

El workflow pone estos valores en Dokku de forma **explícita** (allowlist), no
vuelca todos los secrets/vars del repo — evita filtrar al contenedor cualquier
secreto no relacionado con esta app.

## 5. Deploy

```bash
git push origin main
```

GitHub Actions: build → push a `ghcr.io/iswotech/crm-iswo-api` → `dokku
config:set` → `dokku git:from-image crm-iswo-api <imagen>`. Antes de levantar
el contenedor, Dokku corre la fase `release` de `Procfile` (migraciones como
owner — ver §6); el entrypoint del contenedor (`bin/docker-entrypoint`)
corre además `bin/rails db:prepare` en cada arranque como `crm_iswo`, que ya
no encuentra nada pendiente que crear.

Esto significa que, con el setup del §2 ya hecho (rol + bases + grants +
`DB_OWNER_*_DATABASE_URL`), **el primer deploy de la app funciona igual que
cualquier otro** — no hace falta ningún bootstrap manual adicional.

Después del primer deploy exitoso:

```bash
dokku letsencrypt:enable crm-iswo-api
dokku letsencrypt:cron-job --add   # renovación automática
```

## 6. Migraciones nuevas (owner, no `crm_iswo`) — automático vía `Procfile release:`

El rol `crm_iswo` solo tiene privilegios DML (`SELECT/INSERT/UPDATE/DELETE`) a
propósito: por diseño de RLS (Fase 3), si `crm_iswo` creara tablas se
volvería su *owner* y los owners de tabla **no** quedan sujetos a las
políticas RLS por defecto (a menos que se use `FORCE ROW LEVEL SECURITY`).
Por eso toda migración que cree/altere tablas necesita correr como el rol
*owner* del servicio Postgres, no como `crm_iswo`.

Esto ya **no es un paso manual**: `Procfile` define un proceso `release`
que Dokku corre automáticamente en cada deploy, después de construir la
imagen y antes de programar el contenedor "web":

```
release: bin/release
```

`bin/release` (script del repo, ejecutable) hace el trabajo real:

```bash
#!/bin/bash -e
export DATABASE_URL="$DB_OWNER_DATABASE_URL"
export CACHE_DATABASE_URL="$DB_OWNER_CACHE_DATABASE_URL"
export QUEUE_DATABASE_URL="$DB_OWNER_QUEUE_DATABASE_URL"
export CABLE_DATABASE_URL="$DB_OWNER_CABLE_DATABASE_URL"
exec bin/rails db:migrate
```

⚠️ **Dos trampas de Dokku que hay que conocer para no repetir este error**
(las dos costaron un deploy roto cada una al construir esto, 2026-07-24):

1. **`app.json` → `scripts.dokku.predeploy` NO sirve para esto.** Para apps
   basadas en `Dockerfile` (como esta), Dokku **no inyecta las config vars
   de la app en la fase `predeploy`** — es intencional, no un bug: esa fase
   se comitea a la imagen final, e inyectar secretos ahí los dejaría
   horneados en la imagen ([dokku/dokku#3817](https://github.com/dokku/dokku/issues/3817)).
   Con `predeploy`, `bin/release` corría con las 4 variables `DB_OWNER_*`
   completamente vacías (`Database URL cannot be empty`) aunque estuvieran
   bien seteadas. La fase `release` de `Procfile`, en cambio, **sí** recibe
   las config vars — porque no se comitea a la imagen, inyectarlas ahí es
   seguro.
2. **El comando de `Procfile`/`app.json` no puede referenciar `$VAR`
   directamente.** Dokku tiene un bug conocido
   ([dokku/dokku#8050](https://github.com/dokku/dokku/issues/8050)):
   cualquier `$VAR` que aparezca *directo en el string* de `release:` (o de
   `scripts.dokku.predeploy`) se reemplaza por **vacío** antes de ejecutar,
   incluso si el mecanismo de inyección de env vars de esa fase sí
   funciona. Por eso `Procfile` solo referencia `bin/release` (una palabra,
   nada que Dokku pueda expandir mal) — el script sí lee `$DB_OWNER_*`
   normalmente en su propio runtime, donde estas sí llegan bien.

Cómo funciona:

- Los `*_DATABASE_URL` que exporta `bin/release` son variables de shell
  **de ese proceso puntual** (la fase `release`), no de la app en general —
  leen los valores de `DB_OWNER_*_DATABASE_URL` (config vars seteadas una
  sola vez, §2) y apuntan a `crm_iswo_production` y sus 3 hermanas
  conectando como el rol *owner*.
- El contenedor "web" real **nunca** ve estas variables ni se conecta como
  owner — sigue arrancando con `DB_HOST`/`CRM_ISWO_DATABASE_PASSWORD` de
  siempre, conectado como `crm_iswo`. No hay ventana de tiempo con el
  runtime corriendo como superusuario.
- Corre igual en el primer deploy de la app que en cualquier deploy
  posterior — a diferencia de `dokku run`, la fase `release` siempre tiene
  una imagen recién construida contra la cual correr, así que no depende de
  que exista una release previa exitosa.
- Si `bin/release` falla (ej. permisos mal configurados), el deploy entero
  se aborta ahí mismo, sin tocar el contenedor que ya estaba corriendo.
- El `db:prepare` del entrypoint (en cada arranque del contenedor web, como
  `crm_iswo`) ya no encuentra migraciones pendientes, así que no intenta
  ningún DDL — sigue siendo la doble red de seguridad que ya era, ahora sin
  nada que hacer en el caso normal.
- Un `Procfile` que define **solo** `release:` (sin `web:`) es seguro: Dokku
  sigue usando el `CMD` del `Dockerfile` para el proceso web normalmente.

**Correr una migración a mano, fuera de un deploy** (ej. para probar algo
puntual), reusando el mismo script — esto sí requiere una release ya
desplegada, como cualquier `dokku run`:

```bash
dokku run crm-iswo-api bin/release
```

## 7. Verificación post-deploy

```bash
dokku run crm-iswo-api bin/rails staging:preflight
dokku run crm-iswo-api bin/rails prod:security_dry_run
curl -I https://iswocrm.com/up   # 200
```

Ver también `docs/PRODUCTION_CHECKLIST.md` para el checklist completo (PII,
RLS, exports S3).

## 8. Troubleshooting del primer deploy

Bitácora de los fallos encontrados en el primer deploy real a producción
(2026-07-24). Se repiten en cualquier "primer deploy" de una app Dokku nueva
(otro ambiente, staging, etc.), así que quedan documentados acá.

### 8.1 `CHECKS`: sin verbo HTTP

`CHECKS` (raíz del repo) usa el formato legacy de Dokku — la línea de ruta es
**solo la ruta**, sin `GET`:

```
WAIT=5
ATTEMPTS=24
/up
```

Con `GET /up` en vez de `/up`, Dokku concatena mal host+puerto+`GET` al armar
la URL del healthcheck (`http://host:80GET`) y el check nunca puede
ejecutarse (`invalid port ":80GET" after host`).

### 8.2 `DB_HOST` con la URL completa en vez del hostname

Al seguir el §2 (`dokku config:get ... DATABASE_URL` → anotar `<host>`), es
fácil copiar de más y terminar seteando `DB_HOST=<host>:<puerto>/<db>` en vez
de solo `<host>`. Síntoma: `PG::ConnectionBad: could not translate host name
"host:5432/db"`. Fix:

```bash
dokku config:set crm-iswo-api DB_HOST=<solo-el-hostname>
```

### 8.3 Primer deploy: `db:prepare` no puede crear el schema (bootstrap sin `dokku run`)

> **Ya resuelto de forma permanente** — la fase `release` de `Procfile` (§6)
> corre las migraciones como owner automáticamente en cada deploy, primero
> incluido. Lo de abajo es la bitácora de cómo se resolvió *a mano* el
> 2026-07-24, antes de automatizarlo; se deja como referencia por si el
> mecanismo nuevo llegara a fallar y hay que volver a hacerlo manualmente.

El §6 (versión anterior) asumía que ya existía una release desplegada para
poder usar `dokku run`. En el **primer** deploy de una app nueva eso no era
cierto: si el deploy falla
el healthcheck, Dokku descarta la imagen local (`dokku/crm-iswo-api:latest`)
y `dokku run` responde `App image not found` / `App has not been deployed` —
no hay forma de correr `db:migrate` como owner por fuera del propio arranque.

Bootstrap que funcionó (una sola vez, solo para la primera carga de schema):

1. Setear temporalmente las 4 `*_DATABASE_URL` como **config vars de la app**
   (no solo para un comando puntual como en §6), usando el rol owner:
   ```bash
   dokku config:set crm-iswo-api \
     DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production" \
     CACHE_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production_cache" \
     QUEUE_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production_queue" \
     CABLE_DATABASE_URL="postgres://<owner>:<pass>@<host>:5432/crm_iswo_production_cable"
   ```
2. Redesplegar (rebuild+release+deploy) — ahora el `db:prepare` automático del
   entrypoint corre como el owner y sí puede crear tablas/extensiones (ej.
   `btree_gist`, usada por índices GiST de exclusión).
3. **Apenas el healthcheck pase, revertir de inmediato** — si no, el
   contenedor sigue sirviendo tráfico real conectado como superuser, sin RLS:
   ```bash
   dokku config:unset crm-iswo-api DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL
   ```
   Esto reinicia la app; como el schema ya existe, el `db:prepare` normal (§6,
   primer párrafo) no tiene nada pendiente que crear y arranca directo como
   `crm_iswo`.

Nota: el password del rol owner usado en la URL debe ser **alfanumérico**,
sin `@ : / # %` — esos caracteres rompen el parseo de la URI
(`URI::InvalidURIError`) si no van percent-encoded. Si el password real los
tiene, lo más simple es rotarlo a uno alfanumérico solo para el bootstrap:
```bash
dokku postgres:connect crm-iswo-api-db
# ALTER USER <owner> WITH PASSWORD 'temporal-alfanumerica';
```

### 8.4 GHCR: `denied` al reintentar `git:from-image` manual

El `GITHUB_TOKEN` que usa `deploy.yml` para el login a GHCR es efímero — vale
solo durante esa ejecución de Actions. Si el deploy falla y se reintenta a
mano por SSH con `dokku git:from-image ...`, el login guardado ya venció →
`Error response from daemon: error from registry: denied`. Fix: no
reintentar a mano — volver a disparar el workflow (`gh run rerun <id>`, o
re-run desde la UI de Actions). Hace login fresco a GHCR y deploy en el mismo
paso, y no toca las config vars que no están en su allowlist (§4), así que un
bootstrap del §8.3 en curso sobrevive al re-run.

### 8.5 Let's Encrypt necesita email

`dokku letsencrypt:enable` falla con `Cannot request a certificate without an
e-mail address` si no se seteó antes:

```bash
dokku letsencrypt:set crm-iswo-api email <tu-email>
dokku letsencrypt:enable crm-iswo-api
```

### 8.6 `gh run rerun` sobre el mismo commit: Dokku lo saltea en silencio

`gh run rerun <id>` reusa el mismo `github.sha` de siempre. Si no hubo push
nuevo, `dokku git:from-image` ve el mismo contenido y responde:

```
!     No changes detected, skipping git commit
!     Call 'ps:rebuild' on app to rebuild the app from existing source
```

y **no hace ninguna release nueva** — el contenedor que ya estaba corriendo
sigue corriendo tal cual (útil saberlo si se está esperando que un cambio de
config vars tome efecto: si no cambia el commit, un `rerun` no alcanza). Fix,
directo en el servidor:

```bash
dokku ps:rebuild crm-iswo-api
```

Esto sí fuerza una release nueva desde la imagen ya presente en el host,
aplicando las config vars actuales.

### 8.7 `app.json` `predeploy` no recibe las config vars (Dockerfile apps)

Para apps basadas en `Dockerfile` (como esta), Dokku **no inyecta las config
vars de la app en la fase `predeploy`** de `app.json` — es intencional, no
un bug: esa fase se comitea a la imagen final, e inyectar secretos ahí los
dejaría horneados en la imagen
([dokku/dokku#3817](https://github.com/dokku/dokku/issues/3817)). Síntoma:
un script referenciando una config var propia (ej. `DB_OWNER_DATABASE_URL`)
la ve **vacía** dentro del `predeploy`, aunque `dokku run`/`dokku enter` en
el contenedor "web" normal la muestren bien seteada — confirmar con:

```bash
dokku enter crm-iswo-api web
echo "[$MI_VARIABLE]"
```

Si sale vacío solo en `predeploy` pero bien en `web`, es este caso. Fix: usar
la fase `release` de `Procfile` en vez de `predeploy` de `app.json` — esa sí
recibe las config vars (no se comitea a la imagen). Ver §6.

### 8.8 `$VAR` en `app.json`/`Procfile` se reemplaza por vacío (bug de Dokku)

Aparte de lo anterior, si el comando de `release:` (o de
`scripts.dokku.predeploy`) referencia una config var **directo en el
string** (ej. `"release": "... $DB_OWNER_DATABASE_URL ..."`), Dokku la
reemplaza por **vacío** antes de ejecutar — sin importar que la variable
exista, esté bien seteada, y que la fase en cuestión sí reciba env vars
([dokku/dokku#8050](https://github.com/dokku/dokku/issues/8050), bug
reconocido por el propio mantenedor). Síntoma típico en Rails: `Database
URL cannot be empty` con una `DATABASE_URL` que en teoría estaba seteada.
Fix: no referenciar `$VAR` directo en el `Procfile`/JSON — poner la lógica
en un script real del repo (`bin/release`) que solo se invoca por nombre;
ese script sí lee las variables correctamente porque el bug es solo en el
parseo del *string* de `Procfile`/`app.json`, no en el entorno real del
proceso. Ver §6 para el ejemplo actual.

### 8.9 `dokku config:set app K1=v1 K2=v2 ...` puede perder pares silenciosamente

Setear varias variables en un solo comando (`dokku config:set app K1=v1
K2=v2 K3=v3`) a veces solo aplicó la **primera** — las demás se perdían sin
ningún error visible, probablemente por cómo el cliente SSH/terminal partía
la línea larga al pegarla. Pasó dos veces seguidas construyendo esto
(2026-07-24): de 4 variables pegadas juntas, solo la primera quedaba
seteada; reintentado de a una por vez, sí funcionó siempre.

**Recomendación: setear una variable por comando**, nunca varias juntas,
sobre todo si el valor son URLs largas con `@`/`:`/`/`. Verificar después
con:

```bash
dokku config:get crm-iswo-api <VARIABLE>
```

o, para ver de un vistazo cuáles quedaron realmente registradas:

```bash
dokku config:export crm-iswo-api --format docker-args-keys
```

(lista todas las keys conocidas por Dokku para la app — si una variable que
creías seteada no aparece ahí, no se aplicó.)

### 8.10 Diagnóstico: ¿la variable llega al contenedor o no?

Cuando `dokku run` no está disponible (imagen no desplegada, ver §8.3) pero
la app **sí** está corriendo, se puede inspeccionar el contenedor vivo en vez
de usar `dokku run`:

```bash
dokku enter crm-iswo-api web
echo "[$MI_VARIABLE]"
exit
```

Esto fue clave para diagnosticar el §8.7: confirmó que `DB_OWNER_DATABASE_URL`
llegaba bien al contenedor "web" normal, mientras que la fase `predeploy`/
`release` la veía vacía — aislando el problema a la fase, no a la variable
en sí.

### 8.11 `Procfile` con solo `release:` deja 0 réplicas web — app caída 3 días sin loguear crash

**Causa raíz real:** el commit `281c161` (24 jul, ver §8.7/§8.8) reemplazó
`app.json` por un `Procfile` que definía **únicamente** `release: bin/release`,
sin línea `web:`. Para apps basadas en Dockerfile, si existe un `Procfile`,
Dokku usa exclusivamente los process types que declara — al no listar `web`,
la app quedó con **cero réplicas web desplegadas para siempre**, desde ese
mismo deploy del 24 jul. No fue un crash: nunca hubo container web para
crashear.

Síntomas que llevaron a diagnosticar mal al principio (2026-07-27): `ps:report`
mostraba `Running: false` / `Status web 1: missing` con un CID que ni existía
en `docker ps -a`, RAM/disco/`dmesg` sanos (descartando OOM), y
`docker images | grep crm-iswo-api` vacío — todo apuntaba a un crash o a un
`docker prune` externo, pero la explicación real es más simple: nunca se creó
el container web tras `281c161`, así que no había container ni imagen "de la
app corriendo" que preservar.

Esto se confirmó leyendo el log completo del deploy en GitHub Actions (`gh run
view <id> --log`), no con `ps:report` — ahí aparece explícito:

```
-----> Deploying crm-iswo-api via the docker-local scheduler...
 !     Skipping web as it is missing from the current Procfile
-----> Deploying release (count=0)
```

**Fix:** agregar la línea `web:` al `Procfile`, replicando el `CMD` del
`Dockerfile`:

```
web: ./bin/thrust ./bin/rails server
release: bin/release
```

**Complicación aparte durante el diagnóstico:** `dokku ps:rebuild` (probado
antes de encontrar la causa real) falló con `failed to fetch oauth token:
denied: denied` — el login a GHCR que usa el deploy normal
(`registry:login` en `.github/workflows/deploy.yml`) se hace con el
`GITHUB_TOKEN` del job, efímero, y ya no era válido fuera de esa corrida. No
era la causa de la caída, pero sí bloqueaba reintentar un rebuild local; el
único camino que funciona para redesplegar es re-disparar el workflow
completo (`gh workflow run deploy.yml` o push a `main`), que repite el login
con un token fresco.

**Lección:** ante `ps:report` con `Running: false`/`missing`, revisar primero
el log completo del **último deploy que sí corrió** (`gh run view --log`,
buscando `Skipping <process>` o `Deploying release (count=N)`) antes de
asumir un crash post-deploy — Dokku puede reportar "missing" tanto por un
container que murió como por uno que nunca se creó.

**Pendiente real:** este repo no tiene forma de alertar si la app cae (o
nunca queda con réplicas) fuera de mirar manualmente (no hay
monitoreo/healthcheck externo). Ver también §8.12.

### 8.12 Pendiente (no urgente)

- **`CHECKS` → `healthchecks` en `app.json`**: Dokku avisa en cada deploy que
  `CHECKS` está deprecado a favor de `healthchecks` en `app.json`. Funciona
  correctamente tal como está (§8.1 ya resuelto); migrarlo es cosmético, no
  se hizo para no sumar riesgo a un pipeline que recién se estabilizó.
- **Datos demo en producción**: si en algún momento se corrió `db:seed`
  contra esta base, hay tenants/usuarios de fixture con password débil
  conocida — ver `docs/PRODUCTION_CHECKLIST.md` sobre por qué `db:seed`
  nunca debe correr contra producción real y qué usar en su lugar.
- **Monitoreo/uptime check externo**: ver §8.11 — no hay alerta si la app
  cae fuera de un ciclo de deploy.
