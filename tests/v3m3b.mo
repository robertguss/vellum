## Vellum v3 Milestone 3 Slice 3.2 Integration Tests:
## Chat Moat (1-Click Thread->Task + Live Status Sync + Bidirectional Backlinks),
## ACL-Safe Inline Citations & FERPA Redaction, Decision -> Modb.World Proposals,
## Cross-Boundary FERPA Locks, Private Origin Hiding & Slack Export Batch Importer.
module Tests.V3m3b
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
        "file": "assets/main-v3m3b.js",
        "css": ["assets/main-v3m3b.css"],
        "isEntry": true
      }
    }
    """
  {
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m3b.js": "console.log('v3m3b');",
    "public/assets/main-v3m3b.css": "body{margin:0}"
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

fn col_req(slug: Text, name: Text) : Api.Request
  Api.post("/api/collections").with_json(
    Json.Object({
      "slug": Json.String(slug),
      "name": Json.String(name),
      "description": Json.Null,
      "icon": Json.Null,
      "write_policy": Json.String("direct_with_audit"),
      "freshness_ttl_days": Json.Null
    })
  )
end

fn page_req(col_id: Text, title: Text, md: Text) : Api.Request
  Api.post("/api/pages").with_json(
    Json.Object({
      "collection_id": Json.String(col_id),
      "parent_page_id": Json.Null,
      "title": Json.String(title),
      "markdown": Json.String(md),
      "icon": Json.Null,
      "freshness_ttl_days": Json.Null,
      "reason": Json.String("seed #{title}")
    })
  )
end

fn ch_req(kind: Text, col_id: Text, name: Text) : Api.Request
  Api.post("/api/v1/chat/channels").with_json(
    Json.Object({
      "kind": Json.String(kind),
      "collection_id": Json.String(col_id),
      "name": Json.String(name),
      "topic": Json.String(name),
      "member_principal_ids": Json.Array([])
    })
  )
end

fn task_db_req(col_id: Text, title: Text, with_status?: Bool) : Api.Request
  var props = [
    Json.Object({
      "id": Json.String("title"),
      "name": Json.String("Title"),
      "kind": Json.String("title"),
      "required": Json.Boolean(true),
      "sort_order": Json.String("a")
    })
  ]
  if with_status?
    props = props.append(
      Json.Object({
        "id": Json.String("status"),
        "name": Json.String("Status"),
        "kind": Json.Object({
          "status": Json.Object({
            "options": Json.Array([
              Json.Object({"id": Json.String("opt_todo"), "label": Json.String("Todo"), "color": Json.String("gray")}),
              Json.Object({"id": Json.String("opt_done"), "label": Json.String("Done"), "color": Json.String("green")})
            ]),
            "done_option_ids": Json.Array([Json.String("opt_done")])
          })
        }),
        "required": Json.Boolean(false),
        "sort_order": Json.String("b")
      })
    )
  end
  Api.post("/api/databases").with_json(
    Json.Object({
      "collection_id": Json.String(col_id),
      "parent_page_id": Json.Null,
      "title": Json.String(title),
      "description": Json.Null,
      "properties": Json.Array(props)
    })
  )
end

fn slack_batch_json(col_id: Text, ch_id_opt: Option(Text), with_msgs?: Bool) : Json
  ch_obj = case ch_id_opt
    Some(cid): Json.Object({
      "id": Json.String(cid),
      "slack_id": Json.String("C_SLK_01"),
      "name": Json.String("slack-eng"),
      "topic": Json.String("Imported"),
      "is_private": Json.Boolean(false),
      "read_only": Json.Boolean(true)
    })
    None: Json.Object({
      "slack_id": Json.String("C_SLK_01"),
      "name": Json.String("slack-eng"),
      "topic": Json.String("Imported"),
      "is_private": Json.Boolean(false),
      "read_only": Json.Boolean(true)
    })
  end
  msgs_arr = if with_msgs?
    Json.Array([
      Json.Object({
        "ts": Json.String("1700000001.000100"),
        "thread_ts": Json.Null,
        "author_handle": Json.String("ada"),
        "author_name": Json.String("Ada Lovelace"),
        "author_email": Json.String("ada@acme.io"),
        "text": Json.String("Deploy checklist"),
        "created_at": Json.String("2026-01-15T10:00:00Z"),
        "attachment_ids": Json.Array([]),
        "reactions": Json.Object({"🚀": Json.Array([Json.String("ada")])}),
        "is_decision": Json.Boolean(true)
      }),
      Json.Object({
        "ts": Json.String("1700000002.000200"),
        "thread_ts": Json.String("1700000001.000100"),
        "author_handle": Json.String("bob"),
        "author_name": Json.String("Bob Member"),
        "author_email": Json.String("bob@acme.io"),
        "text": Json.String("LGTM reply"),
        "created_at": Json.String("2026-01-15T10:01:00Z"),
        "attachment_ids": Json.Array([]),
        "reactions": Json.Object({}),
        "is_decision": Json.Boolean(false)
      })
    ])
  else
    Json.Array([])
  end
  Json.Object({"collection_id": Json.String(col_id), "channel": ch_obj, "messages": msgs_arr})
end

test "v3 M3.2 create-task live status sync, bidirectional backlinks, citations, World proposal & autocomplete"
  files = Files.in_memory(test_files_map())
  rng = SecureRandom.seeded(20261231)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-12-12T10:00:00Z") or stop "t0"
  c0 = Clock.fixed(t0)
  empty_net = Network.fake(Http.replies([]))
  env = Env.of(test_env_map(key_hex))
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_config failed"
  end

  ga = WebTest.new().with_header("Host", "127.0.0.1:8080")
  sa = ApiTest.send(Main, WebTest.prepare(ga, Api.get("/auth/oidc/login?return_to=/")), files, c0, env, rng, empty_net)
  (sta, vera, ca, toka, uia) = make_oidc_mocks("sub_ada_1", "ada@acme.io", "Ada Lovelace", "code_a1", sa.header("Location") or "", sa, key_bytes)
  gwa = WebTest.absorb(ga, sa)
  ada = WebTest.absorb(
    gwa,
    ApiTest.send(
      Main,
      WebTest.prepare(gwa, Api.get("/auth/oidc/callback?code=#{ca}&state=#{sta}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, ca, vera), Http.reply(200, toka)),
          (Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_1"), Http.reply(200, uia))
        ])
      )
    )
  )

  col_res = ApiTest.send(Main, WebTest.prepare(ada, col_req("moat-ops", "Moat Ops")), files, c0, env, rng, empty_net)
  assert col_res.status == 201
  col_id = must_json(col_res.text).text_at("id") or stop "col_id"

  pg_res = ApiTest.send(Main, WebTest.prepare(ada, page_req(col_id, "Cache Runbook Target", "# Runbook")), files, c0, env, rng, empty_net)
  assert pg_res.status == 201
  target_pg_id = must_json(pg_res.text).text_at("page.id") or stop "target_pg_id"

  db_res = ApiTest.send(Main, WebTest.prepare(ada, task_db_req(col_id, "Engineering Tasks", true)), files, c0, env, rng, empty_net)
  assert db_res.status == 201
  db_id = must_json(db_res.text).text_at("database.id") or stop "db_id"

  ch_res = ApiTest.send(Main, WebTest.prepare(ada, ch_req("public", col_id, "Cache Triage")), files, c0, env, rng, empty_net)
  assert ch_res.status == 201
  ch_id = must_json(ch_res.text).text_at("channel.id") or stop "ch_id"

  m1_res = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_id}/messages").with_json(Json.Object({"body_markdown": Json.String("Decision: ship cache tags.")}))),
    files,
    Clock.fixed(t0 + 1.seconds),
    env,
    rng,
    empty_net
  )
  assert m1_res.status == 201
  msg1_id = must_json(m1_res.text).text_at("message.id") or stop "msg1_id"

  ct_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/v1/chat/channels/#{ch_id}/messages/#{msg1_id}/create-task").with_json(
        Json.Object({
          "database_id": Json.String(db_id),
          "title": Json.String("Ship edge cache invalidation"),
          "cells": Json.Object({"status": Json.Object({"select_val": Json.Object({"option_id": Json.String("opt_todo")})})})
        })
      )
    ),
    files,
    Clock.fixed(t0 + 2.seconds),
    env,
    rng,
    empty_net
  )
  assert ct_res.status == 201
  ct_j = must_json(ct_res.text)
  row_id = ct_j.text_at("row.id") or stop "row_id"
  row_page_id = ct_j.text_at("row.page_id") or stop "row_page_id"
  assert ((ct_j.list_at("message.linked_rows") or []).first or Json.Null).text_at("status_label") == Some("Todo")

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/databases/#{db_id}/rows/#{row_id}").with_json(
        Json.Object({
          "cells": Json.Object({"status": Json.Object({"select_val": Json.Object({"option_id": Json.String("opt_done")})})}),
          "expected_version": Json.int(1),
          "reason": Json.String("done")
        })
      )
    ),
    files,
    Clock.fixed(t0 + 3.seconds),
    env,
    rng,
    empty_net
  ).status ==
    200

  msgs_after = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{ch_id}/messages")), files, c0, env, rng, empty_net).text)
    .list_at("messages") or []
  m1_after = msgs_after.find(fn(m) m.text_at("id") == Some(msg1_id) end) or stop "m1_after"
  m1_lr0 = ((m1_after.list_at("linked_rows") or []).first or Json.Null)
  assert m1_lr0.text_at("status_label") == Some("Done") and m1_lr0.text_at("status_color") == Some("green")

  db_show = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/databases/#{db_id}")), files, c0, env, rng, empty_net).text)
  row_links = (db_show.get("row_chat_links") or Json.Null).list_at(row_id) or []
  assert (row_links.first or Json.Null).text_at("channel_id") == Some(ch_id) and (row_links.first or Json.Null).text_at("message_id") == Some(msg1_id)

  rpage_show = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/pages/#{row_page_id}")), files, c0, env, rng, empty_net).text)
  assert (rpage_show.list_at("origin_chat_threads") or []).any?(fn(l) l.text_at("channel_id") == Some(ch_id) and l.text_at("message_id") == Some(msg1_id) end)

  dp_res = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_id}/messages/#{msg1_id}/draft-proposal").with_json(Json.Object({"target_page_id": Json.String(target_pg_id), "tone": Json.String("info")}))),
    files,
    Clock.fixed(t0 + 4.seconds),
    env,
    rng,
    empty_net
  )
  assert dp_res.status == 201
  prop_id = must_json(dp_res.text).text_at("proposal.id") or stop "prop_id"

  assert ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/proposals/#{prop_id}/accept").with_json(Json.Object({}))), files, Clock.fixed(t0 + 5.seconds), env, rng, empty_net).status == 200

  tpg_show = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/pages/#{target_pg_id}")), files, c0, env, rng, empty_net).text)
  assert (tpg_show.list_at("blocks") or []).any?(fn(b)
    (b.get("kind") or Json.Null).get("callout") != None and (b.text_at("markdown") or "").contains?("[[thread:#{ch_id}:#{msg1_id}]]")
  end)
  assert (tpg_show.list_at("origin_chat_threads") or []).any?(fn(l) l.text_at("link_kind") == Some("proposal") and l.text_at("channel_id") == Some(ch_id) end)

  cite_body = "Linked [[page:#{target_pg_id}]] @page:#{target_pg_id} @task:#{row_id} @proposal:#{prop_id} @thread:#{ch_id}:#{msg1_id}"
  m2_res = ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_id}/messages").with_json(Json.Object({"body_markdown": Json.String(cite_body)}))), files, Clock.fixed(t0 + 6.seconds), env, rng, empty_net)
  assert m2_res.status == 201
  m2_refs = must_json(m2_res.text).list_at("message.inline_refs") or []
  assert m2_refs.any?(fn(r) r.text_at("kind") == Some("page") and r.bool_at("redacted") == Some(false) end)
  assert m2_refs.any?(fn(r) r.text_at("kind") == Some("row") and r.bool_at("redacted") == Some(false) end)
  assert m2_refs.any?(fn(r) r.text_at("kind") == Some("proposal") and r.bool_at("redacted") == Some(false) end)
  assert m2_refs.any?(fn(r) r.text_at("kind") == Some("thread") and r.bool_at("redacted") == Some(false) end)

  ent_res = ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/v1/chat/entities?q=Runbook")), files, c0, env, rng, empty_net)
  assert ent_res.status == 200
  assert (must_json(ent_res.text).list_at("entities") or []).any?(fn(e) e.text_at("id") == Some(target_pg_id) and e.text_at("insert_token") == Some("[[page:#{target_pg_id}]]") end)
end

test "v3 M3.2 FERPA cross-boundary locks, citation redaction, private origin hiding & Slack ZIP import"
  files = Files.in_memory(test_files_map())
  rng = SecureRandom.seeded(20261232)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-12-12T11:00:00Z") or stop "t0"
  c0 = Clock.fixed(t0)
  empty_net = Network.fake(Http.replies([]))
  env = Env.of(test_env_map(key_hex))
  oidc_cfg = case Auth.oidc_config(env)
    Ok(c): c
    Error(_): stop "oidc_config failed"
  end

  ga = WebTest.new().with_header("Host", "127.0.0.1:8080")
  sa = ApiTest.send(Main, WebTest.prepare(ga, Api.get("/auth/oidc/login?return_to=/")), files, c0, env, rng, empty_net)
  (sta, vera, ca, toka, uia) = make_oidc_mocks("sub_ada_2", "ada@acme.io", "Ada Lovelace", "code_a2", sa.header("Location") or "", sa, key_bytes)
  gwa = WebTest.absorb(ga, sa)
  ada = WebTest.absorb(
    gwa,
    ApiTest.send(
      Main,
      WebTest.prepare(gwa, Api.get("/auth/oidc/callback?code=#{ca}&state=#{sta}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, ca, vera), Http.reply(200, toka)),
          (Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_2"), Http.reply(200, uia))
        ])
      )
    )
  )

  gb = WebTest.new().with_header("Host", "127.0.0.1:8080")
  sb = ApiTest.send(Main, WebTest.prepare(gb, Api.get("/auth/oidc/login?return_to=/")), files, c0, env, rng, empty_net)
  (stb, verb, cb, tokb, uib) = make_oidc_mocks("sub_bob_2", "bob@acme.io", "Bob Member", "code_b2", sb.header("Location") or "", sb, key_bytes)
  gwb = WebTest.absorb(gb, sb)
  bob = WebTest.absorb(
    gwb,
    ApiTest.send(
      Main,
      WebTest.prepare(gwb, Api.get("/auth/oidc/callback?code=#{cb}&state=#{stb}")),
      files,
      c0,
      env,
      rng,
      Network.fake(
        Http.replies([
          (Oidc.token_exchange_request(oidc_cfg, cb, verb), Http.reply(200, tokb)),
          (Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_bob_2"), Http.reply(200, uib))
        ])
      )
    )
  )

  prs = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/admin/vault/status")), files, c0, env, rng, empty_net).text)
    .list_at("principals") or []
  ada_pid = (prs.find(fn(p) p.text_at("email") == Some("ada@acme.io") end) or Json.Null).text_at("id") or stop "ada_pid"

  col_std = must_json(ApiTest.send(Main, WebTest.prepare(ada, col_req("std-moat", "Std Moat")), files, c0, env, rng, empty_net).text)
    .text_at("id") or stop "col_std"
  col_ferpa = must_json(ApiTest.send(Main, WebTest.prepare(ada, col_req("ferpa-moat", "FERPA Moat")), files, c0, env, rng, empty_net).text)
    .text_at("id") or stop "col_ferpa"

  grp_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.post("/api/admin/groups").with_json(Json.Object({"name": Json.String("Vault Staff"), "slug": Json.Null, "description": Json.String("Vault"), "member_principal_ids": Json.Array([Json.String(ada_pid)])}))),
      files,
      c0,
      env,
      rng,
      empty_net
    ).text
  ).text_at("group.id") or stop "grp_id"

  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.patch("/api/collections/#{col_ferpa}/security").with_json(Json.Object({"security_tier": Json.String("ferpa_restricted"), "allowed_group_ids": Json.Array([Json.String(grp_id)]), "allowed_principal_ids": Json.Array([]), "allow_local_ai": Json.Boolean(false), "reason": Json.String("vault")}))),
    files,
    c0,
    env,
    rng,
    empty_net
  ).status == 200

  pub_pg_id = must_json(ApiTest.send(Main, WebTest.prepare(ada, page_req(col_std, "Public Target", "# Pub")), files, c0, env, rng, empty_net).text)
    .text_at("page.id") or stop "pub_pg_id"
  ferpa_pg_id = must_json(ApiTest.send(Main, WebTest.prepare(ada, page_req(col_ferpa, "Secret FERPA Dossier", "# Secret")), files, c0, env, rng, empty_net).text)
    .text_at("page.id") or stop "ferpa_pg_id"
  pub_db_id = must_json(ApiTest.send(Main, WebTest.prepare(ada, task_db_req(col_std, "Public Tasks", false)), files, c0, env, rng, empty_net).text)
    .text_at("database.id") or stop "pub_db_id"
  ferpa_db_id = must_json(ApiTest.send(Main, WebTest.prepare(ada, task_db_req(col_ferpa, "FERPA Cases", false)), files, c0, env, rng, empty_net).text)
    .text_at("database.id") or stop "ferpa_db_id"
  ferpa_row_id = must_json(
    ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/databases/#{ferpa_db_id}/rows").with_json(Json.Object({"cells": Json.Object({"title": Json.Object({"text_val": Json.String("Secret FERPA Row")})}), "markdown": Json.Null, "reason": Json.String("seed")}))), files, c0, env, rng, empty_net)
      .text
  ).text_at("row.id") or stop "ferpa_row_id"

  ch_pub = must_json(ApiTest.send(Main, WebTest.prepare(ada, ch_req("public", col_std, "General Moat")), files, c0, env, rng, empty_net).text)
    .text_at("channel.id") or stop "ch_pub"
  ch_priv = must_json(ApiTest.send(Main, WebTest.prepare(ada, ch_req("private", col_std, "Ada Private")), files, c0, env, rng, empty_net).text)
    .text_at("channel.id") or stop "ch_priv"
  ch_ferpa = must_json(ApiTest.send(Main, WebTest.prepare(ada, ch_req("public", col_ferpa, "FERPA Room")), files, c0, env, rng, empty_net).text)
    .text_at("channel.id") or stop "ch_ferpa"

  ferpa_msg_id = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_ferpa}/messages").with_json(Json.Object({"body_markdown": Json.String("Confidential")}))), files, Clock.fixed(t0 + 1.seconds), env, rng, empty_net).text)
    .text_at("message.id") or stop "ferpa_msg_id"

  assert ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_ferpa}/messages/#{ferpa_msg_id}/create-task").with_json(Json.Object({"database_id": Json.String(pub_db_id)}))), files, Clock.fixed(t0 + 2.seconds), env, rng, empty_net).status == 403
  assert ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_ferpa}/messages/#{ferpa_msg_id}/draft-proposal").with_json(Json.Object({"target_page_id": Json.String(pub_pg_id)}))), files, Clock.fixed(t0 + 2.seconds), env, rng, empty_net).status == 403

  cite_msg_id = must_json(
    ApiTest.send(
      Main,
      WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_pub}/messages").with_json(Json.Object({"body_markdown": Json.String("See @page:#{ferpa_pg_id} @row:#{ferpa_row_id} @thread:#{ch_ferpa}:#{ferpa_msg_id}")}))),
      files,
      Clock.fixed(t0 + 3.seconds),
      env,
      rng,
      empty_net
    ).text
  ).text_at("message.id") or stop "cite_msg_id"

  bob_pub_raw = ApiTest.send(Main, WebTest.prepare(bob, Api.get("/api/v1/chat/channels/#{ch_pub}/messages")), files, c0, env, rng, empty_net).text
  assert not bob_pub_raw.contains?("Secret FERPA Dossier") and not bob_pub_raw.contains?("Secret FERPA Row")
  bob_cite_m = (must_json(bob_pub_raw).list_at("messages") or []).find(fn(m) m.text_at("id") == Some(cite_msg_id) end) or stop "bob_cite_m"
  bob_refs = bob_cite_m.list_at("inline_refs") or []
  assert bob_refs.size == 3 and bob_refs.all?(fn(r) r.bool_at("redacted") == Some(true) and r.bool_at("accessible") == Some(false) end)
  assert bob_refs.any?(fn(r) r.text_at("title") == Some("[Restricted Citation]") end) and bob_refs.any?(fn(r) r.text_at("title") == Some("[Restricted Thread]") end)

  priv_msg_id = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_priv}/messages").with_json(Json.Object({"body_markdown": Json.String("Private note")}))), files, Clock.fixed(t0 + 4.seconds), env, rng, empty_net).text)
    .text_at("message.id") or stop "priv_msg_id"
  assert ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{ch_priv}/messages/#{priv_msg_id}/draft-proposal").with_json(Json.Object({"target_page_id": Json.String(pub_pg_id)}))), files, Clock.fixed(t0 + 5.seconds), env, rng, empty_net).status == 201
  assert (must_json(ApiTest.send(Main, WebTest.prepare(bob, Api.get("/api/pages/#{pub_pg_id}")), files, c0, env, rng, empty_net).text).list_at("origin_chat_threads") or []).empty?
  assert (must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/pages/#{pub_pg_id}")), files, c0, env, rng, empty_net).text).list_at("origin_chat_threads") or [])
    .any?(fn(l) l.text_at("channel_id") == Some(ch_priv) end)

  pre_res = ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/import/slack").with_json(slack_batch_json(col_std, None, false))), files, Clock.fixed(t0 + 6.seconds), env, rng, empty_net)
  assert pre_res.status == 200 or pre_res.status == 201
  slk_ch_id = must_json(pre_res.text).text_at("channel.id") or stop "slk_ch_id"
  assert must_json(pre_res.text).bool_at("channel.read_only") == Some(true)

  batch_j = slack_batch_json(col_std, Some(slk_ch_id), true)
  b1_res = ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/import/slack").with_json(batch_j)), files, Clock.fixed(t0 + 7.seconds), env, rng, empty_net)
  assert (b1_res.status == 200 or b1_res.status == 201) and must_json(b1_res.text).int_at("created_count") == Some(2)

  assert ApiTest.send(Main, WebTest.prepare(bob, Api.post("/api/v1/chat/import/slack").with_json(batch_j)), files, Clock.fixed(t0 + 7.seconds), env, rng, empty_net).status == 403

  slk_msgs = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{slk_ch_id}/messages")), files, c0, env, rng, empty_net).text).list_at("messages") or []
  slk_parent = slk_msgs.find(fn(m) m.text_at("slack_ts") == Some("1700000001.000100") end) or stop "slk_parent"
  slk_parent_id = slk_parent.text_at("id") or stop "slk_parent_id"
  assert slk_parent.bool_at("is_decision") == Some(true) and slk_parent.int_at("reply_count") == Some(1)

  slk_replies = must_json(ApiTest.send(Main, WebTest.prepare(ada, Api.get("/api/v1/chat/channels/#{slk_ch_id}/messages?parent_message_id=#{slk_parent_id}")), files, c0, env, rng, empty_net).text).list_at("messages") or []
  slk_reply = slk_replies.find(fn(m) m.text_at("slack_ts") == Some("1700000002.000200") end) or stop "slk_reply"
  assert slk_reply.text_at("parent_message_id") == Some(slk_parent_id)

  assert ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/channels/#{slk_ch_id}/messages").with_json(Json.Object({"body_markdown": Json.String("Blocked post")}))), files, Clock.fixed(t0 + 8.seconds), env, rng, empty_net).status == 403

  b2_res = ApiTest.send(Main, WebTest.prepare(ada, Api.post("/api/v1/chat/import/slack").with_json(batch_j)), files, Clock.fixed(t0 + 9.seconds), env, rng, empty_net)
  assert (b2_res.status == 200 or b2_res.status == 201) and must_json(b2_res.text).int_at("created_count") == Some(0) and must_json(b2_res.text).int_at("skipped_count") == Some(2)
end
