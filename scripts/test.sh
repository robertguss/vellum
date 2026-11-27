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
mo check domain/formulas.mo
mo check domain/blueprints.mo
mo check domain/feed-bridge.mo
mo check domain/taint-bridge.mo
mo check domain/rlm.mo
mo check domain/rlm-vm.mo
mo check domain/packs.mo
mo check domain/sync.mo
mo check domain/garden.mo
mo check domain/collab.mo
mo check domain/secrets.mo
mo check domain/notion-import.mo
mo check db.mo
mo check erasure-ops.mo
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
mo check tests/stage1.mo
mo check tests/stage2.mo
mo check tests/stage3.mo
mo check tests/stage4.mo
mo check tests/stage5.mo
mo check tests/phase1a.mo
mo check tests/phase1b.mo
mo check tests/phase1c.mo
mo check tests/phase2a.mo
mo check tests/phase2b.mo
mo check tests/phase2c.mo
mo check tests/phase3a.mo
mo check tests/phase3a2.mo
mo check tests/phase3b.mo
mo check tests/phase3b2.mo
mo check tests/phase4.mo
mo check tests/v3m1.mo
mo check tests/v3m1b.mo
mo check tests/v3m1c.mo
mo check tests/unit-database-model.mo
mo check tests/unit-formulas.mo
mo check tests/unit-db.mo
mo check tests/unit-blocks.mo
mo check tests/unit-packs.mo
mo check tests/unit-domain-misc.mo
mo check tests/unit-rlm.mo
mo check tests/unit-sync-cli.mo

mo test domain/blocks.mo
mo test domain/policy.mo
mo test domain/notion-import.mo
mo test tests/unit-database-model.mo
mo test tests/unit-formulas.mo
mo test tests/unit-db.mo
mo test tests/unit-blocks.mo
mo test tests/unit-packs.mo
mo test tests/unit-domain-misc.mo
mo test tests/unit-rlm.mo
mo test tests/unit-sync-cli.mo
mo test tests/stage1.mo
mo test tests/stage2.mo
mo test tests/stage3.mo
mo test tests/stage4.mo
mo test tests/stage5.mo
mo test tests/phase1a.mo
mo test tests/phase1b.mo
mo test tests/phase1c.mo
mo test tests/phase2a.mo
mo test tests/phase2b.mo
mo test tests/phase2c.mo
mo test tests/phase3a.mo
mo test tests/phase3a2.mo
mo test tests/phase3b.mo
mo test tests/phase3b2.mo
mo test tests/phase4.mo
mo test tests/v3m1.mo
mo test tests/v3m1b.mo
mo test tests/v3m1c.mo

echo "All Vellum Stage 1-5 checks, frontend build checks, and tests passed."
