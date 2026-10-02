# Checklist de producción — RFC §7 + Dokku

Consolidado para el primer deploy. Ver también `SECURITY_FASE1.md`, `SECURITY_FASE2.md`,
`SECURITY_FASE3.md` y `DEPLOY_DOKKU.md` (setup completo del servidor + GitHub Actions).

**Dry-run local (sin desplegar):**

```bash
bundle exec rails prod:security_dry_run
```

## 1. Variables de entorno en Dokku (`dokku config:set`) — ver `DEPLOY_DOKKU.md`

- [ ] `ASSUME_SSL=true`, `DB_SSLMODE=disable` (Postgres colocado en el mismo host, red docker privada — ver `SECURITY_FASE1.md`), `APP_HOST=iswocrm.com`, `DB_RLS_ENABLED=true`, `SOLID_QUEUE_IN_PUMA=true`
- [ ] `CORS_ALLOWED_ORIGINS=https://iswocrm.com,https://app.iswocrm.com`
- [ ] Secretos puestos vía GitHub Actions (Environment `production`): `RAILS_MASTER_KEY`, `CRM_ISWO_DATABASE_PASSWORD`, `DEVISE_JWT_SECRET_KEY`, `LOCKBOX_MASTER_KEY`, `BLIND_INDEX_MASTER_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- [ ] App creada: `dokku apps:create crm-iswo-api`
- [ ] Descomentar/definir `AWS_S3_BUCKET`, `AWS_REGION` (+ opcional `AWS_KMS_KEY_ID`) para exports en prod — `AWS_REGION` también la usa SES para email
- [ ] Identidad de dominio verificada en SES (DKIM/SPF) para `iswocrm.com` y cuenta SES fuera de modo *sandbox*
- [ ] `DB_OWNER_DATABASE_URL`, `DB_OWNER_CACHE_DATABASE_URL`, `DB_OWNER_QUEUE_DATABASE_URL`, `DB_OWNER_CABLE_DATABASE_URL` seteadas **directo en el servidor** (nunca como secret de GitHub) — las usa `bin/release` (fase `release` de `Procfile`) para migrar como owner (ver `DEPLOY_DOKKU.md` §2/§6)

## 2. Secretos (GitHub → Settings → Environments → `production`)

- [ ] Secrets: `SSH_PRIVATE_KEY`, `RAILS_MASTER_KEY`, `CRM_ISWO_DATABASE_PASSWORD`, `DEVISE_JWT_SECRET_KEY`, `LOCKBOX_MASTER_KEY`, `BLIND_INDEX_MASTER_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ANTHROPIC_API_KEY`
- [ ] Variables: `DOKKU_HOST`, `APP_HOST`, `CORS_ALLOWED_ORIGINS`, `SPA_HOST`, `AWS_REGION`
- [ ] `LOCKBOX_MASTER_KEY` y `BLIND_INDEX_MASTER_KEY` distintas, 64 hex cada una
- [ ] Misma `LOCKBOX_MASTER_KEY` que en dev si compartes BD (o re-cifrar PII)

## 3. TLS / landings (RFC §6.5)

- [ ] DNS `iswocrm.com` (apex, A) → Elastic IP del EC2 Dokku
- [ ] DNS `app.iswocrm.com` y wildcard `*.iswocrm.com` → Vercel (frontend, ver `DOMAIN_SETUP.md`)
- [ ] `dokku letsencrypt:enable crm-iswo-api` (requiere puertos 80/443 abiertos en el Security Group)

Detalle completo de la arquitectura de dominio (por qué el front va en subdominio
de `iswocrm.com` y no en `*.vercel.app`) en [`docs/DOMAIN_SETUP.md`](./DOMAIN_SETUP.md).

## 4. PostgreSQL — rol app + RLS

- [ ] Ejecutar `docs/sql/create_crm_iswo_app_role.sql` (password → `CRM_ISWO_DATABASE_PASSWORD`) — crea rol + 4 bases + grants en un solo paso, idempotente
- [ ] `db:migrate` corre solo, como **owner**, vía la fase `release` de `Procfile` en cada deploy (no manual — ver `DEPLOY_DOKKU.md` §6)
- [ ] En servidor: `bundle exec rails security:rls:install` && `security:rls`
- [ ] Smoke RLS con rol `crm_iswo` (conteos distintos por tenant, no como superuser)
- [ ] **Nunca correr `db:seed` contra esta base.** `db/seeds.rb` siembra 3
      tenants de fixture (ISWO/Mi Casita/Libranzas) con usuarios `@*.local` y
      password hardcodeada `Password123!` (ver
      `app/services/tenants/platform_seeder.rb` y `lib/tasks/tenants.rake`) —
      pensado para desarrollo/demo, no para producción real. Si aparece este
      seed en una base de prod, tratarlo como credencial comprometida
      (rotar todos los passwords o borrar los tenants de fixture).
      Para crear un tenant real usar (acepta credenciales reales por
      variable de entorno):
      ```bash
      SLUG=<slug> NAME="<nombre>" ADMIN_EMAIL=<email-real> ADMIN_PASSWORD=<password-real> \
        dokku run crm-iswo-api bin/rails tenants:onboard
      ```

## 5. PII (Fase 2)

- [ ] Si hay contactos legados: `CONTACT_PII_MIGRATING=true bundle exec rails security:encrypt_contacts`
- [ ] `bundle exec rails security:pii` → exit 0

## 6. Deploy y verificación

```bash
# Automático: push a main → GitHub Actions build+push GHCR → dokku git:from-image
# Manual/una vez, ver DEPLOY_DOKKU.md para el setup completo del servidor.
dokku run crm-iswo-api bin/rails staging:preflight
dokku run crm-iswo-api bin/rails security:pii
```

- [ ] `staging:preflight` exit 0 en el contenedor
- [ ] `/up` responde 200
- [ ] Login SPA → API con cookies refresh en HTTPS

## 7. Operación (fuera del repo)

- [ ] Backups PostgreSQL cifrados
- [ ] Disco/volumen cifrado (LUKS / RDS encryption)
- [ ] Credenciales AWS IAM mínimas para bucket S3 exports
