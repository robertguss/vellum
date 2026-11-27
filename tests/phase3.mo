## Vellum Phase 3 Integration Test Suite (split from Main for Mo lowering work limit).
module Tests.Phase3
use Main
use Api
use Arvo.WebTest
use Crypto
use Date
use Db
use Domain.DatabaseModel{
  CellValue,
  DbViewKind,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor,
  ViewQueryResult
}
use Domain.Rlm{RlmBlockSlice, RlmDbSlice}
use Domain.TaintBridge
use Domain.Types{BlockOp, Citation, CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
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

test "Main.test.16"
  # Phase 3.2: Modb.Vec contradiction detection, cited-dependency drift, Proposals-Only Gardener,
  # and HMAC-SHA256 signed GitHub PR-to-Runbook bridge.
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p32.js",
        "css": ["assets/main-p32.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p32.js": "console.log('p32');",
    "public/assets/main-p32.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261206)
  t0 = Time.parse("2026-12-06T09:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  gh_secret = "gh-bridge-test-secret"
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_GITHUB_WEBHOOK_SECRET": gh_secret
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

  ops_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "ops-runbooks",
          name: "Ops Runbooks",
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
  assert ops_col_res.status == 201
  ops_col_id = must_json(ops_col_res.text).text_at("id") or stop "ops_col_id"

  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "secret-vault",
          name: "Secret Vault",
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

  # 1. Seed authoritative source page + dependent page with block citation & excerpt, then update source
  p_auth_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Public API Rate Limit Spec",
          markdown: "Public API rate limit is 100 req/s per tenant.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed rate limit spec")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert p_auth_res.status == 201
  p_auth_j = must_json(p_auth_res.text)
  p_auth_id = p_auth_j.text_at("page.id") or stop "p_auth_id"
  b_auth_blk = (p_auth_j.list_at("blocks") or []).first or stop "b_auth_blk"
  b_auth_id = b_auth_blk.text_at("id") or stop "b_auth_id"

  p_dep_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Gateway Failover SOP",
          markdown: "Respect upstream API rate limit before retrying gateway failover.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed dependent sop")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert p_dep_res.status == 201
  p_dep_j = must_json(p_dep_res.text)
  p_dep_id = p_dep_j.text_at("page.id") or stop "p_dep_id"
  b_dep_blk = (p_dep_j.list_at("blocks") or []).first or stop "b_dep_blk"
  b_dep_id = b_dep_blk.text_at("id") or stop "b_dep_id"

  cite_patch = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{p_dep_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            AttachCitations(
              block_id: b_dep_id,
              citations: [
                Citation(
                  source_kind: "block",
                  source_ref: b_auth_id,
                  label: "Rate Limit §1",
                  excerpt: Some("Public API rate limit is 100 req/s per tenant.")
                )
              ]
            )
          ],
          expected_versions: {},
          reason: Some("link block dependency citation")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cite_patch.status == 200

  bump_auth = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{p_auth_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: b_auth_id,
              expected_version: 1,
              kind: None,
              markdown: "Public API rate limit is 25 req/s per tenant during failover."
            )
          ],
          expected_versions: {b_auth_id: 1},
          reason: Some("tighten failover rate limit")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bump_auth.status == 200

  # 2. Seed Modb.Vec near-duplicate contradicting pair + cross-collection secret doc
  dup_a = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Deploy Rollback Checklist Alpha",
          markdown: "Always enable feature flag legacy_auth during canary deploy step 2 within 30 seconds.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed alpha rollback")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dup_a.status == 201
  dup_a_id = must_json(dup_a.text).text_at("page.id") or stop "dup_a_id"

  dup_b = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Deploy Rollback Checklist Beta",
          markdown: "Never enable feature flag legacy_auth during canary deploy step 2 within 10 seconds.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed beta rollback contradiction")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dup_b.status == 201

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Secret Rollback Checklist Vault",
          markdown: "Never enable feature flag legacy_auth during canary deploy step 2 within 10 seconds secret_vault.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed secret vault doc")
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

  # Scoped agent restricted ONLY to ops_col_id verifies ACL isolation in GET /api/admin/garden
  mint_ops = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@ops_gardener"),
          "display_name": Json.String("Ops Gardener"),
          "model_id": Json.Null,
          "label": Json.String("ops-garden"),
          "allowed_actions": Json.Array([Json.String("read"), Json.String("propose")]),
          "allowed_collections": Json.Array([Json.String(ops_col_id)]),
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
  assert mint_ops.status == 201
  ag_tok = must_json(mint_ops.text).text_at("raw_token") or stop "ag_tok"
  ag_ops = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  g_scan = ApiTest.send(
    Main,
    WebTest.prepare(ag_ops, Api.get("/api/admin/garden")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert g_scan.status == 200
  assert not g_scan.text.contains?("Secret Rollback Checklist Vault")
  gj = must_json(g_scan.text)
  drifts = gj.list_at("citation_drifts") or []
  assert drifts.any?(fn(d)
    d.text_at("dependent_page_id") == Some(p_dep_id) and
      d.text_at("cited_page_id") == Some(p_auth_id) and
      d.text_at("cited_block_id") == Some(b_auth_id)
  end)
  dups = gj.list_at("duplicate_pairs") or []
  assert dups.any?(fn(dp) dp.bool_at("possible_contradiction") == Some(true) end)

  # Show page also surfaces cited-dependency drifts
  dep_show = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{p_dep_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dep_show.status == 200
  assert (must_json(dep_show.text).list_at("citation_drifts") or []).size >= 1

  # 3. Proposals-Only Invariant: even on DirectWithAudit collection, POST /api/admin/garden/propose
  # opens a Modb.World Change Proposal without mutating live content until accepted
  gp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/garden/propose").with_json(
        Ai.GardenProposeInput(
          kind: "citation_drift",
          target_page_id: p_dep_id,
          target_block_id: Some(b_dep_id),
          related_page_id: Some(p_auth_id),
          related_block_id: Some(b_auth_id),
          reason: Some("Sync cited rate limit change"),
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
  assert gp_res.status == 201
  gp_j = must_json(gp_res.text)
  gp_id = gp_j.text_at("proposal.id") or stop "gp_id"
  assert gp_j.text_at("proposal.status") == Some("open")

  # Verify live p_dep is STILL untouched
  dep_before_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{p_dep_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert not (must_json(dep_before_acc.text).text_at("anchored_markdown") or "").contains?(
    "Gardener sync review"
  )

  # Accept gardener proposal -> live page now reflects reconciliation callout
  acc_gp = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{gp_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Accept gardener drift reconciliation"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_gp.status == 200
  dep_after_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{p_dep_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(dep_after_acc.text).text_at("anchored_markdown") or "").contains?(
    "Gardener sync review"
  )

  # Duplicate/contradiction gardener proposal also stages cleanly as Modb.World proposal
  gp_dup = ApiTest.send(
    Main,
    WebTest.prepare(
      ag_ops,
      Api.post("/api/admin/garden/propose").with_json(
        Ai.GardenProposeInput(
          kind: "duplicate_contradiction",
          target_page_id: dup_a_id,
          target_block_id: None,
          related_page_id: None,
          related_block_id: None,
          reason: Some("Reconcile Always vs Never flag rollout"),
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
  assert gp_dup.status == 201

  # 4. Signed Inbound GitHub PR Webhook Bridge (`POST /api/webhooks/github`)
  gh_payload = Json.Object({
    "action": Json.String("opened"),
    "repository": Json.Object({"full_name": Json.String("acme/gateway")}),
    "changed_files": Json.Array([Json.String("docs/gateway-failover-sop.md")]),
    "pull_request": Json.Object({
      "number": Json.int(412),
      "title": Json.String("Gateway failover rate limit retry update"),
      "body": Json.String("Respect upstream API rate limit before retrying gateway failover."),
      "html_url": Json.String("https://github.com/acme/gateway/pull/412"),
      "merged": Json.Boolean(false),
      "head": Json.Object({"sha": Json.String("abc1234deadbeef")})
    })
  })
  gh_req_base = Api.post("/api/webhooks/github").with_json(gh_payload)

  # Unsigned or invalid HMAC signature fails closed with 403
  unsigned_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.new().with_header("Host", "127.0.0.1:8080").with_header("X-GitHub-Event", "pull_request"),
      gh_req_base
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert unsigned_res.status == 403

  bad_sig_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.new()
        .with_header("Host", "127.0.0.1:8080")
        .with_header("X-GitHub-Event", "pull_request")
        .with_header("X-Hub-Signature-256", "sha256=deadbeef"),
      gh_req_base
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_sig_res.status == 403

  # Valid HMAC-SHA256 signature stages Modb.World Change Proposals under @github-pr-bridge
  sig_hex = Crypto.hmac_sha256(gh_secret.bytes, gh_req_base.body).to_hex.ascii_lowercase
  signed_client = WebTest.new()
    .with_header("Host", "127.0.0.1:8080")
    .with_header("X-GitHub-Event", "pull_request")
    .with_header("X-Hub-Signature-256", "sha256=#{sig_hex}")
  signed_res = ApiTest.send(
    Main,
    WebTest.prepare(signed_client, gh_req_base),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert signed_res.status == 201
  sj = must_json(signed_res.text)
  assert (sj.int_at("matched_pages") or 0) >= 1
  gh_props = sj.list_at("proposals") or []
  assert gh_props.size >= 1
  gh_p0 = gh_props.first or stop "gh_p0"
  gh_prop_id = gh_p0.text_at("id") or stop "gh_prop_id"
  gh_target_pg = gh_p0.text_at("target_page_id") or stop "gh_target_pg"
  assert gh_p0.text_at("author_handle") == Some("@github-pr-bridge")
  assert gh_p0.text_at("status") == Some("open")

  # Verify Proposals-Only invariant: target live page does NOT contain PR #412 before review
  before_gh_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{gh_target_pg}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert not (must_json(before_gh_acc.text).text_at("anchored_markdown") or "").contains?(
    "PR #412"
  )

  acc_gh = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{gh_prop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Accept PR #412 runbook update"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_gh.status == 200
  after_gh_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{gh_target_pg}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(after_gh_acc.text).text_at("anchored_markdown") or "").contains?("PR #412")
end

test "Main.test.17"
  # Phase 3.3: DB Gallery & Timeline views, grant-filtered Explicit + Modb.Vec Semantic Backlinks,
  # Visual Modb.Replay Status, and Point-in-Time Scrubber reconstruction.
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p33.js",
        "css": ["assets/main-p33.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p33.js": "console.log('p33');",
    "public/assets/main-p33.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261207)
  t0 = Time.parse("2026-12-07T09:00:00Z") or stop "t0"
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

  ops_col = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "platform-ops",
          name: "Platform Ops",
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
  assert ops_col.status == 201
  ops_col_id = must_json(ops_col.text).text_at("id") or stop "ops_col_id"

  sec_col = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sec-vault",
          name: "Secret Vault",
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
  assert sec_col.status == 201
  sec_col_id = must_json(sec_col.text).text_at("id") or stop "sec_col_id"

  # 1. GalleryView & TimelineView CRUD, validation, chronological range query, & schema evolution
  todo_opt = SelectOption(id: "todo", label: "Planned", color: Gray)
  live_opt = SelectOption(id: "live", label: "Shipped", color: Green)
  rm_props = [
    PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
    PropertyDef(id: "cover", name: "Cover URL", kind: Url, required: false, sort_order: "b"),
    PropertyDef(
      id: "start_at",
      name: "Start Date",
      kind: DateProp(include_time: false),
      required: false,
      sort_order: "c"
    ),
    PropertyDef(
      id: "end_at",
      name: "End Date",
      kind: DateProp(include_time: false),
      required: false,
      sort_order: "d"
    ),
    PropertyDef(
      id: "status",
      name: "Status",
      kind: Select(options: [todo_opt, live_opt]),
      required: false,
      sort_order: "e"
    )
  ]
  rm_db = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Launch Roadmap",
          description: Some("Release windows"),
          properties: rm_props
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rm_db.status == 201
  rm_db_id = must_json(rm_db.text).text_at("database.id") or stop "rm_db_id"

  # Non-date property rejected for TimelineView (422)
  bad_tl = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Invalid Timeline",
          kind: TimelineView(
            start_date_prop_id: "cover",
            end_date_prop_id: None,
            card_prop_ids: ["status"]
          ),
          filters: [],
          filter_match_all: true,
          sorts: []
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_tl.status == 422

  gal_vw = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Asset Gallery",
          kind: GalleryView(
            cover_prop_id: Some("cover"),
            card_prop_ids: ["status"],
            card_size: "md"
          ),
          filters: [],
          filter_match_all: true,
          sorts: []
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gal_vw.status == 201
  gal_vw_id = must_json(gal_vw.text).text_at("id") or stop "gal_vw_id"

  tl_vw = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Release Timeline",
          kind: TimelineView(
            start_date_prop_id: "start_at",
            end_date_prop_id: Some("end_at"),
            card_prop_ids: ["status"]
          ),
          filters: [],
          filter_match_all: true,
          sorts: []
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tl_vw.status == 201
  tl_vw_id = must_json(tl_vw.text).text_at("id") or stop "tl_vw_id"

  r_late = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("GA Rollout"),
            "start_at": DateVal(start: Date.parse_iso("2026-12-18") or stop "d3", end_date: None),
            "end_at": DateVal(start: Date.parse_iso("2026-12-26") or stop "d4", end_date: None),
            "status": SelectVal(option_id: "todo")
          },
          markdown: None,
          reason: Some("late")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r_late.status == 201
  r_late_id = must_json(r_late.text).text_at("row.id") or stop "r_late_id"

  r_unsched = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Backlog Item"), "status": SelectVal(option_id: "todo")},
          markdown: None,
          reason: Some("unscheduled")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r_unsched.status == 201
  r_unsched_id = must_json(r_unsched.text).text_at("row.id") or stop "r_unsched_id"

  r_early = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Beta Milestone"),
            "cover": UrlVal("https://example.com/beta.png"),
            "start_at": DateVal(start: Date.parse_iso("2026-12-01") or stop "d1", end_date: None),
            "end_at": DateVal(start: Date.parse_iso("2026-12-09") or stop "d2", end_date: None),
            "status": SelectVal(option_id: "live")
          },
          markdown: None,
          reason: Some("early")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r_early.status == 201
  r_early_id = must_json(r_early.text).text_at("row.id") or stop "r_early_id"

  # TimelineView query sorts scheduled items chronologically then unscheduled
  tl_all_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(tl_vw_id),
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tl_all_q.status == 200
  case Json.decode_strict[ViewQueryResult](tl_all_q.text.bytes)
    Ok(vq): assert vq.rows.map(fn(e) e.row.id end) == [r_early_id, r_late_id, r_unsched_id]
    Error(_): stop "expected ViewQueryResult for timeline"
  end

  # TimelineView date-window query returns only overlapping window
  tl_win_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(tl_vw_id),
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: Some("2026-12-05"),
          to_date: Some("2026-12-12")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tl_win_q.status == 200
  assert (must_json(tl_win_q.text).list_at("rows") or []).size == 1

  gal_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{rm_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(gal_vw_id),
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gal_q.status == 200
  assert (must_json(gal_q.text).list_at("rows") or []).size == 3

  # Schema removal: dropping required Timeline start_at fails 422; dropping optional cover clears cleanly
  drop_start = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{rm_db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some(rm_props.filter(fn(p) p.id != "start_at" end)),
          expected_version: 1
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert drop_start.status == 422

  drop_cover = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{rm_db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some(rm_props.filter(fn(p) p.id != "cover" end)),
          expected_version: 1
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert drop_cover.status == 200

  # 2. Explicit PageLink/Citation + Modb.Vec Semantic Backlinks with collection ACL isolation
  pg_a = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Kubernetes Failover Runbook",
          markdown: "Multi-zone Kubernetes failover steps for production ingress.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed pg_a")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_a.status == 201
  pg_a_j = must_json(pg_a.text)
  pg_a_id = pg_a_j.text_at("page.id") or stop "pg_a_id"
  pg_a_blk0 = (pg_a_j.list_at("blocks") or []).first or stop "pg_a_blk0"
  pg_a_blk_id = pg_a_blk0.text_at("id") or stop "pg_a_blk_id"

  pg_b = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Regional Disaster SOP",
          markdown: "Before drain execute [[#{pg_a_id}]] checklist.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed linking pg_b")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_b.status == 201
  pg_b_id = must_json(pg_b.text).text_at("page.id") or stop "pg_b_id"

  pg_c = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Kubernetes Cluster Failover Checklist",
          markdown: "Multi-zone Kubernetes ingress failover checklist and verification.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed semantic pg_c")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_c.status == 201
  pg_c_id = must_json(pg_c.text).text_at("page.id") or stop "pg_c_id"

  pg_sec = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Secret Kubernetes Failover Vault",
          markdown: "Secret multi-zone Kubernetes cluster failover ingress keys.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed restricted secret doc")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_sec.status == 201

  mint_ops = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@p33_scoped"),
          "display_name": Json.String("P33 Scoped Reader"),
          "model_id": Json.Null,
          "label": Json.String("p33-ops"),
          "allowed_actions": Json.Array([Json.String("read"), Json.String("propose")]),
          "allowed_collections": Json.Array([Json.String(ops_col_id)]),
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
  assert mint_ops.status == 201
  ag_tok = must_json(mint_ops.text).text_at("raw_token") or stop "ag_tok"
  ag_ops = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  # Scoped reader sees pg_b (explicit) and pg_c (Modb.Vec semantic), NEVER pg_sec!
  bl_res = ApiTest.send(
    Main,
    WebTest.prepare(ag_ops, Api.get("/api/pages/#{pg_a_id}/backlinks")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bl_res.status == 200
  assert not bl_res.text.contains?("Secret Kubernetes Failover Vault")
  blj = must_json(bl_res.text)
  exps = blj.list_at("explicit_backlinks") or []
  sems = blj.list_at("semantic_backlinks") or []
  assert exps.any?(fn(x) x.text_at("source_page_id") == Some(pg_b_id) end)
  assert sems.any?(fn(x) x.text_at("page_id") == Some(pg_c_id) end)

  # show_page also embeds both backlink rails
  show_a = ApiTest.send(
    Main,
    WebTest.prepare(ag_ops, Api.get("/api/pages/#{pg_a_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_a.status == 200
  assert (must_json(show_a.text).list_at("explicit_backlinks") or []).size >= 1
  assert (must_json(show_a.text).list_at("semantic_backlinks") or []).size >= 1

  # 3. Visual Modb.Replay Status & Point-in-Time Scrubber Reconstruction
  bl_pin = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/admin/replay/baseline")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bl_pin.status == 201

  prop1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals").with_json(
        Collab.OpenProposalInput(
          page_id: pg_a_id,
          title: "Replay Rev 1",
          reason: "First failover revision"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert prop1.status == 201
  prop1_id = must_json(prop1.text).text_at("id") or stop "prop1_id"
  st1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{prop1_id}/ops").with_json(
        Collab.StageProposalOpsInput(
          ops: [
            ReplaceBlock(
              block_id: pg_a_blk_id,
              expected_version: 1,
              kind: None,
              markdown: "Revision 1 multi-zone Kubernetes drain step."
            )
          ],
          expected_versions: {pg_a_blk_id: 1},
          reason: "stage rev 1"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert st1.status == 200
  acc1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{prop1_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("accept rev 1"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc1.status == 200

  prop2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals").with_json(
        Collab.OpenProposalInput(
          page_id: pg_a_id,
          title: "Replay Rev 2",
          reason: "Second failover revision"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert prop2.status == 201
  prop2_id = must_json(prop2.text).text_at("id") or stop "prop2_id"
  st2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{prop2_id}/ops").with_json(
        Collab.StageProposalOpsInput(
          ops: [
            ReplaceBlock(
              block_id: pg_a_blk_id,
              expected_version: 2,
              kind: None,
              markdown: "Revision 2 multi-zone Kubernetes drain step."
            )
          ],
          expected_versions: {pg_a_blk_id: 2},
          reason: "stage rev 2"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert st2.status == 200
  acc2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{prop2_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("accept rev 2"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc2.status == 200

  # Replay Status lists CoW baseline and 2 calls
  rpl_st = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/replay/status")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rpl_st.status == 200
  rpl_j = must_json(rpl_st.text)
  assert rpl_j.int_at("call_count") == Some(2)
  assert (rpl_j.list_at("calls") or []).size == 2

  # Page History scrubber has Baseline + Call 1 + Call 2 (3 stops)
  pg_hist = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_a_id}/history")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_hist.status == 200
  phj = must_json(pg_hist.text)
  assert phj.bool_at("can_scrub") == Some(true)
  assert (phj.list_at("stops") or []).size == 3

  # Point-in-time scrub to stop_before_seq=1 -> baseline before Rev 1 & Rev 2
  tt1 = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_a_id}/time-travel?stop_before_seq=1")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tt1.status == 200
  tt1_md = must_json(tt1.text).text_at("historical_markdown") or ""
  assert tt1_md.contains?("Multi-zone Kubernetes failover steps")
  assert not tt1_md.contains?("Revision 1") and not tt1_md.contains?("Revision 2")

  # Point-in-time scrub to stop_before_seq=2 -> Rev 1 (NOT Rev 2!), non-mutating vs live!
  tt2 = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_a_id}/time-travel?stop_before_seq=2")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tt2.status == 200
  tt2_j = must_json(tt2.text)
  tt2_md = tt2_j.text_at("historical_markdown") or ""
  assert tt2_md.contains?("Revision 1 multi-zone Kubernetes drain step.")
  assert not tt2_md.contains?("Revision 2")
  assert (tt2_j.int_at("ops_to_live_count") or 0) >= 1

  # Live page STILL retains Revision 2
  live_now = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_a_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(live_now.text).text_at("anchored_markdown") or "").contains?(
    "Revision 2 multi-zone Kubernetes drain step."
  )

  # Visual Replay Simulate returns enriched outcomes + excluded=1 + bucket_diffs
  sim2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/replay/simulate").with_json(
        Collab.SimulateReplayInput(
          filter_kind: "stop_before_seq",
          target: None,
          seq: Some(2),
          description: "Simulate rewinding Rev 2"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sim2.status == 201
  sim2_j = must_json(sim2.text)
  assert sim2_j.int_at("summary.excluded") == Some(1)
  assert (sim2_j.list_at("outcomes") or []).size == 2
  assert (sim2_j.list_at("bucket_diffs") or []).size >= 1
end

test "Main.test.18"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p34.js",
        "css": ["assets/main-p34.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p34.js": "console.log('p34');",
    "public/assets/main-p34.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261209)
  t0 = Time.parse("2026-12-09T14:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_AI_API_KEY": "test-p34-key",
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

  eng_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "eng-p34",
          name: "Eng P34",
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
  assert eng_res.status == 201
  eng_id = must_json(eng_res.text).text_at("id") or stop "eng_id"

  sec_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sec-p34",
          name: "Sec P34",
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
  assert sec_res.status == 201
  sec_id = must_json(sec_res.text).text_at("id") or stop "sec_id"

  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: eng_id,
          parent_page_id: None,
          title: "Tier 2 Canary Playbook",
          markdown: "## Rollback Steps\n\n```bash\nkubectl rollout undo deploy/canary-edge\n```\n\nVerify quorum replicas before shifting traffic.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed tier 2 runbook")
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
  pg_j = must_json(pg_res.text)
  pg_id = pg_j.text_at("page.id") or stop "pg_id"
  pg_blks = pg_j.list_at("blocks") or []
  blk_code_id = (pg_blks.get(1) or stop "blk1").text_at("id") or stop "blk_code_id"

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_id,
          parent_page_id: None,
          title: "Restricted Master Keys",
          markdown: "Master vault token vlm_tier2_secret_z99.",
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
  assert sec_pg.status == 201

  # Seed an agent with tight max_calls=2 to verify per-LLM-call grant debit + exhaustion,
  # plus a normal scoped agent for planner + recursive rlm.sub tests.
  ag_ok_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@rlm2_bot"),
          "display_name": Json.String("RLM2 Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("p34-ok"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(eng_id)]),
          "max_calls": Json.int(40),
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
  assert ag_ok_res.status == 201
  ag_ok_tok = must_json(ag_ok_res.text).text_at("raw_token") or stop "ag_ok_tok"
  ag_ok = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_ok_tok}"
  )

  ag_tight_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@rlm2_tight"),
          "display_name": Json.String("RLM2 Tight"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("p34-tight"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(eng_id)]),
          "max_calls": Json.int(1),
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
  assert ag_tight_res.status == 201
  ag_tight_tok = must_json(ag_tight_res.text).text_at("raw_token") or stop "ag_tight_tok"
  ag_tight = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tight_tok}"
  )

  # 1. Static capability firewall blocks Files.read and Http.send fail-closed BEFORE any LLM call
  bad_fs_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: "canary rollback",
          collection_id: Some(eng_id),
          block_kinds: None,
          heading_contains: None,
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(2),
          max_rows_scanned: None,
          session_id: None,
          tier: Some("tier2"),
          script: Some("let x = Files.read(\"vellum.modb\")\nreturn x"),
          max_depth: Some(2)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_fs_res.status == 422
  assert bad_fs_res.text.contains?("Files.read")

  # 2. Recursion depth limit fails closed when depth 2 exceeds max_depth=1
  bad_depth_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: "canary rollback",
          collection_id: Some(eng_id),
          block_kinds: None,
          heading_contains: None,
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(3),
          max_rows_scanned: None,
          session_id: None,
          tier: Some("tier2"),
          script: Some("return rlm.sub(\"deeper canary\", null)"),
          max_depth: Some(1)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_depth_res.status == 422
  assert bad_depth_res.text.contains?("depth")

  # 3. Planner-generated script with rlm.sub + ws.search + ws.blocks + llm.ask via HTTP API
  assert Ai.ai_config(env) is Ok(ai_cfg)
  (plan_sys, plan_usr) = Ai.build_rlm_tier2_planner_prompts(
    "How do we rollback canary edge deploy?",
    Some(eng_id),
    Some("Rollback"),
    [],
    false,
    6,
    6,
    4,
    2
  )
  blk_code_j = pg_blks.get(1) or stop "b1"
  blk_para_j = pg_blks.get(2) or stop "b2"
  blk_para_id = blk_para_j.text_at("id") or stop "blk_para_id"
  b1_slice = RlmBlockSlice(
    page_id: pg_id,
    page_title: "Tier 2 Canary Playbook",
    collection_id: eng_id,
    block_id: blk_code_id,
    rank: blk_code_j.text_at("rank") or "0002",
    kind_tag: "code_block",
    heading_level: 0,
    heading_path: Some("Rollback Steps"),
    markdown: blk_code_j.text_at("markdown") or "",
    score: 1
  )
  b2_slice = RlmBlockSlice(
    page_id: pg_id,
    page_title: "Tier 2 Canary Playbook",
    collection_id: eng_id,
    block_id: blk_para_id,
    rank: blk_para_j.text_at("rank") or "0003",
    kind_tag: "paragraph",
    heading_level: 0,
    heading_path: Some("Rollback Steps"),
    markdown: blk_para_j.text_at("markdown") or "",
    score: 1
  )
  planned_mo = [
    "```mo",
    "let hits = ws.search(\"canary-edge rollback\", collection_id)",
    "if len(hits) == 0",
    "  return \"NO_HITS\"",
    "end",
    "let sub_note = rlm.sub(\"Verify quorum\", \"let b = ws.blocks([\\\"#{pg_id}\\\"], [\\\"paragraph\\\"], \\\"Rollback\\\"); return llm.ask(\\\"extract\\\", join(map_field(b, \\\"excerpt\\\"), \\\"\\n\\\"))\")",
    "let blks = ws.blocks(map_field(hits, \"page_id\"), [\"code_block\"], \"Rollback\")",
    "return llm.ask(\"final synthesis\", sub_note + \"\\n\" + join(map_field(blks, \"excerpt\"), \"\\n\"))",
    "```"
  ].join("\n")
  sub_sys = "You are Vellum RLM Tier 2 sub-agent at recursion depth 2. Answer strictly using the inspected MoDB context provided and preserve every [Title §block_id] and [DB: Title #row_id] citation."
  sub_excerpt = "[Tier 2 Canary Playbook §#{blk_para_id}] (paragraph) #{Rlm.format_slice_excerpt(b2_slice)}"
  sub_usr = "extract\n\nContext:\n#{sub_excerpt}"
  sub_ans = "Verified quorum requirement [Tier 2 Canary Playbook §#{blk_para_id}]."

  root_sys = "You are Vellum RLM Tier 2 sub-agent at recursion depth 1. Answer strictly using the inspected MoDB context provided and preserve every [Title §block_id] and [DB: Title #row_id] citation."
  blk_ctx = "[Tier 2 Canary Playbook §#{blk_code_id}] (code_block) #{Rlm.format_slice_excerpt(b1_slice)}"
  root_usr = "final synthesis\n\nContext:\n#{sub_ans}\n#{blk_ctx}"
  final_ans = "Run `kubectl rollout undo deploy/canary-edge` per [Tier 2 Canary Playbook §#{blk_code_id}]."

  t2_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, plan_sys, plan_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(planned_mo)})})
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, sub_sys, sub_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(sub_ans)})})
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, root_sys, root_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(final_ans)})})
            ])
          }).to_text
        )
      )
    ])
  )

  t2_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: "How do we rollback canary edge deploy?",
          collection_id: Some(eng_id),
          block_kinds: None,
          heading_contains: Some("Rollback"),
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(4),
          max_rows_scanned: None,
          session_id: Some("p34-plan"),
          tier: Some("tier2"),
          script: None,
          max_depth: Some(2)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    t2_net
  )
  assert t2_res.status == 200
  t2_j = must_json(t2_res.text)
  assert t2_j.text_at("tier") == Some("tier2_micro_repl")
  assert t2_j.int_at("depth_used") == Some(2)
  assert t2_j.int_at("subcalls_used") == Some(2)
  assert (t2_j.list_at("child_sessions") or []).size == 1
  assert t2_j.text_at("answer") == Some(final_ans)
  assert (t2_j.list_at("trace") or []).any?(fn(s) s.text_at("op") == Some("plan_script") end)
  assert (t2_j.list_at("trace") or []).any?(fn(s) s.text_at("op") == Some("rlm_sub") end)
  assert (t2_j.list_at("trace") or []).any?(fn(s) s.text_at("op") == Some("hybrid_search") end)
  assert not t2_res.text.contains?("vlm_tier2_secret_z99")

  # 4. Scoped Agent via MCP vellum.rlm_query tier2 debits grant calls + enforces collection isolation
  mcp_sc = "let s = ws.summaries(null)\nreturn str(len(s))"
  mcp_t2 = ApiTest.send(
    Main,
    WebTest.prepare(
      ag_ok,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.rlm_query"),
            "arguments": Json.Object({
              "question": Json.String("count permitted entities"),
              "tier": Json.String("tier2"),
              "script": Json.String(mcp_sc),
              "max_subcalls": Json.int(1)
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
  assert mcp_t2.status == 200
  assert not mcp_t2.text.contains?("vlm_tier2_secret_z99")
  mcp_j = must_json(mcp_t2.text)
  assert mcp_j.bool_at("result.isError") == Some(false)
  assert mcp_j.text_at("result.structuredContent.tier") == Some("tier2_micro_repl")

  # 5. Tight max_calls=1 agent fails closed with 403 Forbidden on 2nd llm.ask inside Tier 2 VM
  tight_sc = "let a = llm.ask(\"k\", \"a\")\nlet b = llm.ask(\"k\", \"b\")\nreturn a + b"
  tight_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, root_sys, "k\n\nContext:\na"),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String("one")})})
            ])
          }).to_text
        )
      )
    ])
  )
  tight_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ag_tight,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: "tight budget",
          collection_id: Some(eng_id),
          block_kinds: None,
          heading_contains: None,
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(3),
          max_rows_scanned: None,
          session_id: None,
          tier: Some("tier2"),
          script: Some(tight_sc),
          max_depth: Some(1)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    tight_net
  )
  assert tight_res.status == 403

  # 6. Mark block untrusted provenance -> rlm.sub child becomes tainted AND propagates upward to clean parent in MoDB!
  assert TaintBridge.mark_block_untrusted_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    blk_code_id,
    "guest:untrusted_actor",
    t0
  ) is
    Ok(_)

  up_sc = "let x = rlm.sub(\"inspect untrusted child\", \"let b = ws.blocks([\\\"#{pg_id}\\\"], [\\\"code_block\\\"], null); return str(len(b))\")\nreturn x"
  up_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: "check child taint propagation",
          collection_id: Some(eng_id),
          block_kinds: None,
          heading_contains: None,
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(2),
          max_rows_scanned: None,
          session_id: Some("p34-upward"),
          tier: Some("tier2"),
          script: Some(up_sc),
          max_depth: Some(2)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert up_res.status == 200
  up_j = must_json(up_res.text)
  assert up_j.bool_at("taint.untrusted_tainted") == Some(true)
  parent_sid = up_j.text_at("session_id") or stop "parent_sid"
  child_sids = (up_j.list_at("child_sessions") or []).map(fn(x)
    case x
      Json.String(s): s
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): ""
    end
  end)
  assert child_sids.size == 1
  child_sid = child_sids.first or stop "child_sid"
  assert Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      st = Ledger.store(db)
      ps = try TaintBridge.get_taint_session(st, parent_sid)
      cs = try TaintBridge.get_taint_session(st, child_sid)
      Ok((ps, cs))
    end
  ) is
    Ok((Some(ps_row), Some(cs_row)))
  assert ps_row.untrusted_tainted and cs_row.untrusted_tainted
  assert cs_row.parent_session_id == Some(parent_sid)
end
