# Vellum

**An open-source, AI-native collaborative workspace (docs, wikis, and relational databases) built in [Mo](https://github.com/robertguss/mo), [MoDB](https://github.com/robertguss/modb), and [Arvo](https://github.com/robertguss/arvo).**

> **Status: `v0.1.0-spec`** — Architecture and upstream roadmap locked in. Stage 0 upstream foundations across `mo`, `modb`, and `arvo` are up next.

Vellum is designed from first principles as a self-hostable open-source replacement for Notion, Outline, and Confluence where **AI agents and humans are equal, accountable, capability-confined collaborators**—running as a single compiled binary with **zero SQLite, zero Redis, and zero Node in production**.

---

## Why Vellum (vs. Outline, Notion & Confluence)

Most knowledge bases bolt AI onto an architecture built solely for humans typing into opaque rich-text blobs. Vellum builds directly on Mo's object-capability runtime and MoDB's CoW B+Tree Layer 4 primitives:

| Capability | Traditional KBs (Notion / Outline / Confluence) | Vellum (Mo + MoDB + Arvo) |
| --- | --- | --- |
| **Document Representation** | Opaque ProseMirror/editor JSON blobs that agents blindly overwrite or fail to parse cleanly | **Canonical Block Tree + Lossless Markdown** with stable ULID block IDs (`blk_...`)—TipTap WYSIWYG for humans, clean anchored Markdown & surgical block patches for agents |
| **Agent Permissions** | Broad user-level API keys or coarse workspace tokens | **Attenuated Capability Grants (`Modb.Grants`)**—humans (via OIDC) and agents receive hierarchical, scope-narrowed grants with call budgets, TTLs, and cascading revocation |
| **Concurrent Collaboration** | Last-write-wins or hidden conflicts between bots and humans | **Advisory Block/Row Claims (`Modb.Claims`) + Live SSE Presence**—agents and humans see each other's active leases directly through data |
| **Reviewing Agent Edits** | Either bots can't edit, or bots silently mutate live docs | **Speculative CoW Change Proposals (`Modb.World`)**—agents edit inside isolated copy-on-write worlds with mandatory `reason` + citations and $O(\text{diff})$ human review |
| **Mistake Recovery** | Manual copy-paste from page history one page at a time | **Hash-Chained Audit & Selective Undo (`Modb.Ledger` + `Modb.Replay`)**—simulate `ExcludePrincipal` / `ExcludeGrant` and atomically roll back one agent's edits without losing subsequent human work |
| **Structured Knowledge** | Pure prose (Outline) or proprietary cloud-only databases (Notion) | **Relational Databases & Multi-View Engine**—typed schemas (`Decimal`, `Date`, `Select`, `Relation`, `Rollup`) with **Table, Kanban Board, and Calendar** views |
| **Agent Connectivity** | Separate REST APIs plus third-party MCP wrappers | **Native Streamable HTTP `/mcp` + OpenAPI 3.1 + Signed Webhooks** sharing the exact same policy, grant, and audit pipeline as the web UI |
| **Deployment** | Node/Python/Ruby + PostgreSQL + Redis + Elasticsearch/Typesense + worker fleet | **One compiled `mo` binary + MoDB CoW B+Tree file + S3-compatible object storage** (AWS S3, Cloudflare R2, MinIO) |

---

## Architecture & Stack

- **Language & Runtime:** [Mo](https://github.com/robertguss/mo) (`v0.3.0+`, 100% pure safe Rust `#![forbid(unsafe_code)]`, isolated per-request VM heaps, multi-worker `mo serve`, capability confinement, zero-socket `mo test`).
- **Storage Engine:** **100% Pure [MoDB](https://github.com/robertguss/modb)** (single-file crash-safe CoW 4 KiB B+Tree with per-page SHA-256 checksums, typed `Modb.Table` secondary indexes, `Modb.Ledger` hash-chained audit, `Modb.Grants`, `Modb.Claims`, `Modb.World`, `Modb.Replay`, `Modb.Views`, plus `Modb.Fts` BM25 full-text search).
- **Web Framework:** [Arvo](https://github.com/robertguss/arvo) on MoDB (`Arvo.Oidc` OIDC/SSO-only authentication, `Arvo.S3` SigV4 presigned object storage, `Arvo.Mcp` Streamable HTTP server, `Arvo.Sse`, `Arvo.Webhooks`, `Arvo.Jobs`, `Arvo.Inertia`, `Arvo.WebTest`).
- **Frontend:** Inertia v2 + React 19 + TypeScript + Vite + Tailwind CSS v4 + shadcn/ui + TipTap (compiled to static fingerprinted assets served directly by `mo serve`).

---

## Documentation

- **[`docs/vellum-spec.md`](docs/vellum-spec.md)** — Complete v1 architecture and technical specification: data models, OIDC + Grants, canonical Block Tree / Markdown engine, Relational Databases (Table / Board / Calendar), Claims / Change Proposals / Selective Undo, SSE protocol, `Modb.Fts`, MCP + Webhooks + Built-in AI, S3 storage, and verification strategy.
- **[`docs/upstream-roadmap.md`](docs/upstream-roadmap.md)** — Concrete upstream PR roadmap across **`mo`**, **`modb`**, and **`arvo`**, verified against the current codebases, plus the staged Stage 0–4 delivery plan.
- **[`AGENTS.md`](AGENTS.md)** — Engineering rules and workflow for coding agents working in this repository.

---

## Sibling Repositories

- [`robertguss/mo`](https://github.com/robertguss/mo) — Programming language, compiler, bytecode VM, `api`/`mo serve` runtime
- [`robertguss/modb`](https://github.com/robertguss/modb) — Pure-Mo crash-safe CoW B+Tree multi-agent database
- [`robertguss/arvo`](https://github.com/robertguss/arvo) — Pure-Mo full-stack web framework

---

## License

[MIT](LICENSE)
