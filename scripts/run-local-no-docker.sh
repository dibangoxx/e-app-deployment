#!/usr/bin/env bash
set -euo pipefail

# Run backend + serve frontend from Express for non-Docker local testing.
# Prerequisites:
# - PostgreSQL running locally
# - Redis running locally (optional for degraded mode, recommended for full functionality)

if ! command -v node >/dev/null 2>&1; then
  echo "Error: Node.js is required (>=20)." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "Error: npm is required." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="${ROOT_DIR}/app/backend"

cd "${BACKEND_DIR}"

if [[ ! -d node_modules ]]; then
  echo "Installing backend dependencies..."
  npm install
fi

export NODE_ENV="${NODE_ENV:-development}"
export PORT="${PORT:-3001}"
export DB_HOST="${DB_HOST:-localhost}"
export DB_PORT="${DB_PORT:-5432}"
export DB_NAME="${DB_NAME:-flashinfo}"
export DB_USER="${DB_USER:-postgres}"
export DB_PASSWORD="${DB_PASSWORD:-}"
export REDIS_HOST="${REDIS_HOST:-localhost}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-}"
export CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:3001,http://127.0.0.1:3001}"

echo "Starting FlashInfo backend on http://localhost:${PORT}"
echo "Frontend available at http://localhost:${PORT}/"
echo "Operations app available at http://localhost:${PORT}/src/operations.html"

npm run dev
