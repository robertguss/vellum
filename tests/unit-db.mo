## Unit tests extracted from `Db` to keep `main.mo` and integration test suites under the Mo lowering budget.
module Tests.UnitDb
use Db{
  ai_cell_meta_table,
  blocks_table,
  blueprints_table,
  collections_table,
  databases_table,
  default_collection_id,
  default_workspace_id,
  enrich_rows_with_rollups,
  ensure_ai_col_feed_locked,
  ledger_db_path,
  load_page_blocks,
  lookup_row_ids_by_cell,
  map_ledger_error,
  map_table_error,
  map_vec_error,
  neural_vec_index,
  neural_vec_populated,
  packs_table,
  page_meta_table,
  page_summary_key,
  pages_table,
  rlm_view_catalog,
  search_pages,
  search_pages_hybrid,
  sketch_min_vec_score,
  sketch_vec_dims,
  sketch_vec_index,
  summaries_table,
  sync_ai_col_feed_locked,
  truncate_text_bytes,
  tx_delete_page_and_blocks,
  tx_mint_agent,
  tx_put_db_row,
  tx_put_page_neural_vector,
  tx_save_page_and_blocks,
  tx_upsert_human_principal,
  vellum_schema
}
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta}
use Domain.DatabaseModel{
  AiCellMeta,
  AiColumnMode,
  AiOutputKind,
  CellValue,
  DatabaseDef,
  DbRow,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor
}
use Domain.Packs{ContextPack}
use Domain.Policy
use Domain.TaintBridge
use Domain.Types{
  AppError,
  AuthContext,
  AuthorKind,
  Block,
  BlockKind,
  Collection,
  CollectionWritePolicy,
  Page,
  PageKind,
  Principal,
  PrincipalKind,
  Provenance,
  WorkspaceRole
}
use Json
use Modb
use Modb.Ledger
use Modb.Table
use Modb.Vec
use Modb.Views

test "Db schema, JIT OIDC human provisioning, page/block FTS indexing, and agent minting"
  files = Files.in_memory({})
  rng = SecureRandom.seeded(100)
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(
    principal: "system:test",
    action: "test.init",
    reason: "verify Db module",
    at: t0
  )

  (raw_tok, pref, thash) = Policy.mint_agent_token_raw(rng)
  assert raw_tok.starts_with?("vlm_ag_")

  res = Ledger.transact_locked(
    files,
    ledger_db_path,
    vellum_schema(),
    meta,
    "provision owner and agent",
    Json.Object({"test": Json.Boolean(true)}),
    map_ledger_error,
    fn(tx)
      (t1, owner) = try tx_upsert_human_principal(
        tx,
        "ada@acme.io",
        "Ada Lovelace",
        None,
        "usr_ada",
        "gr_ada",
        t0
      )
      if owner.role != Owner
        return Error(ServerFailed(reason: "first user should be Owner"))
      end
      (t2, member) = try tx_upsert_human_principal(
        t1,
        "grace@acme.io",
        "Grace Hopper",
        None,
        "usr_grace",
        "gr_grace",
        t0
      )
      if member.role != Member
        return Error(ServerFailed(reason: "second user should be Member"))
      end

      (t3, _agt, _gr, _tok) = try tx_mint_agent(
        t2,
        owner.id,
        "gardener",
        "Docs Gardener",
        Some("claude-sonnet-4-6"),
        "CI token",
        ["read", "write_direct"],
        Some([default_collection_id]),
        100,
        t0 + 7.days,
        "agt_1",
        "gr_agt_1",
        "tok_1",
        pref,
        thash,
        t0
      )
      Ok((t3, Unit))
    end
  )
  assert res is Ok(Unit)
end

test "Db relational database composite cell indexes, rollup enrichment, and Ledger invariants"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  schema = vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "db.test",
    reason: "verify database invariants and composite indexes",
    at: t0
  )

  tasks_def = DatabaseDef(
    id: "db_tasks",
    collection_id: default_collection_id,
    page_id: "pg_db_tasks",
    title: "Tasks",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "points",
        name: "Points",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "b"
      )
    ],
    version: 1
  )
  proj_def = DatabaseDef(
    id: "db_proj",
    collection_id: default_collection_id,
    page_id: "pg_db_proj",
    title: "Projects",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(
          options: [
            SelectOption(id: "active", label: "Active", color: Green),
            SelectOption(id: "paused", label: "Paused", color: Gray)
          ]
        ),
        required: true,
        sort_order: "b"
      ),
      PropertyDef(
        id: "tasks",
        name: "Tasks",
        kind: Relation(target_db_id: "db_tasks", inverse_prop_id: None),
        required: false,
        sort_order: "c"
      ),
      PropertyDef(
        id: "total_pts",
        name: "Total Pts",
        kind: Rollup(relation_prop_id: "tasks", target_prop_id: "points", agg: SumValues),
        required: false,
        sort_order: "d"
      )
    ],
    version: 1
  )

  p_host_t = Page(
    id: "pg_db_tasks",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Tasks",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: Some("db_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  p_host_p = Page(
    id: "pg_db_proj",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Projects",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "b",
    database_id: Some("db_proj"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  d1 = "0.1".to_decimal or stop "d1"
  d2 = "0.2".to_decimal or stop "d2"
  d3 = "0.3".to_decimal or stop "d3"

  task1_pg = Page(
    id: "pg_t1",
    collection_id: default_collection_id,
    parent_page_id: Some("pg_db_tasks"),
    title: "Task One",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: "db_tasks", row_id: "row_t1"),
    sort_order: "row_t1",
    database_id: Some("db_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  task2_pg = Page(
    id: "pg_t2",
    collection_id: default_collection_id,
    parent_page_id: Some("pg_db_tasks"),
    title: "Task Two",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: "db_tasks", row_id: "row_t2"),
    sort_order: "row_t2",
    database_id: Some("db_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  proj1_pg = Page(
    id: "pg_p1",
    collection_id: default_collection_id,
    parent_page_id: Some("pg_db_proj"),
    title: "Launch Vellum",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: "db_proj", row_id: "row_p1"),
    sort_order: "row_p1",
    database_id: Some("db_proj"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  task1 = DbRow(
    id: "row_t1",
    database_id: "db_tasks",
    page_id: "pg_t1",
    cells: {"title": TextVal("Task One"), "points": NumberVal(d1)},
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  task2 = DbRow(
    id: "row_t2",
    database_id: "db_tasks",
    page_id: "pg_t2",
    cells: {"title": TextVal("Task Two"), "points": NumberVal(d2)},
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  proj1 = DbRow(
    id: "row_p1",
    database_id: "db_proj",
    page_id: "pg_p1",
    cells: {
      "title": TextVal("Launch Vellum"),
      "status": SelectVal(option_id: "active"),
      "tasks": RelationVal(row_ids: ["row_t1", "row_t2"])
    },
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  seed_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed related databases and rows",
    Json.Object({"seed": Json.Boolean(true)}),
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, pages_table(), p_host_t.id, p_host_t).map_error(map_table_error)
      t2 = try Table.put(t1, pages_table(), p_host_p.id, p_host_p).map_error(map_table_error)
      t3 = try Table.put(t2, databases_table(), tasks_def.id, tasks_def).map_error(map_table_error)
      t4 = try Table.put(t3, databases_table(), proj_def.id, proj_def).map_error(map_table_error)
      t5 = try tx_put_db_row(t4, tasks_def, task1, task1_pg, [])
      t6 = try tx_put_db_row(t5, tasks_def, task2, task2_pg, [])
      t7 = try tx_put_db_row(t6, proj_def, proj1, proj1_pg, [])
      Ok((t7, Unit))
    end
  )
  assert seed_res is Ok(Unit)

  ## Composite vlm_db_cells lookup + exact Decimal rollup + Ledger verify_all (5 invariants)
  check_res = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      by_status = try lookup_row_ids_by_cell(store, "db_proj", "status", "active")
      return Error(BadInput(reason: "expected row_p1")) if by_status != ["row_p1"]
      by_rel = try lookup_row_ids_by_cell(store, "db_proj", "tasks", "row_t2")
      return Error(BadInput(reason: "expected reverse relation")) if by_rel != ["row_p1"]

      enriched = try enrich_rows_with_rollups(store, proj_def, [proj1])
      first_e = try enriched.first.or_fail(BadInput(reason: "missing enriched"))
      if first_e.rollups.get("total_pts") != Some(NumberVal(d3))
        return Error(BadInput(reason: "rollup decimal mismatch"))
      end

      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      return Error(BadInput(reason: "expected 9 invariants")) if rep.invariants_checked != 9
      Ok(Unit)
    end
  )
  assert check_res is Ok(Unit)

  ## Commit-time invariant rejects dangling relation target
  bad_rel_proj = DbRow(
    id: "row_p1",
    database_id: "db_proj",
    page_id: "pg_p1",
    cells: {
      "title": TextVal("Launch Vellum"),
      "status": SelectVal(option_id: "active"),
      "tasks": RelationVal(row_ids: ["row_nonexistent"])
    },
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 2
  )
  bad_rel_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "attempt dangling relation",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_put_db_row(tx, proj_def, bad_rel_proj, proj1_pg, [])
      Ok((t1, Unit))
    end
  )
  assert bad_rel_res is Error(BadInput(reason: _))
end

test "Db Modb.Vec hybrid RRF search, neural vector updates/dimension switches, archive cleanup, and fail-closed grants"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  schema = vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "db.vec_test",
    reason: "verify Modb.Vec hybrid RRF and fail-closed grant filtering",
    at: t0
  )

  sec_col = Collection(
    id: "col_secret",
    workspace_id: default_workspace_id,
    slug: "secret-exec",
    name: "Secret Executive",
    description: "",
    icon: None,
    write_policy: DirectWithAudit,
    freshness_ttl_days: None,
    sort_order: "z",
    archived_at: None
  )
  pg_pub = Page(
    id: "pg_pub_deploy",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Gateway Rollout Checklist",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  pg_other = Page(
    id: "pg_pub_lunch",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Catering Menu Notes",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "b",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  pg_sec = Page(
    id: "pg_sec_vault",
    collection_id: "col_secret",
    parent_page_id: None,
    title: "Executive Master Password",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "c",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  seed = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed hybrid vector test pages",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, collections_table(), sec_col.id, sec_col).map_error(map_table_error)
      t2 = try tx_save_page_and_blocks(t1, pg_pub, [])
      t3 = try tx_save_page_and_blocks(t2, pg_other, [])
      t4 = try tx_save_page_and_blocks(t3, pg_sec, [])
      # Attach 4-d neural embeddings where BOTH pg_pub and pg_sec match query [1,0,0,0] identically
      t5 = try tx_put_page_neural_vector(t4, pg_pub.id, pg_pub.collection_id, 4, [1.0, 0.0, 0.0, 0.0])
      t6 = try tx_put_page_neural_vector(
        t5,
        pg_other.id,
        pg_other.collection_id,
        4,
        [0.0, 1.0, 0.0, 0.0]
      )
      t7 = try tx_put_page_neural_vector(t6, pg_sec.id, pg_sec.collection_id, 4, [1.0, 0.0, 0.0, 0.0])
      Ok((t7, Unit))
    end
  )
  assert seed is Ok(Unit)

  owner_auth = AuthContext(
    principal: Principal(
      id: "usr_ada",
      kind: Human,
      handle: "@ada",
      display_name: "Ada",
      email: Some("ada@acme.io"),
      avatar_url: None,
      role: Owner,
      model_id: None,
      root_grant_id: "gr_ada",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_ada",
    session: None,
    allowed_collections: None,
    allowed_actions: ["read", "write_direct"]
  )
  scoped_auth = AuthContext(
    principal: Principal(
      id: "agt_1",
      kind: Agent,
      handle: "@agent1",
      display_name: "Scoped Agent",
      email: None,
      avatar_url: None,
      role: Member,
      model_id: Some("gpt-4o-mini"),
      root_grant_id: "gr_agt_1",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_agt_1",
    session: None,
    allowed_collections: Some(["collection:#{default_collection_id}"]),
    allowed_actions: ["read"]
  )

  verify = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      has_n = try neural_vec_populated(store, 4)
      return Error(BadInput(reason: "expected neural docs")) if not has_n

      # Zero lexical overlap query ("zero_overlap_concept"): BM25 finds nothing, Semantic + Hybrid find both permitted & secret for Owner
      owner_sem = try search_pages_hybrid(
        store,
        owner_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "semantic",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "owner should see 2 semantic hits")) if owner_sem.size != 2

      # Scoped agent MUST NOT see pg_sec_vault even though its cosine similarity is 1.0
      ag_sem = try search_pages_hybrid(
        store,
        scoped_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "semantic",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "agent leaked secret semantic hit")) if ag_sem.map(fn(h)
        h.page_id
      end) != [pg_pub.id]

      ag_hyb = try search_pages_hybrid(
        store,
        scoped_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "hybrid",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "agent hybrid mismatch")) if ag_hyb.map(fn(h) h.page_id end) != [
        pg_pub.id
      ]

      ag_bm25 = try search_pages_hybrid(
        store,
        scoped_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "bm25",
        10,
        true,
        None,
        None
      )
      return Error(BadInput(reason: "expected 0 bm25 hits")) if not ag_bm25.empty?

      # Hybrid RRF merges BM25 + Vector: query matches pg_other by keyword AND pg_pub by vector
      rrf_hits = try search_pages_hybrid(
        store,
        scoped_auth,
        "Catering",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "hybrid",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "expected both BM25 & Vec hits in RRF")) if rrf_hits.size != 2

      # Sketch fallback index works with zero external embedding call
      sk_hits = try search_pages_hybrid(
        store,
        scoped_auth,
        "Gateway Rollout",
        Some(Vec.text_sketch_embedding("Gateway Rollout", sketch_vec_dims)),
        sketch_vec_index(),
        "hybrid",
        10,
        true,
        None,
        Some(sketch_min_vec_score)
      )
      first_sk = try sk_hits.first.or_fail(BadInput(reason: "missing sketch hit"))
      if first_sk.page_id != pg_pub.id or first_sk.fts_rank != Some(1) or first_sk.vec_rank != Some(1)
        return Error(BadInput(reason: "expected dual fts_rank+vec_rank on Gateway Rollout"))
      end
      Ok(Unit)
    end
  )
  assert verify is Ok(Unit)

  # Archiving pg_pub removes both sketch and neural vectors; switching pg_other to 8-d cleans up old 4-d slot
  archived_pub = Page(
    id: pg_pub.id,
    collection_id: pg_pub.collection_id,
    parent_page_id: None,
    title: pg_pub.title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: Some(t0),
    version: 2
  )
  cleanup_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "archive page and switch neural dim",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_save_page_and_blocks(tx, archived_pub, [])
      t2 = try tx_put_page_neural_vector(
        t1,
        pg_other.id,
        pg_other.collection_id,
        8,
        [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
      )
      Ok((t2, Unit))
    end
  )
  assert cleanup_res is Ok(Unit)

  verify_after = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pub_doc = try Vec.get_doc(store, neural_vec_index(4), pg_pub.id).map_error(map_vec_error)
      return Error(BadInput(reason: "expected archived pub neural vec gone")) if pub_doc != None
      old_other = try Vec.get_doc(store, neural_vec_index(4), pg_other.id).map_error(map_vec_error)
      return Error(BadInput(reason: "expected old 4d vector removed on 8d reindex")) if old_other !=
        None
      new_other = try Vec.get_doc(store, neural_vec_index(8), pg_other.id).map_error(map_vec_error)
      return Error(BadInput(reason: "expected 8d vector present")) if new_other == None
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      return Error(BadInput(reason: "expected 9 invariants")) if rep.invariants_checked != 9
      Ok(Unit)
    end
  )
  assert verify_after is Ok(Unit)
end

test "truncate_text_bytes, diff-only tx_save_page_and_blocks, and large-doc sketch search"
  assert truncate_text_bytes("hello", 0) == ""
  assert truncate_text_bytes("hello", 5) == "hello"
  assert truncate_text_bytes("hello 😀 world", 9) == "hello "
  assert truncate_text_bytes("hello 😀 world", 10) == "hello 😀"

  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  t1_time = Time.parse("2026-11-26T12:01:00Z") or stop "t1"
  schema = vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "db.diff_test",
    reason: "verify diff-only block puts and truncated sketch indexing",
    at: t0
  )
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: t0
  )
  large_tail = " filler word".repeat(500)
  pg = Page(
    id: "pg_diff",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Kernel Runbook",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  b1 = Block(
    id: "blk_d1",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0001",
    kind: Paragraph,
    markdown: "Unchanged quantum telemetry lead paragraph.#{large_tail}",
    provenance: prov,
    version: 1
  )
  b2 = Block(
    id: "blk_d2",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0002",
    kind: Paragraph,
    markdown: "Original second paragraph.",
    provenance: prov,
    version: 1
  )
  b3 = Block(
    id: "blk_d3",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0003",
    kind: Paragraph,
    markdown: "Deleted third paragraph.",
    provenance: prov,
    version: 1
  )

  seed = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed diff test",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t_next = try tx_save_page_and_blocks(tx, pg, [b1, b2, b3])
      Ok((t_next, Unit))
    end
  )
  assert seed is Ok(Unit)

  pg_v2 = Page(
    id: pg.id,
    collection_id: pg.collection_id,
    parent_page_id: None,
    title: pg.title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t1_time,
    archived_at: None,
    version: 2
  )
  b2_v2 = Block(
    id: "blk_d2",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0002",
    kind: Paragraph,
    markdown: "Edited second paragraph.",
    provenance: prov,
    version: 2
  )
  b4 = Block(
    id: "blk_d4",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0004",
    kind: Paragraph,
    markdown: "Inserted fourth paragraph.",
    provenance: prov,
    version: 1
  )

  diff_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "diff update",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t_next = try tx_save_page_and_blocks(tx, pg_v2, [b1, b2_v2, b4])
      puts_cnt = Modb.tx_touched_puts(t_next, blocks_table().bucket).size
      Ok((t_next, puts_cnt))
    end
  )
  assert diff_res == Ok(2)

  verify = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      loaded = try load_page_blocks(store, pg.id)
      return Error(BadInput(reason: "expected 3 blocks after diff update")) if loaded != [
        b1,
        b2_v2,
        b4
      ]
      auth = AuthContext(
        principal: Principal(
          id: "usr_ada",
          kind: Human,
          handle: "ada",
          display_name: "Ada",
          email: Some("ada@example.com"),
          avatar_url: None,
          role: Owner,
          model_id: None,
          root_grant_id: "gr_root",
          suspended: false,
          created_at: t0,
          last_seen_at: None
        ),
        grant_id: "gr_root",
        session: None,
        allowed_collections: None,
        allowed_actions: ["read"]
      )
      q_txt = "Kernel Runbook quantum telemetry"
      hits = try search_pages_hybrid(
        store,
        auth,
        q_txt,
        Some(Vec.text_sketch_embedding(q_txt, sketch_vec_dims)),
        sketch_vec_index(),
        "hybrid",
        10,
        true,
        None,
        Some(sketch_min_vec_score)
      )
      first_h = try hits.first.or_fail(BadInput(reason: "expected sketch hit on >5KiB doc"))
      return Error(BadInput(reason: "wrong doc hit")) if first_h.page_id != pg.id
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      return Error(BadInput(reason: "expected invariants")) if rep.invariants_checked < 5
      Ok(Unit)
    end
  )
  assert verify is Ok(Unit)
end

test "blueprints and page_meta integrity, FTS indexing, and delete cleanup"
  files = Files.in_memory({})
  schema = vellum_schema()
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "usr_ada", action: "test.bp", reason: "bp test", at: t0)
  bp = BlueprintDef(
    id: "bp_rfc",
    slug: "architecture-rfc",
    name: "Architecture RFC",
    description: "Proposal template",
    icon: Some("file-text"),
    fields: [
      PropertyDef(
        id: "tier",
        name: "Tier",
        kind: Select(options: [SelectOption(id: "t1", label: "CriticalTier", color: Red)]),
        required: true,
        sort_order: "a"
      )
    ],
    default_template_markdown: "## Summary",
    version: 1
  )
  pg = Page(
    id: "pg_rfc1",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Storage Engine",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "i",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  pm = PageBlueprintMeta(
    page_id: pg.id,
    blueprint_id: bp.id,
    values: {"tier": SelectVal(option_id: "t1")},
    updated_at: t0
  )

  ins_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "save bp and page meta",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, blueprints_table(), bp.id, bp).map_error(map_table_error)
      t2 = try Table.put(t1, pages_table(), pg.id, pg).map_error(map_table_error)
      t3 = try Table.put(t2, page_meta_table(), pm.page_id, pm).map_error(map_table_error)
      t4 = try tx_save_page_and_blocks(t3, pg, [])
      Ok((t4, Unit))
    end
  )
  assert ins_res is Ok(Unit)

  # FTS matches structured metadata label "CriticalTier"
  auth = AuthContext(
    principal: Principal(
      id: "usr_ada",
      kind: Human,
      handle: "ada",
      display_name: "Ada",
      email: Some("ada@example.com"),
      avatar_url: None,
      role: Owner,
      model_id: None,
      root_grant_id: "gr_root",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_root",
    session: None,
    allowed_collections: None,
    allowed_actions: ["read"]
  )
  fts_res = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      search_pages(store, auth, "CriticalTier", 10, false, None)
    end
  )
  assert fts_res.map(fn(hs) hs.map(fn(h) h.page_id end) end) == Ok([pg.id])

  # Deleting page removes page_meta automatically inside transaction
  del_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "delete page cleans meta",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_delete_page_and_blocks(tx, pg.id)
      rem = try Table.tx_get(t1, page_meta_table(), pg.id).map_error(map_table_error)
      Ok((t1, rem))
    end
  )
  assert del_res == Ok(None)
end

test "living summaries auto-persist on page/db writes, clean up on delete, and enforce pack_valid invariant"
  files = Files.in_memory({})
  schema = vellum_schema()
  t0 = Time.parse("2026-11-27T10:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "usr_ada", action: "test.packs", reason: "pack test", at: t0)
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: t0
  )
  pg = Page(
    id: "pg_ls1",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Release Checklist",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  blk = Block(
    id: "blk_ls1",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0001",
    kind: Heading(level: 2),
    markdown: "Rollback Plan",
    provenance: prov,
    version: 1
  )
  pk = ContextPack(
    id: "pk_ls1",
    slug: "release-pack",
    name: "Release Pack",
    description: "Essential release context",
    collection_ids: [default_collection_id],
    pinned_page_ids: [pg.id],
    database_ids: [],
    query_hint: None,
    fresh_only: false,
    include_full_blocks: true,
    token_budget: 2048,
    created_by: "usr_ada",
    updated_at: t0,
    version: 1
  )

  w_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "save page and context pack",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_save_page_and_blocks(tx, pg, [blk])
      t2 = try Table.put(t1, packs_table(), pk.id, pk).map_error(map_table_error)
      Ok((t2, Unit))
    end
  )
  assert w_res is Ok(Unit)

  chk_res = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      s_opt = try Table.get(store, summaries_table(), page_summary_key(pg.id)).map_error(
        map_table_error
      )
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      Ok((s_opt, rep.invariants_checked))
    end
  )
  case chk_res
    Ok((Some(s), inv_cnt)):
      assert s.title == "Release Checklist"
      assert s.headings == ["Rollback Plan"]
      assert inv_cnt == 9
    Ok((None, _)) | Error(_): assert false
  end

  del_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "delete page removes living summary",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_delete_page_and_blocks(tx, pg.id)
      s_rem = try Table.tx_get(t1, summaries_table(), page_summary_key(pg.id)).map_error(
        map_table_error
      )
      Ok((t1, s_rem))
    end
  )
  assert del_res == Ok(None)
end

test "AiDerived Modb.Feeds O(diff) staleness detection, World PutAiCellMeta landing, and 9 invariants"
  files = Files.in_memory({})
  schema = vellum_schema()
  t0 = Time.parse("2026-12-01T10:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "usr_ada", action: "test.ai_cols", reason: "seed ai db", at: t0)
  opt_low = SelectOption(id: "low", label: "Low", color: Green)
  opt_high = SelectOption(id: "high", label: "High", color: Red)
  ai_prop = PropertyDef(
    id: "tier",
    name: "Tier",
    kind: AiDerived(
      prompt: "Classify tier",
      source_prop_ids: ["title"],
      include_row_body: false,
      output_kind: AiSelect(options: [opt_low, opt_high]),
      mode: StageProposal,
      daily_call_cap: 10
    ),
    required: false,
    sort_order: "b"
  )
  def = DatabaseDef(
    id: "db_feed1",
    collection_id: default_collection_id,
    page_id: "pg_db_feed1",
    title: "Alerts",
    description: "Feed staleness test",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      ai_prop
    ],
    version: 1
  )
  row1 = DbRow(
    id: "row_f1",
    database_id: def.id,
    page_id: "pg_rf1",
    cells: {"title": TextVal("Minor latency"), "tier": SelectVal(option_id: "low")},
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  row_pg = Page(
    id: "pg_rf1",
    collection_id: default_collection_id,
    parent_page_id: Some(def.page_id),
    title: "Minor latency",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: def.id, row_id: row1.id),
    sort_order: row1.id,
    database_id: Some(def.id),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  host_pg = Page(
    id: def.page_id,
    collection_id: default_collection_id,
    parent_page_id: None,
    title: def.title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: Some(def.id),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  m1 = AiCellMeta(
    id: DatabaseModel.ai_cell_meta_key(def.id, row1.id, ai_prop.id),
    database_id: def.id,
    row_id: row1.id,
    prop_id: ai_prop.id,
    model: "gpt-4o-mini",
    prompt_hash: DatabaseModel.compute_ai_prompt_hash("Classify tier", AiSelect(options: [opt_low, opt_high])),
    input_hash: DatabaseModel.compute_ai_input_hash(def, ai_prop, row1, ""),
    stale: false,
    rationale: Some("Initial low latency"),
    citations: [],
    proposal_id: None,
    computed_at: t0
  )

  w0 = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed db and ai meta",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, pages_table(), host_pg.id, host_pg).map_error(map_table_error)
      t2 = try Table.put(t1, databases_table(), def.id, def).map_error(map_table_error)
      t3 = try tx_put_db_row(t2, def, row1, row_pg, [])
      t4 = try Table.put(t3, ai_cell_meta_table(), m1.id, m1).map_error(map_table_error)
      Ok((t4, Unit))
    end
  )
  assert w0 is Ok(Unit)

  assert ensure_ai_col_feed_locked(files, def.id, t0) is Ok(Unit)
  idle_sync = sync_ai_col_feed_locked(files, def.id, t0)
  case idle_sync
    Ok(s):
      assert s.events_seen == 0
      assert s.marked_stale_count == 0
    Error(_): assert false
  end

  # Mutate source title -> Modb.Feeds O(diff) detects delta and marks m1 stale!
  row1_v2 = DbRow(
    id: row1.id,
    database_id: def.id,
    page_id: row1.page_id,
    cells: {"title": TextVal("Critical DB Outage"), "tier": SelectVal(option_id: "low")},
    created_by: row1.created_by,
    created_at: row1.created_at,
    updated_at: t0 + 10.seconds,
    archived_at: None,
    version: 2
  )
  pg_v2 = Page(
    id: row_pg.id,
    collection_id: row_pg.collection_id,
    parent_page_id: row_pg.parent_page_id,
    title: "Critical DB Outage",
    icon: None,
    cover_attachment_id: None,
    kind: row_pg.kind,
    sort_order: row_pg.sort_order,
    database_id: row_pg.database_id,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: row_pg.created_by,
    created_at: row_pg.created_at,
    updated_at: t0 + 10.seconds,
    archived_at: None,
    version: 2
  )
  w1 = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "mutate source cell",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_put_db_row(tx, def, row1_v2, pg_v2, [])
      Ok((t1, Unit))
    end
  )
  assert w1 is Ok(Unit)

  dirty_sync = sync_ai_col_feed_locked(files, def.id, t0 + 15.seconds)
  case dirty_sync
    Ok(s):
      assert s.events_seen >= 1
      assert s.marked_stale_count == 1
    Error(_): assert false
  end

  chk = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      got_m = try Table.get(store, ai_cell_meta_table(), m1.id).map_error(map_table_error)
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      Ok((got_m.map(fn(x) x.stale end), rep.invariants_checked))
    end
  )
  assert chk == Ok((Some(true), 9))
end

test "RLM Tier 1 Modb.Views catalog enforces grant ViewDenied isolation, TaintSession tracking, and ReadLimits budget"
  files = Files.in_memory({})
  rng = SecureRandom.seeded(919)
  schema = vellum_schema()
  t0 = Time.parse("2026-12-01T12:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "@ada", action: "test.rlm_views", reason: "seed rlm views", at: t0)
  (_raw, pref, thash) = Policy.mint_agent_token_raw(rng)
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: Some("seed rlm"),
    citations: [],
    updated_at: t0
  )

  col_sec = Collection(
    id: "col_sec",
    workspace_id: default_workspace_id,
    slug: "secret-ops",
    name: "Secret Ops",
    description: "Restricted",
    icon: None,
    write_policy: DirectWithAudit,
    freshness_ttl_days: None,
    sort_order: "z",
    archived_at: None
  )
  pg_pub = Page(
    id: "pg_pub",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Gateway Runbook",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: Some(t0),
    verified_by: Some("usr_ada"),
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  b1 = Block(
    id: "blk_r1",
    page_id: pg_pub.id,
    parent_block_id: None,
    rank: "a",
    kind: Heading(level: 2),
    markdown: "Rollback Procedure",
    provenance: prov,
    version: 1
  )
  b2 = Block(
    id: "blk_r2",
    page_id: pg_pub.id,
    parent_block_id: None,
    rank: "b",
    kind: CodeBlock(language: "bash"),
    markdown: "vellum rollback --quorum",
    provenance: prov,
    version: 1
  )
  pg_sec = Page(
    id: "pg_sec",
    collection_id: col_sec.id,
    parent_page_id: None,
    title: "Vault Custody",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  b_sec = Block(
    id: "blk_sec",
    page_id: pg_sec.id,
    parent_block_id: None,
    rank: "a",
    kind: Paragraph,
    markdown: "Top secret vault master phrase.",
    provenance: prov,
    version: 1
  )

  seed = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed rlm views test",
    Json.Null,
    map_ledger_error,
    fn(tx)
      (t1, owner) = try tx_upsert_human_principal(
        tx,
        "ada@acme.io",
        "Ada",
        None,
        "usr_ada",
        "gr_ada",
        t0
      )
      t2 = try Table.put(t1, collections_table(), col_sec.id, col_sec).map_error(map_table_error)
      t3 = try tx_save_page_and_blocks(t2, pg_pub, [b1, b2])
      t4 = try tx_save_page_and_blocks(t3, pg_sec, [b_sec])
      (t5, _ag, gr, _tok) = try tx_mint_agent(
        t4,
        owner.id,
        "@rlm_scoped",
        "RLM Scoped",
        Some("gpt-4o-mini"),
        "rlm",
        ["read"],
        Some([default_collection_id]),
        20,
        t0 + 7.days,
        "agt_rlm",
        "gr_rlm",
        "tok_rlm",
        pref,
        thash,
        t0
      )
      Ok((t5, gr.id))
    end
  )
  ag_gid = case seed
    Ok(g): g
    Error(_): stop "seed failed"
  end

  cat = rlm_view_catalog([default_collection_id, col_sec.id])
  limits = Views.ReadLimits(max_rows_scanned: 50, max_ops: 2000, max_result_rows: 50)

  # 1. Scoped agent succeeds on authorized collection via TaintBridge
  sess_ag = case TaintBridge.ensure_taint_session_locked(
    files,
    ledger_db_path,
    schema,
    "rlm:ag_test",
    "agt_rlm",
    Some(ag_gid),
    t0
  )
    Ok(s): s
    Error(_): stop "sess_ag failed"
  end
  assert not sess_ag.untrusted_tainted

  ok_sum = case TaintBridge.run_tainted_read_program_locked(
    files,
    ledger_db_path,
    schema,
    cat,
    sess_ag.id,
    Views.ReadProgram(
      view: "rlm_summaries:#{default_collection_id}",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(20)
    ),
    false,
    limits,
    t0
  )
    Ok(r): r
    Error(_): stop "ok_sum failed"
  end
  assert ok_sum.governed.result.result_count == 1
  assert not ok_sum.governed.result.answer_hash.trim.empty?

  # 2. Scoped agent fails closed (Forbidden / ViewDenied) on restricted collection
  denied = TaintBridge.run_tainted_read_program_locked(
    files,
    ledger_db_path,
    schema,
    cat,
    sess_ag.id,
    Views.ReadProgram(
      view: "rlm_blocks:#{col_sec.id}",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(20)
    ),
    false,
    limits,
    t0
  )
  assert denied is Error(Forbidden(reason: _))

  # 3. Workspace-wide human session (None, is_admin=true) reads col_sec cleanly
  sess_hum = case TaintBridge.ensure_taint_session_locked(
    files,
    ledger_db_path,
    schema,
    "rlm:hum_test",
    "usr_ada",
    None,
    t0
  )
    Ok(s): s
    Error(_): stop "sess_hum failed"
  end
  ok_hum = case TaintBridge.run_tainted_read_program_locked(
    files,
    ledger_db_path,
    schema,
    cat,
    sess_hum.id,
    Views.ReadProgram(
      view: "rlm_summaries:#{col_sec.id}",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(20)
    ),
    true,
    limits,
    t0
  )
    Ok(r): r
    Error(_): stop "ok_hum failed"
  end
  assert ok_hum.governed.result.result_count == 1

  # 4. Tight ReadLimits enforces WorkBudgetExceeded -> BadInput
  tight_limits = Views.ReadLimits(max_rows_scanned: 1, max_ops: 200, max_result_rows: 10)
  over = TaintBridge.run_tainted_read_program_locked(
    files,
    ledger_db_path,
    schema,
    cat,
    sess_hum.id,
    Views.ReadProgram(
      view: "rlm_blocks:#{default_collection_id}",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(20)
    ),
    true,
    tight_limits,
    t0
  )
  assert over is Error(BadInput(reason: _))
end
