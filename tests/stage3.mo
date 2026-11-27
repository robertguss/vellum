## Vellum Tests.Stage3 Integration Tests (split for Mo lowering budget).
module Tests.Stage3
use Main
use Api
use Arvo.Modb.Jobs
use Arvo.Oidc
use Arvo.WebTest
use Arvo.Webhooks
use Crypto
use Db
use Domain.Types{BlockOp, CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Auth
use Routes.Collab
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

