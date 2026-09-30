# Seguridad Fase 3 — RLS PostgreSQL (multi-tenant)

Capa adicional en PostgreSQL: cada fila con `tenant_id` solo es visible si coincide con el tenant de la sesión.

Complementa `ActsAsTenant` + Pundit (defensa en profundidad).

## Activación

```bash
cd api
bundle exec rails db:migrate   # 20260610120000_enable_tenant_row_level_security

# Si security:rls dice "faltan políticas" pero migrate no corre nada (p. ej. tras db:schema:load):
bundle exec rails security:rls:install

# Dev (opcional):
DB_RLS_ENABLED=true bundle exec rails security:rls

# Producción (default DB_RLS_ENABLED=true):
bundle exec rails security:rls
```

## Cómo funciona

| Setting PostgreSQL | Cuándo |
|--------------------|--------|
| `crm.current_tenant_id` | Request/job con `ActsAsTenant.with_tenant` |
| `crm.bypass_rls=on` | Jobs rake, `ActsAsTenant.without_tenant`, consola admin |

Política `crm_tenant_isolation` en 19 tablas con `tenant_id`.

## Producción

1. Usuario BD dedicado `crm_iswo` (no superuser, sin `BYPASSRLS`).
2. `DB_RLS_ENABLED=true` en Dokku (`dokku config:set`).
3. Migraciones con usuario owner; app con `crm_iswo` (ver "Migraciones" en `docs/DEPLOY_DOKKU.md`).

Opcional endurecimiento:

```sql
ALTER TABLE contacts FORCE ROW LEVEL SECURITY;
-- repetir por tabla si el owner debe quedar sujeto a RLS
```

## Verificación

```bash
bundle exec rails staging:preflight   # incluye security:rls si DB_RLS_ENABLED
```

En dev como `postgres` (superuser) RLS no filtra — el check avisa. El aislamiento real se valida con rol de aplicación.
