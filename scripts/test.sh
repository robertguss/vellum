#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p public/assets

if [[ -d frontend/node_modules ]]; then
  (
    cd frontend
    npm run typecheck
    npm run build
  )
  node -e '
    const fs = require("fs");
    const manifest = JSON.parse(fs.readFileSync("public/manifest.json", "utf8"));
    const entry = manifest["src/main.tsx"];
    if (!entry || !entry.file) {
      throw new Error("public/manifest.json missing src/main.tsx entry");
    }
    if (!fs.existsSync("public/" + entry.file)) {
      throw new Error("Missing built asset: public/" + entry.file);
    }
    for (const css of entry.css || []) {
      if (!fs.existsSync("public/" + css)) {
        throw new Error("Missing built CSS asset: public/" + css);
      }
    }
    console.log("Verified Vite manifest & assets:", entry.file);
  '
fi

mo check domain/types.mo
mo check domain/blocks.mo
mo check domain/policy.mo
mo check domain/database-model.mo
mo check domain/blueprints.mo
mo check domain/feed-bridge.mo
mo check domain/taint-bridge.mo
mo check domain/rlm.mo
mo check domain/rlm-vm.mo
mo check domain/packs.mo
mo check domain/sync.mo
mo check domain/garden.mo
mo check domain/collab.mo
mo check domain/notion-import.mo
mo check db.mo
mo check routes/auth.mo
mo check routes/workspace.mo
mo check routes/databases.mo
mo check routes/collab.mo
mo check routes/mcp.mo
mo check routes/importer.mo
mo check routes/ai.mo
mo check routes/packs.mo
mo check routes/sync.mo
mo check sync.mo
mo check main.mo

mo test domain/blocks.mo
mo test domain/policy.mo
mo test domain/database-model.mo
mo test domain/blueprints.mo
mo test domain/packs.mo
mo test domain/sync.mo
mo test domain/rlm.mo
mo test domain/rlm-vm.mo
mo test domain/garden.mo
mo test domain/collab.mo
mo test domain/notion-import.mo
mo test sync.mo
mo test db.mo
mo test main.mo

echo "All Vellum Stage 1-5 checks, frontend build checks, and tests passed."
