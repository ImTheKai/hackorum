#!/usr/bin/env bash
set -euo pipefail

UMAMI_DB="${UMAMI_DB:-umami}"
UMAMI_DB_USER="${UMAMI_DB_USER:-umami}"
UMAMI_DB_PASSWORD="${UMAMI_DB_PASSWORD:-umami}"

psql -v ON_ERROR_STOP=1 \
  -v UMAMI_DB="$UMAMI_DB" \
  -v UMAMI_DB_USER="$UMAMI_DB_USER" \
  -v UMAMI_DB_PASSWORD="$UMAMI_DB_PASSWORD" \
  --username "$POSTGRES_USER" \
  --dbname "postgres" <<'EOSQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'UMAMI_DB_USER') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'UMAMI_DB_USER', :'UMAMI_DB_PASSWORD');
  END IF;
END
$$;

SELECT format('CREATE DATABASE %I OWNER %I', :'UMAMI_DB', :'UMAMI_DB_USER')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'UMAMI_DB')\gexec
EOSQL
