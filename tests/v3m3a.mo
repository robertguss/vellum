## Vellum v3 Milestone 3 Slice 3.1 Integration Tests:
## Unified Vellum Chat Core — Public/Private Channels, Deduplicated 1:1 & Group DMs,
## PATCH, SSE Topics, Idempotent Messages, Cursor Pagination, Side-Threads, Reactions,
## Edits, Decisions & Tombstones.
module Tests.V3m3a
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Http
use Json
use Routes.Auth

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

fn make_oidc_mocks(
  sub: Text,
  email: Text,
  display_name: Text,
  code: Text,
  auth_loc: Text,
  oidc_start: Api.Response,
  key_bytes: Bytes
) : (Text, Text, Text, Text, Text)
  q_params = Api.request("GET", auth_loc).query
  oidc_state = q_params.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or stop "state"
  oidc_nonce = q_params.find(fn(p) p.0 == "nonce" end).map(fn(p) p.1 end) or stop "nonce"
  verifier = unseal_oidc_code_verifier(oidc_start, "vellum_oidc_state", key_bytes)
  id_jwt = Oidc.build_unsigned_test_jwt(
    Json.Object({
      "iss": Json.String("https://auth.example.com"),
      "aud": Json.String("vellum-web"),
      "sub": Json.String(sub),
      "nonce": Json.String(oidc_nonce),
      "exp": Json.int(1800000000),
      "email": Json.String(email),
      "email_verified": Json.Boolean(true)
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
    "email_verified": Json.Boolean(true),
    "name": Json.String(display_name)
  }).to_text
  (oidc_state, verifier, code, tok_body, ui_body)
end

fn test_files_map() : Map(Text, Text)
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m3a.js",
        "css": ["assets/main-v3m3a.css"],
        "isEntry": true
      }
    }
    """
  {
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m3a.js": "console.log('v3m3a');",
    "public/assets/main-v3m3a.css": "body{margin:0}"
  }
end

fn test_env_map(key_hex: Text) : Map(Text, Text)
  {
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
  }
end

test "v3 M3.1 channels, private ACL, 1:1 DM dedup, Group DM, PATCH & SSE topics"
  files = Files.in_memory(test_files_map())
  rng = SecureRandom.seeded(20261221)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-12-10T10:00:00Z") or stop "t0"
  c0 = Clock.fixed(t0)
  empty_net = Network.fake(Http.replies([]))
  env = Env.of(test_env_map(key_hex))
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_config failed"
  end

  guest_a = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_a = ApiTest.send(
    Main,
    WebTest.prepare(guest_a, Api.get("/auth/oidc/login?return_to=/")),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  (st_a, ver_a, code_a, tok_a, ui_a) = make_oidc_mocks(
    "sub_ada_1",
    "ada@acme.io",
    "Ada Lovelace",
    "code_a1",
    start_a.header("Location") or "",
    start_a,
    key_bytes
  )
  gw_a = WebTest.absorb(guest_a, start_a)
  ada = WebTest.absorb(
    gw_a,
    ApiTest.send(
      Main,
      WebTest.prepare(gw_a, Api.get("/auth/oidc/callback?code=#{code_a}&state=#{st_a}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, code_a, ver_a), Http.reply(200, tok_a)),
          (
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_1"),
            Http.reply(200, ui_a)
          )
        ])
      )
    )
  )

  guest_b = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_b = ApiTest.send(
    Main,
    WebTest.prepare(guest_b, Api.get("/auth/oidc/login?return_to=/")),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  (st_b, ver_b, code_b, tok_b, ui_b) = make_oidc_mocks(
    "sub_bob_1",
    "bob@acme.io",
    "Bob Member",
    "code_b1",
    start_b.header("Location") or "",
    start_b,
    key_bytes
  )
  gw_b = WebTest.absorb(guest_b, start_b)
  bob = WebTest.absorb(
    gw_b,
    ApiTest.send(
      Main,
      WebTest.prepare(gw_b, Api.get("/auth/oidc/callback?code=#{code_b}&state=#{st_b}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, code_b, ver_b), Http.reply(200, tok_b)),
          (
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_bob_1"),
            Http.reply(200, ui_b)
          )
        ])
      )
    )
  )

  guest_c = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_c = ApiTest.send(
    Main,
    WebTest.prepare(guest_c, Api.get("/auth/oidc/login?return_to=/")),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  (st_c, ver_c, code_c, tok_c, ui_c) = make_oidc_mocks(
    "sub_carol_1",
    "carol@acme.io",
    "Carol Member",
    "code_c1",
    start_c.header("Location") or "",
    start_c,
    key_bytes
  )
  gw_c = WebTest.absorb(guest_c, start_c)
  carol = WebTest.absorb(
    gw_c,
    ApiTest.send(
      Main,
      WebTest.prepare(gw_c, Api.get("/auth/oidc/callback?code=#{code_c}&state=#{st_c}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, code_c, ver_c), Http.reply(200, tok_c)),
          (
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_carol_1"),
            Http.reply(200, ui_c)
          )
        ])
      )
    )
  )

  prs = must_json(
    ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/admin/vault/status")), files, c0, env, rng, empty_net)
      .text
  ).list_at("principals") or []
  ada_pid = (prs.find(fn(p) p.text_at("email") == Some("ada@acme.io") end) or Json.Null).text_at("id") or
    stop "ada_pid"
  bob_pid = (prs.find(fn(p) p.text_at("email") == Some("bob@acme.io") end) or Json.Null).text_at("id") or
    stop "bob_pid"
  carol_pid = (prs.find(fn(p) p.text_at("email") == Some("carol@acme.io") end) or Json.Null).text_at("id") or
    stop "carol_pid"

  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/collections").with_json(
        Json.Object({
          "slug": Json.String("chat-ops"),
          "name": Json.String("Chat Ops"),
          "description": Json.Null,
          "icon": Json.Null,
          "write_policy": Json.String("direct_with_audit"),
          "freshness_ttl_days": Json.Null
        })
      )
    ),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  assert col_res.status == 201
  col_id = must_json(col_res.text).text_at("id") or stop "col_id"

  pub_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels").with_json(
        Json.Object({
          "kind": Json.String("public"),
          "collection_id": Json.String(col_id),
          "name": Json.String("Engineering Hub"),
          "topic": Json.String("Daily triage"),
          "member_principal_ids": Json.Array([])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 1.seconds),
    env,
    rng,
    empty_net
  )
  assert pub_res.status == 201
  ch_pub = must_json(pub_res.text).text_at("channel.id") or stop "ch_pub"

  priv_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels").with_json(
        Json.Object({
          "kind": Json.String("private"),
          "collection_id": Json.String(col_id),
          "name": Json.String("Sec Review"),
          "topic": Json.String("Incident response"),
          "member_principal_ids": Json.Array([Json.String(bob_pid)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 2.seconds),
    env,
    rng,
    empty_net
  )
  assert priv_res.status == 201
  ch_priv = must_json(priv_res.text).text_at("channel.id") or stop "ch_priv"

  dm1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels").with_json(
        Json.Object({
          "kind": Json.String("dm"),
          "collection_id": Json.Null,
          "name": Json.String(""),
          "topic": Json.String(""),
          "member_principal_ids": Json.Array([Json.String(bob_pid)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 3.seconds),
    env,
    rng,
    empty_net
  )
  assert dm1_res.status == 201
  dm1_j = must_json(dm1_res.text)
  assert dm1_j.bool_at("existing") == Some(false)
  ch_dm1 = dm1_j.text_at("channel.id") or stop "ch_dm1"

  dm_dup_a = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels").with_json(
        Json.Object({
          "kind": Json.String("dm"),
          "collection_id": Json.Null,
          "name": Json.String(""),
          "topic": Json.String(""),
          "member_principal_ids": Json.Array([Json.String(bob_pid)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 4.seconds),
    env,
    rng,
    empty_net
  )
  assert dm_dup_a.status == 200 and must_json(dm_dup_a.text).bool_at("existing") == Some(true)
  assert must_json(dm_dup_a.text).text_at("channel.id") == Some(ch_dm1)

  dm_dup_b = ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/channels").with_json(
        Json.Object({
          "kind": Json.String("dm"),
          "collection_id": Json.Null,
          "name": Json.String(""),
          "topic": Json.String(""),
          "member_principal_ids": Json.Array([Json.String(ada_pid)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 5.seconds),
    env,
    rng,
    empty_net
  )
  assert dm_dup_b.status == 200 and must_json(dm_dup_b.text).bool_at("existing") == Some(true)
  assert must_json(dm_dup_b.text).text_at("channel.id") == Some(ch_dm1)

  dm_grp = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels").with_json(
        Json.Object({
          "kind": Json.String("dm"),
          "collection_id": Json.Null,
          "name": Json.String("Launch Core"),
          "topic": Json.String("Cutover"),
          "member_principal_ids": Json.Array([Json.String(bob_pid), Json.String(carol_pid)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 6.seconds),
    env,
    rng,
    empty_net
  )
  assert dm_grp.status == 201 and must_json(dm_grp.text).bool_at("existing") == Some(false)
  assert must_json(dm_grp.text).text_at("channel.id") != Some(ch_dm1)

  for denied_ch in [ch_priv, ch_dm1]
    assert ApiTest.send(
      Main,
      WebTest.prepare(carol, Api.get("/api/v1/chat/channels/#{denied_ch}/messages")),
      files,
      c0,
      env,
      rng,
      empty_net
    ).status ==
      403
    assert ApiTest.send(
      Main,
      WebTest.prepare(
        carol,
        Api.post("/api/v1/chat/channels/#{denied_ch}/messages").with_json(
          Json.Object({"body_markdown": Json.String("intrude")})
        )
      ),
      files,
      c0,
      env,
      rng,
      empty_net
    ).status ==
      403
    assert ApiTest.send(
      Main,
      WebTest.prepare(carol, Api.get("/api/v1/events?channel_id=#{denied_ch}")),
      files,
      c0,
      env,
      rng,
      empty_net
    ).status ==
      403
  end

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.patch("/api/v1/chat/channels/#{ch_pub}").with_json(
        Json.Object({"topic": Json.String("hijack")})
      )
    ),
    files,
    c0,
    env,
    rng,
    empty_net
  ).status ==
    403

  pch = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/v1/chat/channels/#{ch_pub}").with_json(
        Json.Object({"name": Json.String("Platform Hub"), "topic": Json.String("Release eng")})
      )
    ),
    files,
    Clock.fixed(t0 + 7.seconds),
    env,
    rng,
    empty_net
  )
  assert pch.status == 200
  assert must_json(pch.text).text_at("channel.slug") == Some("platform-hub")
  assert must_json(pch.text).text_at("channel.topic") == Some("Release eng")

  ev_sub = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/v1/events?channel_id=#{ch_pub}")),
    files,
    Clock.fixed(t0 + 8.seconds),
    env,
    rng,
    empty_net
  )
  assert ev_sub.status == 200
  assert ev_sub.sse_subscribe_topics == ["claims", "chat:inbox:#{ada_pid}", "chat:channel:#{ch_pub}"]
end

test "v3 M3.1 messages, idempotency, cursor pagination, threads, reactions, edit, decision & tombstone"
  files = Files.in_memory(test_files_map())
  rng = SecureRandom.seeded(20261222)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-12-10T10:00:00Z") or stop "t0"
  c0 = Clock.fixed(t0)
  empty_net = Network.fake(Http.replies([]))
  env = Env.of(test_env_map(key_hex))
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_config failed"
  end

  guest_a = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_a = ApiTest.send(
    Main,
    WebTest.prepare(guest_a, Api.get("/auth/oidc/login?return_to=/")),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  (st_a, ver_a, code_a, tok_a, ui_a) = make_oidc_mocks(
    "sub_ada_2",
    "ada@acme.io",
    "Ada Lovelace",
    "code_a2",
    start_a.header("Location") or "",
    start_a,
    key_bytes
  )
  gw_a = WebTest.absorb(guest_a, start_a)
  ada = WebTest.absorb(
    gw_a,
    ApiTest.send(
      Main,
      WebTest.prepare(gw_a, Api.get("/auth/oidc/callback?code=#{code_a}&state=#{st_a}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, code_a, ver_a), Http.reply(200, tok_a)),
          (
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_2"),
            Http.reply(200, ui_a)
          )
        ])
      )
    )
  )

  guest_b = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_b = ApiTest.send(
    Main,
    WebTest.prepare(guest_b, Api.get("/auth/oidc/login?return_to=/")),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  (st_b, ver_b, code_b, tok_b, ui_b) = make_oidc_mocks(
    "sub_bob_2",
    "bob@acme.io",
    "Bob Member",
    "code_b2",
    start_b.header("Location") or "",
    start_b,
    key_bytes
  )
  gw_b = WebTest.absorb(guest_b, start_b)
  bob = WebTest.absorb(
    gw_b,
    ApiTest.send(
      Main,
      WebTest.prepare(gw_b, Api.get("/auth/oidc/callback?code=#{code_b}&state=#{st_b}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, code_b, ver_b), Http.reply(200, tok_b)),
          (
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_bob_2"),
            Http.reply(200, ui_b)
          )
        ])
      )
    )
  )

  col_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/collections").with_json(
          Json.Object({
            "slug": Json.String("msg-ops"),
            "name": Json.String("Msg Ops"),
            "description": Json.Null,
            "icon": Json.Null,
            "write_policy": Json.String("direct_with_audit"),
            "freshness_ttl_days": Json.Null
          })
        )
      ),
      files,
      c0,
      env,
      rng,
      empty_net
    ).text
  ).text_at("id") or stop "col_id"

  ch_pub = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/v1/chat/channels").with_json(
          Json.Object({
            "kind": Json.String("public"),
            "collection_id": Json.String(col_id),
            "name": Json.String("Messages Room"),
            "topic": Json.String("Core"),
            "member_principal_ids": Json.Array([])
          })
        )
      ),
      files,
      Clock.fixed(t0 + 1.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("channel.id") or stop "ch_pub"

  # Idempotent POST + SSE
  m1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("First kickoff message"),
          "client_msg_id": Json.String("cli_idem_1")
        })
      )
    ),
    files,
    Clock.fixed(t0 + 2.seconds),
    env,
    rng,
    empty_net
  )
  assert m1_res.status == 201 and must_json(m1_res.text).bool_at("deduplicated") == Some(false)
  m1_id = must_json(m1_res.text).text_at("message.id") or stop "m1_id"
  assert m1_res.sse_published_events.any?(fn(e)
    e.topic == "chat:channel:#{ch_pub}" and e.event == Some("chat.message_created")
  end)

  m1_dup = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("First kickoff message"),
          "client_msg_id": Json.String("cli_idem_1")
        })
      )
    ),
    files,
    Clock.fixed(t0 + 3.seconds),
    env,
    rng,
    empty_net
  )
  assert m1_dup.status == 200 and must_json(m1_dup.text).bool_at("deduplicated") == Some(true)
  assert must_json(m1_dup.text).text_at("message.id") == Some(m1_id)

  m2_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        bob,
        Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
          Json.Object({"body_markdown": Json.String("Second root message")})
        )
      ),
      files,
      Clock.fixed(t0 + 4.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("message.id") or stop "m2_id"

  m3_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
          Json.Object({"body_markdown": Json.String("Third root message")})
        )
      ),
      files,
      Clock.fixed(t0 + 5.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("message.id") or stop "m3_id"

  # Pagination: ?limit=2, ?before=..., ?after=...
  top_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_pub}/messages?limit=2")),
      files,
      Clock.fixed(t0 + 6.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  assert top_j.bool_at("has_more") == Some(true)
  assert (top_j.list_at("messages") or []).size == 2
  assert top_j.text_at("next_before_cursor") == Some(m2_id)
  assert top_j.text_at("next_after_cursor") == Some(m3_id)

  old_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_pub}/messages?before=#{m2_id}&limit=2")),
      files,
      Clock.fixed(t0 + 7.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  assert old_j.bool_at("has_more") == Some(false)
  assert (old_j.list_at("messages") or []).size == 1
  assert ((old_j.list_at("messages") or []).first or Json.Null).text_at("id") == Some(m1_id)

  after_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_pub}/messages?after=#{m1_id}&limit=10")),
      files,
      Clock.fixed(t0 + 8.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  assert (after_j.list_at("messages") or []).size == 2

  # Side-threads + reject nested reply (422)
  r1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("Thread reply from Bob"),
          "parent_message_id": Json.String(m1_id)
        })
      )
    ),
    files,
    Clock.fixed(t0 + 9.seconds),
    env,
    rng,
    empty_net
  )
  assert r1_res.status == 201
  r1_id = must_json(r1_res.text).text_at("message.id") or stop "r1_id"
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("Nested"),
          "parent_message_id": Json.String(r1_id)
        })
      )
    ),
    files,
    Clock.fixed(t0 + 10.seconds),
    env,
    rng,
    empty_net
  ).status ==
    422

  thr_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_pub}/messages?parent_message_id=#{m1_id}")),
      files,
      Clock.fixed(t0 + 11.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  assert (thr_j.list_at("messages") or []).size == 1

  roots_chk = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_pub}/messages?before=#{m2_id}&limit=5")),
      files,
      Clock.fixed(t0 + 12.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  assert ((roots_chk.list_at("messages") or []).first or Json.Null).int_at("reply_count") == Some(1)

  # Reactions (+ SSE)
  ron = ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages/#{m1_id}/reactions").with_json(
        Json.Object({"emoji": Json.String("👍")})
      )
    ),
    files,
    Clock.fixed(t0 + 13.seconds),
    env,
    rng,
    empty_net
  )
  assert ron.status == 200 and (must_json(ron.text).get("reactions") or Json.Object({})).list_at("👍") != None
  assert ron.sse_published_events.any?(fn(e)
    e.topic == "chat:channel:#{ch_pub}" and e.event == Some("chat.reaction_updated")
  end)

  roff = ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages/#{m1_id}/reactions").with_json(
        Json.Object({"emoji": Json.String("👍")})
      )
    ),
    files,
    Clock.fixed(t0 + 14.seconds),
    env,
    rng,
    empty_net
  )
  assert roff.status == 200 and
    (must_json(roff.text).get("reactions") or Json.Object({})).list_at("👍") == None

  # Edit + is_decision + non-author 403 + ?decisions_only=1
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.patch("/api/v1/chat/channels/#{ch_pub}/messages/#{m1_id}").with_json(
        Json.Object({"body_markdown": Json.String("hijack")})
      )
    ),
    files,
    Clock.fixed(t0 + 15.seconds),
    env,
    rng,
    empty_net
  ).status ==
    403

  em1 = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/v1/chat/channels/#{ch_pub}/messages/#{m1_id}").with_json(
        Json.Object({"body_markdown": Json.String("Kickoff updated!"), "is_decision": Json.Boolean(true)})
      )
    ),
    files,
    Clock.fixed(t0 + 16.seconds),
    env,
    rng,
    empty_net
  )
  assert em1.status == 200
  assert must_json(em1.text).bool_at("message.is_decision") == Some(true)
  assert must_json(em1.text).text_at("message.edited_at") != None
  assert em1.sse_published_events.any?(fn(e)
    e.topic == "chat:channel:#{ch_pub}" and e.event == Some("chat.message_updated")
  end)

  dec_msgs = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_pub}/messages?decisions_only=1")),
      files,
      Clock.fixed(t0 + 17.seconds),
      env,
      rng,
      empty_net
    ).text
  ).list_at("messages") or []
  assert dec_msgs.size == 1 and (dec_msgs.first or Json.Null).text_at("id") == Some(m1_id)

  # Tombstone Delete + 422 guards
  m_del_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        bob,
        Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
          Json.Object({"body_markdown": Json.String("temp draft")})
        )
      ),
      files,
      Clock.fixed(t0 + 18.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("message.id") or stop "m_del_id"

  del_res = ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.delete("/api/v1/chat/channels/#{ch_pub}/messages/#{m_del_id}")),
    files,
    Clock.fixed(t0 + 19.seconds),
    env,
    rng,
    empty_net
  )
  assert del_res.status == 200 and must_json(del_res.text).bool_at("deleted") == Some(true)
  assert must_json(del_res.text).text_at("message.body_markdown") == Some("")
  assert del_res.sse_published_events.any?(fn(e)
    e.topic == "chat:channel:#{ch_pub}" and e.event == Some("chat.message_deleted")
  end)
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.patch("/api/v1/chat/channels/#{ch_pub}/messages/#{m_del_id}").with_json(
        Json.Object({"body_markdown": Json.String("nope")})
      )
    ),
    files,
    Clock.fixed(t0 + 20.seconds),
    env,
    rng,
    empty_net
  ).status ==
    422
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages/#{m_del_id}/reactions").with_json(
        Json.Object({"emoji": Json.String("👍")})
      )
    ),
    files,
    Clock.fixed(t0 + 21.seconds),
    env,
    rng,
    empty_net
  ).status ==
    422
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({"body_markdown": Json.String("nope"), "parent_message_id": Json.String(m_del_id)})
      )
    ),
    files,
    Clock.fixed(t0 + 22.seconds),
    env,
    rng,
    empty_net
  ).status ==
    422
end
