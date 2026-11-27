## Vellum Tests.Stage4 Integration Tests (split for Mo lowering budget).
module Tests.Stage4
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Db
use Domain.DatabaseModel{DbFilterRule, FilterOp, PropertyDef, PropertyKind}
use Domain.NotionImport{NotionCsvImport, NotionPageImport}
use Domain.Types{CollectionWritePolicy}
use Http
use Json
use Modb.Ledger
use Routes.Ai
use Routes.Auth
use Routes.Databases
use Routes.Importer
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

