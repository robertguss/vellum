#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

cleanup() {
  if [[ -n "${VITE_PID:-}" ]]; then
    kill "$VITE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

(
  cd frontend
  npm run dev -- --host 127.0.0.1 --port 5173
) &
VITE_PID=$!

export VELLUM_VITE_DEV_URL="${VELLUM_VITE_DEV_URL:-http://127.0.0.1:5173}"
exec mo serve main.mo --watch --bind 127.0.0.1 --port 8080
