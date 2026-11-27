## Vellum Tests.Phase2b Integration Tests (split for Mo lowering budget).
module Tests.Phase2b
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
use Routes.Databases
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

