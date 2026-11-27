## Vellum Phase 3b Integration Test Suite (split from Phase3 for Mo lowering work limit).
module Tests.Phase3b
use Main
use Api
use Arvo.WebTest
use Date
use Domain.DatabaseModel{
  CellValue,
  DbViewKind,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor,
  ViewQueryResult
}
use Domain.Types{BlockOp, CollectionWritePolicy}
use Http
use Json
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

