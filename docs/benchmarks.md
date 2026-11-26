# Vellum Scale, Concurrency & Search Benchmarks

Reproducible scale, multi-worker concurrency, and hot-path benchmarks for Vellum (`mo serve --workers 8`, 100% Pure MoDB storage with zero SQLite, synced 4 KiB CoW pages, `Modb.Ledger`, `Modb.Fts`, `Modb.Vec`, `Modb.Claims`, `Modb.World`, and live SSE fanout).

## Stack & Upstream Optimizations

Every "After" measurement below was recorded on:
- **`mo` (`0.3.0`) + [robertguss/mo#443](https://github.com/robertguss/mo/pull/443)**: adds `#![forbid(unsafe_code)]` Rust primitives `Bytes.dot_u16_be_biased` and `Bytes.dot_u8_biased` with fast `i64` inner loops, exact `i128` overflow fallback, Lean `MoCore` semantics and safety proofs.
- **`modb` (`v0.5.0`) + [robertguss/modb#8](https://github.com/robertguss/modb/pull/8)**: replaces per-character `wc.to_text.byte_count` allocation in `Modb.Fts.tokenize` with `utf8_code_bytes`, caches packed `q_bytes` in `Modb.Vec.PreparedQuery`, and executes `Cosine`/`DotProduct` integer inner products in `score_encoded_vector` using `Bytes.dot_u16_be_biased`/`Bytes.dot_u8_biased`.
- **`vellum`**:
  - [`domain/blocks.mo`](../domain/blocks.mo): adds O(N) `blocks_sorted?` fast-path to `sort_blocks`, O(N) ordered `insert_block_sorted` (preserving `(rank, id)` tie-break parity) for `InsertBlockAfter`/`MoveBlock`, and skips re-sorting on `ReplaceBlock`/`DeleteBlock`/`AttachCitations` in `apply_block_ops`.
  - [`db.mo`](../db.mo): converts `tx_save_page_and_blocks` to diff-only `Table.put` (skipping unchanged blocks), computes `Blocks.blocks_plain_text` once per `tx_index_page`, and bounds 256-d sketch embedding input via UTF-8-safe `truncate_text_bytes(..., 4096)`.

## Reproducible Commands

Pure-Mo/MoDB document hotpaths, corpus search scaling, and relational enrichment:

```bash
rm -rf /tmp/vellum-bench-hotpaths && mkdir -p /tmp/vellum-bench-hotpaths
mo run --root /tmp/vellum-bench-hotpaths bench/bench-vellum-hotpaths.mo
rm -rf /tmp/vellum-bench-hotpaths
```

8-worker live `mo serve` HTTP/MCP/Claims/World/SSE concurrency & large-document budget probe:

```bash
python3 bench/bench_vellum_live.py
```

Upstream `modb` 1,000-document search benchmark (from `/home/exedev/Projects/modb`):

```bash
rm -rf /tmp/modb-bench-search && mkdir -p /tmp/modb-bench-search
mo run --root /tmp/modb-bench-search bench/bench-search.mo 1000
rm -rf /tmp/modb-bench-search
```

---

## 1. Document Block Hotpaths & Single-Page Ledger Write

Measured via `bench/bench-vellum-hotpaths.mo`:

| Operation | Scale | Before | After | Speedup |
| --- | --- | --- | --- | --- |
| `parse_markdown_blocks` | 5 KiB (5,720 B, 120 blocks) | 2 ms | 2 ms | 1.00x |
| `to_anchored_markdown` | 5 KiB (120 blocks) | 4 ms | 0 ms | — |
| `blocks_plain_text` | 5 KiB (120 blocks) | 3 ms | 0 ms | — |
| `apply_block_ops` (2 ops) | 5 KiB (120 blocks) | 12 ms | 0 ms | — |
| `text_sketch_embedding` (256d, full doc) | 5 KiB (120 blocks) | 30 ms | 34 ms | 0.88x |
| `parse_markdown_blocks` | 50 KiB (53,893 B, 1,128 blocks) | 20 ms | 20 ms | 1.00x |
| `to_anchored_markdown` | 50 KiB (1,128 blocks) | 74 ms | 10 ms | **7.40x** |
| `blocks_plain_text` | 50 KiB (1,128 blocks) | 55 ms | 6 ms | **9.17x** |
| `apply_block_ops` (2 ops) | 50 KiB (1,128 blocks) | 190 ms | 4 ms | **47.50x** |
| `text_sketch_embedding` (256d, full doc) | 50 KiB (1,128 blocks) | 288 ms | 259 ms | 1.11x |
| `parse_markdown_blocks` | 200 KiB (215,519 B, 4,504 blocks) | 83 ms | 87 ms | 0.95x |
| `to_anchored_markdown` | 200 KiB (4,504 blocks) | 301 ms | 49 ms | **6.14x** |
| `blocks_plain_text` | 200 KiB (4,504 blocks) | 229 ms | 32 ms | **7.16x** |
| `apply_block_ops` (2 ops) | 200 KiB (4,504 blocks) | 671 ms | 27 ms | **24.85x** |
| `parse_markdown_blocks` | 500 KiB (539,178 B, 11,256 blocks) | 183 ms | 230 ms | 0.80x |
| `to_anchored_markdown` | 500 KiB (11,256 blocks) | 652 ms | 874 ms | 0.75x |
| `blocks_plain_text` | 500 KiB (11,256 blocks) | 643 ms | 738 ms | 0.87x |
| `apply_block_ops` (2 ops) | 500 KiB (11,256 blocks) | 1,907 ms | 641 ms | **2.98x** |
| Single-page synced Ledger write (`Fts` + `Sketch256` + `Neural256`, 20 tx) | 20 pages | 585 ms (29 ms/page) | 556 ms (27 ms/page) | 1.05x |

---

## 2. Corpus Search Scaling (100 / 250 / 500 Pages, Synced 4 KiB CoW Pages)

Measured via `bench/bench-vellum-hotpaths.mo`:

| Corpus | Metric | Before | After | Speedup |
| --- | --- | --- | --- | --- |
| **100 pages** (996 KiB DB) | Batch seed | 1,570 ms | 1,515 ms | 1.04x |
| 100 pages | BM25 (20x) `owner_unscoped` | 371 ms | 377 ms | 0.98x |
| 100 pages | BM25 (20x) `agent_1of10` | 248 ms | 226 ms | 1.10x |
| 100 pages | Hybrid Sketch256 (10x) `owner_unscoped` | 697 ms | 286 ms | **2.44x** |
| 100 pages | Hybrid Neural256 (10x) `owner_unscoped` | 756 ms | 336 ms | **2.25x** |
| 100 pages | Hybrid Neural256 (10x) `agent_scoped` | 197 ms | 173 ms | 1.14x |
| 100 pages | Hybrid Neural256 (10x) `semantic_only` | 611 ms | 182 ms | **3.36x** |
| **250 pages** (2,200 KiB DB) | Batch seed | 2,861 ms | 3,102 ms | 0.92x |
| 250 pages | BM25 (20x) `owner_unscoped` | 781 ms | 785 ms | 0.99x |
| 250 pages | BM25 (20x) `agent_1of10` | 534 ms | 592 ms | 0.90x |
| 250 pages | Hybrid Sketch256 (10x) `owner_unscoped` | 1,648 ms | 507 ms | **3.25x** |
| 250 pages | Hybrid Neural256 (10x) `owner_unscoped` | 1,679 ms | 666 ms | **2.52x** |
| 250 pages | Hybrid Neural256 (10x) `agent_scoped` | 448 ms | 351 ms | 1.28x |
| 250 pages | Hybrid Neural256 (10x) `semantic_only` | 1,446 ms | 331 ms | **4.37x** |
| **500 pages** (4,064 KiB DB) | Batch seed | 4,826 ms | 5,270 ms | 0.92x |
| 500 pages | BM25 (20x) `owner_unscoped` | 1,884 ms | 1,495 ms | 1.26x |
| 500 pages | BM25 (20x) `agent_1of10` | 1,173 ms | 1,153 ms | 1.02x |
| 500 pages | Hybrid Sketch256 (10x) `owner_unscoped` | 3,374 ms | 904 ms | **3.73x** |
| 500 pages | Hybrid Neural256 (10x) `owner_unscoped` | 3,351 ms | 1,168 ms | **2.87x** |
| 500 pages | Hybrid Neural256 (10x) `agent_scoped` | 761 ms | 476 ms | **1.60x** |
| 500 pages | Hybrid Neural256 (10x) `semantic_only` | 3,124 ms | 572 ms | **5.46x** |

---

## 3. Relational Database Enrichment & `Ledger.verify_all`

Measured via `bench/bench-vellum-hotpaths.mo`:

| Workload | Before | After |
| --- | --- | --- |
| Seed 200 Tasks + 25 Projects (8 relations/proj) | 4,441 ms | 4,561 ms |
| 20x secondary cell lookup | 123 ms | **91 ms** |
| Enrich 25x8 Relation -> Rollup `SumValues` (25 rows) | 62 ms | 68 ms |
| Filter + Sort + Board + Calendar (200 rows) | 75 ms | 81 ms |
| Full `Ledger.verify_all` (audit=48, invariants=5, pages=1,216) | 899 ms | 862 ms |

---

## 4. 8-Worker Live `mo serve` Concurrency & Large-Doc Request Budget

Measured via `python3 bench/bench_vellum_live.py` (`--workers 8`, local mock OIDC + `/v1/embeddings`):

### Phase A: 8-Thread Read Burst (400 requests across `GET /api/pages/:id`, BM25, Hybrid RRF, Semantic, `POST /api/databases/:id/query`)

| Metric | Before | After | Speedup |
| --- | --- | --- | --- |
| Aggregate throughput | 153.0 req/s (2.61s) | **213.3 req/s (1.88s)** | **1.39x** |
| Overall latency `p50 / p95 / p99 / max` | 44.2 / 96.4 / 147.9 / 150.0 ms | **34.0 / 52.4 / 116.6 / 148.4 ms** | **1.84x (p95)** |
| `page_get` (`n=80`, `p50 / p95 / max`) | 22.2 / 44.2 / 67.8 ms | 20.3 / 29.1 / 116.6 ms | 1.52x (p95) |
| `search_bm25` (`n=80`, `p50 / p95 / max`) | 40.8 / 86.5 / 102.4 ms | 36.2 / 49.2 / 120.8 ms | 1.76x (p95) |
| `search_hybrid` (`n=80`, `p50 / p95 / max`) | 60.7 / 116.8 / 150.0 ms | **35.4 / 56.9 / 148.4 ms** | **2.05x (p95)** |
| `search_semantic` (`n=80`, `p50 / p95 / max`) | 54.3 / 106.5 / 118.1 ms | **35.8 / 51.1 / 70.9 ms** | **2.08x (p95)** |
| `db_query` (`n=80`, `p50 / p95 / max`) | 48.6 / 103.0 / 149.9 ms | 40.0 / 59.2 / 116.3 ms | 1.74x (p95) |

### Phase B: Mixed 4R + 2W + 2 Live SSE Subscribers (`mo serve --workers 8`)

| Metric | Before | After | Speedup |
| --- | --- | --- | --- |
| Aggregate ops/s & errors | 69.2 req/s (356 ops in 5.14s, 0 err) | **96.9 req/s (434 ops in 4.48s, 0 err)** | **1.40x** |
| `http_reads` (`p50 / p95`) | `n=156`: 53.5 / 222.3 ms | `n=208`: 43.8 / 155.9 ms | 1.43x (p95) |
| `mcp_search` (`p50 / p95`) | `n=80`: 95.3 / 184.2 ms | `n=106`: **46.1 / 103.5 ms** | **2.07x (p50)** |
| `patch_blocks` (`n=20`, `p50 / p95`) | 100.8 / 217.7 ms | 89.1 / 192.5 ms | 1.13x |
| `claims_ops` (`n=60`, `p50 / p95`) | 49.9 / 130.3 ms | 47.2 / 94.1 ms | 1.38x (p95) |
| `proposal_e2e` (`n=10`, `p50 / p95`) | 410.4 / 752.1 ms | 386.7 / 451.3 ms | 1.67x (p95) |
| Live SSE fanout delivered (`col_0`, `col_1`) | 131 / 131 events | 131 / 131 events | 100% delivered |

### Phase C: Large-Document HTTP Request Budget Probe (`MO_LIMIT_API_REQUEST_WORK = 67,108,864`)

| Document Size | Before (`POST` / `GET` / `PATCH`) | After (`POST` / `GET` / `PATCH`) | Outcome |
| --- | --- | --- | --- |
| **5 KiB** (5,450 B, 126 blks) | 201 (198.1ms) / 200 (100.9ms) / 200 (333.2ms) | 201 (191.0ms) / 200 (76.8ms) / 200 (229.7ms) | Fast pass |
| **25 KiB** (27,034 B, 624 blks) | 201 (810.8ms) / 200 (561.5ms) / 200 (1918.9ms) | 201 (559.8ms) / 200 (319.6ms) / **200 (797.0ms)** | `PATCH` **2.41x** |
| **50 KiB** (53,917 B, 1,242 blks) | 201 (2443.3ms) / 200 (1005.3ms) / **500 (2500.6ms)** | **201 (1162.3ms) / 200 (703.0ms) / 200 (1445.6ms)** | **50 KiB `PATCH` 500 fixed** (`POST` 2.10x) |
| **100 KiB** (107,683 B) | POST 500 (3366.0ms) | POST 500 (2473.3ms) | Hits `MO_LIMIT_API_REQUEST_WORK` during bulk ingest |
| **200 KiB** (215,476 B) | POST 500 (4518.1ms) | POST 500 (4877.9ms) | Hits `MO_LIMIT_API_REQUEST_WORK` during bulk ingest |

> **Honest boundary note:** Diff-only block persistence, O(1) `ReplaceBlock`, and 4 KiB-bounded sketch indexing eliminated the 50 KiB (1,242-block) `PATCH` HTTP 500 under `MO_LIMIT_API_REQUEST_WORK`. Single-request `POST /api/pages` creation at >= 100 KiB (~2,480+ blocks inserted, serialized, and FTS-tokenized inside one request) still exceeds `MO_LIMIT_API_REQUEST_WORK`.

### Phase D: Post-Load Integrity & Audit

- **Before**: `/api/audit` `200` (22.1 ms); `Ledger.verify_all`: `audit=253 invariants=5 pages=578` (577 ms)
- **After**: `/api/audit` `200` (25.6 ms); `Ledger.verify_all`: `audit=255 invariants=5 pages=972` (1,178 ms)

---

## 5. Upstream `modb/bench/bench-search.mo 1000` Summary

Comparing `modb/BENCHMARKS.md` Milestone 11B baseline against [robertguss/modb#8](https://github.com/robertguss/modb/pull/8) + [robertguss/mo#443](https://github.com/robertguss/mo/pull/443):

| Benchmark (`1,000` docs, synced 4 KiB pages) | Before (M11B) | After (`modb#8` + `mo#443`) | Speedup |
| --- | --- | --- | --- |
| `Fts` index 1,000 docs (10 scopes, 529 pages) | 8,529 ms | **5,382 ms** | 1.58x |
| `Fts` 50x queries (`exact_1term` / `multi_2term` / `prefix`) | 6,462 / 11,551 / 6,213 ms | **3,060 / 5,887 / 3,376 ms** | 2.11x / 1.96x / 1.84x |
| `Vec 64d_Q16`: `put(1000)` / `20x full_cos` / `20x scoped` | 2,188 / 4,374 / 451 ms | **1,407 / 2,110 / 197 ms** | 1.55x / 2.07x / 2.29x |
| `Vec 384d_Q16`: `put(1000)` / `20x scoped_cos` (`20x full = 2,152 ms`) | 6,071 / 1,607 ms | **5,086 / 355 ms** | 1.19x / **4.53x** |
| `Vec 384d_Q8`: `put(1000)` / `20x scoped_cos` (`20x full = 2,301 ms`) | 4,719 / 1,834 ms | **4,130 / 255 ms** | 1.14x / **7.19x** |
| `Hybrid BM25+64d RRF (20x)`: `full` / `scoped(1/10)` | 9,171 / 3,468 ms | **4,516 / 1,951 ms** | **2.03x / 1.78x** |
