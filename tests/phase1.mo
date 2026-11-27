## Vellum Phase 1.1-1.3 Integration Tests.
module Tests.Phase1
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Date
use Db
use Domain.DatabaseModel{
  CellValue,
  DbSortRule,
  DbViewKind,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor
}
use Domain.Types{BlockKind, BlockOp}
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

test "end-to-end Vellum Phase 1.1: Solo & Personal auth modes, loopback guard, local disk attachments with HMAC + XSS hardening, and unchanged MoDB Grants"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-solo1234.js",
        "css": ["assets/main-solo1234.css"],
        "isEntry": true
      }
    }
    """
  solo_files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-solo1234.js": "console.log('solo');",
    "public/assets/main-solo1234.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(991122)
  t0 = Time.parse("2026-11-26T15:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  empty_net = Network.fake({})

  # Solo env: ZERO VELLUM_SECRET_KEY, ZERO OIDC_*, ZERO S3_*
  solo_env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")

  # Unauthenticated JSON endpoint MUST still return 401
  unauth_api = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/api/audit")),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert unauth_api.status == 401

  # Non-loopback Host header MUST fail closed with 403 even on /auth/solo/login
  evil_host = ApiTest.send(
    Main,
    Api.get("/auth/solo/login?return_to=/").with_header("Host", "evil.example.com"),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert evil_host.status == 403
  assert not solo_files.exists?(".vellum_secret")

  # Loopback browser GET / redirects cleanly to /auth/solo/login
  guest_home = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/").with_header("Host", "127.0.0.1:8080")),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert guest_home.status == 303
  assert WebTest.redirect_location(guest_home) == Some("/auth/solo/login?return_to=/")

  # /login renders Solo Auth mode cleanly without OIDC
  solo_login_page = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/login").with_header("Host", "127.0.0.1:8080")),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert solo_login_page.status == 200
  login_p = must_page(solo_login_page)
  assert login_p.component == "Auth/Login"
  assert Json.Object(login_p.props).text_at("auth_mode") == Some("solo")
  assert Json.Object(login_p.props).bool_at("oidc_enabled") == Some(false)

  # Loopback /auth/solo/login generates .vellum_secret, provisions Owner, opens MoDB session
  solo_cb = ApiTest.send(
    Main,
    WebTest.prepare(
      guest,
      Api.get("/auth/solo/login?return_to=/").with_header("Host", "127.0.0.1:8080")
    ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert solo_cb.status == 303
  assert WebTest.redirect_location(solo_cb) == Some("/")
  assert solo_files.exists?(".vellum_secret")

  solo_owner = WebTest.absorb(guest, solo_cb)
  solo_home = ApiTest.send(
    Main,
    WebTest.prepare(solo_owner, Api.get("/").with_header("Host", "127.0.0.1:8080")),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert solo_home.status == 200
  assert must_page(solo_home).component == "Workspace/Home"

  # Scoped agent tokens & MoDB Grants remain strictly enforced in Solo Mode
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      solo_owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "solo-reader",
          display_name: "Solo Read Bot",
          model_id: Some("claude-sonnet-4-6"),
          label: "Read only",
          allowed_actions: ["read"],
          allowed_collections: Some(["col_general"]),
          max_calls: 25,
          ttl_days: 7
        )
      )
    ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert mint_res.status == 201
  solo_agent_tok = must_json(mint_res.text).text_at("raw_token") or stop "solo_agent_tok"

  # Read-only agent token is denied page creation in Solo Mode (fail-closed)
  denied_write = ApiTest.send(
    Main,
    Api.post("/api/pages")
      .with_bearer(solo_agent_tok)
      .with_json(
        Workspace.CreatePageInput(
          collection_id: "col_general",
          parent_page_id: None,
          title: "Unauthorized Write",
          markdown: "Should fail.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("test grant enforcement")
        )
      ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert denied_write.status == 403

  # Create page + exercise local-disk attachments (SVG XSS hardening + HMAC tamper check)
  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      solo_owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: "col_general",
          parent_page_id: None,
          title: "Solo Architecture Note",
          markdown: "# Overview\n\nLocal disk storage works.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("create solo page")
        )
      )
    ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert pg_res.status == 201
  pg_id = (must_json(pg_res.text).get("page") or Json.Null).text_at("id") or stop "pg_id"

  svg_body = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"4\"/></svg>".bytes
  svg_sha = Crypto.sha256(svg_body).to_hex
  presign_res = ApiTest.send(
    Main,
    WebTest.prepare(
      solo_owner,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: pg_id,
          filename: "diagram.svg",
          content_type: "image/svg+xml",
          size_bytes: svg_body.size,
          sha256_hex: Some(svg_sha)
        )
      )
    ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert presign_res.status == 201
  presign_j = must_json(presign_res.text)
  att_id = (presign_j.get("attachment") or Json.Null).text_at("id") or stop "att_id"
  assert (presign_j.get("attachment") or Json.Null).text_at("s3_bucket") == Some("local")
  upload_url = presign_j.text_at("upload_url") or stop "upload_url"
  assert upload_url.starts_with?("/api/attachments/#{att_id}/upload?")

  # Tampered signature on local upload is rejected with 403
  tampered_put = ApiTest.send(
    Main,
    Api.put("/api/attachments/#{att_id}/upload?exp=9999999999&sig=0000").with_bytes(
      svg_body,
      "image/svg+xml"
    ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert tampered_put.status == 403

  # Valid signed PUT stores bytes on local disk, commit succeeds, and download hardens SVG disposition
  valid_put = ApiTest.send(
    Main,
    Api.put(upload_url).with_bytes(svg_body, "image/svg+xml"),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert valid_put.status == 200

  commit_res = ApiTest.send(
    Main,
    WebTest.prepare(
      solo_owner,
      Api.post("/api/attachments/#{att_id}/commit").with_json(Json.Object({}))
    ),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert commit_res.status == 200
  assert must_json(commit_res.text).text_at("status") == Some("ready")

  dl_res = ApiTest.send(
    Main,
    WebTest.prepare(solo_owner, Api.get("/api/attachments/#{att_id}/download")),
    solo_files,
    clock,
    solo_env,
    rng,
    empty_net
  )
  assert dl_res.status == 200
  assert dl_res.body == svg_body
  assert dl_res.header("X-Content-Type-Options") == Some("nosniff")
  assert (dl_res.header("Content-Disposition") or "").starts_with?("attachment;")

  # Personal Mode tests (scrypt hash verification + missing-passphrase fail-closed + solo disabled)
  pers_files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-solo1234.js": "console.log('personal');",
    "public/assets/main-solo1234.css": "body{margin:0}"
  })
  no_pass_env = Env.of({"VELLUM_MODE": "personal", "VELLUM_INSECURE_COOKIES": "1"})
  missing_pass_res = ApiTest.send(
    Main,
    Api.post("/auth/personal/login").with_json(
      Auth.PersonalLoginInput(passphrase: "anything-1234", return_to: None)
    ),
    pers_files,
    clock,
    no_pass_env,
    rng,
    empty_net
  )
  assert missing_pass_res.status == 500

  scrypt_hash = case Crypto.hash_password("vellum-personal-secret", rng.bytes(16))
    Ok(h): h
    Error(_): stop "hash_password"
  end
  pers_env = Env.of({
    "VELLUM_MODE": "personal",
    "VELLUM_PERSONAL_PASSPHRASE_HASH": scrypt_hash,
    "VELLUM_INSECURE_COOKIES": "1"
  })

  # /auth/solo/login MUST return 403 in Personal mode
  solo_denied_in_personal = ApiTest.send(
    Main,
    Api.get("/auth/solo/login"),
    pers_files,
    clock,
    pers_env,
    rng,
    empty_net
  )
  assert solo_denied_in_personal.status == 403

  # Bad passphrase returns 401
  bad_pass = ApiTest.send(
    Main,
    Api.post("/auth/personal/login").with_json(
      Auth.PersonalLoginInput(passphrase: "wrong-passphrase", return_to: Some("/proposals"))
    ),
    pers_files,
    clock,
    pers_env,
    rng,
    empty_net
  )
  assert bad_pass.status == 401

  # Valid passphrase logs in, creates session + .vellum_secret, and opens Workspace/Home
  good_pass = ApiTest.send(
    Main,
    Api.post("/auth/personal/login").with_json(
      Auth.PersonalLoginInput(
        passphrase: "vellum-personal-secret",
        return_to: Some("https://evil.example.com")
      )
    ),
    pers_files,
    clock,
    pers_env,
    rng,
    empty_net
  )
  assert good_pass.status == 200
  # Unsafe external return_to sanitized to "/"
  assert must_json(good_pass.text).text_at("redirect_to") == Some("/")

  pers_owner = WebTest.absorb(guest, good_pass)
  pers_home = ApiTest.send(
    Main,
    WebTest.prepare(pers_owner, Api.get("/")),
    pers_files,
    clock,
    pers_env,
    rng,
    empty_net
  )
  assert pers_home.status == 200
  assert must_page(pers_home).component == "Workspace/Home"
end

test "Vellum Phase 1.2: saved views lifecycle, 11-type schema evolution, unified multi-resource Modb.World Scenarios, exact Decimal deltas & concurrent conflict rejection"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p12.js",
        "css": ["assets/main-p12.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p12.js": "console.log('p12');",
    "public/assets/main-p12.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261127)
  t0 = Time.parse("2026-11-27T10:00:00Z") or stop "t0"
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

  # Fetch home to discover owner principal ID
  home_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert home_res.status == 200
  owner_id = Json.Object(must_page(home_res).props).text_at("auth.id") or stop "owner_id"

  # 1. Create Projects target DB (for Relation + Rollup), primary Budgets DB, and wiki page
  proj_db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Projects",
          description: Some("Parent initiatives"),
          properties: [
            PropertyDef(id: "title", name: "Name", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "budget_cap",
              name: "Budget Cap",
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
  assert proj_db_res.status == 201
  proj_db_id = must_json(proj_db_res.text).text_at("database.id") or stop "proj_db_id"

  d500 = "500.00".to_decimal or stop "d500"
  proj_row_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{proj_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Core Platform"), "budget_cap": NumberVal(d500)},
          markdown: None,
          reason: Some("seed parent project")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert proj_row_res.status == 201
  proj_row_id = must_json(proj_row_res.text).text_at("row.id") or stop "proj_row_id"

  opt_plan = SelectOption(id: "planned", label: "Planned", color: Blue)
  opt_act = SelectOption(id: "active", label: "Active", color: Green)
  tag_inf = SelectOption(id: "infra", label: "Infra", color: Purple)
  tag_ops = SelectOption(id: "ops", label: "Ops", color: Amber)

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Q4 Spend",
          description: Some("Department budget ledger"),
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "status",
              name: "Status",
              kind: Select(options: [opt_plan, opt_act]),
              required: false,
              sort_order: "b"
            ),
            PropertyDef(
              id: "amount",
              name: "Amount",
              kind: Number(format: "currency"),
              required: false,
              sort_order: "c"
            ),
            PropertyDef(
              id: "due",
              name: "Due Date",
              kind: DateProp(include_time: false),
              required: false,
              sort_order: "d"
            ),
            PropertyDef(id: "done", name: "Approved", kind: Checkbox, required: false, sort_order: "e")
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
  db_json = must_json(db_res.text)
  db_id = db_json.text_at("database.id") or stop "db_id"
  table_vw_id = db_json.text_at("default_view.id") or stop "table_vw_id"

  wiki_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Q4 Budget Memo"),
          "markdown": Json.String("Live quarterly cap is $300.30."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("seed wiki page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert wiki_pg_res.status == 201
  wiki_pg_json = must_json(wiki_pg_res.text)
  wiki_pg_id = wiki_pg_json.text_at("page.id") or stop "wiki_pg_id"
  wiki_blk_id = ((wiki_pg_json.list_at("blocks") or []).first or Json.Null).text_at("id") or stop "wiki_blk_id"

  # 2. Saved view CRUD (create, rename/update filter+sort, delete until 1 remains -> 422)
  create_board = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Kanban",
          kind: BoardView(
            group_by_prop_id: "status",
            card_prop_ids: ["amount", "done"],
            hide_empty_groups: false
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
  assert create_board.status == 201
  board_vw_id = must_json(create_board.text).text_at("id") or stop "board_vw_id"

  create_cal = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Timeline Cal",
          kind: CalendarView(date_prop_id: "due", card_prop_ids: ["amount"]),
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
  assert create_cal.status == 201
  cal_vw_id = must_json(create_cal.text).text_at("id") or stop "cal_vw_id"

  patch_board = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}/views/#{board_vw_id}").with_json(
        Json.Object({
          "name": Json.String("Sprint Board"),
          "filter_match_all": Json.Boolean(false),
          "sorts": [DbSortRule(prop_id: "amount", desc: true)].to_json
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert patch_board.status == 200
  patch_board_j = must_json(patch_board.text)
  assert patch_board_j.text_at("name") == Some("Sprint Board")
  assert patch_board_j.bool_at("filter_match_all") == Some(false)

  del_cal = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.delete("/api/databases/#{db_id}/views/#{cal_vw_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_cal.status == 200

  del_board = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.delete("/api/databases/#{db_id}/views/#{board_vw_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_board.status == 200

  # Deleting the final remaining view fails with 422
  del_last = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.delete("/api/databases/#{db_id}/views/#{table_vw_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_last.status == 422

  # 3. Schema evolution adding all 11 property kinds + legacy column, rows, GET /api/databases/:id, and column deletion safety
  evolved_props = [
    PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
    PropertyDef(
      id: "status",
      name: "Status",
      kind: Select(options: [opt_plan, opt_act]),
      required: false,
      sort_order: "b"
    ),
    PropertyDef(
      id: "amount",
      name: "Amount",
      kind: Number(format: "currency"),
      required: false,
      sort_order: "c"
    ),
    PropertyDef(
      id: "due",
      name: "Due Date",
      kind: DateProp(include_time: false),
      required: false,
      sort_order: "d"
    ),
    PropertyDef(id: "done", name: "Approved", kind: Checkbox, required: false, sort_order: "e"),
    PropertyDef(id: "notes", name: "Notes", kind: RichText, required: false, sort_order: "f"),
    PropertyDef(
      id: "tags",
      name: "Tags",
      kind: MultiSelect(options: [tag_inf, tag_ops]),
      required: false,
      sort_order: "g"
    ),
    PropertyDef(id: "owners", name: "Owners", kind: Person, required: false, sort_order: "h"),
    PropertyDef(id: "link", name: "Spec URL", kind: Url, required: false, sort_order: "i"),
    PropertyDef(
      id: "project",
      name: "Project",
      kind: Relation(target_db_id: proj_db_id, inverse_prop_id: None),
      required: false,
      sort_order: "j"
    ),
    PropertyDef(
      id: "proj_budget",
      name: "Project Cap",
      kind: Rollup(relation_prop_id: "project", target_prop_id: "budget_cap", agg: SumValues),
      required: false,
      sort_order: "k"
    ),
    PropertyDef(id: "legacy", name: "Legacy", kind: RichText, required: false, sort_order: "l")
  ]
  evolve_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some(evolved_props),
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
  assert evolve_res.status == 200
  assert must_json(evolve_res.text).int_at("version") == Some(2)

  d100 = "100.10".to_decimal or stop "d100"
  d200 = "200.20".to_decimal or stop "d200"
  dt1 = Date.parse_iso("2026-12-01") or stop "dt1"
  r1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Cluster Upgrade"),
            "status": SelectVal(option_id: "planned"),
            "amount": NumberVal(d100),
            "due": DateVal(start: dt1, end_date: None),
            "done": BoolVal(true),
            "notes": TextVal("NVMe nodes"),
            "tags": MultiSelectVal(option_ids: ["infra"]),
            "owners": PrincipalVal([owner_id]),
            "link": UrlVal("https://vellum.example.com/cluster"),
            "project": RelationVal(row_ids: [proj_row_id]),
            "legacy": TextVal("drop me")
          },
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
          cells: {
            "title": TextVal("CDN Egress"),
            "status": SelectVal(option_id: "active"),
            "amount": NumberVal(d200),
            "done": BoolVal(false)
          },
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

  show_db_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_db_res.status == 200
  show_db_j = must_json(show_db_res.text)
  assert (show_db_j.list_at("principals") or []).size >= 1
  rel_list = show_db_j.list_at("relation_targets.#{proj_db_id}") or []
  assert rel_list.size == 1
  assert (show_db_j.list_at("scenarios") or []).empty?
  assert show_db_res.text.contains?("500")

  # Re-create BoardView grouped by "status", verify removing "status" fails 422, adding required prop fails 422, removing "legacy" succeeds cleanly
  create_board2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "By Status",
          kind: BoardView(
            group_by_prop_id: "status",
            card_prop_ids: ["amount"],
            hide_empty_groups: false
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
  assert create_board2.status == 201
  board_vw2_id = must_json(create_board2.text).text_at("id") or stop "board_vw2_id"

  props_no_status = evolved_props.filter(fn(p) p.id != "status" end)
  drop_grouped_col = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some(props_no_status),
          expected_version: 2
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert drop_grouped_col.status == 422

  props_with_req = evolved_props.append(
    PropertyDef(id: "cost_center", name: "Cost Center", kind: RichText, required: true, sort_order: "z")
  )
  add_req_col = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some(props_with_req),
          expected_version: 2
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert add_req_col.status == 422

  props_no_legacy = evolved_props.filter(fn(p) p.id != "legacy" end)
  drop_legacy = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some(props_no_legacy),
          expected_version: 2
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert drop_legacy.status == 200
  assert must_json(drop_legacy.text).int_at("version") == Some(3)

  show_after_drop = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_after_drop.status == 200
  assert not show_after_drop.text.contains?("drop me")

  # 4. Mint scoped agent WITHOUT manage_schema
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@scen_bot"),
          "display_name": Json.String("Scenario Bot"),
          "model_id": Json.String("claude-sonnet-4-6"),
          "label": Json.String("scen-bot"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("propose"),
            Json.String("query_db"),
            Json.String("write_db"),
            Json.String("publish")
          ]),
          "allowed_collections": Json.Array([Json.String(Db.default_collection_id)]),
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
  bot_tok = must_json(mint_res.text).text_at("raw_token") or stop "bot_tok"
  bot_agent = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{bot_tok}"
  )

  # 5. Fork What-If Scenario and stage multi-resource mutations (row update + create + delete + schema update + wiki page patch)
  scen_open = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/scenarios").with_json(
        Json.Object({
          "title": Json.String("Q4 Cut Plan"),
          "reason": Json.String("Model 33% spend reduction across DB and memo")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen_open.status == 201
  scen_id = must_json(scen_open.text).text_at("id") or stop "scen_id"

  mut_update = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_row_update"),
          "database_id": Json.String(db_id),
          "row_id": Json.String(r1_id),
          "cells": Json.Object({
            "amount": Json.Object({"number_val": Json.String("150.30")})
          }),
          "expected_version": Json.int(1),
          "reason": Json.String("Expand cluster budget slightly")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_update.status == 200

  mut_create = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_row_create"),
          "database_id": Json.String(db_id),
          "cells": Json.Object({
            "title": Json.Object({"text_val": Json.String("Cache Tier")}),
            "status": Json.Object({"select_val": Json.Object({"option_id": Json.String("planned")})}),
            "amount": Json.Object({"number_val": Json.String("49.90")})
          }),
          "reason": Json.String("Add low-cost cache tier")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_create.status == 200
  created_scen_row_id = must_json(mut_create.text).text_at("step_reply.row_id") or stop "created_scen_row_id"

  mut_delete = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_row_delete"),
          "database_id": Json.String(db_id),
          "row_id": Json.String(r2_id),
          "reason": Json.String("Defer CDN migration")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_delete.status == 200

  props_plus_risk = props_no_legacy.append(
    PropertyDef(id: "risk_note", name: "Risk Note", kind: RichText, required: false, sort_order: "m")
  )
  mut_schema = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_schema_update"),
          "database_id": Json.String(db_id),
          "properties": props_plus_risk.to_json,
          "expected_version": Json.int(3),
          "reason": Json.String("Track risk note column")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_schema.status == 200

  mut_page = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("page_patch"),
          "page_id": Json.String(wiki_pg_id),
          "ops": [
            ReplaceBlock(
              block_id: wiki_blk_id,
              expected_version: 1,
              kind: None,
              markdown: "Scenario updated cap to $200.20."
            )
          ].to_json,
          "expected_versions": Json.Object({wiki_blk_id: Json.int(1)}),
          "reason": Json.String("Align Q4 Budget Memo with What-If Scenario")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_page.status == 200

  # Verify Live DB & Live Wiki page are untouched while Scenario is open
  live_db_check = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  live_db_j = must_json(live_db_check.text)
  assert live_db_j.int_at("database.version") == Some(3)
  assert (live_db_j.list_at("rows") or []).size == 2
  assert (live_db_j.list_at("scenarios") or []).size == 1

  live_pg_check = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{wiki_pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert live_pg_check.text.contains?("Live quarterly cap is $300.30.")
  assert not live_pg_check.text.contains?("Scenario updated cap to $200.20.")

  # Query Scenario + inspect exact Decimal deltas & row_changes
  scen_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/scenarios/#{scen_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(board_vw2_id),
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
  assert scen_q.status == 200
  scen_qj = must_json(scen_q.text)
  assert scen_qj.int_at("live_row_count") == Some(2)
  assert scen_qj.int_at("scenario_row_count") == Some(2)
  assert scen_qj.bool_at("schema_changed") == Some(true)
  assert scen_qj.int_at("step_count") == Some(5)
  assert (scen_qj.list_at("removed_rows") or []).size == 1
  assert scen_qj.text_at("row_changes.#{r1_id}") == Some("modified")
  assert scen_qj.text_at("row_changes.#{created_scen_row_id}") == Some("added")
  assert (scen_qj.list_at("query_result.board_groups") or []).size >= 2

  deltas_arr = scen_qj.list_at("deltas") or []
  amount_delta = deltas_arr.filter(fn(d) d.text_at("prop_id") == Some("amount") end).first or stop "amount_delta"
  live_tot = (amount_delta.text_at("live_total") or "").to_decimal or stop "live_tot"
  scen_tot = (amount_delta.text_at("scenario_total") or "").to_decimal or stop "scen_tot"
  diff_tot = (amount_delta.text_at("delta") or "").to_decimal or stop "diff_tot"
  exp_live = "300.30".to_decimal or stop "exp_live"
  exp_scen = "200.20".to_decimal or stop "exp_scen"
  exp_diff = "-100.10".to_decimal or stop "exp_diff"
  assert live_tot == exp_live
  assert scen_tot == exp_scen
  assert diff_tot == exp_diff

  # Multi-resource diff inspection
  scen_diff = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{scen_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen_diff.status == 200
  scen_diff_j = must_json(scen_diff.text)
  assert (scen_diff_j.list_at("block_diffs") or []).size == 1
  assert (scen_diff_j.list_at("db_row_diffs") or []).size == 3
  assert (scen_diff_j.list_at("db_schema_diffs") or []).size == 1
  assert (scen_diff_j.list_at("rollup_deltas") or []).size >= 1
  assert (scen_diff_j.list_at("bucket_diffs") or []).size >= 1

  # Agent without manage_schema is denied accepting schema-touching scenario (403)
  bot_accept = ApiTest.send(
    Main,
    WebTest.prepare(bot_agent, Api.post("/api/proposals/#{scen_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bot_accept.status == 403

  # Fork a second Scenario, reject it, and confirm GET /diff still returns 200 cleanly
  scen2_open = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/scenarios").with_json(
        Json.Object({"title": Json.String("Discard Me"), "reason": Json.String("Test reject cleanup")})
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen2_open.status == 201
  scen2_id = must_json(scen2_open.text).text_at("id") or stop "scen2_id"
  scen2_rej = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{scen2_id}/reject")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen2_rej.status == 200
  scen2_diff = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{scen2_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen2_diff.status == 200
  assert must_json(scen2_diff.text).text_at("proposal.status") == Some("rejected")

  # Owner accepts Scenario 1 -> ALL DB row changes, schema change, AND wiki page edit land atomically!
  owner_accept = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{scen_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert owner_accept.status == 200

  landed_db_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert landed_db_res.status == 200
  landed_db_j = must_json(landed_db_res.text)
  assert landed_db_j.int_at("database.version") == Some(4)
  assert landed_db_res.text.contains?("Risk Note")
  assert landed_db_res.text.contains?("Cache Tier")
  r1_row_j = (landed_db_j.list_at("rows") or []).filter(fn(er)
    er.text_at("row.id") == Some(r1_id)
  end).first or stop "landed r1"
  r1_amt_dec = (r1_row_j.text_at("row.cells.amount.number_val") or "").to_decimal or stop "r1_amt_dec"
  exp_150 = "150.30".to_decimal or stop "exp_150"
  assert r1_amt_dec == exp_150
  assert not landed_db_res.text.contains?("CDN Egress")

  landed_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{wiki_pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert landed_pg_res.status == 200
  assert landed_pg_res.text.contains?("Scenario updated cap to $200.20.")

  # 6. Concurrent modification conflict check on Scenario land
  scen3_open = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/scenarios").with_json(
        Json.Object({
          "title": Json.String("Stale Update"),
          "reason": Json.String("Verify optimistic lock on land")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen3_open.status == 201
  scen3_id = must_json(scen3_open.text).text_at("id") or stop "scen3_id"

  mut3 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen3_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_row_update"),
          "database_id": Json.String(db_id),
          "row_id": Json.String(r1_id),
          "cells": Json.Object({
            "amount": Json.Object({"number_val": Json.String("999.00")})
          }),
          "expected_version": Json.int(2),
          "reason": Json.String("Scenario wants 999")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut3.status == 200

  # Conflicting direct write on Live bumps r1 version 2 -> 3
  d777 = "777.00".to_decimal or stop "d777"
  live_bump = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{db_id}/rows/#{r1_id}").with_json(
        Databases.UpdateRowInput(
          cells: {"amount": NumberVal(d777)},
          expected_version: 2,
          reason: Some("Direct live override")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert live_bump.status == 200

  conflict_accept = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{scen3_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert conflict_accept.status == 409 or conflict_accept.status == 422

  after_conflict_db = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert after_conflict_db.text.contains?("777")
  assert not after_conflict_db.text.contains?("999")
end

test "Vellum Phase 1.3: Blueprints CRUD + meta FTS/YAML, DatabaseViewEmbed + MoveBlock, Markdown reconciliation + 409, live metrics + Scenario deltas + fail-closed ACL, Block context"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p13.js",
        "css": ["assets/main-p13.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p13.js": "console.log('p13');",
    "public/assets/main-p13.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261128)
  t0 = Time.parse("2026-11-28T10:00:00Z") or stop "t0"
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

  # 1. Blueprints CRUD (POST, GET, PUT with optimistic concurrency)
  opt_open = SelectOption(id: "open", label: "OpenStatus", color: Amber)
  opt_approved = SelectOption(id: "approved", label: "ApprovedLabel", color: Green)
  bp_create = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/blueprints").with_json(
        Workspace.CreateBlueprintInput(
          slug: "decision-record",
          name: "Decision Record",
          description: Some("Engineering & finance decisions"),
          icon: Some("scale"),
          fields: [
            PropertyDef(
              id: "status",
              name: "Status",
              kind: Select(options: [opt_open, opt_approved]),
              required: true,
              sort_order: "a"
            ),
            PropertyDef(
              id: "budget",
              name: "Budget",
              kind: Number(format: "currency"),
              required: false,
              sort_order: "b"
            )
          ],
          default_template_markdown: Some("## Context\n\n## Decision")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bp_create.status == 201
  bp_id = must_json(bp_create.text).text_at("id") or stop "bp_id"

  bp_list = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/blueprints")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bp_list.status == 200
  assert bp_list.text.contains?("decision-record")

  bp_upd = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/blueprints/#{bp_id}").with_json(
        Workspace.UpdateBlueprintInput(
          slug: None,
          name: Some("Architecture Decision"),
          description: None,
          icon: None,
          fields: None,
          default_template_markdown: None,
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
  assert bp_upd.status == 200
  assert must_json(bp_upd.text).int_at("version") == Some(2)

  bp_stale = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/blueprints/#{bp_id}").with_json(
        Workspace.UpdateBlueprintInput(
          slug: None,
          name: Some("Stale"),
          description: None,
          icon: None,
          fields: None,
          default_template_markdown: None,
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
  assert bp_stale.status == 409

  # 2. Create Document page -> validation + attach blueprint meta + FTS search + detach + re-attach
  pg_create = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Zero Downtime Failover"),
          "markdown": Json.String(""),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create empty page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_create.status == 201
  pg_id = must_json(pg_create.text).text_at("page.id") or stop "pg_id"

  # Missing required "status" returns 400
  d250 = "250.50".to_decimal or stop "d250"
  meta_missing_req = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/meta").with_json(
        Workspace.SetPageMetaInput(
          blueprint_id: Some(bp_id),
          values: Some({"budget": NumberVal(d250)}),
          apply_template_if_empty: Some(true),
          reason: Some("missing status")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert meta_missing_req.status == 422

  meta_attach = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/meta").with_json(
        Workspace.SetPageMetaInput(
          blueprint_id: Some(bp_id),
          values: Some({"status": SelectVal(option_id: "approved"), "budget": NumberVal(d250)}),
          apply_template_if_empty: Some(true),
          reason: Some("attach decision record")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert meta_attach.status == 200
  meta_attach_j = must_json(meta_attach.text)
  assert meta_attach_j.text_at("page_blueprint.id") == Some(bp_id)
  assert (meta_attach_j.text_at("yaml_frontmatter") or "") != ""
  assert (meta_attach_j.text_at("yaml_frontmatter") or "").contains?("blueprint: \"decision-record\"")
  assert (meta_attach_j.text_at("yaml_frontmatter") or "").contains?("  status: \"approved\"")
  assert (meta_attach_j.text_at("anchored_markdown") or "").contains?("## Context")

  # FTS finds the page via structured Select option label "ApprovedLabel"
  search_meta = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=ApprovedLabel")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert search_meta.status == 200
  assert search_meta.text.contains?(pg_id)

  # Detach blueprint cleanly and re-attach
  meta_detach = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/meta").with_json(
        Workspace.SetPageMetaInput(
          blueprint_id: None,
          values: None,
          apply_template_if_empty: None,
          reason: Some("detach test")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert meta_detach.status == 200
  assert must_json(meta_detach.text).get("page_meta") == Some(Json.Null)

  meta_reattach = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/meta").with_json(
        Workspace.SetPageMetaInput(
          blueprint_id: Some(bp_id),
          values: Some({"status": SelectVal(option_id: "approved"), "budget": NumberVal(d250)}),
          apply_template_if_empty: Some(false),
          reason: Some("re-attach decision record")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert meta_reattach.status == 200

  # 3. Create Q4 Costs DB + 2 rows + DatabaseViewEmbed + MoveBlock
  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Q4 Costs",
          description: Some("Infra spend"),
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
  db_j = must_json(db_res.text)
  db_id = db_j.text_at("database.id") or stop "db_id"
  vw_id = db_j.text_at("default_view.id") or stop "vw_id"

  c1 = "100.25".to_decimal or stop "c1"
  c2 = "49.75".to_decimal or stop "c2"
  row1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Primary Cluster"), "cost": NumberVal(c1)},
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
  assert row1_res.status == 201
  row1_id = must_json(row1_res.text).text_at("row.id") or stop "row1_id"

  row2_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Replica Pool"), "cost": NumberVal(c2)},
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
  assert row2_res.status == 201

  # Insert DatabaseViewEmbed block
  ins_embed = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{pg_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            InsertBlockAfter(
              after_block_id: None,
              parent_block_id: None,
              kind: DatabaseViewEmbed(database_id: db_id, view_id: Some(vw_id)),
              markdown: ""
            )
          ],
          expected_versions: {},
          reason: Some("embed costs DB")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert ins_embed.status == 200
  ins_blks = must_json(ins_embed.text).list_at("blocks") or []
  assert ins_blks.size == 3
  embed_blk_id = (ins_blks.get(0) or Json.Null).text_at("id") or stop "embed_blk_id"
  last_blk_id = (ins_blks.get(2) or Json.Null).text_at("id") or stop "last_blk_id"

  # Move embed block to the end via MoveBlock
  move_embed = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{pg_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [MoveBlock(block_id: embed_blk_id, new_parent_id: None, after_block_id: Some(last_blk_id))],
          expected_versions: {},
          reason: Some("move embed to end")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert move_embed.status == 200

  pg_show = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_show.status == 200
  pg_show_j = must_json(pg_show.text)
  assert (pg_show_j.text_at("anchored_markdown") or "").contains?("<!-- db_embed:#{db_id}|#{vw_id} -->")
  assert pg_show_j.get("blueprints") != None
  assert pg_show_j.get("principals") != None
  assert pg_show_j.get("page_audit") != None
  cur_pg_ver = pg_show_j.int_at("page.version") or stop "cur_pg_ver"

  show_blks = pg_show_j.list_at("blocks") or []
  b0_j = show_blks.get(0) or Json.Null
  b1_j = show_blks.get(1) or Json.Null
  b0_id = b0_j.text_at("id") or stop "b0_id"
  b0_ver = b0_j.int_at("version") or stop "b0_ver"
  b0_prov = b0_j.get("provenance") or Json.Null
  b1_id = b1_j.text_at("id") or stop "b1_id"
  b1_ver = b1_j.int_at("version") or stop "b1_ver"
  b0_md = b0_j.text_at("markdown") or ""

  # 4. Markdown Lens sync preserves unchanged block ID/version/provenance and rejects stale page version
  tok_sum = "{{metric:#{db_id}.cost:sum}}"
  tok_cnt = "{{metric:#{db_id}.cost:count}}"
  tok_avg = "{{metric:#{db_id}.cost:avg}}"
  synced_md = "---\ntitle: \"Ignored Frontmatter\"\n---\n\n<!-- blk:#{b0_id} -->\n## #{b0_md}\n\n<!-- blk:#{b1_id} -->\nTotal: #{tok_sum} across #{tok_cnt} items (avg #{tok_avg})\n\n<!-- blk:#{embed_blk_id} -->\n<!-- db_embed:#{db_id}|#{vw_id} -->"

  md_sync = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/markdown").with_json(
        Workspace.SyncPageMarkdownInput(
          markdown: synced_md,
          expected_page_version: cur_pg_ver,
          reason: Some("edit decision summary via markdown lens")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert md_sync.status == 200
  md_sync_j = must_json(md_sync.text)
  synced_blks = md_sync_j.list_at("blocks") or []
  assert synced_blks.size == 3
  nb0 = synced_blks.get(0) or Json.Null
  nb1 = synced_blks.get(1) or Json.Null
  assert nb0.text_at("id") == Some(b0_id)
  assert nb0.int_at("version") == Some(b0_ver)
  assert nb0.get("provenance") == Some(b0_prov)
  assert nb1.text_at("id") == Some(b1_id)
  assert nb1.int_at("version") == Some(b1_ver + 1)

  # Stale expected_page_version returns 409 Conflict
  md_stale = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/markdown").with_json(
        Workspace.SyncPageMarkdownInput(markdown: synced_md, expected_page_version: cur_pg_ver, reason: None)
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert md_stale.status == 409

  # 5. Resolve live metrics (sum, count, avg) + Scenario delta + fail-closed agent ACL
  m_live = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/metrics/resolve").with_json(
        Workspace.ResolveMetricsInput(tokens: [tok_sum, tok_cnt, tok_avg], scenario_id: None)
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert m_live.status == 200
  m_live_j = must_json(m_live.text).get("metrics") or Json.Null
  assert (m_live_j.get(tok_sum) or Json.Null).text_at("status") == Some("ok")
  assert ((m_live_j.get(tok_sum) or Json.Null).text_at("value") or "").to_decimal == ("150".to_decimal)
  assert (m_live_j.get(tok_cnt) or Json.Null).text_at("value") == Some("2")
  assert ((m_live_j.get(tok_avg) or Json.Null).text_at("value") or "").to_decimal == ("75".to_decimal)

  # Open Scenario and stage row update (+100.25)
  scen_open = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/scenarios").with_json(
        Json.Object({
          "title": Json.String("HA Standby Expansion"),
          "reason": Json.String("Model additional cluster cost")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen_open.status == 201
  scen_id = must_json(scen_open.text).text_at("id") or stop "scen_id"

  scen_mut = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_row_update"),
          "database_id": Json.String(db_id),
          "row_id": Json.String(row1_id),
          "cells": Json.Object({
            "cost": Json.Object({"number_val": Json.String("200.50")})
          }),
          "expected_version": Json.int(1),
          "reason": Json.String("Upgrade primary cluster")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen_mut.status == 200

  m_scen = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/metrics/resolve").with_json(
        Workspace.ResolveMetricsInput(tokens: [tok_sum], scenario_id: Some(scen_id))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert m_scen.status == 200
  m_scen_tok = (must_json(m_scen.text).get("metrics") or Json.Null).get(tok_sum) or Json.Null
  assert (m_scen_tok.text_at("live_value") or "").to_decimal == ("150".to_decimal)
  assert (m_scen_tok.text_at("scenario_value") or "").to_decimal == ("250.25".to_decimal)
  assert (m_scen_tok.text_at("delta") or "").to_decimal == ("100.25".to_decimal)

  # Mint agent restricted to secret-ops collection only
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

  mint_sec = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@isolated_bot"),
          "display_name": Json.String("Isolated Bot"),
          "model_id": Json.String("claude-sonnet-4-6"),
          "label": Json.String("isolated"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(sec_col_id)]),
          "max_calls": Json.int(20),
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
  assert mint_sec.status == 201
  iso_tok = must_json(mint_sec.text).text_at("raw_token") or stop "iso_tok"
  iso_agent = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{iso_tok}"
  )

  # Fail-closed metric check: no data leak across collections
  m_iso = ApiTest.send(
    Main,
    WebTest.prepare(
      iso_agent,
      Api.post("/api/metrics/resolve").with_json(
        Workspace.ResolveMetricsInput(tokens: [tok_sum], scenario_id: None)
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert m_iso.status == 200
  m_iso_tok = (must_json(m_iso.text).get("metrics") or Json.Null).get(tok_sum) or Json.Null
  assert m_iso_tok.text_at("status") == Some("forbidden")
  assert m_iso_tok.get("value") == Some(Json.Null)
  assert m_iso_tok.get("database_title") == Some(Json.Null)
  assert m_iso_tok.int_at("row_count") == Some(0)

  # 6. GET /api/blocks/:block_id returns context to owner (200) and denies cross-collection agent (403)
  blk_ok = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/blocks/#{b1_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert blk_ok.status == 200
  blk_ok_j = must_json(blk_ok.text)
  assert blk_ok_j.text_at("block.id") == Some(b1_id)
  assert blk_ok_j.text_at("page.id") == Some(pg_id)
  assert blk_ok_j.text_at("prev_block.id") == Some(b0_id)
  assert blk_ok_j.text_at("next_block.id") == Some(embed_blk_id)

  blk_denied = ApiTest.send(
    Main,
    WebTest.prepare(iso_agent, Api.get("/api/blocks/#{b1_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert blk_denied.status == 403

  # 7. Ledger invariant verification (8 invariants including blueprint_valid, page_meta_integrity, and pack_valid)
  ver_res = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) Ledger.verify_all(db).map_error(Db.map_ledger_error) end
  )
  case ver_res
    Ok(rep): assert rep.invariants_checked == 9
    Error(_): assert false
  end
end

