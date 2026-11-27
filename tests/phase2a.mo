## Vellum Tests.Phase2a Integration Tests (split for Mo lowering budget).
module Tests.Phase2a
use Main
use Api
use Arvo.WebTest
use Db
use Domain.DatabaseModel{
  CellValue,
  PropertyDef,
  PropertyKind
}
use Http
use Json
use Modb.Ledger
use Routes.Ai
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

