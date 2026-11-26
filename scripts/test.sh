#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p public/assets

mo check domain/types.mo
mo check domain/blocks.mo
mo check domain/policy.mo
mo check db.mo
mo check routes/auth.mo
mo check routes/workspace.mo
mo check main.mo

mo test domain/blocks.mo
mo test domain/policy.mo
mo test db.mo
mo test main.mo

echo "All Vellum Stage 1 checks and tests passed."
