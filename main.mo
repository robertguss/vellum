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
  AiColumnMode,
  AiOutputKind,
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
use Domain.Rlm{RlmBlockSlice, RlmDbSlice}
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
use Routes.Packs
use Routes.Sync
use Routes.Workspace

api
  port 8080
  static "/assets" from "public/assets"
  auth AuthContext via Auth.authenticate

  get "/login" Auth.show_login
  get "/auth/oidc/login" Auth.start_oidc_login
  get "/auth/oidc/callback" Auth.oidc_callback
  get "/auth/solo/login" Auth.solo_login
  post "/auth/solo/login" Auth.solo_login
  post "/auth/personal/login" Auth.personal_login
  post "/logout" Auth.post_logout

  get "/" Workspace.home
  get "/c/:slug" Workspace.show_collection
  get "/p/:id" Workspace.show_page
  get "/d/:id" Databases.show_database
  get "/proposals" Workspace.proposals_page
  get "/packs" Packs.packs_page
  get "/llms.txt" Packs.llms_txt
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
    put "/attachments/:id/upload" Workspace.upload_local_attachment
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
    patch "/databases/:id/views/:view_id" Databases.update_view
    delete "/databases/:id/views/:view_id" Databases.delete_view
    post "/databases/:id/query" Databases.query_database
    post "/databases/:id/scenarios" Collab.open_db_scenario
    post "/databases/:id/scenarios/:proposal_id/query" Collab.query_db_scenario
    post "/databases/:id/rows" Databases.create_row
    patch "/databases/:id/rows/:row_id" Databases.update_row
    delete "/databases/:id/rows/:row_id" Databases.delete_row
    get "/databases/:id/ai-columns/status" Ai.ai_columns_status
    post "/databases/:id/ai-columns/sync-feed" Ai.sync_ai_column_feed
    post "/databases/:id/ai-columns/:prop_id/run" Ai.run_ai_column

    get "/events" Collab.events_stream
    get "/claims" Collab.list_claims
    post "/claims" Collab.acquire_claim
    post "/claims/heartbeat" Collab.heartbeat_claim
    post "/claims/release" Collab.release_claim
    get "/proposals" Collab.list_proposals
    post "/proposals" Collab.open_proposal
    post "/proposals/:id/ops" Collab.stage_proposal_ops
    post "/proposals/:id/mutations" Collab.stage_proposal_mutation
    get "/proposals/:id/diff" Collab.diff_proposal
    post "/proposals/:id/accept" Collab.accept_proposal
    post "/proposals/:id/reject" Collab.reject_proposal
    get "/proposals/:id/comments" Collab.list_proposal_comments
    post "/proposals/:id/comments" Collab.create_proposal_comment
    post "/proposals/:id/comments/:comment_id/resolve" Collab.resolve_proposal_comment
    post "/proposals/:id/hunks/reject" Collab.reject_proposal_hunk
    post "/proposals/:id/steer" Ai.steer_proposal
    post "/admin/replay/baseline" Collab.pin_replay_baseline
    post "/admin/replay/simulate" Collab.simulate_replay
    post "/admin/replay/:id/accept" Collab.accept_replay
    post "/admin/replay/:id/discard" Collab.discard_replay
    post "/grants/delegate" Collab.delegate_grant
    get "/webhooks" Collab.list_webhooks
    post "/webhooks" Collab.create_webhook

    get "/blueprints" Workspace.list_blueprints
    post "/blueprints" Workspace.create_blueprint
    put "/blueprints/:id" Workspace.update_blueprint
    put "/pages/:id/meta" Workspace.set_page_blueprint_meta
    put "/pages/:id/markdown" Workspace.sync_page_markdown
    post "/metrics/resolve" Workspace.resolve_metrics
    get "/blocks/:block_id" Workspace.show_block_context
    get "/summaries" Packs.list_summaries
    get "/packs" Packs.list_packs
    post "/packs" Packs.create_pack
    put "/packs/:id" Packs.update_pack
    delete "/packs/:id" Packs.delete_pack
    get "/packs/:slug" Packs.compile_pack_json
    get "/packs/:slug/markdown" Packs.compile_pack_markdown
    get "/sync/snapshot" Sync.sync_snapshot
    post "/sync/push" Sync.sync_push
    post "/import/notion" Importer.import_notion
    post "/ai/ask" Ai.ask_workspace
    post "/ai/deep-research" Ai.deep_research
    post "/ai/draft" Ai.draft_blocks
    post "/ai/brief/refresh" Ai.refresh_ai_brief
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
      assert rep.invariants_checked == 9
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
    Ok(rep): assert rep.invariants_checked == 9
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

  http_diff_a = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{prop_a_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert http_diff_a.status == 200
  http_diff_json = must_json(http_diff_a.text)
  assert (http_diff_json.list_at("bucket_diffs") or []).size >= 1
  http_block_diffs = http_diff_json.list_at("block_diffs") or []
  assert http_block_diffs.size == 1
  first_bdiff = http_block_diffs.first or stop "first_bdiff"
  assert first_bdiff.text_at("change") == Some("modified")
  assert first_bdiff.text_at("before_markdown") == Some("Original gateway baseline rule.")
  assert first_bdiff.text_at("after_markdown") == Some("Agent revised gateway rule.")

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
    Ok(rep): assert rep.invariants_checked == 9
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

  # Live HTTP-to-SSE streaming mode returns immediate citation events + X-Mo-Sse-Relay directive
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
    empty_net
  )
  assert ask_sse_res.status == 200
  assert ask_sse_res.header("Content-Type") == Some("text/event-stream; charset=utf-8")
  assert ask_sse_res.text.contains?("event: ai.citation")
  assert ask_sse_res.text.contains?("Gateway Runbook")
  assert ask_sse_res.sse_relay_spec is Some(sse_relay)
  assert sse_relay.method == "POST"
  assert sse_relay.url == ai_cfg.base_url
  assert sse_relay.mode == "openai_sse"
  assert sse_relay.body.contains?("\"stream\":true")
  assert sse_relay.token_event == Some("ai.token")
  assert sse_relay.done_event == Some("ai.done")
  assert sse_relay.error_event == Some("ai.error")

  # Anthropic streaming relay mode + x-api-key header
  ant_env = Env.of({
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
    "VELLUM_AI_PROVIDER": "anthropic",
    "VELLUM_AI_API_KEY": "sk-ant-test-123",
    "VELLUM_AI_MODEL": "claude-sonnet-4-6"
  })
  ant_sse_res = ApiTest.send(
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
    ant_env,
    rng,
    empty_net
  )
  assert ant_sse_res.status == 200
  assert ant_sse_res.sse_relay_spec is Some(ant_relay)
  assert ant_relay.mode == "anthropic_sse"
  assert ant_relay.url == "https://api.anthropic.com/v1/messages"
  assert ant_relay.headers.any?(fn(h) h.0 == "x-api-key" and h.1 == "sk-ant-test-123" end)
  assert ant_relay.body.contains?("\"stream\":true")

  # Fail-closed secret isolation on Ask Workspace (both JSON and streaming SSE relay modes)
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

  ask_sec_sse = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/ai/ask").with_json(
        Ai.AskWorkspaceInput(
          question: "zxqvault",
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
    empty_net
  )
  assert ask_sec_sse.status == 200
  assert not ask_sec_sse.text.contains?("event: ai.citation")
  assert ask_sec_sse.sse_relay_spec is Some(sec_relay)
  assert not sec_relay.body.contains?("Vault")

  # Pure-Mo Http.open_stream + Http.next_sse_event over Network.fake
  stream_req = Ai.build_llm_request_with_stream(ai_cfg, ask_sys, ask_usr_pub, true)
  sse_wire = "event: ai.citation\ndata: {\"page_id\":\"#{gateway_pg_id}\"}\n\nevent: ai.token\ndata: {\"delta\":\"Rotate \"}\n\nevent: ai.done\ndata: {\"model\":\"gpt-4o-mini\"}\n\n"
  stream_net = Network.fake(
    Http.replies([
      (
        stream_req,
        Http.Response(
          status: 200,
          headers: [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            ("Content-Length", "#{sse_wire.byte_count}")
          ],
          body: sse_wire.bytes
        )
      )
    ])
  )
  assert stream_req.open_stream(stream_net) is Ok(st0)
  assert st0.stream_status == 200
  assert st0.next_sse_event is Ok((Some(ev1), st1))
  assert ev1.event == Some("ai.citation")
  assert st1.next_sse_event is Ok((Some(ev2), st2))
  assert ev2.event == Some("ai.token")
  assert ev2.data == "{\"delta\":\"Rotate \"}"
  assert st2.next_sse_event is Ok((Some(ev3), st3))
  assert ev3.event == Some("ai.done")
  assert st3.next_sse_event is Ok((None, _st4))

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
    Ok(rep): assert rep.invariants_checked == 9
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

test "end-to-end Vellum Hybrid Semantic + BM25 Search: Modb.Vec neural outbox indexing, RRF ranking, Ask Workspace semantic RAG, MCP mode selection, and fail-closed grant isolation"
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
  rng = SecureRandom.seeded(20261201)
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
    "VELLUM_OIDC_ALLOWED_DOMAINS": "acme.io",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-hybrid-llm",
    "VELLUM_AI_BASE_URL": "https://llm.example.com/v1/chat/completions",
    "VELLUM_AI_MODEL": "gpt-4o-mini",
    "VELLUM_EMBED_API_KEY": "sk-embed-test",
    "VELLUM_EMBED_BASE_URL": "https://embed.example.com/v1/embeddings",
    "VELLUM_EMBED_MODEL": "text-embedding-3-small",
    "VELLUM_EMBED_DIMENSIONS": "4"
  })
  empty_net = Network.fake(Http.replies([]))

  # OIDC Owner bootstrap
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
      "sub": Json.String("sub_hyb_owner"),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String("hybrid@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  token_body = Json.Object({
    "access_token": Json.String("at-hyb"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  userinfo_body = Json.Object({
    "sub": Json.String("sub_hyb_owner"),
    "email": Json.String("hybrid@acme.io"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Hybrid Owner")
  }).to_text
  oidc_net = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, "c1", verifier), Http.reply(200, token_body)),
      (
        Oidc.userinfo_request("https://auth.example.com/userinfo", "at-hyb"),
        Http.reply(200, userinfo_body)
      )
    ])
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

  # Create permitted ops collection + secret collection
  ops_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "hyb-ops",
          name: "Hybrid Ops",
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
  assert ops_res.status == 201
  ops_col_id = must_json(ops_res.text).text_at("id") or stop "ops_col_id"

  sec_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "hyb-secret",
          name: "Hybrid Secret",
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
  assert sec_res.status == 201
  sec_col_id = must_json(sec_res.text).text_at("id") or stop "sec_col_id"

  p1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Deployment Runbook",
          markdown: "Rotate API gateway tokens before deploy.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("ops page")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert p1_res.status == 201
  p1_json = must_json(p1_res.text)
  p1_id = p1_json.text_at("page.id") or stop "p1_id"
  p1_blk_id = ((p1_json.list_at("blocks") or []).first or Json.Null).text_at("id") or stop "p1_blk_id"

  p_other_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Office Catering",
          markdown: "Order tacos on Friday.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("catering")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert p_other_res.status == 201
  p_other_id = must_json(p_other_res.text).text_at("page.id") or stop "p_other_id"

  p_sec_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Executive Vault",
          markdown: "Master recovery passphrase zxq999.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("secret vault")
        )
      )
    ),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert p_sec_res.status == 201
  p_sec_id = must_json(p_sec_res.text).text_at("page.id") or stop "p_sec_id"

  # Mint agent restricted strictly to ops_col_id
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "hyb-agent",
          display_name: "Hybrid Scoped Agent",
          model_id: Some("gpt-4o-mini"),
          label: "hyb-ops-only",
          allowed_actions: ["read"],
          allowed_collections: Some([ops_col_id]),
          max_calls: 50,
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

  ecfg = Ai.embed_config(env) or stop "embed_config"
  acfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "ai_config"
  end

  sem_query = "credential renewal procedure"
  vec_sec = [1.0, 0.0, 0.0, 0.0]
  vec_other = [0.0, 1.0, 0.0, 0.0]
  vec_updated = [0.0, 0.0, 1.0, 0.0]

  embed_reply = fn(v)
    Json.Object({
      "object": Json.String("list"),
      "data": Json.Array([Json.Object({"embedding": v.to_json})])
    }).to_text
  end

  ask_sys = "You are Vellum Workspace Assistant. Answer strictly from the provided workspace excerpts and cite [Title §block_id]."
  ask_usr = "Question: #{sem_query}\n\nWorkspace Sources:\n[Deployment Runbook §#{p1_blk_id}]\nRotate API gateway tokens before deploy."
  updated_body = "Updated deploy checklist with HSM rotation."

  ai_embed_net = Network.fake(
    Http.replies([
      (
        Ai.build_embedding_request(ecfg, "Deployment Runbook\nRotate API gateway tokens before deploy."),
        Http.reply(200, embed_reply(vec_sec))
      ),
      (
        Ai.build_embedding_request(ecfg, "Office Catering\nOrder tacos on Friday."),
        Http.reply(200, embed_reply(vec_other))
      ),
      (
        Ai.build_embedding_request(ecfg, "Executive Vault\nMaster recovery passphrase zxq999."),
        Http.reply(200, embed_reply(vec_sec))
      ),
      (
        Ai.build_embedding_request(ecfg, sem_query),
        Http.reply(200, embed_reply(vec_sec))
      ),
      (
        Ai.build_embedding_request(ecfg, "catering"),
        Http.reply(200, embed_reply(vec_sec))
      ),
      (
        Ai.build_embedding_request(ecfg, "Deployment Runbook\n#{updated_body}"),
        Http.reply(200, embed_reply(vec_updated))
      ),
      (
        Ai.build_embedding_request(ecfg, "hsm concept"),
        Http.reply(200, embed_reply(vec_updated))
      ),
      (
        Ai.build_llm_request(acfg, ask_sys, ask_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String(
                    "Follow [Deployment Runbook §#{p1_blk_id}] to renew gateway tokens."
                  )
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )

  # Run outbox job drain to compute & persist neural embeddings in vellum_neural_4
  assert ApiTest.run_job(Main, "arvo.jobs.drain", Json.Null, files, clock0, env, rng, ai_embed_net) ==
    Ok(Unit)
  jobs_after_drain = case Jobs.list_recent(files.read_only, Db.ledger_db_path, 10)
    Ok(rows): rows
    Error(_): stop "list_recent failed"
  end
  assert not jobs_after_drain.empty?
  for j in jobs_after_drain
    assert j.last_error == None
    assert j.state == "completed"
  end
  assert Ai.fetch_embedding(ecfg, sem_query, ai_embed_net) == Ok(vec_sec)
  has_neural_check = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) Db.neural_vec_populated(Ledger.store(db), 4) end
  )
  assert has_neural_check == Ok(true)

  # Owner semantic search with zero lexical overlap returns BOTH p1_id and p_sec_id (both cosine=1.0), NOT p_other_id
  owner_sem = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.get("/api/search?q=credential+renewal+procedure&mode=semantic&limit=10")
    ),
    files,
    clock0,
    env,
    rng,
    ai_embed_net
  )
  assert owner_sem.status == 200
  owner_sem_j = must_json(owner_sem.text)
  assert owner_sem_j.text_at("mode") == Some("semantic")
  assert owner_sem_j.text_at("vector_backend") == Some("neural")
  owner_ids = (owner_sem_j.list_at("results") or []).map(fn(x) x.text_at("page_id") or "" end)
  assert owner_ids.contains?(p1_id) and owner_ids.contains?(p_sec_id)
  assert not owner_ids.contains?(p_other_id)

  # Scoped agent semantic & hybrid search MUST return ONLY p1_id (NEVER p_sec_id despite cosine=1.0)
  for m in ["semantic", "hybrid"]
    ag_res = ApiTest.send(
      Main,
      Api.get("/api/search?q=credential+renewal+procedure&mode=#{m}&limit=10").with_bearer(agent_tok),
      files,
      clock0,
      env,
      rng,
      ai_embed_net
    )
    assert ag_res.status == 200
    ag_j = must_json(ag_res.text)
    assert ag_j.text_at("vector_backend") == Some("neural")
    assert ag_j.text_at("mode") == Some(m)
    ag_hits = ag_j.list_at("results") or []
    assert ag_hits.map(fn(x) x.text_at("page_id") or "" end) == [p1_id]
  end

  # BM25 mode on zero lexical overlap returns 0 hits and makes 0 HTTP requests (empty_net)
  bm25_res = ApiTest.send(
    Main,
    Api.get("/api/search?q=credential+renewal+procedure&mode=bm25&limit=10").with_bearer(agent_tok),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert bm25_res.status == 200
  assert must_json(bm25_res.text).text_at("vector_backend") == Some("none")
  assert (must_json(bm25_res.text).list_at("results") or []).empty?

  # Invalid mode returns 422
  bad_mode = ApiTest.send(
    Main,
    Api.get("/api/search?q=test&mode=bogus").with_bearer(agent_tok),
    files,
    clock0,
    env,
    rng,
    empty_net
  )
  assert bad_mode.status == 422

  # Hybrid RRF returns BOTH BM25 match (p_other_id via "catering") AND Vector match (p1_id via [1,0,0,0])
  rrf_res = ApiTest.send(
    Main,
    Api.get("/api/search?q=catering&mode=hybrid&limit=10").with_bearer(agent_tok),
    files,
    clock0,
    env,
    rng,
    ai_embed_net
  )
  assert rrf_res.status == 200
  rrf_ids = (must_json(rrf_res.text).list_at("results") or []).map(fn(x)
    x.text_at("page_id") or ""
  end)
  assert rrf_ids.contains?(p_other_id) and rrf_ids.contains?(p1_id) and not rrf_ids.contains?(p_sec_id)

  # Scoped MCP vellum.search honors mode=semantic & fail-closed collection grants
  mcp_sem = ApiTest.send(
    Main,
    Api.post("/mcp").with_bearer(agent_tok).with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(10),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.search"),
          "arguments": Json.Object({"q": Json.String(sem_query), "mode": Json.String("semantic")})
        })
      })
    ),
    files,
    clock0,
    env,
    rng,
    ai_embed_net
  )
  assert mcp_sem.status == 200
  mcp_sc = must_json(mcp_sem.text)
  assert mcp_sc.text_at("result.structuredContent.vector_backend") == Some("neural")
  mcp_ids = (mcp_sc.list_at("result.structuredContent.results") or []).map(fn(x)
    x.text_at("page_id") or ""
  end)
  assert mcp_ids == [p1_id]

  # Ask Workspace semantic RAG cites ONLY permitted p1_id (ZERO lexical overlap with sem_query) and NEVER leaks p_sec_id
  ask_res = ApiTest.send(
    Main,
    WebTest.prepare(
      agent,
      Api.post("/api/ai/ask").with_json(
        Ai.AskWorkspaceInput(
          question: sem_query,
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
    ai_embed_net
  )
  assert ask_res.status == 200
  ask_j = must_json(ask_res.text)
  assert (ask_j.text_at("answer") or "").contains?("Deployment Runbook")
  ask_cite_ids = (ask_j.list_at("citations") or []).map(fn(x) x.text_at("page_id") or "" end)
  assert ask_cite_ids == [p1_id]

  # Patching blocks enqueues vellum.page.indexed & re-draining updates neural vector to vec_updated
  patch_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{p1_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: p1_blk_id,
              expected_version: 1,
              kind: None,
              markdown: updated_body
            )
          ],
          expected_versions: {p1_blk_id: 1},
          reason: Some("update for re-embedding")
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
  assert ApiTest.run_job(Main, "arvo.jobs.drain", Json.Null, files, clock0, env, rng, ai_embed_net) ==
    Ok(Unit)

  reembed_sem = ApiTest.send(
    Main,
    Api.get("/api/search?q=hsm+concept&mode=semantic&limit=10").with_bearer(agent_tok),
    files,
    clock0,
    env,
    rng,
    ai_embed_net
  )
  assert reembed_sem.status == 200
  assert (must_json(reembed_sem.text).list_at("results") or []).map(fn(x)
    x.text_at("page_id") or ""
  end) == [p1_id]

  # Cryptographic Ledger audit + invariants verification passes cleanly
  verify_rep = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e end,
    fn(db) Ledger.verify_all(db) end
  )
  case verify_rep
    Ok(rep): assert rep.invariants_checked == 9
    Error(_): stop "Ledger.verify_all failed"
  end
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

test "end-to-end Vellum Phase 2.1: Living Summaries, /llms.txt, Context Packs, MCP vellum://packs, and :::ai-brief proposals"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p21.js",
        "css": ["assets/main-p21.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p21.js": "console.log('p21');",
    "public/assets/main-p21.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261201)
  t0 = Time.parse("2026-12-01T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  later_clock = Clock.fixed(t0 + 5.days)
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

  # 1. Create primary page + database with 2 rows -> verify automatic Living Summaries
  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Runbook Alpha"),
          "markdown": Json.String(
            "## Failover\nPrimary failover instructions and quorum verification steps."
          ),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create runbook alpha")
        })
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

  # Verbose secondary page to force token-budget compaction
  long_para = "Latency budget, canary promotion rules, and distributed consensus checkpoints. ".repeat(
    18
  )
  long_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Verbose Architecture Spec"),
          "markdown": Json.String("## Deep Dive\n#{long_para}"),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create verbose page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert long_pg_res.status == 201

  # Stale-candidate page with 1-day freshness TTL
  stale_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(Db.default_collection_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Outdated Legacy Runbook"),
          "markdown": Json.String("Stale legacy instructions that must be excluded."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.int(1),
          "reason": Json.String("create stale page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert stale_pg_res.status == 201

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Incident Spend",
          description: Some("Operational incident cost ledger"),
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
  db_id = must_json(db_res.text).text_at("database.id") or stop "db_id"

  c1 = "120.00".to_decimal or stop "c1"
  c2 = "80.00".to_decimal or stop "c2"
  r1 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Hot Standby"), "cost": NumberVal(c1)},
          markdown: None,
          reason: Some("seed spend row 1")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r1.status == 201
  r2 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Pager Override"), "cost": NumberVal(c2)},
          markdown: None,
          reason: Some("seed spend row 2")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert r2.status == 201

  sum_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/summaries")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sum_res.status == 200
  summaries_list = must_json(sum_res.text).list_at("summaries") or []
  pg_sum = summaries_list.find(fn(s) s.text_at("entity_id") == Some(pg_id) end) or stop "pg_sum"
  assert pg_sum.text_at("entity_kind") == Some("page")
  assert not (pg_sum.text_at("structural_summary") or "").empty?
  assert (pg_sum.int_at("estimated_tokens") or 0) > 0
  db_sum = summaries_list.find(fn(s) s.text_at("entity_id") == Some(db_id) end) or stop "db_sum"
  assert db_sum.text_at("entity_kind") == Some("database")
  assert db_sum.int_at("row_count") == Some(2)
  assert (db_sum.int_at("estimated_tokens") or 0) > 0

  # 2. Isolated second collection + grant-filtered /llms.txt
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

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(sec_col_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Secret Vault Doc"),
          "markdown": Json.String("Restricted rotation credentials."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("create secret doc")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_pg.status == 201

  mint_iso = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@iso_reader"),
          "display_name": Json.String("Isolated Reader"),
          "model_id": Json.String("claude-sonnet-4-6"),
          "label": Json.String("iso"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(sec_col_id)]),
          "max_calls": Json.int(25),
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
  assert mint_iso.status == 201
  iso_tok = must_json(mint_iso.text).text_at("raw_token") or stop "iso_tok"
  iso_agent = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{iso_tok}"
  )

  mint_ops = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@ops_agent"),
          "display_name": Json.String("Ops Pack Agent"),
          "model_id": Json.String("claude-sonnet-4-6"),
          "label": Json.String("ops"),
          "allowed_actions": Json.Array([Json.String("read"), Json.String("propose")]),
          "allowed_collections": Json.Array([Json.String(Db.default_collection_id)]),
          "max_calls": Json.int(25),
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
  ops_tok = must_json(mint_ops.text).text_at("raw_token") or stop "ops_tok"
  ops_agent = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ops_tok}"
  )

  llms_owner = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/llms.txt")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert llms_owner.status == 200
  assert llms_owner.header("Content-Type") == Some("text/markdown; charset=utf-8")
  assert llms_owner.text.contains?("# Vellum Workspace Index (/llms.txt)")
  assert llms_owner.text.contains?("Runbook Alpha")
  assert llms_owner.text.contains?("Incident Spend")
  assert llms_owner.text.contains?("Secret Vault Doc")

  llms_iso = ApiTest.send(
    Main,
    WebTest.prepare(iso_agent, Api.get("/llms.txt")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert llms_iso.status == 200
  assert llms_iso.text.contains?("secret-ops")
  assert llms_iso.text.contains?("Secret Vault Doc")
  assert not llms_iso.text.contains?("Runbook Alpha")
  assert not llms_iso.text.contains?("Incident Spend")

  # 3. Context Pack CRUD + Optimistic Concurrency + Hard Token Budget + fresh_only + Fail-Closed ACL
  pk_create = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/packs").with_json(
        Packs.CreatePackInput(
          slug: "ops-brief",
          name: "Operations Brief",
          description: Some("Compact runbook & spend bundle"),
          collection_ids: [Db.default_collection_id],
          pinned_page_ids: [pg_id],
          database_ids: [db_id],
          query_hint: None,
          fresh_only: Some(false),
          include_full_blocks: Some(true),
          token_budget: Some(280)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_create.status == 201
  pk_id = must_json(pk_create.text).text_at("id") or stop "pk_id"

  pk_list = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_list.status == 200 and pk_list.text.contains?("ops-brief")

  pk_page_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/packs")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_page_res.status == 200
  assert must_page(pk_page_res).component == "Workspace/Packs"

  pk_upd = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/packs/#{pk_id}").with_json(
        Packs.UpdatePackInput(
          slug: None,
          name: Some("Operations Brief v2"),
          description: None,
          collection_ids: None,
          pinned_page_ids: None,
          database_ids: None,
          query_hint: None,
          fresh_only: None,
          include_full_blocks: None,
          token_budget: None,
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
  assert pk_upd.status == 200
  assert must_json(pk_upd.text).int_at("version") == Some(2)

  pk_stale = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/packs/#{pk_id}").with_json(
        Packs.UpdatePackInput(
          slug: None,
          name: Some("Should Conflict"),
          description: None,
          collection_ids: None,
          pinned_page_ids: None,
          database_ids: None,
          query_hint: None,
          fresh_only: None,
          include_full_blocks: None,
          token_budget: None,
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
  assert pk_stale.status == 409

  comp_json = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/ops-brief")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert comp_json.status == 200
  cj = must_json(comp_json.text)
  assert cj.int_at("token_budget") == Some(280)
  assert (cj.int_at("tokens_used") or 9999) <= 280
  assert (cj.list_at("included_items") or []).size >= 1

  comp_md = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/ops-brief/markdown")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert comp_md.status == 200
  assert comp_md.header("Content-Type") == Some("text/markdown; charset=utf-8")
  assert comp_md.header("X-Vellum-Token-Budget") == Some("280")
  used_hdr = (comp_md.header("X-Vellum-Tokens-Used") or "9999").to_int or 9999
  assert used_hdr <= 280
  assert comp_md.text.contains?("# Context Pack:")

  # Enable fresh_only and compile at later_clock (+5 days) -> stale page skipped!
  pk_fresh_upd = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/packs/#{pk_id}").with_json(
        Packs.UpdatePackInput(
          slug: None,
          name: None,
          description: None,
          collection_ids: None,
          pinned_page_ids: None,
          database_ids: None,
          query_hint: None,
          fresh_only: Some(true),
          include_full_blocks: None,
          token_budget: Some(1200),
          expected_version: Some(2)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pk_fresh_upd.status == 200

  comp_fresh = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/ops-brief")),
    files,
    later_clock,
    env,
    rng,
    empty_net
  )
  assert comp_fresh.status == 200
  cf_j = must_json(comp_fresh.text)
  assert (cf_j.int_at("skipped_stale_count") or 0) >= 1
  assert not (cf_j.text_at("markdown") or "").contains?("Stale legacy instructions")

  # Fail-closed cross-collection pack access
  iso_pack_denied = ApiTest.send(
    Main,
    WebTest.prepare(iso_agent, Api.get("/api/packs/ops-brief")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert iso_pack_denied.status == 403

  # Delete temporary pack cleanly
  tmp_pk = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/packs").with_json(
        Packs.CreatePackInput(
          slug: "temp-pack",
          name: "Temp Pack",
          description: None,
          collection_ids: [],
          pinned_page_ids: [],
          database_ids: [],
          query_hint: None,
          fresh_only: None,
          include_full_blocks: None,
          token_budget: Some(512)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tmp_pk.status == 201
  tmp_pk_id = must_json(tmp_pk.text).text_at("id") or stop "tmp_pk_id"
  del_pk = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.delete("/api/packs/#{tmp_pk_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_pk.status == 200 and must_json(del_pk.text).bool_at("deleted") == Some(true)
  after_del = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/packs/temp-pack")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert after_del.status == 404

  # 4. MCP Progressive Disclosure: resources/list, resources/read (vellum://index + vellum://packs), tools/call
  mcp_list_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(101),
          "method": Json.String("resources/list")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_list_res.status == 200
  assert mcp_list_res.text.contains?("vellum://index")
  assert mcp_list_res.text.contains?("vellum://packs/ops-brief")

  mcp_idx = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(102),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://index")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_idx.status == 200
  assert mcp_idx.text.contains?("vellum://packs/ops-brief")
  assert not mcp_idx.text.contains?("Secret Vault Doc")

  mcp_pk = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(103),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://packs/ops-brief")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_pk.status == 200
  assert mcp_pk.text.contains?("# Context Pack:")

  mcp_tool_sums = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(104),
          "method": Json.String("tools/call"),
          "params": Json.Object({"name": Json.String("vellum.list_summaries"), "arguments": Json.Object({})})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_tool_sums.status == 200
  assert mcp_tool_sums.text.contains?("\"isError\":false")
  assert mcp_tool_sums.text.contains?("Runbook Alpha")

  mcp_tool_packs = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(105),
          "method": Json.String("tools/call"),
          "params": Json.Object({"name": Json.String("vellum.list_packs"), "arguments": Json.Object({})})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_tool_packs.status == 200
  assert mcp_tool_packs.text.contains?("\"isError\":false")
  assert mcp_tool_packs.text.contains?("ops-brief")

  mcp_tool_read_pk = ApiTest.send(
    Main,
    WebTest.prepare(
      ops_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(106),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.read_pack"),
            "arguments": Json.Object({"slug": Json.String("ops-brief")})
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
  assert mcp_tool_read_pk.status == 200
  assert mcp_tool_read_pk.text.contains?("\"isError\":false")
  assert mcp_tool_read_pk.text.contains?("Operations Brief v2")

  # Isolated agent denied vellum://packs/ops-brief via MCP
  mcp_iso_denied = ApiTest.send(
    Main,
    WebTest.prepare(
      iso_agent,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(107),
          "method": Json.String("resources/read"),
          "params": Json.Object({"uri": Json.String("vellum://packs/ops-brief")})
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mcp_iso_denied.status == 200 and mcp_iso_denied.text.contains?("\"error\"")

  # 5. :::ai-brief Markdown round-trip + proposals-only refresh + Accept
  pg_v1 = must_json(pg_res.text).int_at("page.version") or stop "pg_v1"
  brief_md = "## Failover\nPrimary failover instructions and quorum verification steps.\n\n:::ai-brief [scope=#{Db.default_collection_id}] Summarize operational status\nPlaceholder brief body\n:::"
  sync_brief = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/markdown").with_json(
        Workspace.SyncPageMarkdownInput(
          markdown: brief_md,
          expected_page_version: pg_v1,
          reason: Some("add ai-brief card via markdown lens")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sync_brief.status == 200
  sync_blks = must_json(sync_brief.text).list_at("blocks") or []
  brief_blk = sync_blks.find(fn(b)
    (b.text_at("markdown") or "").contains?("Placeholder brief body")
  end) or
    stop "brief_blk"
  brief_blk_id = brief_blk.text_at("id") or stop "brief_blk_id"
  assert (must_json(sync_brief.text).text_at("anchored_markdown") or "").contains?(
    ":::ai-brief [scope=#{Db.default_collection_id}] Summarize operational status"
  )

  # Refresh AI brief -> proposals-only (never touches live block!)
  refresh_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/brief/refresh").with_json(
        Ai.RefreshAiBriefInput(
          page_id: pg_id,
          block_id: brief_blk_id,
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
  assert refresh_res.status == 201
  ref_j = must_json(refresh_res.text)
  brief_prop_id = ref_j.text_at("proposal.id") or stop "brief_prop_id"
  assert ref_j.text_at("model") == Some("deterministic-summary")

  pg_before_accept = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_before_accept.status == 200
  assert (must_json(pg_before_accept.text).text_at("anchored_markdown") or "").contains?(
    "Placeholder brief body"
  )

  accept_brief = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/proposals/#{brief_prop_id}/accept")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert accept_brief.status == 200

  pg_after_accept = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_after_accept.status == 200
  after_md = must_json(pg_after_accept.text).text_at("anchored_markdown") or ""
  assert after_md.contains?(":::ai-brief [scope=#{Db.default_collection_id} refreshed=")
  assert after_md.contains?("Runbook Alpha")
  assert after_md.contains?("Incident Spend")
  assert not after_md.contains?("Placeholder brief body")

  # 6. Ledger 9 invariants check
  ver21 = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) Ledger.verify_all(db).map_error(Db.map_ledger_error) end
  )
  case ver21
    Ok(rep): assert rep.invariants_checked == 9
    Error(_): assert false
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

test "end-to-end Vellum Phase 2.3: Full MCP DB Surface (schema/create/update/propose) and Patchwork Per-Hunk Reject + Steer-in-Place"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p23.js",
        "css": ["assets/main-p23.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p23.js": "console.log('p23');",
    "public/assets/main-p23.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261203)
  t0 = Time.parse("2026-12-03T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-test-steer",
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

  gcol_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "gated-p23",
          name: "Gated P23",
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
  assert gcol_res.status == 201
  gcol_id = must_json(gcol_res.text).text_at("id") or stop "gcol_id"

  ocol_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "other-p23",
          name: "Other P23",
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
  assert ocol_res.status == 201
  ocol_id = must_json(ocol_res.text).text_at("id") or stop "ocol_id"

  ddb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: Db.default_collection_id,
          parent_page_id: None,
          title: "Direct Ops",
          description: None,
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
  assert ddb_res.status == 201
  ddb_id = must_json(ddb_res.text).text_at("database.id") or stop "ddb_id"

  gdb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: gcol_id,
          parent_page_id: None,
          title: "Gated Ledger",
          description: None,
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
  assert gdb_res.status == 201
  gdb_id = must_json(gdb_res.text).text_at("database.id") or stop "gdb_id"

  gr0 = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{gdb_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Existing Budget"), "cost": NumberVal(10.0)},
          markdown: None,
          reason: Some("seed gated db")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gr0.status == 201
  gr0_id = must_json(gr0.text).text_at("row.id") or stop "gr0_id"

  mint_mcp = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@mcp_db_bot"),
          "display_name": Json.String("MCP DB Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("p23"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("write_db"),
            Json.String("propose"),
            Json.String("comment")
          ]),
          "allowed_collections": Json.Array([
            Json.String(Db.default_collection_id),
            Json.String(gcol_id)
          ]),
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
  assert mint_mcp.status == 201
  ag_tok = must_json(mint_mcp.text).text_at("raw_token") or stop "ag_tok"
  ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  mint_other = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@other_bot"),
          "display_name": Json.String("Other Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("other"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(ocol_id)]),
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
  assert mint_other.status == 201
  other_tok = must_json(mint_other.text).text_at("raw_token") or stop "other_tok"
  other_ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{other_tok}"
  )

  # 1. Fail-closed db_schema for out-of-scope agent, success for permitted agent
  unauth_schema = ApiTest.send(
    Main,
    WebTest.prepare(
      other_ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_schema"),
            "arguments": Json.Object({"database_id": Json.String(ddb_id)})
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
  assert unauth_schema.status == 200
  assert must_json(unauth_schema.text).bool_at("result.isError") == Some(true)

  ok_schema = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(2),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_schema"),
            "arguments": Json.Object({"database_id": Json.String(ddb_id)})
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
  assert ok_schema.status == 200
  ok_schema_j = must_json(ok_schema.text)
  assert ok_schema_j.bool_at("result.isError") == Some(false)
  assert (ok_schema_j.list_at("result.structuredContent.views") or []).size >= 1

  # 2. DirectWithAudit MCP db_create_row & db_update_row (+ optimistic version check)
  c_row = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(3),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_create_row"),
            "arguments": Json.Object({
              "database_id": Json.String(ddb_id),
              "cells": Json.Object({
                "title": Json.Object({"text_val": Json.String("Edge Proxy")}),
                "cost": Json.Object({"number_val": Json.String("25.00")})
              }),
              "reason": Json.String("MCP create row")
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
  assert c_row.status == 200
  c_row_j = must_json(c_row.text)
  assert c_row_j.bool_at("result.isError") == Some(false)
  r_dir_id = c_row_j.text_at("result.structuredContent.row.id") or stop "r_dir_id"

  stale_u = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(4),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_update_row"),
            "arguments": Json.Object({
              "database_id": Json.String(ddb_id),
              "row_id": Json.String(r_dir_id),
              "cells": Json.Object({"cost": Json.Object({"number_val": Json.String("99.00")})}),
              "expected_version": Json.int(99),
              "reason": Json.String("stale update")
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
  assert stale_u.status == 200
  assert must_json(stale_u.text).bool_at("result.isError") == Some(true)

  ok_u = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(5),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_update_row"),
            "arguments": Json.Object({
              "database_id": Json.String(ddb_id),
              "row_id": Json.String(r_dir_id),
              "cells": Json.Object({"cost": Json.Object({"number_val": Json.String("75.50")})}),
              "expected_version": Json.int(1),
              "reason": Json.String("revise cost")
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
  assert ok_u.status == 200
  ok_u_j = must_json(ok_u.text)
  assert ok_u_j.bool_at("result.isError") == Some(false)
  assert ok_u_j.int_at("result.structuredContent.row.version") == Some(2)

  # 3. Gated collection blocks direct db_create_row and accepts db_propose_changes
  gated_dir = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(6),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_create_row"),
            "arguments": Json.Object({
              "database_id": Json.String(gdb_id),
              "cells": Json.Object({"title": Json.Object({"text_val": Json.String("Blocked")})}),
              "reason": Json.String("must be blocked")
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
  assert gated_dir.status == 200
  assert must_json(gated_dir.text).bool_at("result.isError") == Some(true)

  prop_db = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(7),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_propose_changes"),
            "arguments": Json.Object({
              "database_id": Json.String(gdb_id),
              "title": Json.String("Propose Budget + New Row"),
              "reason": Json.String("gated DB change batch"),
              "mutations": Json.Array([
                Json.Object({
                  "kind": Json.String("db_row_update"),
                  "row_id": Json.String(gr0_id),
                  "expected_version": Json.int(1),
                  "cells": Json.Object({"cost": Json.Object({"number_val": Json.String("45.00")})})
                }),
                Json.Object({
                  "kind": Json.String("db_row_create"),
                  "cells": Json.Object({
                    "title": Json.Object({"text_val": Json.String("New Hardware")}),
                    "cost": Json.Object({"number_val": Json.String("15.00")})
                  })
                })
              ])
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
  assert prop_db.status == 200
  prop_db_j = must_json(prop_db.text)
  assert prop_db_j.bool_at("result.isError") == Some(false)
  assert prop_db_j.int_at("result.structuredContent.staged_count") == Some(2)
  db_prop_id = prop_db_j.text_at("result.structuredContent.proposal.id") or stop "db_prop_id"

  diff_db = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{db_prop_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert diff_db.status == 200
  assert (must_json(diff_db.text).list_at("db_row_diffs") or []).size == 2

  acc_db = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{db_prop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Approve MCP DB batch"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_db.status == 200

  q_gdb = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(8),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.db_query"),
            "arguments": Json.Object({"database_id": Json.String(gdb_id)})
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
  assert q_gdb.status == 200
  assert must_json(q_gdb.text).int_at("result.structuredContent.total_count") == Some(2)

  # 4. Patchwork Per-Hunk Reject + Steer-in-Place + Anchored Proposal Comments
  pg_p = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: gcol_id,
          parent_page_id: None,
          title: "Service SLA",
          icon: None,
          markdown: "Live block one\n\nLive block two",
          freshness_ttl_days: None,
          reason: Some("seed patchwork page")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_p.status == 201
  pg_p_j = must_json(pg_p.text)
  pg_p_id = pg_p_j.text_at("page.id") or stop "pg_p_id"
  b1_id = pg_p_j.text_at("blocks.0.id") or stop "b1_id"
  b2_id = pg_p_j.text_at("blocks.1.id") or stop "b2_id"

  open_pg_prop = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(9),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_open"),
            "arguments": Json.Object({
              "page_id": Json.String(pg_p_id),
              "title": Json.String("SLA Rewrite"),
              "reason": Json.String("Propose updated SLO wording")
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
  assert open_pg_prop.status == 200
  pg_prop_id = must_json(open_pg_prop.text).text_at("result.structuredContent.id") or stop "pg_prop_id"

  stage_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(10),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_stage_ops"),
            "arguments": Json.Object({
              "proposal_id": Json.String(pg_prop_id),
              "reason": Json.String("Draft changes to both blocks"),
              "ops": Json.Array([
                Json.Object({
                  "replace_block": Json.Object({
                    "block_id": Json.String(b1_id),
                    "expected_version": Json.int(1),
                    "kind": Json.Null,
                    "markdown": Json.String("Agent proposed block one")
                  })
                }),
                Json.Object({
                  "replace_block": Json.Object({
                    "block_id": Json.String(b2_id),
                    "expected_version": Json.int(1),
                    "kind": Json.Null,
                    "markdown": Json.String("Unwanted block two edit")
                  })
                })
              ]),
              "expected_versions": Json.Object({b1_id: Json.int(1), b2_id: Json.int(1)})
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
  assert stage_pg.status == 200
  assert must_json(stage_pg.text).bool_at("result.isError") == Some(false)

  rej_hunk = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/hunks/reject").with_json(
        Collab.RejectProposalHunkInput(
          target_kind: "block",
          target_id: b2_id,
          page_id: None,
          database_id: None,
          reason: Some("Keep original block two")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rej_hunk.status == 200

  after_rej_diff = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/proposals/#{pg_prop_id}/diff")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert after_rej_diff.status == 200
  rem_bdiffs = must_json(after_rej_diff.text).list_at("block_diffs") or []
  assert rem_bdiffs.size == 1

  steer_cfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "steer_cfg"
  end
  (steer_sys, steer_usr) = Ai.build_steer_prompts(
    "Service SLA",
    b1_id,
    "Live block one",
    "Agent proposed block one",
    "Include 99.95% latency target"
  )
  steer_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(steer_cfg, steer_sys, steer_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("Steered block one targeting 99.95% latency")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  steer_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/steer").with_json(
        Ai.SteerProposalInput(
          target_block_id: Some(b1_id),
          target_page_id: None,
          instruction: "Include 99.95% latency target",
          deterministic_fallback: Some(false)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    steer_net
  )
  assert steer_res.status == 200
  steer_j = must_json(steer_res.text)
  assert steer_j.text_at("revised_markdown") == Some("Steered block one targeting 99.95% latency")
  hcmt_id = steer_j.text_at("human_comment.id") or stop "hcmt_id"

  note_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/comments").with_json(
        Collab.CreateProposalCommentInput(
          target_kind: Some("proposal"),
          target_ref: None,
          parent_comment_id: None,
          body_markdown: "Ready to merge",
          steer_requested: Some(false)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert note_res.status == 201

  mcp_cmts = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(11),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.proposal_comments"),
            "arguments": Json.Object({"proposal_id": Json.String(pg_prop_id)})
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
  assert mcp_cmts.status == 200
  assert (must_json(mcp_cmts.text).list_at("result.structuredContent.comments") or []).size == 3

  res_cmt = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/comments/#{hcmt_id}/resolve").with_json(
        Collab.ResolveProposalCommentInput(resolved: Some(true))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert res_cmt.status == 200
  assert must_json(res_cmt.text).text_at("comment.resolved_at") != None

  acc_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{pg_prop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Merge steered SLA"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_pg.status == 200

  final_pg = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_p_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert final_pg.status == 200
  final_md = must_json(final_pg.text).text_at("anchored_markdown") or ""
  assert final_md.contains?("Steered block one targeting 99.95% latency")
  assert final_md.contains?("Live block two")
end

test "RLM Tier 1 Deep Research API & MCP vellum.rlm_query: Modb.Views ReadProgram slicing, sub-calls, WorkBudgetExceeded 422, and fail-closed ViewDenied"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p24.js",
        "css": ["assets/main-p24.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p24.js": "console.log('p24');",
    "public/assets/main-p24.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261204)
  t0 = Time.parse("2026-12-04T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_API_KEY": "sk-test-rlm",
    "VELLUM_AI_BASE_URL": "https://api.openai.com/v1/chat/completions",
    "VELLUM_AI_MODEL": "gpt-4o-mini"
  })
  ai_cfg = case Ai.ai_config(env)
    Ok(c): c
    Error(_): stop "ai_cfg"
  end
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

  eng_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "eng-p24",
          name: "Eng P24",
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
  assert eng_col_res.status == 201
  eng_col_id = must_json(eng_col_res.text).text_at("id") or stop "eng_col_id"

  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sec-p24",
          name: "Sec P24",
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

  pg_rb_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: eng_col_id,
          parent_page_id: None,
          title: "Gateway Rollback Guide",
          markdown: "## Rollback Procedure\n\n```bash\nkubectl rollout undo deploy/gateway\n```\n\n```bash\nvellum quorum-verify --strict\n```\n\n## Observability\n\n```bash\nprometheus --version\n```",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed rlm runbook")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg_rb_res.status == 201
  pg_rb_j = must_json(pg_rb_res.text)
  pg_rb_id = pg_rb_j.text_at("page.id") or stop "pg_rb_id"
  pg_blks = pg_rb_j.list_at("blocks") or []
  assert pg_blks.size == 5
  blk1_j = pg_blks.get(1) or stop "blk1"
  blk2_j = pg_blks.get(2) or stop "blk2"
  blk4_j = pg_blks.get(4) or stop "blk4"
  blk1_id = blk1_j.text_at("id") or stop "blk1_id"
  blk2_id = blk2_j.text_at("id") or stop "blk2_id"
  blk4_id = blk4_j.text_at("id") or stop "blk4_id"

  sec_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Executive Vault Procedure",
          markdown: "Master gateway secret phrase vxq99.",
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
  assert sec_pg_res.status == 201

  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: eng_col_id,
          parent_page_id: None,
          title: "Deploy Matrix",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
            PropertyDef(id: "owner", name: "Owner", kind: RichText, required: false, sort_order: "b")
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
          cells: {"title": TextVal("api-gateway"), "owner": TextVal("@ada")},
          markdown: None,
          reason: Some("seed rlm db row")
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
  row_j = must_json(row_res.text)
  row_id = row_j.text_at("row.id") or stop "row_id"
  row_pg_id = row_j.text_at("row.page_id") or stop "row_pg_id"

  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@rlm_bot"),
          "display_name": Json.String("RLM Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("p24"),
          "allowed_actions": Json.Array([Json.String("read")]),
          "allowed_collections": Json.Array([Json.String(eng_col_id)]),
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
  ag_tok = must_json(mint_res.text).text_at("raw_token") or stop "ag_tok"
  ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  s1 = RlmBlockSlice(
    page_id: pg_rb_id,
    page_title: "Gateway Rollback Guide",
    collection_id: eng_col_id,
    block_id: blk1_id,
    rank: blk1_j.text_at("rank") or "0002",
    kind_tag: "code_block",
    heading_level: 0,
    heading_path: Some("Rollback Procedure"),
    markdown: blk1_j.text_at("markdown") or "",
    score: 1
  )
  s2 = RlmBlockSlice(
    page_id: pg_rb_id,
    page_title: "Gateway Rollback Guide",
    collection_id: eng_col_id,
    block_id: blk2_id,
    rank: blk2_j.text_at("rank") or "0003",
    kind_tag: "code_block",
    heading_level: 0,
    heading_path: Some("Rollback Procedure"),
    markdown: blk2_j.text_at("markdown") or "",
    score: 1
  )
  db_s = RlmDbSlice(
    database_id: db_id,
    database_title: "Deploy Matrix",
    collection_id: eng_col_id,
    row_id: row_id,
    page_id: row_pg_id,
    title: "api-gateway",
    cells_summary: "Item: api-gateway | Owner: @ada"
  )

  # 1. Deep Research with section isolation, block_kinds filter, DB slice, and 2 sub-calls
  q1 = "Rollback gateway deploy quorum"
  (sub1_sys, sub1_usr) = Ai.build_rlm_subcall_prompts(q1, 1, 2, [s1])
  (sub2_sys, sub2_usr) = Ai.build_rlm_subcall_prompts(q1, 2, 2, [s2])
  note1 = "Found rollout undo command [Gateway Rollback Guide §#{blk1_id}]."
  note2 = "Found strict quorum verification [Gateway Rollback Guide §#{blk2_id}]."
  (syn1_sys, syn1_usr) = Ai.build_rlm_synthesis_prompts(
    q1,
    ["Chunk 1/2:\n#{note1}", "Chunk 2/2:\n#{note2}"],
    [s1, s2],
    [db_s]
  )
  deep_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, sub1_sys, sub1_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(note1)})})
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, sub2_sys, sub2_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({"message": Json.Object({"content": Json.String(note2)})})
            ])
          }).to_text
        )
      ),
      (
        Ai.build_llm_request(ai_cfg, syn1_sys, syn1_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String(
                    "Run kubectl rollout undo deploy/gateway [Gateway Rollback Guide §#{blk1_id}] then verify quorum [Gateway Rollback Guide §#{blk2_id}]."
                  )
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )

  deep_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: q1,
          collection_id: Some(eng_col_id),
          block_kinds: Some(["code_block"]),
          heading_contains: Some("Rollback"),
          include_databases: Some(true),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(2),
          max_rows_scanned: None,
          session_id: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    deep_net
  )
  assert deep_res.status == 200
  dj = must_json(deep_res.text)
  assert dj.text_at("tier") == Some("tier1_read_program")
  assert (dj.int_at("rows_scanned") or 0) >= 6
  assert (dj.int_at("ops_used") or 0) >= 6
  assert dj.int_at("subcalls_used") == Some(2)
  assert dj.bool_at("taint.untrusted_tainted") == Some(false)
  cited_bids = (dj.list_at("citations") or []).map(fn(c) c.text_at("block_id") or "" end)
  assert cited_bids.contains?(blk1_id)
  assert cited_bids.contains?(blk2_id)
  assert not cited_bids.contains?(blk4_id)
  db_rows = dj.list_at("db_slices") or []
  assert db_rows.any?(fn(d) d.text_at("row_id") == Some(row_id) end)
  trace_steps = dj.list_at("trace") or []
  assert trace_steps.any?(fn(st) st.text_at("op") == Some("read_program") end)
  assert trace_steps.any?(fn(st) st.text_at("op") == Some("sub_llm") end)
  assert trace_steps.any?(fn(st) st.text_at("op") == Some("synthesize") end)

  # 2. WorkBudgetExceeded -> HTTP 422
  over_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/ai/deep-research").with_json(
        Ai.DeepResearchInput(
          question: q1,
          collection_id: Some(eng_col_id),
          block_kinds: Some(["code_block"]),
          heading_contains: Some("Rollback"),
          include_databases: Some(false),
          max_pages: None,
          max_blocks_per_page: None,
          max_subcalls: Some(0),
          max_rows_scanned: Some(1),
          session_id: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert over_res.status == 422

  # 3. MCP vellum.rlm_query scoped to eng_col skips sec_col
  q2 = "Rollback Procedure gateway quorum"
  (syn2_sys, syn2_usr) = Ai.build_rlm_synthesis_prompts(q2, [], [s1, s2], [db_s])
  mcp_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(ai_cfg, syn2_sys, syn2_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({
                  "content": Json.String("Scoped agent verified [Gateway Rollback Guide §#{blk1_id}].")
                })
              })
            ])
          }).to_text
        )
      )
    ])
  )
  mcp_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.rlm_query"),
            "arguments": Json.Object({
              "question": Json.String(q2),
              "heading_contains": Json.String("Rollback"),
              "block_kinds": Json.Array([Json.String("code_block")]),
              "max_subcalls": Json.int(0)
            })
          })
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    mcp_net
  )
  assert mcp_ok.status == 200
  mcp_ok_j = must_json(mcp_ok.text)
  assert mcp_ok_j.bool_at("result.isError") == Some(false)
  assert not mcp_ok.text.contains?("vxq99")

  # 4. Scoped agent explicitly requesting sec_col fails closed (Modb.Views / Modb.Grants ViewDenied)
  mcp_denied = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/mcp").with_json(
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(2),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("vellum.rlm_query"),
            "arguments": Json.Object({
              "question": Json.String("vault secret"),
              "collection_id": Json.String(sec_col_id),
              "max_subcalls": Json.int(0)
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
  assert mcp_denied.status == 200
  assert must_json(mcp_denied.text).bool_at("result.isError") == Some(true)
end

test "Conflict-safe vellum sync API: grant-filtered snapshot, YAML + Blueprint push, new page create, and version/policy conflict routing to Modb.World Proposals"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p31.js",
        "css": ["assets/main-p31.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p31.js": "console.log('p31');",
    "public/assets/main-p31.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261205)
  t0 = Time.parse("2026-12-05T10:00:00Z") or stop "t0"
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

  dir_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sync-direct",
          name: "Sync Direct",
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
  assert dir_col_res.status == 201
  dir_col_id = must_json(dir_col_res.text).text_at("id") or stop "dir_col_id"

  gated_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sync-gated",
          name: "Sync Gated",
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
  assert gated_col_res.status == 201
  gated_col_id = must_json(gated_col_res.text).text_at("id") or stop "gated_col_id"

  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "sync-secret",
          name: "Sync Secret",
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

  # Blueprint with required tier field
  bp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/blueprints").with_json(
        Workspace.CreateBlueprintInput(
          slug: "runbook-bp",
          name: "Runbook BP",
          description: Some("Service runbook metadata"),
          icon: None,
          fields: [
            PropertyDef(
              id: "tier",
              name: "Tier",
              kind: Select(
                options: [
                  SelectOption(id: "t1", label: "Tier 1", color: Red),
                  SelectOption(id: "t2", label: "Tier 2", color: Blue)
                ]
              ),
              required: true,
              sort_order: "a"
            )
          ],
          default_template_markdown: Some("## Steps")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bp_res.status == 201
  bp_id = must_json(bp_res.text).text_at("id") or stop "bp_id"

  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: dir_col_id,
          parent_page_id: None,
          title: "Failover SOP",
          markdown: "## Steps\n\nCheck quorum before failover.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed sync page")
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

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Secret Note",
          markdown: "Confidential secret-xyz.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed secret sync page")
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

  meta_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.put("/api/pages/#{pg_id}/meta").with_json(
        Workspace.SetPageMetaInput(
          blueprint_id: Some(bp_id),
          values: Some({"tier": SelectVal(option_id: "t1")}),
          apply_template_if_empty: None,
          reason: Some("attach runbook bp")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert meta_res.status == 200

  gated_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: gated_col_id,
          parent_page_id: None,
          title: "Gated Doc",
          markdown: "Original gated line.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed gated doc")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gated_pg.status == 201
  gated_pg_id = must_json(gated_pg.text).text_at("page.id") or stop "gated_pg_id"

  # Scoped sync agent allowed ONLY on [dir_col_id, gated_col_id]
  mint = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@sync_bot"),
          "display_name": Json.String("Sync Bot"),
          "model_id": Json.Null,
          "label": Json.String("sync"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("write_direct"),
            Json.String("propose")
          ]),
          "allowed_collections": Json.Array([Json.String(dir_col_id), Json.String(gated_col_id)]),
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
  assert mint.status == 201
  ag_tok = must_json(mint.text).text_at("raw_token") or stop "ag_tok"
  ag = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  # 1. Snapshot isolation & YAML frontmatter + blk anchor projection
  snap_res = ApiTest.send(
    Main,
    WebTest.prepare(ag, Api.get("/api/sync/snapshot")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert snap_res.status == 200
  assert not snap_res.text.contains?("secret-xyz")
  snap_j = must_json(snap_res.text)
  snap_pages = snap_j.list_at("pages") or []
  pg_snap = snap_pages.find(fn(p) p.text_at("page_id") == Some(pg_id) end) or stop "pg_snap"
  pg_doc = pg_snap.text_at("markdown_document") or ""
  assert pg_doc.contains?("blueprint: \"runbook-bp\"")
  assert pg_doc.contains?("<!-- blk:")
  pg_rel = pg_snap.text_at("rel_path") or stop "pg_rel"
  pg_ver = pg_snap.int_at("version") or stop "pg_ver"

  # Fail closed when explicitly filtering restricted collection
  snap_denied = ApiTest.send(
    Main,
    WebTest.prepare(ag, Api.get("/api/sync/snapshot?collections=sync-secret")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert snap_denied.status == 403

  # 2. Clean local push updates block AND YAML blueprint tier (t1 -> t2) directly
  clean_doc = pg_doc.replace("  tier: \"t1\"", "  tier: \"t2\"").replace(
    "Check quorum before failover.",
    "Check quorum and drain canary before failover."
  )
  clean_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: Some(pg_id),
          collection_id: Some(dir_col_id),
          rel_path: pg_rel,
          markdown_document: clean_doc,
          expected_version: Some(pg_ver),
          reason: Some("local clean sync")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clean_push.status == 200
  cp_j = must_json(clean_push.text)
  assert cp_j.text_at("outcome") == Some("applied")
  next_ver = cp_j.int_at("page.version") or stop "next_ver"
  assert next_ver == pg_ver + 1
  updated_doc = cp_j.text_at("markdown_document") or ""
  assert updated_doc.contains?("  tier: \"t2\"")
  assert updated_doc.contains?("drain canary")

  # 3. Push brand new local Markdown file without frontmatter -> creates page + stamps anchors
  create_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: None,
          collection_id: None,
          rel_path: "sync-direct/new-checklist.md",
          markdown_document: "# On-Call Checklist\n\n- Verify backups",
          expected_version: None,
          reason: Some("create from neovim")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert create_push.status == 201
  assert must_json(create_push.text).text_at("outcome") == Some("created")
  assert (must_json(create_push.text).text_at("markdown_document") or "").contains?("<!-- blk:")

  # 4. Stale expected_version conflict routes cleanly into a Modb.World Change Proposal (HTTP 202)!
  stale_doc = updated_doc.replace(
    "Check quorum and drain canary before failover.",
    "Divergent local developer edit."
  )
  conflict_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: Some(pg_id),
          collection_id: Some(dir_col_id),
          rel_path: pg_rel,
          markdown_document: stale_doc,
          expected_version: Some(pg_ver),
          reason: Some("divergent offline edit")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert conflict_push.status == 202
  cj = must_json(conflict_push.text)
  assert cj.text_at("outcome") == Some("proposal_opened")
  assert cj.text_at("conflict_reason") == Some("version_mismatch")
  cprop_id = cj.text_at("proposal.id") or stop "cprop_id"

  # Verify live page was NOT overwritten and proposal diff captures surgical change
  live_pg = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(live_pg.text).text_at("anchored_markdown") or "").contains?("drain canary")
  assert not (must_json(live_pg.text).text_at("anchored_markdown") or "").contains?("Divergent local")

  acc_sync = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{cprop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Accept local sync conflict proposal"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_sync.status == 200
  after_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(after_acc.text).text_at("anchored_markdown") or "").contains?("Divergent local")

  # 5. Agent pushing even with current version to ProposalsRequiredForAgents routes to proposal_opened!
  gated_snap = snap_pages.find(fn(p) p.text_at("page_id") == Some(gated_pg_id) end) or stop "gsnap"
  g_doc = (gated_snap.text_at("markdown_document") or "").replace(
    "Original gated line.",
    "Agent gated sync proposal line."
  )
  gated_push = ApiTest.send(
    Main,
    WebTest.prepare(
      ag,
      Api.post("/api/sync/push").with_json(
        Sync.SyncPushInput(
          page_id: Some(gated_pg_id),
          collection_id: Some(gated_col_id),
          rel_path: gated_snap.text_at("rel_path") or "sync-gated/doc.md",
          markdown_document: g_doc,
          expected_version: gated_snap.int_at("version"),
          reason: Some("agent push to gated col")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gated_push.status == 202
  assert must_json(gated_push.text).text_at("conflict_reason") == Some("policy_requires_proposal")
end
