## Vellum Phase 3b Integration Test Suite (split from Phase3 for Mo lowering work limit).
module Tests.Phase3b
use Main
use Api
use Arvo.WebTest
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
use Domain.Rlm{RlmBlockSlice}
use Domain.TaintBridge
use Domain.Types{BlockOp, CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Ai
use Routes.Collab
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
