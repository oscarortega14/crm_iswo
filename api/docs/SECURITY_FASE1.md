# Seguridad Fase 1 — Infra (tránsito + secretos)

## Checklist

```bash
cd api
bundle exec rails security:infra
```

## Qué verifica

| Item | Producción |
|------|------------|
| `force_ssl` + `ASSUME_SSL` | Obligatorio (proxy TLS de Dokku, Let's Encrypt) |
| `APP_HOST` | Dominio público API (`iswocrm.com`) |
| `DB_SSLMODE` | `disable` — desviación aceptada, ver nota abajo |
| `DEVISE_JWT_SECRET_KEY` | Sesiones JWT |
| `LOCKBOX_MASTER_KEY` | Integraciones + exports + PII |
| `CORS_ALLOWED_ORIGINS` | Solo `https://`, sin localhost |

## Desviación documentada — `DB_SSLMODE=disable`

El RFC pide tránsito cifrado app↔PostgreSQL (`DB_SSLMODE=require`). En Dokku,
el Postgres de la app (`dokku-postgres`) corre **en el mismo EC2**, en la red
docker privada del host — el tráfico nunca sale a internet ni cruza un
segmento de red compartido con otros tenants/servicios. La imagen oficial de
Postgres que usa `dokku-postgres` no trae TLS activado por defecto (requeriría
generar y montar un certificado autofirmado). Dado el contexto (mismo host,
red interna Docker, sin exposición externa), se acepta `DB_SSLMODE=disable`
para este despliegue. Ver `docs/DEPLOY_DOKKU.md`.

Si en el futuro Postgres se separa a otro host/RDS, volver a `require`.

## Dokku (`dokku config:set`, ver `docs/DEPLOY_DOKKU.md`)

- `ASSUME_SSL=true`, `DB_SSLMODE=disable`
- Secretos puestos vía GitHub Actions (Environment `production`): `LOCKBOX_MASTER_KEY`, `DEVISE_JWT_SECRET_KEY`

## Servidor (fuera del repo)

- TLS en proxy Dokku (`dokku letsencrypt`)
- Backups cifrados
- Volumen/disco cifrado en reposo (LUKS / EBS encryption)
