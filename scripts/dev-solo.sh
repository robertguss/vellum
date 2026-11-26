#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f public/manifest.json ]]; then
  echo "==> Building Vellum frontend assets..."
  (
    cd frontend
    if [[ ! -d node_modules ]]; then
      npm install
    fi
    npm run build
  )
fi

DATA_DIR="${VELLUM_DATA_DIR:-$ROOT_DIR/.vellum-solo}"
mkdir -p "$DATA_DIR"
rm -rf "$DATA_DIR/public"
cp -r "$ROOT_DIR/public" "$DATA_DIR/public"

PORT="${PORT:-8080}"
WORKERS="${WORKERS:-4}"

export VELLUM_MODE=solo
export VELLUM_BIND=127.0.0.1
export VELLUM_INSECURE_COOKIES=1

echo "==> Starting Vellum Solo Mode at http://127.0.0.1:${PORT} (data: ${DATA_DIR})"
exec mo serve main.mo --bind 127.0.0.1 --port "$PORT" --workers "$WORKERS" --data "$DATA_DIR"
