# Vellum

**An open-source, AI-native collaborative workspace (docs, wikis, and relational databases) built in [Mo](https://github.com/robertguss/mo), 100% Pure [MoDB](https://github.com/robertguss/modb), and [Arvo](https://github.com/robertguss/arvo).**

> **Status: Stage 1–5 Implemented (`mo check` + `mo test` + React 19 / Inertia v2 / TipTap Vite UI verified)**

Vellum is designed from first principles as a self-hostable open-source replacement for Notion, Outline, and Confluence where **AI agents and humans are equal, accountable, capability-confined collaborators**—running as a single Mo server backed by **zero SQLite, zero Postgres, zero Redis, and zero Node in production**.

---

## Architecture & Implemented Capabilities

- **Stage 1 — Core Workspace & Identity (`domain/{types,blocks,policy}.mo`, `db.mo`, `routes/{auth,workspace}.mo`):**
  - OIDC/SSO PKCE S256 login (`Arvo.Oidc`), AEAD state cookies, MoDB sessions (`sessions.modb`), double-submit CSRF (`X-XSRF-TOKEN`), and SHA-256 scoped `vlm_ag_...` agent bearer tokens with `Modb.Grants` fail-closed collection ACLs.
  - Canonical Block Tree (`blk_...`) with lossless anchored Markdown round-trips, provenance metadata per block, surgical `BlockOp` patching, inline comments, AWS SigV4 presigned S3 attachments (`Arvo.S3`), and transactional `Modb.Fts` BM25 search.
- **Stage 2 — Relational Databases & Multi-View Engine (`domain/database-model.mo`, `routes/databases.mo`):**
  - Strongly typed columns (`Title`, `RichText`, exact `Decimal` `Number`, `DateProp`, `Select`, `MultiSelect`, `Checkbox`, `Person`, `Url`, `Relation`, `Rollup`).
  - Table, Kanban Board, and Calendar views backed by atomic `vlm_db_cells` composite indexes, optimistic row locking, and 5 incremental `Modb.Ledger` commit invariants.
- **Stage 3 — Real-Time Multi-Actor Collaboration & Native MCP (`domain/collab.mo`, `routes/{collab,mcp}.mo`):**
  - Streamable HTTP `/mcp` server (`Arvo.Mcp`) exposing 17 agent tools including `vellum.onboard`, search, anchored reads, block patches, claims, proposals, databases, and attenuated grant delegation.
  - Advisory `Modb.Claims` block/row leases, isolated copy-on-write `Modb.World` Change Proposals (`GET /api/proposals/:id/diff`, Accept/Reject), offline `Modb.Replay` Selective Undo simulation, signed outbound webhooks (`Arvo.Webhooks` + `Arvo.Modb.Jobs`), and live SSE `/api/events`.
- **Stage 4 — Notion Importer, Built-in AI & Knowledge Gardening (`domain/notion-import.mo`, `routes/{importer,ai}.mo`):**
  - Notion Markdown + CSV batch importer (`/api/import/notion`) stripping 32-hex ID suffixes, rewriting internal `[[...]]` links, and inferring typed database columns.
  - Grant-filtered Ask Workspace (`/api/ai/ask`, JSON + SSE token/citation streaming), Inline Draft-into-Proposal (`/api/ai/draft`), and scheduled Knowledge Gardening (`GET /api/admin/garden` + `vellum.garden` hourly job).
- **Stage 5 — Workspace UI & Self-Hosting (`frontend/`, `Dockerfile`, `docker-compose.dev.yml`):**
  - React 19 + TypeScript + Vite 6 + Tailwind CSS v4 + Inertia v2 + TipTap block editor with Provenance gutters, `Cmd+K` BM25 search modal, Ask AI streaming drawer, Multi-View Databases (Table/Board/Calendar), Change Proposals Diff Viewer, and Agents/Grants/Gardening/Importer/Selective Undo Console.

---

## Quick Start (Local Development)

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```
2. Start local Dex (OIDC) and VersityGW (S3-compatible) containers:
   ```bash
   docker compose -f docker-compose.dev.yml up -d
   ```
3. Install frontend dependencies and start Vite HMR + `mo serve --watch`:
   ```bash
   (cd frontend && npm install)
   ./scripts/dev.sh
   ```
4. Open `http://127.0.0.1:8080`, click **Continue with OIDC SSO**, and sign in with Dex (`ada@acme.io` / `password`).

## Running Full Verification

```bash
./scripts/test.sh
```

Reads `frontend` TypeScript checks (`tsc --noEmit`), Vite production manifest build (`public/manifest.json`), `mo check` on every module, and `mo test` across unit/property suites and full-stack `Arvo.WebTest` integration suites.

---

## Documentation & Roadmaps

- [Vellum v2 Vision & AI-Native Platform Roadmap](docs/v2-vision-and-roadmap.md) — **Active north-star roadmap** covering Solo Mode, Git-style multi-page + DB `Modb.World` branches & What-If scenarios, AI-compiled database columns, Compiled Context Packs, autonomous knowledge gardening, `Modb.Taint` prompt-injection defense, and `Modb.Erasure`.
- [Vellum v1 Architecture & Technical Specification](docs/vellum-spec.md)
- [Upstream PR Roadmap (`mo`, `modb`, `arvo`)](docs/upstream-roadmap.md)
- [Performance & Scale Benchmarks](docs/benchmarks.md)

---

## License

[MIT](LICENSE)
