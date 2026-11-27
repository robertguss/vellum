## Vellum Tests.Stage2 Integration Tests (split for Mo lowering budget).
module Tests.Stage2
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Date
use Db
use Domain.DatabaseModel{
  CellValue,
  DbFilterRule,
  DbSortRule,
  DbViewKind,
  FilterOp,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor,
  ViewQueryResult
}
use Domain.Types{CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Auth
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

fn unseal_oidc_code_verifier(res: Api.Response, cookie_name: Text, key: Bytes) : Text
  pair = cookie_pair_from_set(res, cookie_name)
  val = pair.drop_prefix("#{cookie_name}=") or stop "missing value"
  raw = Bytes.from_base64url(val) or stop "invalid b64url state cookie"
  nonce = raw.slice(0, 12)
  ct = raw.slice(12, raw.size)
  pt = case Crypto.open(key, nonce, ct, "arvo:oidc:#{cookie_name}".bytes)
    Ok(b): b
    Error(_): stop "unseal state failed"
  end
  st = case Json.decode_strict[Oidc.AuthState](pt)
    Ok(s): s
    Error(_): stop "invalid state json"
  end
  st.code_verifier
end

test "end-to-end Vellum Stage 2: relational databases, Decimal rollups, Table/Kanban/Calendar views, FTS, Ledger invariants, and scoped Agent ACLs"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-a1b2c3d4.js",
        "css": ["assets/main-f9e8d7c6.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-a1b2c3d4.js": "console.log('vellum');",
    "public/assets/main-f9e8d7c6.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261127)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_SECRET_KEY": key_hex,
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_OIDC_PROVIDER_ID": "okta-test",
    "VELLUM_OIDC_CLIENT_ID": "vellum-web",
    "VELLUM_OIDC_CLIENT_SECRET": "oidc-secret-xyz",
    "VELLUM_OIDC_REDIRECT_URI": "http://localhost:8080/auth/oidc/callback",
    "VELLUM_OIDC_ISSUER": "https://auth.example.com",
    "VELLUM_OIDC_AUTH_URL": "https://auth.example.com/authorize",
    "VELLUM_OIDC_TOKEN_URL": "https://auth.example.com/token",
    "VELLUM_OIDC_USERINFO_URL": "https://auth.example.com/userinfo",
    "VELLUM_OIDC_ALLOWED_DOMAINS": "acme.io"
  })
  empty_net = Network.fake(Http.replies([]))

  # Sign in Owner via OIDC PKCE
  guest = WebTest.new().with_header("Host", "localhost:8080")
  oidc_start = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert oidc_start.status == 302
  auth_loc = oidc_start.header("Location") or ""
  q_params = Api.request("GET", auth_loc).query
  oidc_state = q_params.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or stop "state"
  oidc_nonce = q_params.find(fn(p) p.0 == "nonce" end).map(fn(p) p.1 end) or stop "nonce"
  verifier = unseal_oidc_code_verifier(oidc_start, "vellum_oidc_state", key_bytes)
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_config"
  end
  id_jwt = Oidc.build_unsigned_test_jwt(
    Json.Object({
      "iss": Json.String("https://auth.example.com"),
      "aud": Json.String("vellum-web"),
      "sub": Json.String("sub_ada_db"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("ada@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  tok_body = Json.Object({
    "access_token": Json.String("at_db"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String("sub_ada_db"),
    "email": Json.String("ada@acme.io"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Ada Lovelace")
  }).to_text
  oidc_net = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, "code_db", verifier), Http.reply(200, tok_body)),
      (
        Oidc.userinfo_request("https://auth.example.com/userinfo", "at_db"),
        Http.reply(200, ui_body)
      )
    ])
  )
  cb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.absorb(guest, oidc_start),
      Api.get("/auth/oidc/callback?code=code_db&state=#{oidc_state}")
    ),
    files,
    clock,
    env,
    rng,
    oidc_net
  )
  assert cb_res.status == 303
  owner = WebTest.absorb(guest, cb_res)

  # 1. Create restricted collection + secret database, plus Tasks & Projects databases in col_general
  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "secret-ops",
          name: "Secret Ops",
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

  sec_db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Secret Vault",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Name", kind: Title, required: true, sort_order: "a")
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
  assert sec_db_res.status == 201
  sec_db_id = must_json(sec_db_res.text).text_at("database.id") or stop "sec_db_id"

  # Create Tasks DB
  todo_opt = SelectOption(id: "todo", label: "Todo", color: Gray)
  done_opt = SelectOption(id: "done", label: "Done", color: Green)
  tasks_db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Sprint Tasks",
          description: Some("Engineering sprint deliverables"),
          properties: [
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "status",
              name: "Status",
              kind: Select(options: [todo_opt, done_opt]),
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
            PropertyDef(
              id: "due",
              name: "Due",
              kind: DateProp(include_time: false),
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
  assert tasks_db_res.status == 201
  tasks_json = must_json(tasks_db_res.text)
  tasks_db_id = tasks_json.text_at("database.id") or stop "tasks_db_id"
  tasks_table_view_id = tasks_json.text_at("default_view.id") or stop "tasks_table_view_id"

  # Create Projects DB with Relation -> Tasks and Rollup(SumValues + CountAll)
  proj_db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Projects",
          description: Some("Roadmap initiatives"),
          properties: [
            PropertyDef(id: "title", name: "Name", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "tasks",
              name: "Tasks",
              kind: Relation(target_db_id: tasks_db_id, inverse_prop_id: None),
              required: false,
              sort_order: "b"
            ),
            PropertyDef(
              id: "total_pts",
              name: "Total Points",
              kind: Rollup(relation_prop_id: "tasks", target_prop_id: "points", agg: SumValues),
              required: false,
              sort_order: "c"
            ),
            PropertyDef(
              id: "task_count",
              name: "Task Count",
              kind: Rollup(relation_prop_id: "tasks", target_prop_id: "title", agg: CountAll),
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
  assert proj_db_res.status == 201
  proj_db_id = must_json(proj_db_res.text).text_at("database.id") or stop "proj_db_id"

  # 2. Create Task rows with 0.1 and 0.2 Decimal points + Dates
  d1 = "0.1".to_decimal or stop "d1"
  d2 = "0.2".to_decimal or stop "d2"
  d3 = "0.3".to_decimal or stop "d3"
  dt_nov10 = Date.parse_iso("2026-11-10") or stop "dt10"
  dt_nov28 = Date.parse_iso("2026-11-28") or stop "dt28"

  t1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Build MoDB Indexes"),
            "status": SelectVal(option_id: "todo"),
            "points": NumberVal(d1),
            "due": DateVal(start: dt_nov10, end_date: None)
          },
          markdown: Some("Implements composite keys in MoDB."),
          reason: Some("seed task 1")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert t1_res.status == 201
  t1_json = must_json(t1_res.text)
  t1_row_id = t1_json.text_at("row.id") or stop "t1_row_id"
  t1_page_id = t1_json.text_at("page.id") or stop "t1_page_id"

  t2_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Ship Kanban Board"),
            "status": SelectVal(option_id: "todo"),
            "points": NumberVal(d2),
            "due": DateVal(start: dt_nov28, end_date: None)
          },
          markdown: None,
          reason: Some("seed task 2")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert t2_res.status == 201
  t2_row_id = must_json(t2_res.text).text_at("row.id") or stop "t2_row_id"

  # Backing page readable via /api/pages/:id and searchable via /api/search
  backing_page = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{t1_page_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert backing_page.status == 200
  assert must_json(backing_page.text).text_at("page.title") == Some("Build MoDB Indexes")

  fts_hit = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=Indexes")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert fts_hit.status == 200
  assert (must_json(fts_hit.text).list_at("results") or []).size == 1

  # Create Project row linking t1 + t2 -> exact Decimal rollup 0.1 + 0.2 == 0.3
  p1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{proj_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Launch Vellum v1"),
            "tasks": RelationVal(row_ids: [t1_row_id, t2_row_id])
          },
          markdown: None,
          reason: Some("link tasks to project")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert p1_res.status == 201

  proj_query = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{proj_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: None,
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
  assert proj_query.status == 200
  case Json.decode_strict[ViewQueryResult](proj_query.text.bytes)
    Ok(vq):
      assert vq.rows.size == 1
      first_e = vq.rows.first or stop "first project row"
      assert first_e.rollups.get("total_pts") == Some(NumberVal(d3))
      assert first_e.rollups.get("task_count") == Some(NumberVal(2.to_decimal))
    Error(_): stop "expected ViewQueryResult json"
  end

  # 3. Validation / Ledger invariant rejections (422) on invalid Select & dangling Relation
  bad_select = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Invalid Option"), "status": SelectVal(option_id: "nope")},
          markdown: None,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_select.status == 422

  dangling_rel = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{proj_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Broken Link"),
            "tasks": RelationVal(row_ids: ["row_does_not_exist"])
          },
          markdown: None,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dangling_rel.status == 422

  # 4. Saved BoardView (Kanban) + row update card move + 409 conflict + CalendarView range query
  board_view_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Kanban",
          kind: BoardView(
            group_by_prop_id: "status",
            card_prop_ids: ["points", "due"],
            hide_empty_groups: false
          ),
          filters: [],
          filter_match_all: true,
          sorts: [DbSortRule(prop_id: "points", desc: true)]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert board_view_res.status == 201
  board_view_id = must_json(board_view_res.text).text_at("id") or stop "board_view_id"

  cal_view_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Sprint Calendar",
          kind: CalendarView(date_prop_id: "due", card_prop_ids: ["status"]),
          filters: [],
          filter_match_all: true,
          sorts: [DbSortRule(prop_id: "due", desc: false)]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cal_view_res.status == 201
  cal_view_id = must_json(cal_view_res.text).text_at("id") or stop "cal_view_id"

  # Move t1 from todo -> done + test stale 409 conflict
  move_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{tasks_db_id}/rows/#{t1_row_id}").with_json(
        Databases.UpdateRowInput(
          cells: {"status": SelectVal(option_id: "done")},
          expected_version: 1,
          reason: Some("completed task")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert move_ok.status == 200

  move_stale = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{tasks_db_id}/rows/#{t1_row_id}").with_json(
        Databases.UpdateRowInput(
          cells: {"status": SelectVal(option_id: "todo")},
          expected_version: 1,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert move_stale.status == 409

  # Query TableView with filter + BoardView + CalendarView
  table_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(tasks_table_view_id),
          filters: [DbFilterRule(prop_id: "status", op: Eq, value: Json.String("done"))],
          filter_match_all: Some(true),
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
  assert table_q.status == 200
  assert must_json(table_q.text).int_at("total_count") == Some(1)

  board_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(board_view_id),
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
  assert board_q.status == 200
  assert (must_json(board_q.text).list_at("board_groups") or []).size == 3

  cal_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(cal_view_id),
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: Some("2026-11-20"),
          to_date: Some("2026-11-30")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cal_q.status == 200
  assert must_json(cal_q.text).int_at("total_count") == Some(1)

  # 5. Scoped read-only Agent ACL checks + Ledger verify_all (5 invariants)
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "db-reader",
          display_name: "DB Analyst",
          model_id: Some("claude-sonnet-4-6"),
          label: "read-general-db",
          allowed_actions: ["read", "query_db"],
          allowed_collections: Some([Db.default_collection_id]),
          max_calls: 20,
          ttl_days: 7
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_res.status == 201
  agent_tok = must_json(mint_res.text).text_at("raw_token") or stop "raw_token"
  agent = WebTest.new().with_header("Authorization", "Bearer #{agent_tok}")

  agent_list = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/databases")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_list.status == 200
  assert (must_json(agent_list.text).list_at("databases") or []).size == 2

  agent_sec = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/databases/#{sec_db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_sec.status == 403

  agent_write = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Unauthorized"), "status": SelectVal(option_id: "todo")},
          markdown: None,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_write.status == 403

  verify_rep = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e end,
    fn(db)
      store = Ledger.store(db)
      done_rows = Db.lookup_row_ids_by_cell(store, tasks_db_id, "status", "done")
      assert done_rows == Ok([t1_row_id])
      Ledger.verify_all(db)
    end
  )
  case verify_rep
    Ok(rep): assert rep.invariants_checked == 9
    Error(_): stop "Ledger.verify_all stage 2 failed"
  end
end

