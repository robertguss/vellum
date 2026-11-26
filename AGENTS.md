# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Gemini, Cursor, and others) working in `vellum`.

## Documents in Order of Authority

1. [`docs/vellum-spec.md`](docs/vellum-spec.md) — Locked v1 architecture, Mo domain types, MoDB storage layout, invariants, and UX/API contracts.
2. [`docs/upstream-roadmap.md`](docs/upstream-roadmap.md) — Staged delivery plan (Stages 0–4) and upstream PR dependencies in `mo`, `modb`, and `arvo`.
3. Sibling repositories on disk:
   - Mo language, runtime & embedded docs: `/home/exedev/code/mo` (especially `docs/reference/README.md` and `docs/agent-guide.md`, or `mo guide --reference`)
   - MoDB storage & Layer 4 primitives: `/home/exedev/Projects/modb`
   - Arvo web framework: `/home/exedev/Projects/arvo`

## Non-Negotiable Architectural Rules

- **100% Pure MoDB Storage:** Vellum uses zero SQLite anywhere in the application or in its Arvo dependencies. All state—documents, blocks, database rows, dynamic indexes, FTS postings, OIDC sessions, background jobs, claims, grants, speculative proposals, and audit logs—lives in MoDB.
- **OIDC/SSO-Only Human Auth + Scoped Agent Tokens:** Mirroring Outline's deployment security model, Vellum stores zero local human passwords. Humans authenticate exclusively via OIDC/SSO (`Arvo.Oidc`); external agents authenticate via SHA-256-hashed, grant-bound capability tokens (`vlm_ag_...`) resolved through `Modb.Grants`.
- **S3-Compatible Object Storage Only:** Never store file attachments, images, or export archives inside MoDB pages or buffer large binaries through `mo serve`. Generate AWS SigV4 presigned URLs via `Arvo.S3` and store only attachment metadata, SHA-256 digests, and ACL refs in MoDB.
- **No Ambient Authority:** All side effects flow explicitly through Mo capabilities (`Files`, `ReadFiles`, `Network.allow_hosts`, `Clock`, `SecureRandom`) so the entire backend and `Arvo.WebTest` suite run deterministically with zero network sockets under `mo test`.
- **Mo Syntax Reminder:** `actor` is a reserved keyword in Mo—never name struct fields, enum fields, parameters, or query params `actor` (use `principal`, `actor_id`, or `author` instead). Use hyphen-case filenames (`block-tree.mo`, `db-views.mo`) for multi-word modules (`E0035`).

## Friction-Driven Upstream Discipline

Vellum is intentionally a **pressure test** for `mo`, `modb`, and `arvo`. Whenever you hit a compiler bug, VM/budget limit, missing stdlib primitive, MoDB scaling cliff, or Arvo gap:

1. Record the concrete reproduction, measured numbers, and module/file reference in `docs/friction.md` (mirroring `modb/FRICTION.md`).
2. Fix upstream gaps via clean, well-tested PRs in the owning repository (`mo`, `modb`, or `arvo`) rather than piling fragile workarounds into `vellum`.

## Verification Baseline

Every Mo module must carry `examples`, executable `promise` invariants where applicable, and deterministic `mo test` coverage (including `Arvo.WebTest` end-to-end route/auth/MCP/SSE tests), alongside `npx tsc --noEmit && npm run build` for `frontend/`.
