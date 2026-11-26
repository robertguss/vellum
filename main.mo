## Vellum — AI-Native Collaborative Knowledge Base built with Mo, 100% Pure MoDB, and Arvo.
module Main
use Api
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Db
use Domain.Types{AuthContext, BlockKind, BlockOp, CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Auth
use Routes.Workspace

api
  port 8080
  static "/assets" from "public/assets"
  auth AuthContext via Auth.authenticate

  get "/login" Auth.show_login
  get "/auth/oidc/login" Auth.start_oidc_login
  get "/auth/oidc/callback" Auth.oidc_callback
  post "/logout" Auth.post_logout

  get "/" Workspace.home
  get "/c/:slug" Workspace.show_collection
  get "/p/:id" Workspace.show_page

  scope "/api"
    get "/collections/:slug" Workspace.show_collection
    post "/collections" Workspace.create_collection
    get "/pages/:id" Workspace.show_page
    post "/pages" Workspace.create_page
    patch "/pages/:id/blocks" Workspace.patch_blocks
    post "/pages/:id/verify" Workspace.verify_page
    post "/pages/:id/comments" Workspace.create_comment
    get "/search" Workspace.search
    post "/attachments/presign" Workspace.presign_attachment
    post "/attachments/:id/commit" Workspace.commit_attachment
    get "/attachments/:id/download" Workspace.download_attachment
    post "/admin/agents" Workspace.mint_agent_token
    post "/admin/grants/:id/revoke" Workspace.revoke_grant
    get "/audit" Workspace.audit_index
  end

  job "arvo.jobs.drain" Workspace.drain_jobs every 10.seconds

  status Unauthenticated = 401
  status Forbidden(_) = 403
  status Missing(_) = 404
  status Conflict(_) = 409
  status BadInput(_) = 422
  status ServerFailed(_) = 500
end

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

test "end-to-end Vellum Stage 1: static assets, OIDC PKCE, CSRF, surgical BlockOps, 409 conflict, scoped Agent ACL/search, S3 attachments, grant revocation, jobs, and Ledger verify"
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
  expected_version = Inertia.version_from_manifest(manifest_json.bytes)

  rng = SecureRandom.seeded(20261126)
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
    "VELLUM_OIDC_ALLOWED_DOMAINS": "acme.io",
    "VELLUM_S3_ENDPOINT": "https://s3.us-east-1.amazonaws.com",
    "VELLUM_S3_REGION": "us-east-1",
    "VELLUM_S3_BUCKET": "vellum-uploads",
    "VELLUM_S3_ACCESS_KEY_ID": "AKIAEXAMPLE123",
    "VELLUM_S3_SECRET_ACCESS_KEY": "secret-s3-key-xyz"
  })
  empty_net = Network.fake(Http.replies([]))

  # 1. Static asset serving + ETag + 304
  asset_res = ApiTest.send(
    Main,
    Api.get("/assets/main-a1b2c3d4.js"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert asset_res.status == 200
  assert asset_res.header("Content-Type") == Some("text/javascript; charset=utf-8")
  assert asset_res.header("Cache-Control") == Some("public, max-age=31536000, immutable")
  etag = asset_res.header("ETag") or ""
  assert not etag.empty?
  not_mod = ApiTest.send(
    Main,
    Api.get("/assets/main-a1b2c3d4.js").with_header("If-None-Match", etag),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert not_mod.status == 304 and not_mod.body.size == 0

  # 2. Unauthenticated guest redirect on `/` and 401 on `/api/search`; zero DB files created on ReadFiles
  guest = WebTest.new().with_header("Host", "localhost:8080")
  guest_home = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert guest_home.status == 303
  assert WebTest.redirect_location(guest_home) == Some("/login")
  guest_api = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/api/search?q=runbook")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert guest_api.status == 401
  assert not files.exists?(Db.sessions_db_path)
  assert not files.exists?(Db.ledger_db_path)

  login_page_res = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/login")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert login_page_res.status == 200
  login_page = must_page(login_page_res)
  assert login_page.component == "Auth/Login"
  assert login_page.version == expected_version

  # 3. Full OIDC PKCE login + JIT Owner provisioning + dual cookies + HTML XSS escaping + flash clear
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
  assert auth_loc.starts_with?("https://auth.example.com/authorize?")
  assert auth_loc.contains?("code_challenge_method=S256")
  q_params = Api.request("GET", auth_loc).query
  oidc_state = q_params.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or stop "state"
  oidc_nonce = q_params.find(fn(p) p.0 == "nonce" end).map(fn(p) p.1 end) or stop "nonce"
  verifier = unseal_oidc_code_verifier(oidc_start, "vellum_oidc_state", key_bytes)

  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_config failed"
  end
  id_jwt = Oidc.build_unsigned_test_jwt(
    Json.Object({
      "iss": Json.String("https://auth.example.com"),
      "aud": Json.String("vellum-web"),
      "sub": Json.String("sub_ada_1"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("Ada@ACME.IO"),
      "email_verified": Json.Boolean(true)
    })
  )
  tok_body = Json.Object({
    "access_token": Json.String("at_live_1"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String("sub_ada_1"),
    "email": Json.String("Ada@ACME.IO"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Ada <Engineering>"),
    "picture": Json.String("https://cdn.acme.io/ada.png")
  }).to_text
  tok_req = Oidc.token_exchange_request(oidc_cfg, "code_ada_1", verifier)
  ui_req = Oidc.userinfo_request("https://auth.example.com/userinfo", "at_live_1")
  oidc_net = Network.fake(
    Http.replies([(tok_req, Http.reply(200, tok_body)), (ui_req, Http.reply(200, ui_body))])
  )

  guest_with_oidc = WebTest.absorb(guest, oidc_start)
  cb_req = WebTest.prepare(
    guest_with_oidc,
    Api.get("/auth/oidc/callback?code=code_ada_1&state=#{oidc_state}")
  )
  cb_res = ApiTest.send(Main, cb_req, files, clock, env, rng, oidc_net)
  assert cb_res.status == 303
  assert WebTest.redirect_location(cb_res) == Some("/")
  set_cookies = cb_res.headers_named("Set-Cookie")
  assert set_cookies.any?(fn(c) c.starts_with?("vellum_session=") and c.contains?("HttpOnly") end)
  assert set_cookies.any?(fn(c) c.starts_with?("XSRF-TOKEN=") and not c.contains?("HttpOnly") end)

  owner = WebTest.absorb(guest_with_oidc, cb_res)
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
  assert home_res.text.contains?("&lt;Engineering&gt;")
  assert not home_res.text.contains?("<Engineering>")
  home_page = must_page(home_res)
  assert home_page.component == "Workspace/Home"
  assert Json.Object(home_page.props).text_at("auth.role") == Some("owner")
  assert Json.Object(home_page.props).text_at("flash.notice") == Some("Signed in")
  owner_clean = WebTest.absorb(owner, home_res)
  assert WebTest.cookie(owner_clean, "arvo_flash") == None

  # Signed-in visit to `/login` redirects to `/`
  revisit_login = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.get("/login")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert revisit_login.status == 303 and WebTest.redirect_location(revisit_login) == Some("/")

  # 4. CSRF rejection on cookie mutations without X-XSRF-TOKEN
  csrf_bad = ApiTest.send(
    Main,
    WebTest.prepare_without_csrf(
      owner_clean,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "secret-ops",
          name: "Secret Ops",
          description: Some("Restricted security ops"),
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: Some(30)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert csrf_bad.status == 403

  # 5. Collection & page creation + surgical BlockOps + 409 stale conflict + verification + comments
  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "secret-ops",
          name: "Secret Ops",
          description: Some("Restricted security ops"),
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: Some(30)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert col_res.status == 201
  col_json = must_json(col_res.text)
  secret_col_id = col_json.text_at("id") or stop "secret_col_id"

  secret_page_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: secret_col_id,
          parent_page_id: None,
          title: "Secret Key Rotation",
          markdown: "# Keys\n\nRotate the xylophone_secret master token quarterly.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed secret runbook")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert secret_page_res.status == 201
  secret_page_id = must_json(secret_page_res.text).text_at("page.id") or stop "secret_p"

  pub_page_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Incident Runbook",
          markdown: "# Overview\n\nInitial triage steps.\n\n- Check alerts",
          icon: None,
          freshness_ttl_days: Some(90),
          reason: Some("create runbook")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pub_page_res.status == 201
  pub_json = must_json(pub_page_res.text)
  pub_page_id = pub_json.text_at("page.id") or stop "pub_page_id"
  pub_blocks = pub_json.list_at("blocks") or []
  assert pub_blocks.size == 3
  second_blk_id = (pub_blocks.get(1) or Json.Null).text_at("id") or stop "second_blk_id"
  assert (pub_json.text_at("anchored_markdown") or "").contains?("<!-- blk:#{second_blk_id} -->")

  # Surgical block patch + optimistic conflict check
  patch_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.patch("/api/pages/#{pub_page_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: second_blk_id,
              expected_version: 1,
              kind: None,
              markdown: "Updated triage playbook steps."
            ),
            InsertBlockAfter(
              after_block_id: Some(second_blk_id),
              parent_block_id: None,
              kind: Paragraph,
              markdown: "Verify dashboards recover."
            )
          ],
          expected_versions: {second_blk_id: 1},
          reason: Some("refine triage section")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert patch_ok.status == 200
  patch_json = must_json(patch_ok.text)
  assert (patch_json.list_at("blocks") or []).size == 4
  assert (patch_json.text_at("anchored_markdown") or "").contains?("Updated triage playbook steps.")

  stale_patch = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.patch("/api/pages/#{pub_page_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: second_blk_id,
              expected_version: 1,
              kind: None,
              markdown: "Stale overwrite attempt"
            )
          ],
          expected_versions: {second_blk_id: 1},
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
  assert stale_patch.status == 409

  verify_res = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.post("/api/pages/#{pub_page_id}/verify")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert verify_res.status == 200
  assert must_json(verify_res.text).text_at("verified_by") != None

  cmt_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.post("/api/pages/#{pub_page_id}/comments").with_json(
        Workspace.CreateCommentInput(
          block_id: Some(second_blk_id),
          parent_comment_id: None,
          body_markdown: "Looks clear for on-call!"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cmt_res.status == 201

  # 6. Scoped Agent token minting + fail-closed collection ACL & BM25 search isolation
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner_clean,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "gardener",
          display_name: "Docs Gardener Bot",
          model_id: Some("claude-sonnet-4-6"),
          label: "general-only-ci",
          allowed_actions: ["read", "comment", "write_direct", "upload_attachment"],
          allowed_collections: Some([Db.default_collection_id]),
          max_calls: 25,
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
  mint_json = must_json(mint_res.text)
  agent_token = mint_json.text_at("raw_token") or stop "raw_token"
  agent_grant_id = mint_json.text_at("grant.id") or stop "grant.id"
  assert agent_token.starts_with?("vlm_ag_")

  agent = WebTest.new().with_header("Authorization", "Bearer #{agent_token}")
  # Allowed on col_general page
  agent_pub = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/pages/#{pub_page_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_pub.status == 200
  # Denied on secret-ops collection & page
  agent_secret_get = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/pages/#{secret_page_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_secret_get.status == 403

  # Search isolation: Owner sees xylophone_secret, Agent gets zero hits
  owner_secret_search = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.get("/api/search?q=xylophone_secret")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert owner_secret_search.status == 200
  assert (must_json(owner_secret_search.text).list_at("results") or []).size == 1

  agent_secret_search = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/search?q=xylophone_secret")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_secret_search.status == 200
  assert (must_json(agent_secret_search.text).list_at("results") or []).empty?

  agent_pub_search = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/search?q=playbook")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_pub_search.status == 200
  assert (must_json(agent_pub_search.text).list_at("results") or []).size == 1

  # 7. S3 Attachment presign -> commit -> 302 download + unauthorized agent 403
  agent_secret_att = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: secret_page_id,
          filename: "secret.png",
          content_type: "image/png",
          size_bytes: 512,
          sha256_hex: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_secret_att.status == 403

  presign_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: pub_page_id,
          filename: "diagram.png",
          content_type: "image/png",
          size_bytes: 2048,
          sha256_hex: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert presign_res.status == 201
  pre_json = must_json(presign_res.text)
  att_id = pre_json.text_at("attachment.id") or stop "att_id"
  upload_url = pre_json.text_at("upload_url") or ""
  assert upload_url.contains?("X-Amz-Algorithm=AWS4-HMAC-SHA256")
  assert upload_url.contains?("X-Amz-Signature=")

  commit_res = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.post("/api/attachments/#{att_id}/commit")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert commit_res.status == 200
  assert must_json(commit_res.text).text_at("status") == Some("ready")

  dl_res = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/attachments/#{att_id}/download")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dl_res.status == 302
  dl_loc = dl_res.header("Location") or ""
  assert dl_loc.contains?("X-Amz-Signature=")
  assert dl_res.header("Cache-Control") == Some("private, no-store")

  # 8. Grant revocation blocks subsequent Agent calls; Ledger verify; Job drain; Logout blocks replay
  rev_res = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.post("/api/admin/grants/#{agent_grant_id}/revoke")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rev_res.status == 200

  after_revoke = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.get("/api/search?q=playbook")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert after_revoke.status == 401

  # Outbox job drain completes queued vellum.page.indexed jobs
  assert ApiTest.run_job(Main, "arvo.jobs.drain", Json.Null, files, clock, env, rng, empty_net) ==
    Ok(Unit)
  jobs_list = Jobs.list_recent(files.read_only, Db.ledger_db_path, 5)
  case jobs_list
    Ok(rows):
      assert not rows.empty?
      assert rows.all?(fn(j) j.state == "completed" end)
    Error(_): stop "expected drained jobs"
  end

  # Cryptographic MoDB Ledger hash-chain + invariant verification
  verify_rep = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e end,
    fn(db) Ledger.verify_all(db) end
  )
  case verify_rep
    Ok(rep):
      assert rep.audit.entry_count >= 10
      assert rep.invariants_checked == 3
    Error(_): stop "Ledger.verify_all failed"
  end

  # Logout clears session & blocks replay
  logout_res = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.post("/logout")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert logout_res.status == 303
  assert WebTest.redirect_location(logout_res) == Some("/login")

  replay_home = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.get("/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert replay_home.status == 303 and WebTest.redirect_location(replay_home) == Some("/login")

  replay_api = ApiTest.send(
    Main,
    WebTest.prepare(owner_clean, Api.get("/api/audit")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert replay_api.status == 401
end
