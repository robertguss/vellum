## Vellum Phase 2 Integration Test Suite (split from Main for Mo lowering work limit).
module Tests.Phase2
use Main
use Api
use Arvo.WebTest
use Db
use Domain.DatabaseModel{
  AiColumnMode,
  AiOutputKind,
  CellValue,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor
}
use Domain.Types{CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Ai
use Routes.Collab
use Routes.Databases
use Routes.Packs
use Routes.Workspace

fn must_page(res: Api.Response) : WebTest.InertiaPage
  case WebTest.inertia_page(res)
    Ok(p): p
    Error(_): stop "expected valid Inertia page"
  end
end

fn cookie_pair_from_set(res: Api.Response, name: Text) : Text
  for h in res.headers_named("Set-Cookie")
    if h.starts_with?("#{name}=")
      return (h.split(";").first or "").trim
    end
  end
  stop "missing Set-Cookie header"
end

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
  end
end

test "end-to-end Vellum Phase 2.1: Living Summaries, /llms.txt, Context Packs, MCP vellum://packs, and :::ai-brief proposals"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p21.js",
        "css": ["assets/main-p21.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p21.js": "console.log('p21');",
    "public/assets/main-p21.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261201)
  t0 = Time.parse("2026-12-01T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  later_clock = Clock.fixed(t0 + 5.days)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  empty_net = Network.fake(Http.replies([]))

  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  login_res = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/solo/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert login_res.status == 303
  owner = WebTest.absorb(guest, login_res)

  # 1. Create primary page + database with 2 rows -> verify automatic Living Summaries
  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Runbook Alpha"),
          "markdown": Json.String(
            "## Failover\nPrimary failover instructions and quorum verification steps."
          ),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create runbook alpha")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_res.status == 201
  pg_id = must_json(pg_res.text).text_at("page.id") or stop "pg_id"

  # Verbose secondary page to force token-budget compaction
  long_para = "Latency budget, canary promotion rules, and distributed consensus checkpoints. ".repeat(
    18
  )
  long_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Verbose Architecture Spec"),
          "markdown": Json.String("## Deep Dive\n#{long_para}"),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create verbose page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert long_pg_res.status == 201

  # Stale-candidate page with 1-day freshness TTL
  stale_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Outdated Legacy Runbook"),
          "markdown": Json.String("Stale legacy instructions that must be excluded."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.int(1),
          "reason": Json.String("create stale page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert stale_pg_res.status == 201

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Incident Spend",
          description: Some("Operational incident cost ledger"),
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "cost",
              name: "Cost",
              kind: Number(format: "currency"),
              required: false,
              sort_order: "b"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert db_res.status == 201
  db_id = must_json(db_res.text).text_at("database.id") or stop "db_id"

  c1 = "120.00".to_decimal or stop "c1"
  c2 = "80.00".to_decimal or stop "c2"
  r1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Hot Standby"), "cost": NumberVal(c1)},
          markdown: None,
          reason: Some("seed spend row 1")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r1.status == 201
  r2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Pager Override"), "cost": NumberVal(c2)},
          markdown: None,
          reason: Some("seed spend row 2")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r2.status == 201

  sum_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/summaries")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sum_res.status == 200
  summaries_list = must_json(sum_res.text).list_at("summaries") or []
  pg_sum = summaries_list.find(fn(s) s.text_at("entity_id") == Some(pg_id) end) or stop "pg_sum"
  assert pg_sum.text_at("entity_kind") == Some("page")
  assert not (pg_sum.text_at("structural_summary") or "").empty?
  assert (pg_sum.int_at("estimated_tokens") or 0) > 0
  db_sum = summaries_list.find(fn(s) s.text_at("entity_id") == Some(db_id) end) or stop "db_sum"
  assert db_sum.text_at("entity_kind") == Some("database")
  assert db_sum.int_at("row_count") == Some(2)
  assert (db_sum.int_at("estimated_tokens") or 0) > 0

  # 2. Isolated second collection + grant-filtered /llms.txt
  sec_col = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Json.Object({
          "slug": Json.String("secret-ops"),
          "name": Json.String("Secret Ops"),
          "description": Json.Null,
          "icon": Json.Null,
          "write_policy": Json.String("direct_with_audit"),
          "freshness_ttl_days": Json.Null
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_col.status == 201
  sec_col_id = must_json(sec_col.text).text_at("id") or stop "sec_col_id"

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(sec_col_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Secret Vault Doc"),
          "markdown": Json.String("Restricted rotation credentials."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create secret doc")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_pg.status == 201

  mint_iso = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@iso_reader"),
          "display_name": Json.String("Isolated Reader"),
          "model_id": Json.String("claude-sonnet-4-6"),
          "label": Json.String("iso"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(sec_col_id)]),
          "max_calls": Json.int(25),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_iso.status == 201
  iso_tok = must_json(mint_iso.text).text_at("raw_token") or stop "iso_tok"
  iso_agent = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{iso_tok}"
  )

  mint_ops = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@ops_agent"),
          "display_name": Json.String("Ops Pack Agent"),
          "model_id": Json.String("claude-sonnet-4-6"),
          "label": Json.String("ops"),
          "allowed_actions": Json.Array([Json.String("read"), Json.String("propose")]),
          "allowed_collections": Json.Array([Json.String(Db.default_collection_id)]),
          "max_calls": Json.int(25),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_ops.status == 201
  ops_tok = must_json(mint_ops.text).text_at("raw_token") or stop "ops_tok"
  ops_agent = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ops_tok}"
  )

  llms_owner = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/llms.txt")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert llms_owner.status == 200
  assert llms_owner.header("Content-Type") == Some("text/markdown; charset=utf-8")
  assert llms_owner.text.contains?("# Vellum Workspace Index (/llms.txt)")
  assert llms_owner.text.contains?("Runbook Alpha")
  assert llms_owner.text.contains?("Incident Spend")
  assert llms_owner.text.contains?("Secret Vault Doc")

  llms_iso = ApiTest.send(
    Main,
    WebTest.prepare(iso_agent, Api.get("/llms.txt")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert llms_iso.status == 200
  assert llms_iso.text.contains?("secret-ops")
  assert llms_iso.text.contains?("Secret Vault Doc")
  assert not llms_iso.text.contains?("Runbook Alpha")
  assert not llms_iso.text.contains?("Incident Spend")

  # 3. Context Pack CRUD + Optimistic Concurrency + Hard Token Budget + fresh_only + Fail-Closed ACL
  pk_create = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/packs").with_json(
        Packs.CreatePackInput(
          slug: "ops-brief",
          name: "Operations Brief",
          description: Some("Compact runbook & spend bundle"),
          collection_ids: [Db.default_collection_id],
          pinned_page_ids: [pg_id],
          database_ids: [db_id],
          query_hint: None,
          fresh_only: Some(false),
          include_full_blocks: Some(true),
          token_budget: Some(280)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_create.status == 201
  pk_id = must_json(pk_create.text).text_at("id") or stop "pk_id"

  pk_list = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_list.status == 200 and pk_list.text.contains?("ops-brief")

  pk_page_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/packs")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_page_res.status == 200
  assert must_page(pk_page_res).component == "Workspace/Packs"

  pk_upd = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/packs/#{pk_id}").with_json(
        Packs.UpdatePackInput(
          slug: None,
          name: Some("Operations Brief v2"),
          description: None,
          collection_ids: None,
          pinned_page_ids: None,
          database_ids: None,
          query_hint: None,
          fresh_only: None,
          include_full_blocks: None,
          token_budget: None,
          expected_version: Some(1)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_upd.status == 200
  assert must_json(pk_upd.text).int_at("version") == Some(2)

  pk_stale = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/packs/#{pk_id}").with_json(
        Packs.UpdatePackInput(
          slug: None,
          name: Some("Should Conflict"),
          description: None,
          collection_ids: None,
          pinned_page_ids: None,
          database_ids: None,
          query_hint: None,
          fresh_only: None,
          include_full_blocks: None,
          token_budget: None,
          expected_version: Some(1)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_stale.status == 409

  comp_json = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/ops-brief")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert comp_json.status == 200
  cj = must_json(comp_json.text)
  assert cj.int_at("token_budget") == Some(280)
  assert (cj.int_at("tokens_used") or 9999) <= 280
  assert (cj.list_at("included_items") or []).size >= 1

  comp_md = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/ops-brief/markdown")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert comp_md.status == 200
  assert comp_md.header("Content-Type") == Some("text/markdown; charset=utf-8")
  assert comp_md.header("X-Vellum-Token-Budget") == Some("280")
  used_hdr = (comp_md.header("X-Vellum-Tokens-Used") or "9999").to_int or 9999
  assert used_hdr <= 280
  assert comp_md.text.contains?("# Context Pack:")

  # Enable fresh_only and compile at later_clock (+5 days) -> stale page skipped!
  pk_fresh_upd = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/packs/#{pk_id}").with_json(
        Packs.UpdatePackInput(
          slug: None,
          name: None,
          description: None,
          collection_ids: None,
          pinned_page_ids: None,
          database_ids: None,
          query_hint: None,
          fresh_only: Some(true),
          include_full_blocks: None,
          token_budget: Some(1200),
          expected_version: Some(2)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_fresh_upd.status == 200

  comp_fresh = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/ops-brief")),
    files,
    later_clock,
    env,
    rng,
    empty_net
  )
  assert comp_fresh.status == 200
  cf_j = must_json(comp_fresh.text)
  assert (cf_j.int_at("skipped_stale_count") or 0) >= 1
  assert not (cf_j.text_at("markdown") or "").contains?("Stale legacy instructions")

  # Fail-closed cross-collection pack access
  iso_pack_denied = ApiTest.send(
    Main,
    WebTest.prepare(iso_agent, Api.get("/api/packs/ops-brief")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert iso_pack_denied.status == 403

  # Delete temporary pack cleanly
  tmp_pk = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/packs").with_json(
        Packs.CreatePackInput(
          slug: "temp-pack",
          name: "Temp Pack",
          description: None,
          collection_ids: [],
          pinned_page_ids: [],
          database_ids: [],
          query_hint: None,
          fresh_only: None,
          include_full_blocks: None,
          token_budget: Some(512)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tmp_pk.status == 201
  tmp_pk_id = must_json(tmp_pk.text).text_at("id") or stop "tmp_pk_id"
  del_pk = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.delete("/api/packs/#{tmp_pk_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_pk.status == 200 and must_json(del_pk.text).bool_at("deleted") == Some(true)
  after_del = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/temp-pack")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert after_del.status == 404

  # 4. MCP Progressive Disclosure: resources/list, resources/read (vellum://index + vellum://packs), tools/call
  mcp_list_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(101),
          "method": Json.String("resources/list")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_list_res.status == 200
  assert mcp_list_res.text.contains?("vellum://index")
  assert mcp_list_res.text.contains?("vellum://packs/ops-brief")

  mcp_idx = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(102),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://index")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_idx.status == 200
  assert mcp_idx.text.contains?("vellum://packs/ops-brief")
  assert not mcp_idx.text.contains?("Secret Vault Doc")

  mcp_pk = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(103),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://packs/ops-brief")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_pk.status == 200
  assert mcp_pk.text.contains?("# Context Pack:")

  mcp_tool_sums = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(104),
          "method": Json.String("tools/call"),
          "params": Json.Object({"name": Json.String("vellum.list_summaries"), "arguments": Json.Object({})})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_tool_sums.status == 200
  assert mcp_tool_sums.text.contains?("\"isError\":false")
  assert mcp_tool_sums.text.contains?("Runbook Alpha")

  mcp_tool_packs = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(105),
          "method": Json.String("tools/call"),
          "params": Json.Object({"name": Json.String("vellum.list_packs"), "arguments": Json.Object({})})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_tool_packs.status == 200
  assert mcp_tool_packs.text.contains?("\"isError\":false")
  assert mcp_tool_packs.text.contains?("ops-brief")

  mcp_tool_read_pk = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(106),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.read_pack"),
            "arguments": Json.Object({"slug": Json.String("ops-brief")})
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_tool_read_pk.status == 200
  assert mcp_tool_read_pk.text.contains?("\"isError\":false")
  assert mcp_tool_read_pk.text.contains?("Operations Brief v2")

  # Isolated agent denied vellum://packs/ops-brief via MCP
  mcp_iso_denied = ApiTest.send(
    Main,
    WebTest.prepare(
      iso_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(107),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://packs/ops-brief")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_iso_denied.status == 200 and mcp_iso_denied.text.contains?("\"error\"")

  # 5. :::ai-brief Markdown round-trip + proposals-only refresh + Accept
  pg_v1 = must_json(pg_res.text).int_at("page.version") or stop "pg_v1"
  brief_md = "## Failover\nPrimary failover instructions and quorum verification steps.\n\n:::ai-brief [scope=#{Db.default_collection_id}] Summarize operational status\nPlaceholder brief body\n:::"
  sync_brief = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/markdown").with_json(
        Workspace.SyncPageMarkdownInput(
          markdown: brief_md,
          expected_page_version: pg_v1,
          reason: Some("add ai-brief card via markdown lens")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sync_brief.status == 200
  sync_blks = must_json(sync_brief.text).list_at("blocks") or []
  brief_blk = sync_blks.find(fn(b)
    (b.text_at("markdown") or "").contains?("Placeholder brief body")
  end) or
    stop "brief_blk"
  brief_blk_id = brief_blk.text_at("id") or stop "brief_blk_id"
  assert (must_json(sync_brief.text).text_at("anchored_markdown") or "").contains?(
    ":::ai-brief [scope=#{Db.default_collection_id}] Summarize operational status"
  )

  # Refresh AI brief -> proposals-only (never touches live block!)
  refresh_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/brief/refresh").with_json(
        Ai.RefreshAiBriefInput(
          page_id: pg_id,
          block_id: brief_blk_id,
          deterministic_fallback: Some(true)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert refresh_res.status == 201
  ref_j = must_json(refresh_res.text)
  brief_prop_id = ref_j.text_at("proposal.id") or stop "brief_prop_id"
  assert ref_j.text_at("model") == Some("deterministic-summary")

  pg_before_accept = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_before_accept.status == 200
  assert (must_json(pg_before_accept.text).text_at("anchored_markdown") or "").contains?(
    "Placeholder brief body"
  )

  accept_brief = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{brief_prop_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert accept_brief.status == 200

  pg_after_accept = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_after_accept.status == 200
  after_md = must_json(pg_after_accept.text).text_at("anchored_markdown") or ""
  assert after_md.contains?(":::ai-brief [scope=#{Db.default_collection_id} refreshed=")
  assert after_md.contains?("Runbook Alpha")
  assert after_md.contains?("Incident Spend")
  assert not after_md.contains?("Placeholder brief body")

  # 6. Ledger 9 invariants check
  ver21 = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) Ledger.verify_all(db).map_error(Db.map_ledger_error) end
  )
  case ver21
    Ok(rep): assert rep.invariants_checked == 9
    Error(_): assert false
  end
end

test "end-to-end Vellum Phase 2.2: AI-Compiled Columns (AutoApply, validation rejection, daily caps, Modb.Feeds staleness, StageProposal + agent policy)"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p22.js",
        "css": ["assets/main-p22.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p22.js": "console.log('p22');",
    "public/assets/main-p22.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261202)
  t0 = Time.parse("2026-12-02T09:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-test-aicol",
    "VELLUM_AI_BASE_URL": "https://api.openai.com/v1/chat/completions",
    "VELLUM_AI_MODEL": "gpt-4o-mini"
  })
  empty_net = Network.fake(Http.replies([]))

  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  login_res = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/solo/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert login_res.status == 303
  owner = WebTest.absorb(guest, login_res)

  opt_low = SelectOption(id: "low", label: "Low Risk", color: Green)
  opt_high = SelectOption(id: "high", label: "High Risk", color: Red)
  tier_out = AiSelect(options: [opt_low, opt_high])
  score_out = AiNumber(format: "plain")
  tier_prompt = "Classify risk tier"
  score_prompt = "Score severity 0-100"

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Risk Registry",
          description: Some("Operational risk ledger"),
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(id: "notes", name: "Notes", kind: RichText, required: false, sort_order: "b"),
            PropertyDef(
              id: "tier",
              name: "Risk Tier",
              kind: AiDerived(
                prompt: tier_prompt,
                source_prop_ids: ["title", "notes"],
                include_row_body: false,
                output_kind: tier_out,
                mode: AutoApply,
                daily_call_cap: 2
              ),
              required: false,
              sort_order: "c"
            ),
            PropertyDef(
              id: "score",
              name: "Severity Score",
              kind: AiDerived(
                prompt: score_prompt,
                source_prop_ids: ["title", "notes"],
                include_row_body: false,
                output_kind: score_out,
                mode: StageProposal,
                daily_call_cap: 5
              ),
              required: false,
              sort_order: "d"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert db_res.status == 201
  db_id = must_json(db_res.text).text_at("database.id") or stop "db_id"

  r1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Core cluster outage"), "notes": TextVal("Primary region down")},
          markdown: None,
          reason: Some("seed row 1")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r1_res.status == 201
  r1_id = must_json(r1_res.text).text_at("row.id") or stop "r1_id"

  r2_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Minor DNS blip"), "notes": TextVal("Self-recovered")},
          markdown: None,
          reason: Some("seed row 2")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r2_res.status == 201
  r2_id = must_json(r2_res.text).text_at("row.id") or stop "r2_id"

  ai_cfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "ai_cfg"
  end
  src_r1 = "- Item (title): Core cluster outage\n- Notes (notes): Primary region down"
  (tier_sys, tier_usr) = Ai.build_ai_column_prompts(
    "Risk Registry",
    "Risk Tier",
    tier_prompt,
    tier_out,
    "Core cluster outage",
    src_r1
  )
  (score_sys, score_usr) = Ai.build_ai_column_prompts(
    "Risk Registry",
    "Severity Score",
    score_prompt,
    score_out,
    "Core cluster outage",
    src_r1
  )

  # 1. Invalid LLM output ("bogus_option") rejected by validate_cell while debiting 1 call
  bad_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, tier_sys, tier_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("{\"value\":\"bogus_option\",\"rationale\":\"bad\"}")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  bad_run = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/ai-columns/tier/run").with_json(
        Ai.RunAiColumnInput(
          row_ids: Some([r1_id]),
          only_stale: Some(true),
          mode_override: None,
          deterministic_fallback: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    bad_net
  )
  assert bad_run.status == 200
  bad_j = must_json(bad_run.text)
  assert bad_j.int_at("updated_count") == Some(0)
  assert bad_j.int_at("usage.calls_used") == Some(1)
  assert bad_j.int_at("usage.remaining_calls") == Some(1)
  assert bad_run.text.contains?("validation_error")

  # 2. Valid AutoApply run writes SelectVal + AiCellMeta (model, citations, rationale), exhausts cap (2)
  ok_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, tier_sys, tier_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String(
                    "{\"value\":\"High Risk\",\"rationale\":\"Cluster outage in primary region\"}"
                  )
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  ok_run = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/ai-columns/tier/run").with_json(
        Ai.RunAiColumnInput(
          row_ids: Some([r1_id]),
          only_stale: Some(true),
          mode_override: None,
          deterministic_fallback: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    ok_net
  )
  assert ok_run.status == 200
  ok_j = must_json(ok_run.text)
  assert ok_j.text_at("mode") == Some("auto_apply")
  assert ok_j.int_at("updated_count") == Some(1)
  assert ok_j.int_at("usage.calls_used") == Some(2)
  assert ok_j.int_at("usage.remaining_calls") == Some(0)

  show_after_auto = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_after_auto.status == 200
  show_j = must_json(show_after_auto.text)
  r1_meta = (show_j.get("ai_cell_meta") or Json.Null).get("#{r1_id}:tier") or Json.Null
  assert r1_meta.text_at("model") == Some("gpt-4o-mini")
  assert r1_meta.bool_at("stale") == Some(false)
  assert r1_meta.text_at("rationale") == Some("Cluster outage in primary region")
  assert (r1_meta.list_at("citations") or []).size >= 1
  r1_enriched = (show_j.list_at("rows") or []).find(fn(er) er.text_at("row.id") == Some(r1_id) end) or
    stop "r1_enriched"
  assert r1_enriched.text_at("row.cells.tier.select_val.option_id") == Some("high")

  # Daily call cap (2) exhausted -> 409 Conflict
  cap_hit = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/ai-columns/tier/run").with_json(
        Ai.RunAiColumnInput(
          row_ids: Some([r2_id]),
          only_stale: Some(true),
          mode_override: None,
          deterministic_fallback: Some(true)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cap_hit.status == 409

  # 3. StageProposal on Severity Score (mode: StageProposal) BEFORE editing row 1 (so r1 is still v2)
  prop_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, score_sys, score_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("{\"value\":\"88.50\",\"rationale\":\"Elevated severity\"}")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  stage_run = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/ai-columns/score/run").with_json(
        Ai.RunAiColumnInput(
          row_ids: Some([r1_id]),
          only_stale: Some(true),
          mode_override: None,
          deterministic_fallback: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    prop_net
  )
  assert stage_run.status == 201
  ai_prop_id = must_json(stage_run.text).text_at("proposal.id") or stop "ai_prop_id"

  # Live row1 must NOT have score before human accepts!
  before_acc_db = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  r1_before_acc = (must_json(before_acc_db.text).list_at("rows") or []).find(fn(er) er.text_at("row.id") == Some(r1_id) end) or stop "r1_before_acc"
  assert r1_before_acc.get("row.cells.score") == None

  diff_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{ai_prop_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert diff_res.status == 200
  diff_j = must_json(diff_res.text)
  assert (diff_j.list_at("db_row_diffs") or []).size == 1
  assert diff_j.text_at("rollup_deltas.0.delta") == Some("88.5") or
    diff_j.text_at("rollup_deltas.0.delta") == Some("88.50")

  acc_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{ai_prop_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_res.status == 200

  after_acc_db = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  after_j = must_json(after_acc_db.text)
  r1_after_acc = (after_j.list_at("rows") or []).find(fn(er) er.text_at("row.id") == Some(r1_id) end) or
    stop "r1_after_acc"
  assert (r1_after_acc.text_at("row.cells.score.number_val") or "").to_decimal == ("88.5".to_decimal)
  r1_score_meta = (after_j.get("ai_cell_meta") or Json.Null).get("#{r1_id}:score") or Json.Null
  assert r1_score_meta.text_at("proposal_id") == Some(ai_prop_id)
  assert r1_score_meta.bool_at("stale") == Some(false)

  # 4. Source cell edit triggers Modb.Feeds sync-feed -> marks row 1 AI cells stale!
  r1_cur_ver = r1_after_acc.int_at("row.version") or stop "r1_cur_ver"
  upd_row = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}/rows/#{r1_id}").with_json(
        Databases.UpdateRowInput(
          cells: {"notes": TextVal("Resolved after failover")},
          expected_version: r1_cur_ver,
          reason: Some("post-incident update")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert upd_row.status == 200

  sync_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/databases/#{db_id}/ai-columns/sync-feed")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sync_res.status == 200
  sync_j = must_json(sync_res.text)
  assert (sync_j.int_at("events_seen") or 0) >= 1
  assert sync_j.int_at("marked_stale_count") == Some(2)

  status_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}/ai-columns/status")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert status_res.status == 200
  st_j = must_json(status_res.text)
  assert ((st_j.get("cells") or Json.Null).get("#{r1_id}:tier") or Json.Null).bool_at("stale") ==
    Some(true)
  assert ((st_j.get("cells") or Json.Null).get("#{r1_id}:score") or Json.Null).bool_at("stale") ==
    Some(true)

  # 5. Collection policy (ProposalsRequiredForAgents) forces agent onto StageProposal even on AutoApply column
  gated_col = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "gated-ai",
          name: "Gated AI",
          description: None,
          icon: None,
          write_policy: ProposalsRequiredForAgents,
          freshness_ttl_days: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gated_col.status == 201
  gcol_id = must_json(gated_col.text).text_at("id") or stop "gcol_id"

  gdb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: gcol_id,
          parent_page_id: None,
          title: "Gated Notes",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "ai_sum",
              name: "AI Summary",
              kind: AiDerived(
                prompt: "Summarize row",
                source_prop_ids: ["title"],
                include_row_body: false,
                output_kind: AiText,
                mode: AutoApply,
                daily_call_cap: 5
              ),
              required: false,
              sort_order: "b"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gdb_res.status == 201
  gdb_id = must_json(gdb_res.text).text_at("database.id") or stop "gdb_id"

  gr1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{gdb_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Quarterly audit review")},
          markdown: None,
          reason: Some("seed gated row")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gr1.status == 201

  mint_ai = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@ai_col_bot"),
          "display_name": Json.String("AI Column Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("gated-ai"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("write_db"),
            Json.String("propose")
          ]),
          "allowed_collections": Json.Array([Json.String(gcol_id)]),
          "max_calls": Json.int(10),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_ai.status == 201
  ag_tok = must_json(mint_ai.text).text_at("raw_token") or stop "ag_tok"
  ag_client = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  no_key_env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  ag_run = ApiTest.send(
    Main,
    WebTest.prepare(
      ag_client,
      Api.post("/api/databases/#{gdb_id}/ai-columns/ai_sum/run").with_json(
        Ai.RunAiColumnInput(
          row_ids: None,
          only_stale: Some(true),
          mode_override: Some("auto"),
          deterministic_fallback: Some(true)
        )
      )
    ),
    files,
    clock,
    no_key_env,
    rng,
    empty_net
  )
  assert ag_run.status == 201
  assert must_json(ag_run.text).text_at("mode") == Some("stage_proposal")

  # 6. Ledger 9 invariants verification
  ver22 = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) Ledger.verify_all(db).map_error(Db.map_ledger_error) end
  )
  case ver22
    Ok(rep): assert rep.invariants_checked == 9
    Error(_): assert false
  end
end

test "end-to-end Vellum Phase 2.3: Full MCP DB Surface (schema/create/update/propose) and Patchwork Per-Hunk Reject + Steer-in-Place"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p23.js",
        "css": ["assets/main-p23.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p23.js": "console.log('p23');",
    "public/assets/main-p23.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261203)
  t0 = Time.parse("2026-12-03T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-test-steer",
    "VELLUM_AI_BASE_URL": "https://api.openai.com/v1/chat/completions",
    "VELLUM_AI_MODEL": "gpt-4o-mini"
  })
  empty_net = Network.fake(Http.replies([]))

  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  login_res = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/solo/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert login_res.status == 303
  owner = WebTest.absorb(guest, login_res)

  gcol_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "gated-p23",
          name: "Gated P23",
          description: None,
          icon: None,
          write_policy: ProposalsRequiredForAgents,
          freshness_ttl_days: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gcol_res.status == 201
  gcol_id = must_json(gcol_res.text).text_at("id") or stop "gcol_id"

  ocol_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "other-p23",
          name: "Other P23",
          description: None,
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert ocol_res.status == 201
  ocol_id = must_json(ocol_res.text).text_at("id") or stop "ocol_id"

  ddb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Direct Ops",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "cost",
              name: "Cost",
              kind: Number(format: "currency"),
              required: false,
              sort_order: "b"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert ddb_res.status == 201
  ddb_id = must_json(ddb_res.text).text_at("database.id") or stop "ddb_id"

  gdb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: gcol_id,
          parent_page_id: None,
          title: "Gated Ledger",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "cost",
              name: "Cost",
              kind: Number(format: "currency"),
              required: false,
              sort_order: "b"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gdb_res.status == 201
  gdb_id = must_json(gdb_res.text).text_at("database.id") or stop "gdb_id"

  gr0 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{gdb_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Existing Budget"), "cost": NumberVal(10.0)},
          markdown: None,
          reason: Some("seed gated db")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gr0.status == 201
  gr0_id = must_json(gr0.text).text_at("row.id") or stop "gr0_id"

  mint_mcp = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@mcp_db_bot"),
          "display_name": Json.String("MCP DB Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("p23"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("write_db"),
            Json.String("propose"),
            Json.String("comment")
          ]),
          "allowed_collections": Json.Array([
            Json.String(Db.default_collection_id),
            Json.String(gcol_id)
          ]),
          "max_calls": Json.int(50),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_mcp.status == 201
  ag_tok = must_json(mint_mcp.text).text_at("raw_token") or stop "ag_tok"
  ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  mint_other = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@other_bot"),
          "display_name": Json.String("Other Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("other"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(ocol_id)]),
          "max_calls": Json.int(10),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_other.status == 201
  other_tok = must_json(mint_other.text).text_at("raw_token") or stop "other_tok"
  other_ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{other_tok}"
  )

  # 1. Fail-closed db_schema for out-of-scope agent, success for permitted agent
  unauth_schema = ApiTest.send(
    Main,
    WebTest.prepare(
      other_ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_schema"),
            "arguments": Json.Object({"database_id": Json.String(ddb_id)})
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert unauth_schema.status == 200
  assert must_json(unauth_schema.text).bool_at("result.isError") == Some(true)

  ok_schema = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(2),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_schema"),
            "arguments": Json.Object({"database_id": Json.String(ddb_id)})
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert ok_schema.status == 200
  ok_schema_j = must_json(ok_schema.text)
  assert ok_schema_j.bool_at("result.isError") == Some(false)
  assert (ok_schema_j.list_at("result.structuredContent.views") or []).size >= 1

  # 2. DirectWithAudit MCP db_create_row & db_update_row (+ optimistic version check)
  c_row = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(3),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_create_row"),
            "arguments": Json.Object({
              "database_id": Json.String(ddb_id),
              "cells": Json.Object({
                "title": Json.Object({"text_val": Json.String("Edge Proxy")}),
                "cost": Json.Object({"number_val": Json.String("25.00")})
              }),
              "reason": Json.String("MCP create row")
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert c_row.status == 200
  c_row_j = must_json(c_row.text)
  assert c_row_j.bool_at("result.isError") == Some(false)
  r_dir_id = c_row_j.text_at("result.structuredContent.row.id") or stop "r_dir_id"

  stale_u = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(4),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_update_row"),
            "arguments": Json.Object({
              "database_id": Json.String(ddb_id),
              "row_id": Json.String(r_dir_id),
              "cells": Json.Object({"cost": Json.Object({"number_val": Json.String("99.00")})}),
              "expected_version": Json.int(99),
              "reason": Json.String("stale update")
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert stale_u.status == 200
  assert must_json(stale_u.text).bool_at("result.isError") == Some(true)

  ok_u = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(5),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_update_row"),
            "arguments": Json.Object({
              "database_id": Json.String(ddb_id),
              "row_id": Json.String(r_dir_id),
              "cells": Json.Object({"cost": Json.Object({"number_val": Json.String("75.50")})}),
              "expected_version": Json.int(1),
              "reason": Json.String("revise cost")
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert ok_u.status == 200
  ok_u_j = must_json(ok_u.text)
  assert ok_u_j.bool_at("result.isError") == Some(false)
  assert ok_u_j.int_at("result.structuredContent.row.version") == Some(2)

  # 3. Gated collection blocks direct db_create_row and accepts db_propose_changes
  gated_dir = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(6),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_create_row"),
            "arguments": Json.Object({
              "database_id": Json.String(gdb_id),
              "cells": Json.Object({"title": Json.Object({"text_val": Json.String("Blocked")})}),
              "reason": Json.String("must be blocked")
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gated_dir.status == 200
  assert must_json(gated_dir.text).bool_at("result.isError") == Some(true)

  prop_db = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(7),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_propose_changes"),
            "arguments": Json.Object({
              "database_id": Json.String(gdb_id),
              "title": Json.String("Propose Budget + New Row"),
              "reason": Json.String("gated DB change batch"),
              "mutations": Json.Array([
                Json.Object({
                  "kind": Json.String("db_row_update"),
                  "row_id": Json.String(gr0_id),
                  "expected_version": Json.int(1),
                  "cells": Json.Object({"cost": Json.Object({"number_val": Json.String("45.00")})})
                }),
                Json.Object({
                  "kind": Json.String("db_row_create"),
                  "cells": Json.Object({
                    "title": Json.Object({"text_val": Json.String("New Hardware")}),
                    "cost": Json.Object({"number_val": Json.String("15.00")})
                  })
                })
              ])
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert prop_db.status == 200
  prop_db_j = must_json(prop_db.text)
  assert prop_db_j.bool_at("result.isError") == Some(false)
  assert prop_db_j.int_at("result.structuredContent.staged_count") == Some(2)
  db_prop_id = prop_db_j.text_at("result.structuredContent.proposal.id") or stop "db_prop_id"

  diff_db = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{db_prop_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert diff_db.status == 200
  assert (must_json(diff_db.text).list_at("db_row_diffs") or []).size == 2

  acc_db = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{db_prop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Approve MCP DB batch"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_db.status == 200

  q_gdb = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(8),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_query"),
            "arguments": Json.Object({"database_id": Json.String(gdb_id)})
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert q_gdb.status == 200
  assert must_json(q_gdb.text).int_at("result.structuredContent.total_count") == Some(2)

  # 4. Patchwork Per-Hunk Reject + Steer-in-Place + Anchored Proposal Comments
  pg_p = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: gcol_id,
          parent_page_id: None,
          title: "Service SLA",
          icon: None,
          markdown: "Live block one\n\nLive block two",
          freshness_ttl_days: None,
          reason: Some("seed patchwork page")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_p.status == 201
  pg_p_j = must_json(pg_p.text)
  pg_p_id = pg_p_j.text_at("page.id") or stop "pg_p_id"
  b1_id = pg_p_j.text_at("blocks.0.id") or stop "b1_id"
  b2_id = pg_p_j.text_at("blocks.1.id") or stop "b2_id"

  open_pg_prop = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(9),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_open"),
            "arguments": Json.Object({
              "page_id": Json.String(pg_p_id),
              "title": Json.String("SLA Rewrite"),
              "reason": Json.String("Propose updated SLO wording")
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert open_pg_prop.status == 200
  pg_prop_id = must_json(open_pg_prop.text).text_at("result.structuredContent.id") or stop "pg_prop_id"

  stage_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(10),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_stage_ops"),
            "arguments": Json.Object({
              "proposal_id": Json.String(pg_prop_id),
              "reason": Json.String("Draft changes to both blocks"),
              "ops": Json.Array([
                Json.Object({
                  "replace_block": Json.Object({
                    "block_id": Json.String(b1_id),
                    "expected_version": Json.int(1),
                    "kind": Json.Null,
                    "markdown": Json.String("Agent proposed block one")
                  })
                }),
                Json.Object({
                  "replace_block": Json.Object({
                    "block_id": Json.String(b2_id),
                    "expected_version": Json.int(1),
                    "kind": Json.Null,
                    "markdown": Json.String("Unwanted block two edit")
                  })
                })
              ]),
              "expected_versions": Json.Object({b1_id: Json.int(1), b2_id: Json.int(1)})
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert stage_pg.status == 200
  assert must_json(stage_pg.text).bool_at("result.isError") == Some(false)

  rej_hunk = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/hunks/reject").with_json(
        Collab.RejectProposalHunkInput(
          target_kind: "block",
          target_id: b2_id,
          page_id: None,
          database_id: None,
          reason: Some("Keep original block two")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rej_hunk.status == 200

  after_rej_diff = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{pg_prop_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert after_rej_diff.status == 200
  rem_bdiffs = must_json(after_rej_diff.text).list_at("block_diffs") or []
  assert rem_bdiffs.size == 1

  steer_cfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "steer_cfg"
  end
  (steer_sys, steer_usr) = Ai.build_steer_prompts(
    "Service SLA",
    b1_id,
    "Live block one",
    "Agent proposed block one",
    "Include 99.95% latency target"
  )
  steer_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(steer_cfg, steer_sys, steer_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("Steered block one targeting 99.95% latency")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  steer_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/steer").with_json(
        Ai.SteerProposalInput(
          target_block_id: Some(b1_id),
          target_page_id: None,
          instruction: "Include 99.95% latency target",
          deterministic_fallback: Some(false)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    steer_net
  )
  assert steer_res.status == 200
  steer_j = must_json(steer_res.text)
  assert steer_j.text_at("revised_markdown") == Some("Steered block one targeting 99.95% latency")
  hcmt_id = steer_j.text_at("human_comment.id") or stop "hcmt_id"

  note_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/comments").with_json(
        Collab.CreateProposalCommentInput(
          target_kind: Some("proposal"),
          target_ref: None,
          parent_comment_id: None,
          body_markdown: "Ready to merge",
          steer_requested: Some(false)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert note_res.status == 201

  mcp_cmts = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(11),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_comments"),
            "arguments": Json.Object({"proposal_id": Json.String(pg_prop_id)})
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_cmts.status == 200
  assert (must_json(mcp_cmts.text).list_at("result.structuredContent.comments") or []).size == 3

  res_cmt = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/comments/#{hcmt_id}/resolve").with_json(
        Collab.ResolveProposalCommentInput(resolved: Some(true))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert res_cmt.status == 200
  assert must_json(res_cmt.text).text_at("comment.resolved_at") != None

  acc_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Merge steered SLA"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_pg.status == 200

  final_pg = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_p_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert final_pg.status == 200
  final_md = must_json(final_pg.text).text_at("anchored_markdown") or ""
  assert final_md.contains?("Steered block one targeting 99.95% latency")
  assert final_md.contains?("Live block two")
end

