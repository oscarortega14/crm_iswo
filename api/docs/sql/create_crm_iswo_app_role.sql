-- Rol de aplicación CRM ISWO (Fase 3 RLS — SECURITY_FASE3.md)
-- Ejecutar como superuser/owner en PostgreSQL de producción:
--   dokku postgres:connect crm-iswo-api-db < docs/sql/create_crm_iswo_app_role.sql
--
-- Idempotente: se puede correr más de una vez sin error (rol y bases se
-- crean solo si no existen; los GRANT/ALTER DEFAULT PRIVILEGES son
-- inherentemente idempotentes en Postgres).
--
-- IMPORTANTE: reemplazar CAMBIAR_PASSWORD_FUERTE por una contraseña real
-- ALFANUMÉRICA (sin `@ : / # %`) antes de correr — esa misma contraseña es
-- el secret CRM_ISWO_DATABASE_PASSWORD de GitHub. Un caracter reservado de
-- URI ahí rompe el parseo de connection strings en cualquier lugar donde se
-- arme una URL con esta password (ver docs/DEPLOY_DOKKU.md §8.2).

-- 1) Rol de runtime — sin superuser, sin bypass RLS, sin privilegio CREATE
--    (a propósito: si crm_iswo creara tablas se volvería su owner, y los
--    owners de tabla no quedan sujetos a RLS por defecto).
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'crm_iswo') THEN
    CREATE ROLE crm_iswo WITH LOGIN PASSWORD 'CAMBIAR_PASSWORD_FUERTE' NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

-- 2) Las 4 bases (ajusta nombres si difieren de config/database.yml)
SELECT 'CREATE DATABASE crm_iswo_production'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'crm_iswo_production')
\gexec

SELECT 'CREATE DATABASE crm_iswo_production_cache'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'crm_iswo_production_cache')
\gexec

SELECT 'CREATE DATABASE crm_iswo_production_queue'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'crm_iswo_production_queue')
\gexec

SELECT 'CREATE DATABASE crm_iswo_production_cable'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'crm_iswo_production_cable')
\gexec

GRANT CONNECT ON DATABASE crm_iswo_production TO crm_iswo;
GRANT CONNECT ON DATABASE crm_iswo_production_cache TO crm_iswo;
GRANT CONNECT ON DATABASE crm_iswo_production_queue TO crm_iswo;
GRANT CONNECT ON DATABASE crm_iswo_production_cable TO crm_iswo;

-- 3) Privilegios DML por base — server-side \c real (no un comentario: si
--    esto queda comentado, como estaba antes, el script entero deja de
--    tener efecto sobre las 4 bases reales y solo toca la base por defecto
--    de la conexión inicial).
\c crm_iswo_production
GRANT USAGE ON SCHEMA public TO crm_iswo;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO crm_iswo;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO crm_iswo;

\c crm_iswo_production_cache
GRANT USAGE ON SCHEMA public TO crm_iswo;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO crm_iswo;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO crm_iswo;

\c crm_iswo_production_queue
GRANT USAGE ON SCHEMA public TO crm_iswo;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO crm_iswo;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO crm_iswo;

\c crm_iswo_production_cable
GRANT USAGE ON SCHEMA public TO crm_iswo;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO crm_iswo;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO crm_iswo;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO crm_iswo;

-- 4) Las migraciones (db:migrate) corren automáticamente en cada deploy
--    como el rol owner vía el predeploy de app.json — ver docs/DEPLOY_DOKKU.md
--    §6. Los GRANT/ALTER DEFAULT PRIVILEGES de arriba ya cubren las tablas
--    que ese owner cree de ahora en más; no hace falta repetir este script
--    salvo que se recree el rol o las bases desde cero.
-- 5) Verificar desde la app: bundle exec rails security:rls
