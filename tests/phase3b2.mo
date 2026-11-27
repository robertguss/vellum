## Vellum Phase 3b2 Integration Test Suite (split from Phase3b for Mo lowering work limit).
module Tests.Phase3b2
use Main
use Api
use Arvo.WebTest
use Db
use Domain.Rlm{RlmBlockSlice}
use Domain.TaintBridge
use Domain.Types{CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Ai
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
