#!/usr/bin/env bash
set -euo pipefail

# Initialize local PostgreSQL schema + seed data for non-Docker development.
# Usage:
#   DB_HOST=localhost DB_PORT=5432 DB_NAME=flashinfo DB_USER=postgres DB_PASSWORD='' ./scripts/init-local-db.sh

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-flashinfo}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"

if ! command -v psql >/dev/null 2>&1; then
  echo "Error: psql is required. Install PostgreSQL first (e.g. brew install postgresql@15)." >&2
  exit 1
fi

if ! command -v createdb >/dev/null 2>&1; then
  echo "Error: createdb is required. Ensure PostgreSQL client tools are installed." >&2
  exit 1
fi

export PGPASSWORD="${DB_PASSWORD}"

echo "Ensuring database exists: ${DB_NAME}"
if ! psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  createdb -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" "${DB_NAME}"
  echo "Created database ${DB_NAME}"
else
  echo "Database ${DB_NAME} already exists"
fi

echo "Applying schema..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f app/backend/src/schema.sql

echo "Applying seed data..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f app/backend/src/seed.sql

echo "Local DB initialization complete."
