## Vellum Tests.Phase1a Integration Tests (split for Mo lowering budget).
module Tests.Phase1a
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Json
use Routes.Auth
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

