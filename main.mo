## Vellum — AI-Native Collaborative Knowledge Base built with Mo, 100% Pure MoDB, and Arvo.
module Main
use Api
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.Oidc
use Arvo.WebTest
use Arvo.Webhooks
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
use Domain.NotionImport{NotionCsvImport, NotionPageImport}
use Domain.Types{AuthContext, BlockKind, BlockOp, CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Ai
use Routes.Auth
use Routes.Collab
use Routes.Databases
use Routes.Importer
use Routes.Mcp
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
  get "/d/:id" Databases.show_database
  get "/proposals" Workspace.proposals_page
  get "/admin" Workspace.admin_page
  post "/mcp" Mcp.handle_mcp

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

    get "/databases" Databases.list_databases
    post "/databases" Databases.create_database
    get "/databases/:id" Databases.show_database
    patch "/databases/:id" Databases.update_database_schema
    post "/databases/:id/views" Databases.create_view
    post "/databases/:id/query" Databases.query_database
    post "/databases/:id/rows" Databases.create_row
    patch "/databases/:id/rows/:row_id" Databases.update_row
    delete "/databases/:id/rows/:row_id" Databases.delete_row

    get "/events" Collab.events_stream
    get "/claims" Collab.list_claims
    post "/claims" Collab.acquire_claim
    post "/claims/heartbeat" Collab.heartbeat_claim
    post "/claims/release" Collab.release_claim
    get "/proposals" Collab.list_proposals
    post "/proposals" Collab.open_proposal
    post "/proposals/:id/ops" Collab.stage_proposal_ops
    get "/proposals/:id/diff" Collab.diff_proposal
    post "/proposals/:id/accept" Collab.accept_proposal
    post "/proposals/:id/reject" Collab.reject_proposal
    post "/admin/replay/baseline" Collab.pin_replay_baseline
    post "/admin/replay/simulate" Collab.simulate_replay
    post "/admin/replay/:id/accept" Collab.accept_replay
    post "/admin/replay/:id/discard" Collab.discard_replay
    post "/grants/delegate" Collab.delegate_grant
    get "/webhooks" Collab.list_webhooks
    post "/webhooks" Collab.create_webhook

    post "/import/notion" Importer.import_notion
    post "/ai/ask" Ai.ask_workspace
    post "/ai/draft" Ai.draft_blocks
    get "/admin/garden" Ai.run_garden
  end

  job "arvo.jobs.drain" Workspace.drain_jobs every 10.seconds
  job "vellum.garden" Ai.garden_job every 1.hour

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
      assert rep.invariants_checked == 5
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
    Ok(rep): assert rep.invariants_checked == 5
    Error(_): stop "Ledger.verify_all stage 2 failed"
  end
end

test "end-to-end Vellum Stage 3: /mcp, Claims leases, Modb.World proposals, Modb.Replay selective agent rollback, monotonic Grant delegation, signed Webhooks, and SSE"
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
  rng = SecureRandom.seeded(20261128)
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

  # Owner login via OIDC PKCE
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
      "sub": Json.String("sub_ada_s3"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("ada@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  tok_body = Json.Object({
    "access_token": Json.String("at_s3"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String("sub_ada_s3"),
    "email": Json.String("ada@acme.io"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Ada Lovelace")
  }).to_text
  oidc_net = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, "code_s3", verifier), Http.reply(200, tok_body)),
      (
        Oidc.userinfo_request("https://auth.example.com/userinfo", "at_s3"),
        Http.reply(200, ui_body)
      )
    ])
  )
  cb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.absorb(guest, oidc_start),
      Api.get("/auth/oidc/callback?code=code_s3&state=#{oidc_state}")
    ),
    files,
    clock,
    env,
    rng,
    oidc_net
  )
  assert cb_res.status == 303
  owner = WebTest.absorb(guest, cb_res)

  # 1. Create proposal-gated collection, Page A + Page B, webhook sub, agent token, then pin Replay baseline
  gated_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "gated-docs",
          name: "Gated Architecture Docs",
          description: None,
          icon: None,
          write_policy: ProposalsRequiredForAgents,
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
  assert gated_col_res.status == 201
  gated_col_id = must_json(gated_col_res.text).text_at("id") or stop "gated_col_id"

  page_a_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: gated_col_id,
          parent_page_id: None,
          title: "Gateway Spec",
          markdown: "Original gateway baseline rule.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed page A")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert page_a_res.status == 201
  page_a_json = must_json(page_a_res.text)
  page_a_id = page_a_json.text_at("page.id") or stop "page_a_id"
  page_a_blk_id = ((page_a_json.list_at("blocks") or []).first or Json.Null).text_at("id") or
    stop "page_a_blk"

  page_b_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: gated_col_id,
          parent_page_id: None,
          title: "Runbook Spec",
          markdown: "Original runbook step 1.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed page B")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert page_b_res.status == 201
  page_b_json = must_json(page_b_res.text)
  page_b_id = page_b_json.text_at("page.id") or stop "page_b_id"
  page_b_blk_id = ((page_b_json.list_at("blocks") or []).first or Json.Null).text_at("id") or
    stop "page_b_blk"

  wh_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/webhooks").with_json(
        Collab.CreateWebhookInput(
          collection_id: Some(gated_col_id),
          url: "https://agent.acme.io/hooks/vellum",
          events: ["proposal.opened", "proposal.accepted"]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert wh_res.status == 201
  wh_secret = must_json(wh_res.text).text_at("secret") or stop "wh_secret"
  assert wh_secret.starts_with?("whsec_")

  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "architect-bot",
          display_name: "Architect Bot",
          model_id: Some("claude-sonnet-4-6"),
          label: "mcp-gated-bot",
          allowed_actions: ["read", "comment", "propose", "write_direct", "claim", "delegate"],
          allowed_collections: Some([gated_col_id]),
          max_calls: 40,
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
  agent_tok = mint_json.text_at("raw_token") or stop "agent_tok"
  agent_grant_id = mint_json.text_at("grant.id") or stop "agent_grant_id"
  agent = WebTest.new().with_header("Authorization", "Bearer #{agent_tok}")

  baseline_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/admin/replay/baseline")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert baseline_res.status == 201

  # 2. Agent interacts via Streamable HTTP /mcp: initialize, onboard, resource read, rejected direct write, Claims
  mcp_init = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("initialize")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_init.status == 200 and mcp_init.text.contains?("vellum-mcp")

  mcp_onboard = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(2),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.onboard"),
            "arguments": Json.Object({})
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
  assert mcp_onboard.status == 200
  assert mcp_onboard.text.contains?("gated-docs")

  mcp_res_read = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(3),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://pages/#{page_a_id}")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_res_read.status == 200 and
    mcp_res_read.text.contains?("Original gateway baseline rule.")

  # Direct write rejected in ProposalsRequiredForAgents collection
  mcp_direct_denied = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(4),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.patch_blocks"),
            "arguments": Json.Object({
              "page_id": Json.String(page_a_id),
              "reason": Json.String("try direct write"),
              "ops": Json.Array([
                ReplaceBlock(
                  block_id: page_a_blk_id,
                  expected_version: 1,
                  kind: None,
                  markdown: "Bypass"
                ).to_json
              ]),
              "expected_versions": Json.Object({page_a_blk_id: Json.int(1)})
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
  assert mcp_direct_denied.status == 200
  assert mcp_direct_denied.text.contains?("\"isError\":true")

  # Modb.Claims lease + 409 Conflict when second actor claims same resource + release
  mcp_claim = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(5),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.claim_acquire"),
            "arguments": Json.Object({
              "resource": Json.String("page:#{page_a_id}"),
              "ttl_seconds": Json.int(120),
              "reason": Json.String("drafting gateway update")
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
  assert mcp_claim.status == 200 and mcp_claim.text.contains?("\"isError\":false")

  owner_claim_conflict = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/claims").with_json(
        Collab.AcquireClaimInput(
          resource: "page:#{page_a_id}",
          ttl_seconds: 120,
          world_id: None,
          reason: "competing claim"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert owner_claim_conflict.status == 409

  # 3. Agent opens Proposal A via MCP (or HTTP /api/proposals -> also triggers signed webhook!) & stages ops
  # Open Proposal A via /api/proposals so webhook outbox fires, then stage & diff via /mcp
  prop_a_open = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/proposals").with_json(
        Collab.OpenProposalInput(
          page_id: page_a_id,
          title: "Agent updates Gateway Spec",
          reason: "Update rate limits per RFC"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert prop_a_open.status == 201
  prop_a_json = must_json(prop_a_open.text)
  prop_a_id = prop_a_json.text_at("id") or stop "prop_a_id"
  prop_a_world_id = prop_a_json.text_at("world_id") or stop "prop_a_world_id"

  mcp_stage_a = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(6),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_stage_ops"),
            "arguments": Json.Object({
              "proposal_id": Json.String(prop_a_id),
              "reason": Json.String("Agent edited gateway rule"),
              "ops": Json.Array([
                ReplaceBlock(
                  block_id: page_a_blk_id,
                  expected_version: 1,
                  kind: None,
                  markdown: "Agent revised gateway rule."
                ).to_json
              ]),
              "expected_versions": Json.Object({page_a_blk_id: Json.int(1)})
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
  assert mcp_stage_a.status == 200 and mcp_stage_a.text.contains?("\"isError\":false")

  mcp_diff_a = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(7),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_diff"),
            "arguments": Json.Object({"proposal_id": Json.String(prop_a_id)})
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
  assert mcp_diff_a.status == 200 and mcp_diff_a.text.contains?("vlm_blocks")

  # Live Page A is STILL untouched before acceptance!
  live_a_before = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{page_a_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert live_a_before.status == 200 and
    live_a_before.text.contains?("Original gateway baseline rule.")

  # Verify queued signed webhook + deliver via arvo.jobs.drain
  queued_jobs = case Jobs.list_recent(files.read_only, Db.ledger_db_path, 10)
    Ok(js): js
    Error(_): stop "list jobs"
  end
  wh_job = queued_jobs.find(
    fn(j) j.job_name == "vellum.webhook.deliver" and j.state == "pending" end
  ) or
    stop "missing webhook job"
  wh_json = must_json(wh_job.payload_json)
  wh_url = wh_json.text_at("url") or stop "wh url"
  wh_job_secret = wh_json.text_at("secret") or stop "wh secret"
  wh_del_id = wh_json.text_at("delivery_id") or stop "wh del"
  wh_ev = wh_json.text_at("event") or stop "wh ev"
  wh_body_json = wh_json.get("body_json") or stop "wh body"
  expected_wh_req = case Webhooks.build_request(
    wh_url,
    wh_job_secret,
    wh_del_id,
    wh_ev,
    wh_body_json.to_text.bytes,
    t0,
    "X-Vellum-Signature-256"
  )
    Ok(r): r
    Error(_): stop "build_request"
  end
  wh_sig = expected_wh_req.headers.find(fn(h) h.0 == "X-Vellum-Signature-256" end).map(
    fn(h) h.1 end
  ) or
    stop "sig"
  assert Webhooks.verify_signature(
    wh_secret,
    Webhooks.unix_seconds(t0),
    wh_sig,
    expected_wh_req.body,
    t0,
    60
  ) ==
    Ok(Unit)
  wh_net = Network.fake(Http.replies([(expected_wh_req, Http.reply(200, "{\"ok\":true}"))]))
  assert ApiTest.run_job(Main, "arvo.jobs.drain", Json.Null, files, clock, env, rng, wh_net) ==
    Ok(Unit)
  after_jobs = case Jobs.list_recent(files.read_only, Db.ledger_db_path, 10)
    Ok(js): js
    Error(_): stop "list after jobs"
  end
  assert after_jobs.filter(fn(j) j.id == wh_job.id end).all?(fn(j) j.state == "completed" end)

  # Agent cannot self-accept its own proposal in ProposalsRequiredForAgents collection
  agent_self_accept = ApiTest.send(
    Main,
    WebTest.prepare(agent, Api.post("/api/proposals/#{prop_a_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_self_accept.status == 403

  # 4. Owner accepts Proposal A (Page A updated) + opens/stages/accepts Proposal B (Page B updated)
  accept_a = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{prop_a_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert accept_a.status == 200

  prop_b_open = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals").with_json(
        Collab.OpenProposalInput(
          page_id: page_b_id,
          title: "Owner updates Runbook Spec",
          reason: "Add incident escalation"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert prop_b_open.status == 201
  prop_b_id = must_json(prop_b_open.text).text_at("id") or stop "prop_b_id"

  stage_b = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{prop_b_id}/ops").with_json(
        Collab.StageProposalOpsInput(
          ops: [
            ReplaceBlock(
              block_id: page_b_blk_id,
              expected_version: 1,
              kind: None,
              markdown: "Owner kept runbook step 1."
            )
          ],
          expected_versions: {page_b_blk_id: 1},
          reason: "Owner updated runbook"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert stage_b.status == 200
  accept_b = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{prop_b_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert accept_b.status == 200

  # 5. Selective Agent Rollback via Modb.Replay (exclude Proposal A's world -> Page A reverts, Page B stays!)
  sim_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/replay/simulate").with_json(
        Collab.SimulateReplayInput(
          filter_kind: "exclude_world",
          target: Some(prop_a_world_id),
          seq: None,
          description: "Undo Agent Gateway Spec proposal only"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sim_res.status == 201
  sim_json = must_json(sim_res.text)
  rpl_id = sim_json.text_at("proposal_id") or stop "rpl_id"
  assert sim_json.int_at("summary.excluded") == Some(1)

  apply_rpl = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/admin/replay/#{rpl_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert apply_rpl.status == 200

  live_a_after_undo = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{page_a_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert live_a_after_undo.text.contains?("Original gateway baseline rule.")
  assert not live_a_after_undo.text.contains?("Agent revised gateway rule.")

  live_b_after_undo = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{page_b_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert live_b_after_undo.text.contains?("Owner kept runbook step 1.")

  # 6. Monotonic Grant Sub-Delegation: widening rejected 422; narrowing succeeds; parent revocation cascades!
  widen_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/grants/delegate").with_json(
        Collab.DelegateGrantInput(
          handle: "evil-child",
          display_name: "Evil Widening Bot",
          model_id: None,
          label: "too-broad",
          allowed_actions: ["read", "publish"],
          allowed_collections: Some([gated_col_id]),
          max_calls: 5,
          ttl_days: 1
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert widen_res.status == 422

  child_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/grants/delegate").with_json(
        Collab.DelegateGrantInput(
          handle: "reader-child",
          display_name: "Sub Reader Bot",
          model_id: Some("claude-haiku-4-5"),
          label: "read-only-child",
          allowed_actions: ["read"],
          allowed_collections: Some([gated_col_id]),
          max_calls: 5,
          ttl_days: 1
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert child_res.status == 201
  child_tok = must_json(child_res.text).text_at("raw_token") or stop "child_tok"
  child_client = WebTest.new().with_header("Authorization", "Bearer #{child_tok}")

  child_read = ApiTest.send(
    Main,
    WebTest.prepare(child_client, Api.get("/api/pages/#{page_b_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert child_read.status == 200

  child_claim = ApiTest.send(
    Main,
    WebTest.prepare(
      child_client,
      Api.post("/api/claims").with_json(
        Collab.AcquireClaimInput(
          resource: "page:#{page_b_id}",
          ttl_seconds: 60,
          world_id: None,
          reason: "forbidden"
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert child_claim.status == 403

  # Cascading revocation of parent grant immediately blocks child token
  rev_parent = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/admin/grants/#{agent_grant_id}/revoke")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rev_parent.status == 200
  child_after_revoke = ApiTest.send(
    Main,
    WebTest.prepare(child_client, Api.get("/api/pages/#{page_b_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert child_after_revoke.status == 401

  # 7. SSE event stream & Last-Event-ID cursor + Ledger verify_all
  sse_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/events").with_header("Last-Event-ID", "1")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sse_res.status == 200
  assert sse_res.header("Content-Type") == Some("text/event-stream; charset=utf-8")
  assert sse_res.text.contains?("event: audit.")
  assert sse_res.text.contains?("event: claims.snapshot")
  assert not sse_res.text.contains?("id: 1\n")

  verify_rep = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e end,
    fn(db) Ledger.verify_all(db) end
  )
  case verify_rep
    Ok(rep): assert rep.invariants_checked == 5
    Error(_): stop "Ledger.verify_all stage 3 failed"
  end
end

test "end-to-end Vellum Stage 4: Notion Markdown+CSV importer, Ask Workspace (JSON & SSE + citations), AI Draft proposal, and Knowledge Gardening"
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
  rng = SecureRandom.seeded(20261129)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
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
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-test-vellum-123",
    "VELLUM_AI_BASE_URL": "https://api.openai.com/v1/chat/completions",
    "VELLUM_AI_MODEL": "gpt-4o-mini"
  })
  empty_net = Network.fake(Http.replies([]))

  # Owner login via OIDC PKCE
  guest = WebTest.new().with_header("Host", "localhost:8080")
  oidc_start = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock0,
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
      "sub": Json.String("sub_ada_s4"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("ada@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  tok_body = Json.Object({
    "access_token": Json.String("at_s4"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String("sub_ada_s4"),
    "email": Json.String("ada@acme.io"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Ada Lovelace")
  }).to_text
  oidc_net = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, "code_s4", verifier), Http.reply(200, tok_body)),
      (
        Oidc.userinfo_request("https://auth.example.com/userinfo", "at_s4"),
        Http.reply(200, ui_body)
      )
    ])
  )
  cb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.absorb(guest, oidc_start),
      Api.get("/auth/oidc/callback?code=code_s4&state=#{oidc_state}")
    ),
    files,
    clock0,
    env,
    rng,
    oidc_net
  )
  assert cb_res.status == 303
  owner = WebTest.absorb(guest, cb_res)

  # Create a restricted secret-ops collection + secret page for AI isolation test
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
          freshness_ttl_days: Some(365)
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert sec_col_res.status == 201
  sec_col_id = must_json(sec_col_res.text).text_at("id") or stop "sec_col_id"

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Vault Recovery",
          markdown: "Use zxqvault recovery key.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("secret doc")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert sec_pg.status == 201

  # 1. Batch Notion Markdown + CSV Import in col_general
  imp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/import/notion").with_json(
        Importer.ImportNotionInput(
          collection_id: Db.default_collection_id,
          pages: [
            NotionPageImport(
              path: "export/Gateway%20Runbook%209a1b2c3d4e5f67890123456789abcdef.md",
              title: None,
              markdown: "Rotate API gateway secrets every 30 days."
            ),
            NotionPageImport(
              path: "export/On-Call%20Guide%200123456789abcdef0123456789abcdef.md",
              title: None,
              markdown: "[[Gateway Runbook 9a1b2c3d4e5f67890123456789abcdef]]\n\n[[pg_missing|Dead Link]]"
            )
          ],
          databases: [
            NotionCsvImport(
              title: "Incidents 0123456789abcdef0123456789abcdef.csv",
              csv_text: "Incident,Severity,Cost,Date,Resolved\n\"Auth, 502 outage\",Sev1,12.50,2026-11-15,true\nDNS blip,Sev2,0.75,2026-11-18,false\n"
            )
          ]
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert imp_res.status == 201
  imp_json = must_json(imp_res.text)
  assert imp_json.int_at("page_count") == Some(2)
  assert imp_json.int_at("database_count") == Some(1)
  assert imp_json.int_at("row_count") == Some(2)

  imp_pages = imp_json.list_at("imported_pages") or []
  gateway_pg_id = (imp_pages.get(0) or Json.Null).text_at("id") or stop "gw_pg_id"
  oncall_pg_id = (imp_pages.get(1) or Json.Null).text_at("id") or stop "oncall_pg_id"
  assert (imp_pages.get(0) or Json.Null).text_at("title") == Some("Gateway Runbook")
  assert (imp_pages.get(1) or Json.Null).text_at("title") == Some("On-Call Guide")

  imp_dbs = imp_json.list_at("imported_databases") or []
  inc_db_id = (imp_dbs.get(0) or Json.Null).text_at("id") or stop "inc_db_id"

  # Rewritten internal link resolved to exact Gateway Runbook page_id
  oncall_read = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{oncall_pg_id}")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert oncall_read.status == 200
  assert (must_json(oncall_read.text).text_at("anchored_markdown") or "").contains?(
    "[[#{gateway_pg_id}|Gateway Runbook]]"
  )

  # Imported CSV database is queryable via Multi-View API
  inc_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{inc_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: None,
          filters: [DbFilterRule(prop_id: "severity", op: Eq, value: Json.String("sev1"))],
          filter_match_all: Some(true),
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert inc_q.status == 200 and must_json(inc_q.text).int_at("total_count") == Some(1)

  # Read Gateway Runbook block details so we construct exact AI prompts for Network.fake
  gw_read = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{gateway_pg_id}")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  gw_json = must_json(gw_read.text)
  gw_blk_id = ((gw_json.list_at("blocks") or []).first or Json.Null).text_at("id") or stop "gw_blk"
  gw_anchored = gw_json.text_at("anchored_markdown") or stop "gw_anchored"

  # Mint scoped Agent limited to col_general
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "ai-helper",
          display_name: "AI Helper",
          model_id: Some("gpt-4o-mini"),
          label: "general-ai",
          allowed_actions: ["read", "propose"],
          allowed_collections: Some([Db.default_collection_id]),
          max_calls: 20,
          ttl_days: 7
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert mint_res.status == 201
  agent_tok = must_json(mint_res.text).text_at("raw_token") or stop "agent_tok"
  agent = WebTest.new().with_header("Authorization", "Bearer #{agent_tok}")

  # 2. Ask Workspace (JSON & SSE) + Fail-Closed Secret Collection Isolation + Inline Draft Proposal
  ai_cfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "ai_config"
  end
  ask_sys = "You are Vellum Workspace Assistant. Answer strictly from the provided workspace excerpts and cite [Title §block_id]."
  ask_usr_pub = "Question: rotate secrets\n\nWorkspace Sources:\n[Gateway Runbook §#{gw_blk_id}]\nRotate API gateway secrets every 30 days."
  ask_usr_sec = "Question: zxqvault\n\nWorkspace Sources:\n(No permitted workspace excerpts matched this query.)"
  draft_sys = "You draft concise Markdown sections for Vellum documents. Output Markdown blocks only."
  draft_inst = "Add an emergency escalation note"
  draft_usr = "Page: Gateway Runbook\nExisting content:\n#{gw_anchored}\n\nInstruction: #{draft_inst}"

  ai_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, ask_sys, ask_usr_pub),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String(
                    "Rotate API gateway secrets every 30 days [Gateway Runbook §#{gw_blk_id}]."
                  )
                })
              })
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, ask_sys, ask_usr_sec),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({"content": Json.String("No matching documentation found.")})
              })
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, draft_sys, draft_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("- Escalate critical keys to @sec-oncall.")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )

  ask_json_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/ai/ask").with_json(
        Ai.AskWorkspaceInput(
          question: "rotate secrets",
          collection_id: None,
          max_sources: Some(3),
          stream: Some(false)
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    ai_net
  )
  assert ask_json_res.status == 200
  ask_j = must_json(ask_json_res.text)
  assert (ask_j.text_at("answer") or "").contains?("Gateway Runbook")
  assert (ask_j.list_at("citations") or []).size == 1

  # SSE streaming mode
  ask_sse_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/ai/ask").with_json(
        Ai.AskWorkspaceInput(
          question: "rotate secrets",
          collection_id: None,
          max_sources: Some(3),
          stream: Some(true)
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    ai_net
  )
  assert ask_sse_res.status == 200
  assert ask_sse_res.header("Content-Type") == Some("text/event-stream; charset=utf-8")
  assert ask_sse_res.text.contains?("event: ai.citation")
  assert ask_sse_res.text.contains?("event: ai.token")
  assert ask_sse_res.text.contains?("event: ai.done")

  # Fail-closed secret isolation on Ask Workspace
  ask_sec_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/ai/ask").with_json(
        Ai.AskWorkspaceInput(
          question: "zxqvault",
          collection_id: None,
          max_sources: Some(3),
          stream: Some(false)
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    ai_net
  )
  assert ask_sec_res.status == 200
  assert (must_json(ask_sec_res.text).list_at("citations") or []).empty?

  # AI Inline Draft as isolated Modb.World Proposal (live Gateway Runbook remains untouched!)
  draft_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/ai/draft").with_json(
        Ai.DraftBlockInput(page_id: gateway_pg_id, instruction: draft_inst, as_proposal: Some(true))
      )
    ),
    files,
    clock0,
    env,
    rng,
    ai_net
  )
  assert draft_res.status == 201
  assert must_json(draft_res.text).text_at("proposal.status") == Some("open")

  gw_still_clean = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{gateway_pg_id}")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert not gw_still_clean.text.contains?("@sec-oncall")

  # Mint long-lived read-only Knowledge Gardening bot token (valid past 100-day session TTL)
  garden_mint = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "garden-bot",
          display_name: "Garden Bot",
          model_id: None,
          label: "gardening",
          allowed_actions: ["read"],
          allowed_collections: None,
          max_calls: 50,
          ttl_days: 180
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert garden_mint.status == 201
  garden_tok = must_json(garden_mint.text).text_at("raw_token") or stop "garden_tok"
  garden_bot = WebTest.new().with_header("Authorization", "Bearer #{garden_tok}")

  # 3. Knowledge Gardening: advance clock 100 days (past default 90-day freshness TTL)
  clock_late = Clock.fixed(t0 + 100.days)
  garden_res = ApiTest.send(
    Main,
    WebTest.prepare(garden_bot, Api.get("/api/admin/garden")),
    files,
    clock_late,
    env,
    rng,
    empty_net
  )
  assert garden_res.status == 200
  g_json = must_json(garden_res.text)
  assert (g_json.list_at("stale_pages") or []).size >= 2
  broken_list = g_json.list_at("broken_links") or []
  assert broken_list.size == 1
  assert (broken_list.first or Json.Null).text_at("target_page_id") == Some("pg_missing")

  # Scheduled vellum.garden job runs cleanly
  assert ApiTest.run_job(Main, "vellum.garden", Json.Null, files, clock_late, env, rng, empty_net) ==
    Ok(Unit)

  verify_rep = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e end,
    fn(db) Ledger.verify_all(db) end
  )
  case verify_rep
    Ok(rep): assert rep.invariants_checked == 5
    Error(_): stop "Ledger.verify_all stage 4 failed"
  end
end

test "end-to-end Vellum Stage 5: Inertia Workspace shells (/proposals, /admin, /d/:id collections sidebar)"
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
  rng = SecureRandom.seeded(20261130)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
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

  guest = WebTest.new().with_header("Host", "localhost:8080")
  g_prop = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/proposals")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert g_prop.status == 303 and g_prop.header("Location") == Some("/login")
  g_admin = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/admin")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert g_admin.status == 303 and g_admin.header("Location") == Some("/login")

  oidc_start = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
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
      "sub": Json.String("sub_ada_s5"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("ada@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  tok_body = Json.Object({
    "access_token": Json.String("at_s5"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String("sub_ada_s5"),
    "email": Json.String("ada@acme.io"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Ada Lovelace")
  }).to_text
  oidc_net = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, "code_s5", verifier), Http.reply(200, tok_body)),
      (
        Oidc.userinfo_request("https://auth.example.com/userinfo", "at_s5"),
        Http.reply(200, ui_body)
      )
    ])
  )
  cb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.absorb(guest, oidc_start),
      Api.get("/auth/oidc/callback?code=code_s5&state=#{oidc_state}")
    ),
    files,
    clock0,
    env,
    rng,
    oidc_net
  )
  assert cb_res.status == 303
  owner = WebTest.absorb(guest, cb_res)

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Roadmap",
          description: Some("UI database"),
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "i")
          ]
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert db_res.status == 201
  db_id = must_json(db_res.text).text_at("database.id") or stop "db_id"

  home_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/").with_header("X-Inertia", "true")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert home_res.status == 200
  home_p = must_page(home_res)
  assert home_p.component == "Workspace/Home"
  assert (Json.Object(home_p.props).list_at("collections") or []).size >= 1
  assert (Json.Object(home_p.props).list_at("databases") or []).size == 1

  db_view_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/d/#{db_id}").with_header("X-Inertia", "true")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert db_view_res.status == 200
  db_p = must_page(db_view_res)
  assert db_p.component == "Workspace/Database"
  assert (Json.Object(db_p.props).list_at("collections") or []).size >= 1
  assert (Json.Object(db_p.props).list_at("databases") or []).size == 1

  prop_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/proposals").with_header("X-Inertia", "true")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert prop_res.status == 200
  prop_p = must_page(prop_res)
  assert prop_p.component == "Workspace/Proposals"
  assert (Json.Object(prop_p.props).list_at("collections") or []).size >= 1

  adm_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/admin").with_header("X-Inertia", "true")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert adm_res.status == 200
  adm_p = must_page(adm_res)
  assert adm_p.component == "Workspace/Admin"
  assert (Json.Object(adm_p.props).list_at("audit_feed") or []).size >= 1
end

test "realtime SSE topic grants, 403 unauthorized page scope, and mutation publish directives"
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
  rng = SecureRandom.seeded(20261130)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
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

  guest = WebTest.new().with_header("Host", "localhost:8080")
  oidc_start = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert oidc_start.status == 302
  q_params = Api.request("GET", oidc_start.header("Location") or "").query
  oidc_state = q_params.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or stop "state"
  oidc_nonce = q_params.find(fn(p) p.0 == "nonce" end).map(fn(p) p.1 end) or stop "nonce"
  verifier = unseal_oidc_code_verifier(
    oidc_start,
    "vellum_oidc_state",
    Bytes.from_hex(key_hex) or stop "key"
  )
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_cfg"
  end
  id_jwt = Oidc.build_unsigned_test_jwt(
    Json.Object({
      "iss": Json.String("https://auth.example.com"),
      "aud": Json.String("vellum-web"),
      "sub": Json.String("sub_sse_owner"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("sse@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  token_body = Json.Object({
    "access_token": Json.String("at-sse"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  userinfo_body = Json.Object({
    "sub": Json.String("sub_sse_owner"),
    "email": Json.String("sse@acme.io"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("SSE Owner")
  }).to_text
  tok_req = Oidc.token_exchange_request(oidc_cfg, "c1", verifier)
  ui_req = Oidc.userinfo_request("https://auth.example.com/userinfo", "at-sse")
  oidc_net = Network.fake(
    Http.replies([(tok_req, Http.reply(200, token_body)), (ui_req, Http.reply(200, userinfo_body))])
  )
  guest_with_oidc = WebTest.absorb(guest, oidc_start)
  cb_res = ApiTest.send(
    Main,
    WebTest.prepare(guest_with_oidc, Api.get("/auth/oidc/callback?code=c1&state=#{oidc_state}")),
    files,
    clock0,
    env,
    rng,
    oidc_net
  )
  assert cb_res.status == 303
  owner = WebTest.absorb(guest_with_oidc, cb_res)

  # Create collection & page, plus secret collection & page
  c1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "pub-col",
          name: "Public Col",
          description: None,
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: Some(30)
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert c1.status == 201
  c1_id = must_json(c1.text).text_at("id") or stop "c1_id"

  c2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "secret-col",
          name: "Secret Col",
          description: None,
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: Some(30)
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert c2.status == 201
  c2_id = must_json(c2.text).text_at("id") or stop "c2_id"

  p1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: c1_id,
          parent_page_id: None,
          title: "Pub Page",
          markdown: "Initial live copy",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed pub")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert p1.status == 201
  p1_id = must_json(p1.text).text_at("page.id") or stop "p1_id"
  p1_blk = must_json(p1.text).text_at("blocks.0.id") or stop "p1_blk"
  create_evs = p1.sse_published_events
  assert create_evs.any?(fn(e) e.topic == "collection:#{c1_id}" and e.event == Some("page.created") end)

  p2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: c2_id,
          parent_page_id: None,
          title: "Secret Page",
          markdown: "Confidential",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed secret")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert p2.status == 201
  p2_id = must_json(p2.text).text_at("page.id") or stop "p2_id"

  # Mint scoped agent allowed only on c1_id (forbidden on c2_id)
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "sse-agent",
          display_name: "SSE Agent",
          model_id: None,
          label: "sse",
          allowed_actions: ["read", "claim", "propose", "write_direct"],
          allowed_collections: Some([c1_id]),
          max_calls: 20,
          ttl_days: 7
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert mint_res.status == 201
  agent_tok = must_json(mint_res.text).text_at("raw_token") or stop "agent_tok"

  # Agent unscoped /api/events subscribes only to claims + c1_id, NEVER c2_id
  ag_ev = ApiTest.send(Main, Api.get("/api/events").with_bearer(agent_tok), files, clock0, env, rng, empty_net)
  assert ag_ev.status == 200
  ag_topics = ag_ev.sse_subscribe_topics
  assert ag_topics.contains?("claims")
  assert ag_topics.contains?("collection:#{c1_id}")
  assert not ag_topics.contains?("collection:#{c2_id}")

  # Agent scoped to unauthorized ?page_id=<p2_id> fails closed with 403
  ag_forbid = ApiTest.send(
    Main,
    Api.get("/api/events?page_id=#{p2_id}").with_bearer(agent_tok),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert ag_forbid.status == 403

  # Authorized ?page_id=<p1_id> subscribes to claims + page:<p1_id>
  owner_page_ev = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/events?page_id=#{p1_id}")),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert owner_page_ev.status == 200
  assert owner_page_ev.sse_subscribe_topics == ["claims", "page:#{p1_id}"]
  assert owner_page_ev.text.contains?("event: connected")

  # Claim + Patch + Proposal publish expected SSE topics & events
  cl_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/claims").with_json(
        Collab.AcquireClaimInput(
          resource: "page:#{p1_id}",
          ttl_seconds: 60,
          world_id: None,
          reason: "editing live"
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert cl_res.status == 201
  assert cl_res.sse_published_events.any?(fn(e) e.topic == "claims" and e.event == Some("claim.acquired") end)

  patch_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{p1_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: p1_blk,
              expected_version: 1,
              kind: None,
              markdown: "Updated live copy"
            )
          ],
          expected_versions: {p1_blk: 1},
          reason: Some("live sync edit")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert patch_res.status == 200
  patch_evs = patch_res.sse_published_events
  assert patch_evs.any?(fn(e) e.topic == "page:#{p1_id}" and e.event == Some("page.blocks_updated") end)
  assert patch_evs.any?(fn(e)
    e.topic == "collection:#{c1_id}" and e.event == Some("page.blocks_updated")
  end)

  mcp_prop = ApiTest.send(
    Main,
    Api.post("/mcp").with_bearer(agent_tok).with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(1),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.proposal_open"),
          "arguments": Json.Object({
            "page_id": Json.String(p1_id),
            "title": Json.String("Agent live proposal"),
            "reason": Json.String("trigger realtime event")
          })
        })
      })
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert mcp_prop.status == 200
  assert mcp_prop.sse_published_events.any?(fn(e)
    e.topic == "page:#{p1_id}" and e.event == Some("proposal.opened")
  end)
end
