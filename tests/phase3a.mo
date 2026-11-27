## Vellum Phase 3a Integration Test Suite (split from Phase3 for Mo lowering work limit).
module Tests.Phase3a
use Main
use Api
use Arvo.WebTest
use Domain.DatabaseModel{
  CellValue,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor
}
use Domain.Rlm{RlmBlockSlice, RlmDbSlice}
use Domain.Types{CollectionWritePolicy}
use Http
use Json
use Routes.Ai
use Routes.Collab
use Routes.Databases
use Routes.Sync
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

test "RLM Tier 1 Deep Research API & MCP vellum.rlm_query: Modb.Views ReadProgram slicing, sub-calls, WorkBudgetExceeded 422, and fail-closed ViewDenied"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p24.js",
        "css": ["assets/main-p24.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p24.js": "console.log('p24');",
    "public/assets/main-p24.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261204)
  t0 = Time.parse("2026-12-04T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-test-rlm",
    "VELLUM_AI_BASE_URL": "https://api.openai.com/v1/chat/completions",
    "VELLUM_AI_MODEL": "gpt-4o-mini"
  })
  ai_cfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "ai_cfg"
  end
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

  eng_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "eng-p24",
          name: "Eng P24",
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
  assert eng_col_res.status == 201
  eng_col_id = must_json(eng_col_res.text).text_at("id") or stop "eng_col_id"

  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sec-p24",
          name: "Sec P24",
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
  assert sec_col_res.status == 201
  sec_col_id = must_json(sec_col_res.text).text_at("id") or stop "sec_col_id"

  pg_rb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: eng_col_id,
          parent_page_id: None,
          title: "Gateway Rollback Guide",
          markdown: "## Rollback Procedure\n\n```bash\nkubectl rollout undo deploy/gateway\n```\n\n```bash\nvellum quorum-verify --strict\n```\n\n## Observability\n\n```bash\nprometheus --version\n```",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed rlm runbook")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_rb_res.status == 201
  pg_rb_j = must_json(pg_rb_res.text)
  pg_rb_id = pg_rb_j.text_at("page.id") or stop "pg_rb_id"
  pg_blks = pg_rb_j.list_at("blocks") or []
  assert pg_blks.size == 5
  blk1_j = pg_blks.get(1) or stop "blk1"
  blk2_j = pg_blks.get(2) or stop "blk2"
  blk4_j = pg_blks.get(4) or stop "blk4"
  blk1_id = blk1_j.text_at("id") or stop "blk1_id"
  blk2_id = blk2_j.text_at("id") or stop "blk2_id"
  blk4_id = blk4_j.text_at("id") or stop "blk4_id"

  sec_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Executive Vault Procedure",
          markdown: "Master gateway secret phrase vxq99.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed restricted page")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_pg_res.status == 201

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: eng_col_id,
          parent_page_id: None,
          title: "Deploy Matrix",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(id: "owner", name: "Owner", kind: RichText, required: false, sort_order: "b")
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

  row_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("api-gateway"), "owner": TextVal("@ada")},
          markdown: None,
          reason: Some("seed rlm db row")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert row_res.status == 201
  row_j = must_json(row_res.text)
  row_id = row_j.text_at("row.id") or stop "row_id"
  row_pg_id = row_j.text_at("row.page_id") or stop "row_pg_id"

  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@rlm_bot"),
          "display_name": Json.String("RLM Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("p24"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(eng_col_id)]),
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
  assert mint_res.status == 201
  ag_tok = must_json(mint_res.text).text_at("raw_token") or stop "ag_tok"
  ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  s1 = RlmBlockSlice(
    page_id: pg_rb_id,
    page_title: "Gateway Rollback Guide",
    collection_id: eng_col_id,
    block_id: blk1_id,
    rank: blk1_j.text_at("rank") or "0002",
    kind_tag: "code_block",
    heading_level: 0,
    heading_path: Some("Rollback Procedure"),
    markdown: blk1_j.text_at("markdown") or "",
    score: 1
  )
  s2 = RlmBlockSlice(
    page_id: pg_rb_id,
    page_title: "Gateway Rollback Guide",
    collection_id: eng_col_id,
    block_id: blk2_id,
    rank: blk2_j.text_at("rank") or "0003",
    kind_tag: "code_block",
    heading_level: 0,
    heading_path: Some("Rollback Procedure"),
    markdown: blk2_j.text_at("markdown") or "",
    score: 1
  )
  db_s = RlmDbSlice(
    database_id: db_id,
    database_title: "Deploy Matrix",
    collection_id: eng_col_id,
    row_id: row_id,
    page_id: row_pg_id,
    title: "api-gateway",
    cells_summary: "Item: api-gateway | Owner: @ada"
  )

  # 1. Deep Research with section isolation, block_kinds filter, DB slice, and 2 sub-calls
  q1 = "Rollback gateway deploy quorum"
  (sub1_sys, sub1_usr) = Ai.build_rlm_subcall_prompts(q1, 1, 2, [s1])
  (sub2_sys, sub2_usr) = Ai.build_rlm_subcall_prompts(q1, 2, 2, [s2])
  note1 = "Found rollout undo command [Gateway Rollback Guide §#{blk1_id}]."
  note2 = "Found strict quorum verification [Gateway Rollback Guide §#{blk2_id}]."
  (syn1_sys, syn1_usr) = Ai.build_rlm_synthesis_prompts(
    q1,
    ["Chunk 1/2:\n#{note1}", "Chunk 2/2:\n#{note2}"],
    [s1, s2],
    [db_s]
  )
  deep_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, sub1_sys, sub1_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(note1)})})
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, sub2_sys, sub2_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(note2)})})
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, syn1_sys, syn1_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String(
                    "Run kubectl rollout undo deploy/gateway [Gateway Rollback Guide §#{blk1_id}] then verify quorum [Gateway Rollback Guide §#{blk2_id}]."
                  )
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )

  deep_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: q1,
          collection_id: Some(eng_col_id),
          block_kinds: Some(["code_block"]),
          heading_contains: Some("Rollback"),
          include_databases: Some(true),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(2),
          max_rows_scanned: None,
          session_id: None,
          tier: None,
          script: None,
          max_depth: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    deep_net
  )
  assert deep_res.status == 200
  dj = must_json(deep_res.text)
  assert dj.text_at("tier") == Some("tier1_read_program")
  assert (dj.int_at("rows_scanned") or 0) >= 6
  assert (dj.int_at("ops_used") or 0) >= 6
  assert dj.int_at("subcalls_used") == Some(2)
  assert dj.bool_at("taint.untrusted_tainted") == Some(false)
  cited_bids = (dj.list_at("citations") or []).map(fn(c) c.text_at("block_id") or "" end)
  assert cited_bids.contains?(blk1_id)
  assert cited_bids.contains?(blk2_id)
  assert not cited_bids.contains?(blk4_id)
  db_rows = dj.list_at("db_slices") or []
  assert db_rows.any?(fn(d) d.text_at("row_id") == Some(row_id) end)
  trace_steps = dj.list_at("trace") or []
  assert trace_steps.any?(fn(st) st.text_at("op") == Some("read_program") end)
  assert trace_steps.any?(fn(st) st.text_at("op") == Some("sub_llm") end)
  assert trace_steps.any?(fn(st) st.text_at("op") == Some("synthesize") end)

  # 2. WorkBudgetExceeded -> HTTP 422
  over_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: q1,
          collection_id: Some(eng_col_id),
          block_kinds: Some(["code_block"]),
          heading_contains: Some("Rollback"),
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(0),
          max_rows_scanned: Some(1),
          session_id: None,
          tier: None,
          script: None,
          max_depth: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert over_res.status == 422

  # 3. MCP vellum.rlm_query scoped to eng_col skips sec_col
  q2 = "Rollback Procedure gateway quorum"
  (syn2_sys, syn2_usr) = Ai.build_rlm_synthesis_prompts(q2, [], [s1, s2], [db_s])
  mcp_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, syn2_sys, syn2_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("Scoped agent verified [Gateway Rollback Guide §#{blk1_id}].")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  mcp_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.rlm_query"),
            "arguments": Json.Object({
              "question": Json.String(q2),
              "heading_contains": Json.String("Rollback"),
              "block_kinds": Json.Array([Json.String("code_block")]),
              "max_subcalls": Json.int(0)
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    mcp_net
  )
  assert mcp_ok.status == 200
  mcp_ok_j = must_json(mcp_ok.text)
  assert mcp_ok_j.bool_at("result.isError") == Some(false)
  assert not mcp_ok.text.contains?("vxq99")

  # 4. Scoped agent explicitly requesting sec_col fails closed (Modb.Views / Modb.Grants ViewDenied)
  mcp_denied = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(2),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.rlm_query"),
            "arguments": Json.Object({
              "question": Json.String("vault secret"),
              "collection_id": Json.String(sec_col_id),
              "max_subcalls": Json.int(0)
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
  assert mcp_denied.status == 200
  assert must_json(mcp_denied.text).bool_at("result.isError") == Some(true)
end

test "Conflict-safe vellum sync API: grant-filtered snapshot, YAML + Blueprint push, new page create, and version/policy conflict routing to Modb.World Proposals"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p31.js",
        "css": ["assets/main-p31.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p31.js": "console.log('p31');",
    "public/assets/main-p31.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261205)
  t0 = Time.parse("2026-12-05T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
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

  dir_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sync-direct",
          name: "Sync Direct",
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
  assert dir_col_res.status == 201
  dir_col_id = must_json(dir_col_res.text).text_at("id") or stop "dir_col_id"

  gated_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sync-gated",
          name: "Sync Gated",
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
  assert gated_col_res.status == 201
  gated_col_id = must_json(gated_col_res.text).text_at("id") or stop "gated_col_id"

  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sync-secret",
          name: "Sync Secret",
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
  assert sec_col_res.status == 201
  sec_col_id = must_json(sec_col_res.text).text_at("id") or stop "sec_col_id"

  # Blueprint with required tier field
  bp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/blueprints").with_json(
        Workspace.CreateBlueprintInput(
          slug: "runbook-bp",
          name: "Runbook BP",
          description: Some("Service runbook metadata"),
          icon: None,
          fields: [
            PropertyDef(
              id: "tier",
              name: "Tier",
              kind: Select(
                options: [
                  SelectOption(id: "t1", label: "Tier 1", color: Red),
                  SelectOption(id: "t2", label: "Tier 2", color: Blue)
                ]
              ),
              required: true,
              sort_order: "a"
            )
          ],
          default_template_markdown: Some("## Steps")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bp_res.status == 201
  bp_id = must_json(bp_res.text).text_at("id") or stop "bp_id"

  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: dir_col_id,
          parent_page_id: None,
          title: "Failover SOP",
          markdown: "## Steps\n\nCheck quorum before failover.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed sync page")
        )
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

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Secret Note",
          markdown: "Confidential secret-xyz.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed secret sync page")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_pg.status == 201

  meta_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/meta").with_json(
        Workspace.SetPageMetaInput(
          blueprint_id: Some(bp_id),
          values: Some({"tier": SelectVal(option_id: "t1")}),
          apply_template_if_empty: None,
          reason: Some("attach runbook bp")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert meta_res.status == 200

  gated_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: gated_col_id,
          parent_page_id: None,
          title: "Gated Doc",
          markdown: "Original gated line.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed gated doc")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gated_pg.status == 201
  gated_pg_id = must_json(gated_pg.text).text_at("page.id") or stop "gated_pg_id"

  # Scoped sync agent allowed ONLY on [dir_col_id, gated_col_id]
  mint = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@sync_bot"),
          "display_name": Json.String("Sync Bot"),
          "model_id": Json.Null,
          "label": Json.String("sync"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("write_direct"),
            Json.String("propose")
          ]),
          "allowed_collections": Json.Array([Json.String(dir_col_id), Json.String(gated_col_id)]),
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
  assert mint.status == 201
  ag_tok = must_json(mint.text).text_at("raw_token") or stop "ag_tok"
  ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  # 1. Snapshot isolation & YAML frontmatter + blk anchor projection
  snap_res = ApiTest.send(
    Main,
    WebTest.prepare(ag, Api.get("/api/sync/snapshot")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert snap_res.status == 200
  assert not snap_res.text.contains?("secret-xyz")
  snap_j = must_json(snap_res.text)
  snap_pages = snap_j.list_at("pages") or []
  pg_snap = snap_pages.find(fn(p) p.text_at("page_id") == Some(pg_id) end) or stop "pg_snap"
  pg_doc = pg_snap.text_at("markdown_document") or ""
  assert pg_doc.contains?("blueprint: \"runbook-bp\"")
  assert pg_doc.contains?("<!-- blk:")
  pg_rel = pg_snap.text_at("rel_path") or stop "pg_rel"
  pg_ver = pg_snap.int_at("version") or stop "pg_ver"

  # Fail closed when explicitly filtering restricted collection
  snap_denied = ApiTest.send(
    Main,
    WebTest.prepare(ag, Api.get("/api/sync/snapshot?collections=sync-secret")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert snap_denied.status == 403

  # 2. Clean local push updates block AND YAML blueprint tier (t1 -> t2) directly
  clean_doc = pg_doc.replace("  tier: \"t1\"", "  tier: \"t2\"").replace(
    "Check quorum before failover.",
    "Check quorum and drain canary before failover."
  )
  clean_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: Some(pg_id),
          collection_id: Some(dir_col_id),
          rel_path: pg_rel,
          markdown_document: clean_doc,
          expected_version: Some(pg_ver),
          reason: Some("local clean sync")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clean_push.status == 200
  cp_j = must_json(clean_push.text)
  assert cp_j.text_at("outcome") == Some("applied")
  next_ver = cp_j.int_at("page.version") or stop "next_ver"
  assert next_ver == pg_ver + 1
  updated_doc = cp_j.text_at("markdown_document") or ""
  assert updated_doc.contains?("  tier: \"t2\"")
  assert updated_doc.contains?("drain canary")

  # 3. Push brand new local Markdown file without frontmatter -> creates page + stamps anchors
  create_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: None,
          collection_id: None,
          rel_path: "sync-direct/new-checklist.md",
          markdown_document: "# On-Call Checklist\n\n- Verify backups",
          expected_version: None,
          reason: Some("create from neovim")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert create_push.status == 201
  assert must_json(create_push.text).text_at("outcome") == Some("created")
  assert (must_json(create_push.text).text_at("markdown_document") or "").contains?("<!-- blk:")

  # 4. Stale expected_version conflict routes cleanly into a Modb.World Change Proposal (HTTP 202)!
  stale_doc = updated_doc.replace(
    "Check quorum and drain canary before failover.",
    "Divergent local developer edit."
  )
  conflict_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: Some(pg_id),
          collection_id: Some(dir_col_id),
          rel_path: pg_rel,
          markdown_document: stale_doc,
          expected_version: Some(pg_ver),
          reason: Some("divergent offline edit")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert conflict_push.status == 202
  cj = must_json(conflict_push.text)
  assert cj.text_at("outcome") == Some("proposal_opened")
  assert cj.text_at("conflict_reason") == Some("version_mismatch")
  cprop_id = cj.text_at("proposal.id") or stop "cprop_id"

  # Verify live page was NOT overwritten and proposal diff captures surgical change
  live_pg = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(live_pg.text).text_at("anchored_markdown") or "").contains?("drain canary")
  assert not (must_json(live_pg.text).text_at("anchored_markdown") or "").contains?("Divergent local")

  acc_sync = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{cprop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Accept local sync conflict proposal"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_sync.status == 200
  after_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(after_acc.text).text_at("anchored_markdown") or "").contains?("Divergent local")

  # 5. Agent pushing even with current version to ProposalsRequiredForAgents routes to proposal_opened!
  gated_snap = snap_pages.find(fn(p) p.text_at("page_id") == Some(gated_pg_id) end) or stop "gsnap"
  g_doc = (gated_snap.text_at("markdown_document") or "").replace(
    "Original gated line.",
    "Agent gated sync proposal line."
  )
  gated_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: Some(gated_pg_id),
          collection_id: Some(gated_col_id),
          rel_path: gated_snap.text_at("rel_path") or "sync-gated/doc.md",
          markdown_document: g_doc,
          expected_version: gated_snap.int_at("version"),
          reason: Some("agent push to gated col")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gated_push.status == 202
  assert must_json(gated_push.text).text_at("conflict_reason") == Some("policy_requires_proposal")
end

