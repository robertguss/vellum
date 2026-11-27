## Vellum v3 Milestone 2 Slice 2.2 Integration Tests:
## Google Workspace OIDC Preset (&hd= + verified email + domain allowlist),
## Configurable VELLUM_SESSION_TTL_SECONDS expiry, and Extended PII
## Detection + Modb.Erasure Crypto-Purge across Document Pages & Database Rows.
module Tests.V3m2b
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Db
use Domain.DatabaseModel{CellValue, PropertyDef, PropertyKind}
use Http
use Json
use Modb.Ledger
use Routes.Auth
use Routes.Databases
use Routes.Workspace

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
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

fn full_set_cookie(res: Api.Response, name: Text) : Text
  for h in res.headers_named("Set-Cookie")
    if h.starts_with?("#{name}=")
      return h
    end
  end
  stop "missing Set-Cookie header"
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

fn build_google_callback_mocks(
  oidc_cfg: Oidc.OidcConfig,
  oidc_start: Api.Response,
  key_bytes: Bytes,
  sub: Text,
  email: Text,
  verified?: Bool,
  display_name: Text,
  code: Text
) : (Text, Http.Request, Text, Http.Request, Text)
  loc = oidc_start.header("Location") or stop "missing Location"
  q_params = Api.request("GET", loc).query
  oidc_state = q_params.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or stop "state"
  oidc_nonce = q_params.find(fn(p) p.0 == "nonce" end).map(fn(p) p.1 end) or stop "nonce"
  verifier = unseal_oidc_code_verifier(oidc_start, "vellum_oidc_state", key_bytes)
  id_jwt = Oidc.build_unsigned_test_jwt(
    Json.Object({
      "iss": Json.String("https://accounts.google.com"),
      "aud": Json.String("vellum-google-client"),
      "sub": Json.String(sub),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String(email),
      "email_verified": Json.Boolean(verified?)
    })
  )
  tok_body = Json.Object({
    "access_token": Json.String("at_#{sub}"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String(sub),
    "email": Json.String(email),
    "email_verified": Json.Boolean(verified?),
    "name": Json.String(display_name)
  }).to_text
  ui_url = oidc_cfg.endpoints.userinfo_endpoint or stop "missing userinfo endpoint"
  tok_req = Oidc.token_exchange_request(oidc_cfg, code, verifier)
  ui_req = Oidc.userinfo_request(ui_url, "at_#{sub}")
  (oidc_state, tok_req, tok_body, ui_req, ui_body)
end

test "v3 M2.2: Google OIDC preset, configurable TTL expiry & Modb.Erasure PII purge across pages and DB rows"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m2b.js",
        "css": ["assets/main-v3m2b.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m2b.js": "console.log('v3m2b');",
    "public/assets/main-v3m2b.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261221)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-12-10T10:00:00Z") or stop "t0"
  t_expired = Time.parse("2026-12-10T11:00:01Z") or stop "t_expired"
  clock = Clock.fixed(t0)
  clock_expired = Clock.fixed(t_expired)
  empty_net = Network.fake(Http.replies([]))

  # Omit VELLUM_AI_* so local sketch vectors require zero external HTTP calls;
  # omit manual VELLUM_OIDC_ISSUER/AUTH_URL/TOKEN_URL/USERINFO_URL/JWKS_URI to verify Google preset.
  env = Env.of({
    "VELLUM_SECRET_KEY": key_hex,
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_OIDC_PROVIDER_ID": "google",
    "VELLUM_OIDC_CLIENT_ID": "vellum-google-client",
    "VELLUM_OIDC_CLIENT_SECRET": "google-secret-xyz",
    "VELLUM_OIDC_REDIRECT_URI": "http://localhost:8080/auth/oidc/callback",
    "VELLUM_OIDC_ALLOWED_DOMAINS": "acme.io",
    "VELLUM_OIDC_REQUIRE_VERIFIED_EMAIL": "1",
    "VELLUM_SESSION_TTL_SECONDS": "3600"
  })

  # 1. Verify Google Workspace OIDC preset endpoints & JWKS URI without manual overrides
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "Auth.oidc_config failed for google preset"
  end
  assert oidc_cfg.endpoints.issuer == "https://accounts.google.com"
  assert oidc_cfg.endpoints.jwks_uri != None
  assert oidc_cfg.endpoints.userinfo_endpoint != None

  # 2. /auth/oidc/login emits single Location header targeting Google OAuth + hd=acme.io
  guest_unver = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_unver = ApiTest.send(
    Main,
    WebTest.prepare(guest_unver, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert start_unver.status == 302
  locs = start_unver.headers_named("Location")
  assert locs.size == 1
  auth_loc = locs.first or stop "Location"
  assert auth_loc.starts_with?("https://accounts.google.com/o/oauth2/v2/auth")
  assert auth_loc.contains?("hd=acme.io")

  # 3. Fail closed when email_verified=false (403)
  (st_u, treq_u, tbody_u, ureq_u, ubody_u) = build_google_callback_mocks(
    oidc_cfg,
    start_unver,
    key_bytes,
    "sub_ada_unverified",
    "ada@acme.io",
    false,
    "Ada Unverified",
    "code_unver"
  )
  net_u = Network.fake(
    Http.replies([(treq_u, Http.reply(200, tbody_u)), (ureq_u, Http.reply(200, ubody_u))])
  )
  cb_unver = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.absorb(guest_unver, start_unver),
      Api.get("/auth/oidc/callback?code=code_unver&state=#{st_u}")
    ),
    files,
    clock,
    env,
    rng,
    net_u
  )
  assert cb_unver.status == 403

  # 4. Fail closed when email domain is outside VELLUM_OIDC_ALLOWED_DOMAINS (403)
  guest_dom = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_dom = ApiTest.send(
    Main,
    WebTest.prepare(guest_dom, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert start_dom.status == 302
  (st_d, treq_d, tbody_d, ureq_d, ubody_d) = build_google_callback_mocks(
    oidc_cfg,
    start_dom,
    key_bytes,
    "sub_intruder",
    "intruder@gmail.com",
    true,
    "Outside User",
    "code_dom"
  )
  net_d = Network.fake(
    Http.replies([(treq_d, Http.reply(200, tbody_d)), (ureq_d, Http.reply(200, ubody_d))])
  )
  cb_dom = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.absorb(guest_dom, start_dom),
      Api.get("/auth/oidc/callback?code=code_dom&state=#{st_d}")
    ),
    files,
    clock,
    env,
    rng,
    net_d
  )
  assert cb_dom.status == 403

  # 5. Verified @acme.io user succeeds (303), receives Max-Age=3600 cookie, valid at t0, expired at t0+3601s
  guest_ok = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_ok = ApiTest.send(
    Main,
    WebTest.prepare(guest_ok, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert start_ok.status == 302
  (st_ok, treq_ok, tbody_ok, ureq_ok, ubody_ok) = build_google_callback_mocks(
    oidc_cfg,
    start_ok,
    key_bytes,
    "sub_ada_google",
    "ada@acme.io",
    true,
    "Ada Lovelace",
    "code_ok"
  )
  net_ok = Network.fake(
    Http.replies([(treq_ok, Http.reply(200, tbody_ok)), (ureq_ok, Http.reply(200, ubody_ok))])
  )
  guest_ok_cb = WebTest.absorb(guest_ok, start_ok)
  cb_ok = ApiTest.send(
    Main,
    WebTest.prepare(guest_ok_cb, Api.get("/auth/oidc/callback?code=code_ok&state=#{st_ok}")),
    files,
    clock,
    env,
    rng,
    net_ok
  )
  assert cb_ok.status == 303
  assert full_set_cookie(cb_ok, "vellum_session").contains?("Max-Age=3600")
  owner = WebTest.absorb(guest_ok_cb, cb_ok)

  session_live = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/audit")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert session_live.status == 200

  session_expired = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/audit")),
    files,
    clock_expired,
    env,
    rng,
    empty_net
  )
  assert session_expired.status == 401

  # 6. Seed extended PII in both a Document page (SSN + Student ID) and a Database row (ABA Routing + Luhn Card)
  ssn_tok = "214-88-4321"
  stu_tok = "STU-90123456"
  aba_tok = "021000021"
  card_tok = "4532-1111-2222-3336"

  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Synthetic Intake Record",
          markdown: "Applicant SSN #{ssn_tok} and campus ID #{stu_tok} under review.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed PII document page")
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

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Payroll Audit Rows",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "notes",
              name: "Notes",
              kind: RichText,
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

  row_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Acme Vendor Disbursement"),
            "notes": TextVal("Routing ##{aba_tok} and corporate card #{card_tok}")
          },
          markdown: None,
          reason: Some("seed PII database row")
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

  # 7. Admin erasure/status detects all 4 extended PII classes without exposing raw tokens
  st_before = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/erasure/status")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert st_before.status == 200
  assert not st_before.text.contains?(ssn_tok)
  assert not st_before.text.contains?(stu_tok)
  assert not st_before.text.contains?(aba_tok)
  assert not st_before.text.contains?(card_tok)
  findings = must_json(st_before.text).list_at("findings") or []
  kinds = findings.map(fn(f) f.text_at("kind") or "" end)
  assert kinds.contains?("us_ssn")
  assert kinds.contains?("student_id")
  assert kinds.contains?("bank_routing")
  assert kinds.contains?("payment_card")

  # 8. Workspace-wide Modb.Erasure purge (redact + compact) scrubs both Document blocks and DB row cells
  purge_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/erasure/purge").with_json(
        Json.Object({
          "mode": Json.String("redact"),
          "compact": Json.Boolean(true),
          "reason": Json.String("Purge synthetic PII #{ssn_tok} and #{aba_tok}")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert purge_res.status == 200
  assert not purge_res.text.contains?(ssn_tok)
  assert not purge_res.text.contains?(stu_tok)
  assert not purge_res.text.contains?(aba_tok)
  assert not purge_res.text.contains?(card_tok)
  pj = must_json(purge_res.text)
  assert pj.bool_at("receipt.key_shredded") == Some(true)
  assert pj.bool_at("receipt.compacted") == Some(true)
  assert (pj.int_at("blocks_redacted") or 0) >= 3

  # 9. Verify redacted Document page, redacted DB row cells, 0 search hits, 0 findings, and clean disk bytes
  pg_after = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_after.status == 200
  assert (must_json(pg_after.text).text_at("anchored_markdown") or "").contains?("[REDACTED]")
  assert not pg_after.text.contains?(ssn_tok)
  assert not pg_after.text.contains?(stu_tok)

  db_after = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/databases/#{db_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert db_after.status == 200
  assert db_after.text.contains?("[REDACTED]")
  assert not db_after.text.contains?(aba_tok)
  assert not db_after.text.contains?(card_tok)

  for q in [ssn_tok, stu_tok, aba_tok, card_tok]
    sres = ApiTest.send(
      Main,
      WebTest.prepare(owner, Api.get("/api/search?q=#{q}")),
      files,
      clock,
      env,
      rng,
      empty_net
    )
    assert sres.status == 200
    assert (must_json(sres.text).list_at("results") or []).size == 0
  end

  clean_search = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=Intake")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clean_search.status == 200
  assert (must_json(clean_search.text).list_at("results") or []).any?(fn(r)
    r.text_at("page_id") == Some(pg_id)
  end)

  st_after = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/erasure/status")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert st_after.status == 200
  assert (must_json(st_after.text).list_at("findings") or []).size == 0
  assert (must_json(st_after.text).list_at("receipts") or []).size == 1

  assert Ledger.open(files, Db.ledger_db_path, Db.vellum_schema(), t0) is Ok(vdb)
  assert Ledger.verify_all(vdb) is Ok(_)
  raw_disk = case files.read_only.read_bytes(Db.ledger_db_path)
    Ok(b): b
    Error(_): stop "read raw disk"
  end
  raw_hex = raw_disk.to_hex
  for tok in [ssn_tok, stu_tok, aba_tok, card_tok]
    assert not raw_hex.contains?(tok.bytes.to_hex)
  end
end
