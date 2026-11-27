## Vellum v3 Milestone 3 Slice 3.1 Vault & Compliance Integration Tests:
## Calm Inbox, Read Cursors, Chat Attachments ACL, Inertia `/chat`,
## FERPA Vault Chat Isolation + Modb.Ledger Audit, and Modb.Erasure Chat PII Scrub.
module Tests.V3m3aVault
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Db
use Http
use Json
use Modb.Ledger
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
    "VELLUM_ATTACHMENTS_BACKEND": "local",
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

test "v3 M3.1 Calm Inbox, read cursors, chat attachments ACL & Inertia /chat"
  files = Files.in_memory(test_files_map())
  rng = SecureRandom.seeded(20261223)
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
    "sub_ada_3",
    "ada@acme.io",
    "Ada Lovelace",
    "code_a3",
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
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_3"),
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
    "sub_bob_3",
    "bob@acme.io",
    "Bob Member",
    "code_b3",
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
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_bob_3"),
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
    "sub_carol_3",
    "carol@acme.io",
    "Carol Member",
    "code_c3",
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
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_carol_3"),
            Http.reply(200, ui_c)
          )
        ])
      )
    )
  )

  dir_j = must_json(
    ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/v1/chat/channels")), files, c0, env, rng, empty_net)
      .text
  )
  dir_ps = dir_j.list_at("principals") or []
  bob_obj = dir_ps.find(fn(p) p.text_at("display_name") == Some("Bob Member") end) or Json.Null
  bob_pid = bob_obj.text_at("id") or stop "bob_pid"
  raw_bh = bob_obj.text_at("handle") or "bob"
  bob_h = raw_bh.drop_prefix("@") or raw_bh

  col_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/collections").with_json(
          Json.Object({
            "slug": Json.String("inbox-ops"),
            "name": Json.String("Inbox Ops"),
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
            "name": Json.String("General"),
            "topic": Json.String("Main"),
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

  ch_priv = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/v1/chat/channels").with_json(
          Json.Object({
            "kind": Json.String("private"),
            "collection_id": Json.String(col_id),
            "name": Json.String("Private Att Room"),
            "topic": Json.String("Files"),
            "member_principal_ids": Json.Array([Json.String(bob_pid)])
          })
        )
      ),
      files,
      Clock.fixed(t0 + 2.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("channel.id") or stop "ch_priv"

  ch_dm1 = must_json(
    ApiTest.send(
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
    ).text
  ).text_at("channel.id") or stop "ch_dm1"

  # Mention + thread_reply + dm -> Bob Calm Inbox + read cursor + ack
  bob_root_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        bob,
        Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
          Json.Object({"body_markdown": Json.String("Bob question thread root")})
        )
      ),
      files,
      Clock.fixed(t0 + 4.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("message.id") or stop "bob_root_id"

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("Ada reply to thread"),
          "parent_message_id": Json.String(bob_root_id)
        })
      )
    ),
    files,
    Clock.fixed(t0 + 5.seconds),
    env,
    rng,
    empty_net
  ).status ==
    201

  mention_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(
        Json.Object({"body_markdown": Json.String("Heads up @#{bob_h} check deployment")})
      )
    ),
    files,
    Clock.fixed(t0 + 6.seconds),
    env,
    rng,
    empty_net
  )
  assert mention_res.status == 201
  assert mention_res.sse_published_events.any?(fn(e)
    e.topic == "chat:inbox:#{bob_pid}" and e.event == Some("chat.inbox_updated")
  end)

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_dm1}/messages").with_json(
        Json.Object({"body_markdown": Json.String("DM ping for Bob")})
      )
    ),
    files,
    Clock.fixed(t0 + 7.seconds),
    env,
    rng,
    empty_net
  ).status ==
    201

  bi_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(bob, Api.get("/api/v1/chat/inbox?unread_only=1")),
      files,
      Clock.fixed(t0 + 8.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  bi_items = bi_j.list_at("items") or []
  bi_ucnt = bi_j.int_at("unread_count") or 0
  assert bi_ucnt >= 3
  bi_kinds = bi_items.map(fn(x) x.text_at("kind") or "" end)
  assert bi_kinds.contains?("mention")
  assert bi_kinds.contains?("thread_reply")
  assert bi_kinds.contains?("dm")

  bob_chs = must_json(
    ApiTest.send(Main, WebTest.prepare(bob, Api.get("/api/v1/chat/channels")), files, c0, env, rng, empty_net)
      .text
  ).list_at("channels") or []
  pub_b = bob_chs.find(fn(c) c.text_at("id") == Some(ch_pub) end) or stop "pub_b"
  assert (pub_b.int_at("unread_count") or 0) > 0

  mark_r = ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.post("/api/v1/chat/channels/#{ch_pub}/read").with_json(Json.Object({}))),
    files,
    Clock.fixed(t0 + 9.seconds),
    env,
    rng,
    empty_net
  )
  assert mark_r.status == 200 and must_json(mark_r.text).int_at("unread_count") == Some(0)

  bob_chs2 = must_json(
    ApiTest.send(Main, WebTest.prepare(bob, Api.get("/api/v1/chat/channels")), files, c0, env, rng, empty_net)
      .text
  ).list_at("channels") or []
  assert (bob_chs2.find(fn(c) c.text_at("id") == Some(ch_pub) end) or Json.Null).int_at("unread_count") ==
    Some(0)

  first_nid = (bi_items.first or Json.Null).text_at("id") or stop "first_nid"
  ack1 = ApiTest.send(
    Main,
    WebTest.prepare(
      bob,
      Api.post("/api/v1/chat/inbox/ack").with_json(Json.Object({"notification_id": Json.String(first_nid)}))
    ),
    files,
    Clock.fixed(t0 + 10.seconds),
    env,
    rng,
    empty_net
  )
  assert ack1.status == 200 and must_json(ack1.text).int_at("unread_count") == Some(bi_ucnt - 1)

  ack_all = ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.post("/api/v1/chat/inbox/ack").with_json(Json.Object({"all": Json.Boolean(true)}))),
    files,
    Clock.fixed(t0 + 11.seconds),
    env,
    rng,
    empty_net
  )
  assert ack_all.status == 200 and must_json(ack_all.text).int_at("unread_count") == Some(0)

  # Chat Attachments ACL on private channel
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      carol,
      Api.post("/api/attachments/presign").with_json(
        Json.Object({
          "page_id": Json.String(ch_priv),
          "filename": Json.String("nope.txt"),
          "content_type": Json.String("text/plain"),
          "size_bytes": Json.int(4),
          "sha256_hex": Json.Null
        })
      )
    ),
    files,
    Clock.fixed(t0 + 12.seconds),
    env,
    rng,
    empty_net
  ).status ==
    403

  att_bytes = "private-chat-spec-v1\n".bytes
  pre_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/attachments/presign").with_json(
          Json.Object({
            "page_id": Json.String(ch_priv),
            "filename": Json.String("secret-spec.txt"),
            "content_type": Json.String("text/plain"),
            "size_bytes": Json.int(att_bytes.size),
            "sha256_hex": Json.String(Crypto.sha256(att_bytes).to_hex)
          })
        )
      ),
      files,
      Clock.fixed(t0 + 13.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  att_id = pre_j.text_at("attachment.id") or stop "att_id"
  assert ApiTest.send(
    Main,
    Api.put(pre_j.text_at("upload_url") or "").with_bytes(att_bytes, "application/octet-stream"),
    files,
    Clock.fixed(t0 + 14.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200
  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.post("/api/attachments/#{att_id}/commit").with_json(Json.Object({}))),
    files,
    Clock.fixed(t0 + 15.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200

  att_msg = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_priv}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("See attached security spec"),
          "attachment_ids": Json.Array([Json.String(att_id)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 16.seconds),
    env,
    rng,
    empty_net
  )
  assert att_msg.status == 201
  assert ((must_json(att_msg.text).list_at("message.attachments") or []).first or Json.Null).text_at(
    "download_url"
  ) ==
    Some("/api/attachments/#{att_id}/download")

  bob_dl = ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.get("/api/attachments/#{att_id}/download")),
    files,
    Clock.fixed(t0 + 17.seconds),
    env,
    rng,
    empty_net
  )
  assert bob_dl.status == 200 and bob_dl.body == att_bytes
  assert ApiTest.send(
    Main,
    WebTest.prepare(carol, Api.get("/api/attachments/#{att_id}/download")),
    files,
    Clock.fixed(t0 + 18.seconds),
    env,
    rng,
    empty_net
  ).status ==
    403

  # Inertia /chat Surface (JSON + HTML)
  chat_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.get("/chat").with_header("Accept", "application/json")),
      files,
      c0,
      env,
      rng,
      empty_net
    ).text
  )
  assert chat_j.list_at("channels") != None and chat_j.list_at("principals") != None
  assert chat_j.int_at("inbox_unread_count") != None and chat_j.list_at("collections") != None

  chat_html = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/chat?channel=#{ch_pub}&msg=#{bob_root_id}")),
    files,
    c0,
    env,
    rng,
    empty_net
  )
  assert chat_html.status == 200 and chat_html.text.contains?("Workspace/Chat")
  assert chat_html.text.contains?(ch_pub) and chat_html.text.contains?(bob_root_id)
end

test "v3 M3.1 FERPA Vault chat isolation, Modb.Ledger audit & Modb.Erasure PII scrub"
  files = Files.in_memory(test_files_map())
  rng = SecureRandom.seeded(20261224)
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
    "sub_ada_4",
    "ada@acme.io",
    "Ada Lovelace",
    "code_a4",
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
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_4"),
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
    "sub_bob_4",
    "bob@acme.io",
    "Bob Member",
    "code_b4",
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
            Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_bob_4"),
            Http.reply(200, ui_b)
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
  raw_bh = (prs.find(fn(p) p.text_at("email") == Some("bob@acme.io") end) or Json.Null).text_at("handle") or
    "bob"
  bob_h = raw_bh.drop_prefix("@") or raw_bh

  col_std = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/collections").with_json(
          Json.Object({
            "slug": Json.String("std-erasure"),
            "name": Json.String("Std Erasure"),
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
  ).text_at("id") or stop "col_std"

  col_ferpa = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/collections").with_json(
          Json.Object({
            "slug": Json.String("ferpa-chat"),
            "name": Json.String("FERPA Chat"),
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
  ).text_at("id") or stop "col_ferpa"

  grp_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/admin/groups").with_json(
          Json.Object({
            "name": Json.String("Registrar"),
            "slug": Json.Null,
            "description": Json.String("Registrar staff"),
            "member_principal_ids": Json.Array([Json.String(ada_pid)])
          })
        )
      ),
      files,
      c0,
      env,
      rng,
      empty_net
    ).text
  ).text_at("group.id") or stop "grp_id"

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/collections/#{col_ferpa}/security").with_json(
        Json.Object({
          "security_tier": Json.String("ferpa_restricted"),
          "allowed_group_ids": Json.Array([Json.String(grp_id)]),
          "allowed_principal_ids": Json.Array([]),
          "allow_local_ai": Json.Boolean(false),
          "reason": Json.String("lock ferpa chat")
        })
      )
    ),
    files,
    Clock.fixed(t0 + 1.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200

  bot_tok = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/admin/agents").with_json(
          Json.Object({
            "handle": Json.String("ws-chat-bot"),
            "display_name": Json.String("Workspace Chat Bot"),
            "model_id": Json.String("gpt-4o-mini"),
            "label": Json.String("wildcard"),
            "allowed_actions": Json.Array([
              Json.String("read"),
              Json.String("comment"),
              Json.String("write_direct"),
              Json.String("upload_attachment")
            ]),
            "allowed_collections": Json.Null,
            "max_calls": Json.int(50),
            "ttl_days": Json.int(7)
          })
        )
      ),
      files,
      Clock.fixed(t0 + 2.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("raw_token") or stop "bot_tok"
  bot = WebTest.new().with_header("Authorization", "Bearer #{bot_tok}")

  ch_ferpa = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/v1/chat/channels").with_json(
          Json.Object({
            "kind": Json.String("public"),
            "collection_id": Json.String(col_ferpa),
            "name": Json.String("Student Care Room"),
            "topic": Json.String("Restricted"),
            "member_principal_ids": Json.Array([])
          })
        )
      ),
      files,
      Clock.fixed(t0 + 3.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("channel.id") or stop "ch_ferpa"

  fatt_bytes = "ferpa-case-chat-file\n".bytes
  fpre_j = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/attachments/presign").with_json(
          Json.Object({
            "page_id": Json.String(ch_ferpa),
            "filename": Json.String("case-file.txt"),
            "content_type": Json.String("text/plain"),
            "size_bytes": Json.int(fatt_bytes.size),
            "sha256_hex": Json.Null
          })
        )
      ),
      files,
      Clock.fixed(t0 + 4.seconds),
      env,
      rng,
      empty_net
    ).text
  )
  fatt_id = fpre_j.text_at("attachment.id") or stop "fatt_id"
  assert ApiTest.send(
    Main,
    Api.put(fpre_j.text_at("upload_url") or "").with_bytes(fatt_bytes, "application/octet-stream"),
    files,
    Clock.fixed(t0 + 5.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200
  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.post("/api/attachments/#{fatt_id}/commit").with_json(Json.Object({}))),
    files,
    Clock.fixed(t0 + 6.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_ferpa}/messages").with_json(
        Json.Object({
          "body_markdown": Json.String("Protected @#{bob_h} ferpachat993 record"),
          "attachment_ids": Json.Array([Json.String(fatt_id)])
        })
      )
    ),
    files,
    Clock.fixed(t0 + 7.seconds),
    env,
    rng,
    empty_net
  ).status ==
    201

  for caller in [bob, bot]
    assert ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/v1/chat/channels/#{ch_ferpa}/messages")),
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
        caller,
        Api.post("/api/v1/chat/channels/#{ch_ferpa}/messages").with_json(
          Json.Object({"body_markdown": Json.String("probe")})
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
      WebTest.prepare(caller, Api.get("/api/v1/events?channel_id=#{ch_ferpa}")),
      files,
      c0,
      env,
      rng,
      empty_net
    ).status ==
      403
    assert ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/attachments/#{fatt_id}/download")),
      files,
      c0,
      env,
      rng,
      empty_net
    ).status ==
      403
    cs = ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/v1/chat/search?q=ferpachat993")),
      files,
      c0,
      env,
      rng,
      empty_net
    )
    assert cs.status == 200 and (must_json(cs.text).list_at("results") or []).empty?
    us = ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/search?q=ferpachat993&include_chat=1")),
      files,
      c0,
      env,
      rng,
      empty_net
    )
    assert us.status == 200 and (must_json(us.text).list_at("chat_results") or []).empty?
  end

  bob_inb = ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.get("/api/v1/chat/inbox")),
    files,
    Clock.fixed(t0 + 8.seconds),
    env,
    rng,
    empty_net
  )
  assert bob_inb.status == 200 and not bob_inb.text.contains?(ch_ferpa) and
    not bob_inb.text.contains?("ferpachat993")

  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_ferpa}/messages")),
    files,
    Clock.fixed(t0 + 9.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200
  ada_fdl = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/attachments/#{fatt_id}/download")),
    files,
    Clock.fixed(t0 + 10.seconds),
    env,
    rng,
    empty_net
  )
  assert ada_fdl.status == 200 and ada_fdl.body == fatt_bytes

  faud = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/admin/ferpa/audit?collection_id=#{col_ferpa}")),
    files,
    Clock.fixed(t0 + 11.seconds),
    env,
    rng,
    empty_net
  )
  assert faud.status == 200
  assert faud.text.contains?("chat.channel_viewed")
  assert faud.text.contains?("ferpa.attachment.downloaded")

  # Modb.Erasure Chat PII Scrubbing
  ch_std = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(
        ada,
        Api.post("/api/v1/chat/channels").with_json(
          Json.Object({
            "kind": Json.String("public"),
            "collection_id": Json.String(col_std),
            "name": Json.String("Erasure Room"),
            "topic": Json.String("Scrub"),
            "member_principal_ids": Json.Array([])
          })
        )
      ),
      files,
      Clock.fixed(t0 + 12.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("channel.id") or stop "ch_std"

  ssn_tok = "214-88-4321"
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_std}/messages").with_json(
        Json.Object({"body_markdown": Json.String("Synthetic intake @#{bob_h} SSN #{ssn_tok}")})
      )
    ),
    files,
    Clock.fixed(t0 + 13.seconds),
    env,
    rng,
    empty_net
  ).status ==
    201

  est_b = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/admin/erasure/status")),
    files,
    Clock.fixed(t0 + 14.seconds),
    env,
    rng,
    empty_net
  )
  assert est_b.status == 200 and not est_b.text.contains?(ssn_tok)
  assert (must_json(est_b.text).list_at("findings") or []).any?(fn(f)
    f.text_at("kind") == Some("us_ssn") and f.text_at("target_kind") == Some("chat_message")
  end)

  purge_r = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/admin/erasure/purge").with_json(
        Json.Object({
          "mode": Json.String("redact"),
          "compact": Json.Boolean(true),
          "reason": Json.String("Scrub chat SSN #{ssn_tok}")
        })
      )
    ),
    files,
    Clock.fixed(t0 + 15.seconds),
    env,
    rng,
    empty_net
  )
  assert purge_r.status == 200 and not purge_r.text.contains?(ssn_tok)
  assert must_json(purge_r.text).bool_at("receipt.key_shredded") == Some(true)
  assert must_json(purge_r.text).bool_at("receipt.compacted") == Some(true)

  pub_a = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_std}/messages")),
    files,
    Clock.fixed(t0 + 16.seconds),
    env,
    rng,
    empty_net
  )
  assert pub_a.status == 200 and pub_a.text.contains?("[REDACTED]") and not pub_a.text.contains?(ssn_tok)

  inb_a = ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.get("/api/v1/chat/inbox")),
    files,
    Clock.fixed(t0 + 17.seconds),
    env,
    rng,
    empty_net
  )
  assert inb_a.status == 200 and inb_a.text.contains?("[REDACTED]") and not inb_a.text.contains?(ssn_tok)

  cs_a = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/v1/chat/search?q=#{ssn_tok}")),
    files,
    Clock.fixed(t0 + 18.seconds),
    env,
    rng,
    empty_net
  )
  assert cs_a.status == 200 and (must_json(cs_a.text).list_at("results") or []).empty?

  est_a = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/admin/erasure/status")),
    files,
    Clock.fixed(t0 + 19.seconds),
    env,
    rng,
    empty_net
  )
  assert est_a.status == 200 and (must_json(est_a.text).list_at("findings") or []).empty?

  assert Ledger.open(files, Db.ledger_db_path, Db.vellum_schema(), t0) is Ok(vdb)
  assert Ledger.verify_all(vdb) is Ok(_)
  raw_disk = case files.read_only.read_bytes(Db.ledger_db_path)
    Ok(b): b
    Error(_): stop "read raw disk"
  end
  assert not raw_disk.to_hex.contains?(ssn_tok.bytes.to_hex)
end
