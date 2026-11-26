## Vellum Phase 1 Scale & Hot-Path Benchmark (Pure Mo + Pure MoDB, synced 4 KiB CoW pages):
## 1. Large-document Markdown parsing, anchored round-trips, plain-text extraction & surgical BlockOps (`Domain.Blocks`)
## 2. Corpus-scale indexing (100 -> 250 -> 500 pages) & latency across BM25 (`Modb.Fts`), Sketch Vec, and Neural Hybrid RRF (`Modb.Vec`)
## 3. Relational Database multi-view rollups (`Decimal` SumValues across 200 Tasks -> 25 Projects) & `Modb.Ledger.verify_all`
module BenchVellumHotpaths
use Date
use Db
use Domain.Blocks
use Domain.DatabaseModel{
  CellValue,
  DatabaseDef,
  DbFilterRule,
  DbRow,
  DbSortRule,
  FilterOp,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor
}
use Domain.Types{
  AuthContext,
  AuthorKind,
  BlockKind,
  BlockOp,
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

fn elapsed_ms(clock: Clock, start: Time) : Int
  (clock.now - start).in_milliseconds
end

fn word_at(i: Int) : Text
  words = [
    "gateway",
    "quorum",
    "rotation",
    "failover",
    "snapshot",
    "ledger",
    "invariant",
    "checkpoint",
    "proposal",
    "collection",
    "webhook",
    "signature",
    "deployment",
    "runbook",
    "latency",
    "compaction",
    "vector",
    "hybrid",
    "semantic",
    "bm25",
    "database",
    "rollup",
    "calendar",
    "kanban"
  ]
  words.get(i.floor_mod(words.size)) or "gateway"
end

fn synth_markdown(target_bytes: Int) : Text
  section = "## Section Overview\n\nVerify gateway healthz, quorum consensus, and atomic checkpoint compaction before key rotation.\n\n- Check leader epoch and replica lag\n- Confirm S3 bucket presigned upload integrity\n\n> [!info]\n> All agent proposals stage isolated copy-on-write buckets prior to merge.\n\n```mo\ncheck = Ledger.verify_all(db)\n```\n\n[[pg_runbook|Runbook Reference]]\n\n"
  sec_bytes = section.byte_count
  reps = if target_bytes <= sec_bytes
    1
  else
    target_bytes.floor_div(sec_bytes) + 1
  end
  var chunks = []
  for i in 0..reps
    chunks = chunks.append("# Block Batch #{i}\n\n#{section}")
  end
  chunks.join("")
end

fn lcg_step(seed: Int) : Int
  seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407)
end

fn unit_vec(seed0: Int, dims: Int) : (List(Float), Int)
  var raw = []
  var s = seed0
  for _ in 0..dims
    s = lcg_step(s)
    v = (s.floor_mod(2001) - 1000).to_float / 1000.0
    raw = raw.append(v)
  end
  (Vec.normalize(raw), s)
end

fn bench_large_docs(console: Console, clock: Clock) : Result(Unit, Text)
  console.print("=== 1. Domain.Blocks Large Document Benchmark ===")
  t0 = clock.now
  prov = Provenance(
    author_id: "usr_bench",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: Some("hotpath bench"),
    citations: [],
    updated_at: t0
  )
  for target_kb in [5, 50, 200, 500]
    md = synth_markdown(target_kb * 1024)
    actual_bytes = md.byte_count

    tp = clock.now
    blocks = Blocks.parse_markdown_blocks("pg_large", md, prov, "blk_lg")
    parse_ms = elapsed_ms(clock, tp)

    ta = clock.now
    _anc = Blocks.to_anchored_markdown(blocks)
    anchor_ms = elapsed_ms(clock, ta)

    tx = clock.now
    plain = Blocks.blocks_plain_text(blocks)
    plain_ms = elapsed_ms(clock, tx)

    first_blk = try blocks.first.or_fail("expected parsed block")
    mid_idx = blocks.size.floor_div(2)
    mid_blk = blocks.get(mid_idx) or first_blk
    ops = [
      ReplaceBlock(
        block_id: mid_blk.id,
        expected_version: mid_blk.version,
        kind: None,
        markdown: "Surgically updated paragraph during benchmark."
      ),
      InsertBlockAfter(
        after_block_id: Some(first_blk.id),
        parent_block_id: None,
        kind: Paragraph,
        markdown: "Inserted follow-up block."
      )
    ]
    top = clock.now
    _patched = try Blocks.apply_block_ops(blocks, ops, "pg_large", prov, ["blk_new_1"])
    ops_ms = elapsed_ms(clock, top)

    sk_note = if target_kb <= 50
      tsk = clock.now
      _sv = Vec.text_sketch_embedding(plain, Db.sketch_vec_dims)
      sk_ms = elapsed_ms(clock, tsk)
      " | text_sketch_256d=#{sk_ms} ms"
    else
      ""
    end

    console.print(
      "Doc #{target_kb} KiB (actual=#{actual_bytes} B, #{blocks.size} blocks): parse=#{parse_ms} ms | to_anchored=#{anchor_ms} ms | plain=#{plain_ms} ms | apply_2_ops=#{ops_ms} ms#{sk_note}"
    )
  end
  Ok(Unit)
end

fn make_auths(t0: Time) : (AuthContext, AuthContext)
  owner_auth = AuthContext(
    principal: Principal(
      id: "usr_bench",
      kind: Human,
      handle: "@bench_owner",
      display_name: "Bench Owner",
      email: Some("owner@acme.io"),
      avatar_url: None,
      role: Owner,
      model_id: None,
      root_grant_id: "gr_owner",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_owner",
    session: None,
    allowed_collections: None,
    allowed_actions: ["read", "write_direct", "publish", "write_db"]
  )
  scoped_auth = AuthContext(
    principal: Principal(
      id: "agt_bench",
      kind: Agent,
      handle: "@bench_agent",
      display_name: "Scoped Agent",
      email: None,
      avatar_url: None,
      role: Member,
      model_id: Some("gpt-4o-mini"),
      root_grant_id: "gr_agent",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_agent",
    session: None,
    allowed_collections: Some(["collection:col_3"]),
    allowed_actions: ["read"]
  )
  (owner_auth, scoped_auth)
end

fn bench_corpus_search(console: Console, files: Files, clock: Clock) : Result(Unit, Text)
  console.print("")
  console.print("=== 2. Pure-MoDB Corpus Scale & Hybrid RRF Benchmark (synced 4 KiB CoW pages) ===")
  t0 = clock.now
  schema = Db.vellum_schema()
  (owner_auth, scoped_auth) = make_auths(t0)
  prov = Provenance(
    author_id: "usr_bench",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: Some("seed corpus"),
    citations: [],
    updated_at: t0
  )
  meta = Ledger.WriteMeta(
    principal: "@bench_owner",
    action: "bench.seed",
    reason: "seed benchmark corpus",
    at: t0
  )

  # Bootstrap schema + 10 collections + 20 single-page individual writes to measure true single-tx synced write latency
  _col_seed = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    schema,
    meta,
    "create 10 benchmark collections",
    Json.Null,
    fn(e) e.to_text end,
    fn(tx)
      var cur = tx
      for ci in 0..10
        col = Collection(
          id: "col_#{ci}",
          workspace_id: Db.default_workspace_id,
          slug: "bench-col-#{ci}",
          name: "Bench Col #{ci}",
          description: "Scale corpus #{ci}",
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: Some(90),
          sort_order: "c#{ci}",
          archived_at: None
        )
        cur = try Table.put(cur, Db.collections_table(), col.id, col).map_error(fn(e) e.to_text end)
      end
      Ok((cur, Unit))
    end
  )

  var seed = 20261126
  single_start = clock.now
  for i in 0..20
    cid = "col_#{i.floor_mod(10)}"
    pid = "pg_bench_#{i}"
    w1 = word_at(i)
    w2 = word_at(i * 5 + 1)
    title = "#{w1} #{w2} Runbook ##{i}"
    md = "## #{title}\n\nOperational notes covering #{w1}, #{w2}, and #{word_at(i * 9 + 3)}."
    blks = Blocks.parse_markdown_blocks(pid, md, prov, "blk_#{i}")
    pg = Page(
      id: pid,
      collection_id: cid,
      parent_page_id: None,
      title: title,
      icon: None,
      cover_attachment_id: None,
      kind: Document,
      sort_order: pid,
      database_id: None,
      freshness_ttl_days: None,
      verified_at: Some(t0),
      verified_by: Some("usr_bench"),
      created_by: "usr_bench",
      created_at: t0,
      updated_at: t0,
      archived_at: None,
      version: 1
    )
    (nvec, next_s) = unit_vec(seed, 256)
    seed = next_s
    _wr = try Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      schema,
      meta,
      "write single page #{pid}",
      Json.Null,
      fn(e) e.to_text end,
      fn(tx)
        t1 = try Db.tx_save_page_and_blocks(tx, pg, blks).map_error(fn(e) e.to_text end)
        t2 = try Db.tx_put_page_neural_vector(t1, pg.id, pg.collection_id, 256, nvec).map_error(fn(e)
          e.to_text
        end)
        Ok((t2, Unit))
      end
    )
  end
  single_ms = elapsed_ms(clock, single_start)
  console.print("Single-page synced Ledger write (Fts+Sketch256+Neural256, 20 tx): total=#{single_ms} ms | avg=#{single_ms / 20} ms/page")

  var cur_n = 20
  for target_n in [100, 250, 500]
    t_seed = clock.now
    while cur_n < target_n
      batch_end = if cur_n + 25 <= target_n: cur_n + 25 else: target_n
      var batch_items = []
      for i in cur_n..batch_end
        cid = "col_#{i.floor_mod(10)}"
        pid = "pg_bench_#{i}"
        w1 = word_at(i)
        w2 = word_at(i * 5 + 1)
        title = "#{w1} #{w2} Runbook ##{i}"
        md = "## #{title}\n\nVerify #{w1}, #{w2}, and #{word_at(i * 9 + 3)} across multi-region clusters.\n\n- Checksum item #{i}"
        blks = Blocks.parse_markdown_blocks(pid, md, prov, "blk_#{i}")
        pg = Page(
          id: pid,
          collection_id: cid,
          parent_page_id: None,
          title: title,
          icon: None,
          cover_attachment_id: None,
          kind: Document,
          sort_order: pid,
          database_id: None,
          freshness_ttl_days: None,
          verified_at: Some(t0),
          verified_by: Some("usr_bench"),
          created_by: "usr_bench",
          created_at: t0,
          updated_at: t0,
          archived_at: None,
          version: 1
        )
        (nvec, next_s) = unit_vec(seed, 256)
        seed = next_s
        batch_items = batch_items.append((pg, blks, nvec))
      end
      _bwr = try Ledger.transact_locked(
        files,
        Db.ledger_db_path,
        schema,
        meta,
        "batch seed #{cur_n}..#{batch_end}",
        Json.Null,
        fn(e) e.to_text end,
        fn(tx)
          var cur = tx
          for (pg, blks, nvec) in batch_items
            cur = try Db.tx_save_page_and_blocks(cur, pg, blks).map_error(fn(e) e.to_text end)
            cur = try Db.tx_put_page_neural_vector(cur, pg.id, pg.collection_id, 256, nvec)
              .map_error(fn(e) e.to_text end)
          end
          Ok((cur, Unit))
        end
      )
      cur_n = batch_end
    end
    batch_ms = elapsed_ms(clock, t_seed)

    (qv256, next_qs) = unit_vec(seed + 777, 256)
    seed = next_qs

    pg_cnt = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db) Ok(Modb.page_count(Ledger.store(db))) end
    )

    tb_own = clock.now
    _b1 = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db)
        store = Ledger.store(db)
        for i in 0..20
          q = "#{word_at(i)} #{word_at(i + 3)}"
          _h = try Db.search_pages(store, owner_auth, q, 10, true, None).map_error(fn(e)
            e.to_text
          end)
        end
        Ok(Unit)
      end
    )
    bm25_own_ms = elapsed_ms(clock, tb_own)

    tb_ag = clock.now
    _b2 = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db)
        store = Ledger.store(db)
        for i in 0..20
          q = "#{word_at(i)} #{word_at(i + 3)}"
          _h = try Db.search_pages(store, scoped_auth, q, 10, true, None).map_error(fn(e)
            e.to_text
          end)
        end
        Ok(Unit)
      end
    )
    bm25_ag_ms = elapsed_ms(clock, tb_ag)

    th_sk_own = clock.now
    _b3 = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db)
        store = Ledger.store(db)
        for i in 0..10
          q = "#{word_at(i)} #{word_at(i + 3)}"
          sq = Vec.text_sketch_embedding(q, Db.sketch_vec_dims)
          _h = try Db.search_pages_hybrid(
            store,
            owner_auth,
            q,
            Some(sq),
            Db.sketch_vec_index(),
            "hybrid",
            10,
            true,
            None,
            Some(Db.sketch_min_vec_score)
          ).map_error(fn(e) e.to_text end)
        end
        Ok(Unit)
      end
    )
    hyb_sk_own_ms = elapsed_ms(clock, th_sk_own)

    th_neu_own = clock.now
    _b4 = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db)
        store = Ledger.store(db)
        for i in 0..10
          q = "#{word_at(i)} #{word_at(i + 3)}"
          _h = try Db.search_pages_hybrid(
            store,
            owner_auth,
            q,
            Some(qv256),
            Db.neural_vec_index(256),
            "hybrid",
            10,
            true,
            None,
            Some(0.0)
          ).map_error(fn(e) e.to_text end)
        end
        Ok(Unit)
      end
    )
    hyb_neu_own_ms = elapsed_ms(clock, th_neu_own)

    th_neu_ag = clock.now
    _b5 = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db)
        store = Ledger.store(db)
        for i in 0..10
          q = "#{word_at(i)} #{word_at(i + 3)}"
          _h = try Db.search_pages_hybrid(
            store,
            scoped_auth,
            q,
            Some(qv256),
            Db.neural_vec_index(256),
            "hybrid",
            10,
            true,
            Some("col_3"),
            Some(0.0)
          ).map_error(fn(e) e.to_text end)
        end
        Ok(Unit)
      end
    )
    hyb_neu_ag_ms = elapsed_ms(clock, th_neu_ag)

    ts_neu = clock.now
    _b6 = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      schema,
      fn(e) e.to_text end,
      fn(db)
        store = Ledger.store(db)
        for _i in 0..10
          _h = try Db.search_pages_hybrid(
            store,
            owner_auth,
            "concept",
            Some(qv256),
            Db.neural_vec_index(256),
            "semantic",
            10,
            true,
            None,
            None
          ).map_error(fn(e) e.to_text end)
        end
        Ok(Unit)
      end
    )
    sem_neu_ms = elapsed_ms(clock, ts_neu)

    console.print("Corpus #{target_n} pages (db=#{pg_cnt * 4} KiB, batch_seed=#{batch_ms} ms):")
    console.print("  BM25 (20x): owner_unscoped=#{bm25_own_ms} ms | agent_1of10=#{bm25_ag_ms} ms")
    console.print("  Hybrid Sketch256 (10x): owner_unscoped=#{hyb_sk_own_ms} ms")
    console.print(
      "  Hybrid Neural256 (10x): owner_unscoped=#{hyb_neu_own_ms} ms | agent_scoped=#{hyb_neu_ag_ms} ms | semantic_only=#{sem_neu_ms} ms"
    )
  end
  Ok(Unit)
end

fn bench_database_scale(console: Console, files: Files, clock: Clock) : Result(Unit, Text)
  console.print("")
  console.print("=== 3. Relational Database Multi-View, Decimal Rollup & Ledger Verify Benchmark ===")
  t0 = clock.now
  schema = Db.vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@bench_owner",
    action: "bench.db",
    reason: "seed relational database scale test",
    at: t0
  )

  st_todo = SelectOption(id: "todo", label: "Todo", color: Gray)
  st_active = SelectOption(id: "active", label: "Active", color: Blue)
  st_done = SelectOption(id: "done", label: "Done", color: Green)
  d_pts = "1.25".to_decimal or stop "d_pts"
  d_day = Date.parse_iso("2026-11-26") or stop "d_day"

  tasks_def = DatabaseDef(
    id: "db_b_tasks",
    collection_id: "col_0",
    page_id: "pg_db_b_tasks",
    title: "Bench Tasks",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(options: [st_todo, st_active, st_done]),
        required: true,
        sort_order: "b"
      ),
      PropertyDef(
        id: "points",
        name: "Points",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "c"
      ),
      PropertyDef(id: "due", name: "Due", kind: DateProp(include_time: false), required: false, sort_order: "d")
    ],
    version: 1
  )
  proj_def = DatabaseDef(
    id: "db_b_proj",
    collection_id: "col_0",
    page_id: "pg_db_b_proj",
    title: "Bench Projects",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(options: [st_todo, st_active, st_done]),
        required: true,
        sort_order: "b"
      ),
      PropertyDef(
        id: "tasks",
        name: "Tasks",
        kind: Relation(target_db_id: "db_b_tasks", inverse_prop_id: None),
        required: false,
        sort_order: "c"
      ),
      PropertyDef(
        id: "total_pts",
        name: "Total Points",
        kind: Rollup(relation_prop_id: "tasks", target_prop_id: "points", agg: SumValues),
        required: false,
        sort_order: "d"
      )
    ],
    version: 1
  )

  p_host_t = Page(
    id: "pg_db_b_tasks",
    collection_id: "col_0",
    parent_page_id: None,
    title: "Bench Tasks",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "z1",
    database_id: Some("db_b_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_bench",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  p_host_p = Page(
    id: "pg_db_b_proj",
    collection_id: "col_0",
    parent_page_id: None,
    title: "Bench Projects",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "z2",
    database_id: Some("db_b_proj"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_bench",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  t_seed = clock.now
  _s0 = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    schema,
    meta,
    "register db schemas",
    Json.Null,
    fn(e) e.to_text end,
    fn(tx)
      t1 = try Table.put(tx, Db.pages_table(), p_host_t.id, p_host_t).map_error(fn(e) e.to_text end)
      t2 = try Table.put(t1, Db.pages_table(), p_host_p.id, p_host_p).map_error(fn(e) e.to_text end)
      t3 = try Table.put(t2, Db.databases_table(), tasks_def.id, tasks_def).map_error(fn(e)
        e.to_text
      end)
      t4 = try Table.put(t3, Db.databases_table(), proj_def.id, proj_def).map_error(fn(e)
        e.to_text
      end)
      Ok((t4, Unit))
    end
  )

  # Insert 200 Tasks in batches of 50 (each Task updates vlm_db_cells + backing Page + FTS + Sketch256)
  for batch in 0..4
    b_start = batch * 50
    b_end = b_start + 50
    _tb = try Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      schema,
      meta,
      "seed tasks #{b_start}..#{b_end}",
      Json.Null,
      fn(e) e.to_text end,
      fn(tx)
        var cur = tx
        for ti in b_start..b_end
          st_id = if ti.floor_mod(3) == 0: "todo" else if ti.floor_mod(3) == 1: "active" else: "done"
          tid = "row_bt_#{ti}"
          pgid = "pg_bt_#{ti}"
          row = DbRow(
            id: tid,
            database_id: tasks_def.id,
            page_id: pgid,
            cells: {
              "title": TextVal("Bench Task #{ti}"),
              "status": SelectVal(option_id: st_id),
              "points": NumberVal(d_pts),
              "due": DateVal(start: d_day, end_date: None)
            },
            created_by: "usr_bench",
            created_at: t0,
            updated_at: t0,
            archived_at: None,
            version: 1
          )
          pg = Page(
            id: pgid,
            collection_id: "col_0",
            parent_page_id: Some(p_host_t.id),
            title: "Bench Task #{ti}",
            icon: None,
            cover_attachment_id: None,
            kind: DatabaseRow(database_id: tasks_def.id, row_id: tid),
            sort_order: tid,
            database_id: Some(tasks_def.id),
            freshness_ttl_days: None,
            verified_at: None,
            verified_by: None,
            created_by: "usr_bench",
            created_at: t0,
            updated_at: t0,
            archived_at: None,
            version: 1
          )
          cur = try Db.tx_put_db_row(cur, tasks_def, row, pg, []).map_error(fn(e) e.to_text end)
        end
        Ok((cur, Unit))
      end
    )
  end

  # Insert 25 Projects (each referencing 8 Tasks -> 200 relations verified by Ledger invariants)
  var proj_rows = []
  for pi in 0..25
    var rel_ids = []
    for k in 0..8
      rel_ids = rel_ids.append("row_bt_#{pi * 8 + k}")
    end
    st_id = if pi.floor_mod(2) == 0: "active" else: "todo"
    prow = DbRow(
      id: "row_bp_#{pi}",
      database_id: proj_def.id,
      page_id: "pg_bp_#{pi}",
      cells: {
        "title": TextVal("Project #{pi}"),
        "status": SelectVal(option_id: st_id),
        "tasks": RelationVal(row_ids: rel_ids)
      },
      created_by: "usr_bench",
      created_at: t0,
      updated_at: t0,
      archived_at: None,
      version: 1
    )
    ppg = Page(
      id: "pg_bp_#{pi}",
      collection_id: "col_0",
      parent_page_id: Some(p_host_p.id),
      title: "Project #{pi}",
      icon: None,
      cover_attachment_id: None,
      kind: DatabaseRow(database_id: proj_def.id, row_id: prow.id),
      sort_order: prow.id,
      database_id: Some(proj_def.id),
      freshness_ttl_days: None,
      verified_at: None,
      verified_by: None,
      created_by: "usr_bench",
      created_at: t0,
      updated_at: t0,
      archived_at: None,
      version: 1
    )
    proj_rows = proj_rows.append((prow, ppg))
  end

  _pb = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    schema,
    meta,
    "seed 25 projects with relations",
    Json.Null,
    fn(e) e.to_text end,
    fn(tx)
      var cur = tx
      for (prow, ppg) in proj_rows
        cur = try Db.tx_put_db_row(cur, proj_def, prow, ppg, []).map_error(fn(e) e.to_text end)
      end
      Ok((cur, Unit))
    end
  )
  db_seed_ms = elapsed_ms(clock, t_seed)

  t_cell = clock.now
  _c = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    schema,
    fn(e) e.to_text end,
    fn(db)
      store = Ledger.store(db)
      for _ in 0..20
        _ids = try Db.lookup_row_ids_by_cell(store, tasks_def.id, "status", "active").map_error(fn(e)
          e.to_text
        end)
      end
      Ok(Unit)
    end
  )
  cell_ms = elapsed_ms(clock, t_cell)

  prows_only = proj_rows.map(fn(p) p.0 end)
  t_roll = clock.now
  enriched_proj_cnt = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    schema,
    fn(e) e.to_text end,
    fn(db)
      enriched_proj = try Db.enrich_rows_with_rollups(Ledger.store(db), proj_def, prows_only)
        .map_error(fn(e) e.to_text end)
      Ok(enriched_proj.size)
    end
  )
  roll_ms = elapsed_ms(clock, t_roll)

  filters = [DbFilterRule(prop_id: "status", op: Eq, value: Json.String("active"))]
  sorts = [DbSortRule(prop_id: "title", desc: false)]
  t_view = clock.now
  _vr = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    schema,
    fn(e) e.to_text end,
    fn(db)
      store = Ledger.store(db)
      task_pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), tasks_def.id)
        .map_error(fn(e) e.to_text end)
      tasks_list = task_pairs.map(fn(p) p.1 end)
      enriched_tasks = try Db.enrich_rows_with_rollups(store, tasks_def, tasks_list).map_error(fn(e)
        e.to_text
      end)
      filtered = enriched_tasks.filter(fn(er) DatabaseModel.matches_filters?(er, filters, true) end)
      sorted = DatabaseModel.sort_enriched_rows(filtered, sorts)
      _groups = DatabaseModel.group_rows_for_board(tasks_def, sorted, "status", false)
      _cal = DatabaseModel.filter_calendar_range(sorted, "due", Some(d_day), Some(d_day))
      Ok(Unit)
    end
  )
  view_ms = elapsed_ms(clock, t_view)

  t_ver = clock.now
  ver_res = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    schema,
    fn(e) e.to_text end,
    fn(db)
      rep = try Ledger.verify_all(db).map_error(fn(e) e.to_text end)
      Ok((rep.audit.entry_count, rep.invariants_checked, Modb.page_count(Ledger.store(db))))
    end
  )
  ver_ms = elapsed_ms(clock, t_ver)

  console.print(
    "Seed 200 Tasks + 25 Projects (8 relations/proj): #{db_seed_ms} ms | 20x cell_lookup=#{cell_ms} ms"
  )
  console.print(
    "Enrich 25x8 Relation->Rollup SumValues: #{roll_ms} ms (#{enriched_proj_cnt} rows) | Filter+Sort+Board+Cal(200 rows)=#{view_ms} ms"
  )
  console.print(
    "Full Ledger.verify_all (audit=#{ver_res.0}, invariants=#{ver_res.1}, pages=#{ver_res.2}): #{ver_ms} ms"
  )
  Ok(Unit)
end

fn verify_existing(console: Console, files: Files, clock: Clock) : Result(Unit, Text)
  t0 = clock.now
  res = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e.to_text end,
    fn(db)
      rep = try Ledger.verify_all(db).map_error(fn(e) e.to_text end)
      Ok((rep.audit.entry_count, rep.invariants_checked, Modb.page_count(Ledger.store(db))))
    end
  )
  ms = elapsed_ms(clock, t0)
  console.print(
    "Ledger.verify_all ok: audit=#{res.0} invariants=#{res.1} pages=#{res.2} (#{ms} ms)"
  )
  Ok(Unit)
end

fn run_all(console: Console, files: Files, clock: Clock) : Result(Unit, Text)
  try bench_large_docs(console, clock)
  try bench_corpus_search(console, files, clock)
  bench_database_scale(console, files, clock)
end

fn main(args: Args, console: Console, files: Files, clock: Clock) : Int
  res = if args.list.first == Some("--verify-only")
    verify_existing(console, files, clock)
  else
    run_all(console, files, clock)
  end
  case res
    Ok(Unit): 0
    Error(msg):
      console.error("bench-vellum-hotpaths failed: #{msg}")
      1
  end
end
