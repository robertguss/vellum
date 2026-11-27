## Vellum v3 Milestone 2 Slice 2.1 Integration Tests:
## Opt-In FERPA / Restricted Vault per Collection, Department Groups allowlists,
## Zero-Exfiltration AI/Webhook/`/llms.txt` lock, and `Modb.Ledger` FERPA read/export audits.
module Tests.V3m2a
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Http
use Json
use Modb.Ledger
use Routes.Ai
use Routes.Auth
use Db

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
  _env: Env,
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

test "v3 M2.1: Opt-In FERPA Vault, Department Groups, zero-exfiltration AI/webhook/llms.txt lock & Modb.Ledger read audit"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m2a.js",
        "css": ["assets/main-v3m2a.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m2a.js": "console.log('v3m2a');",
    "public/assets/main-v3m2a.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261215)
  key_hex = "1111111111111111111111111111111122222222222222222222222222222222"
  key_bytes = Bytes.from_hex(key_hex) or stop "key_hex"
  t0 = Time.parse("2026-12-10T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  empty_net = Network.fake(Http.replies([]))

  base_env = {
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
    "VELLUM_S3_SECRET_ACCESS_KEY": "secret-s3-key-xyz",
    "VELLUM_AI_API_KEY": "test-key",
    "VELLUM_AI_PROVIDER": "openai",
    "VELLUM_AI_BASE_URL": "https://api.openai.com/v1/chat/completions"
  }
  env_ext = Env.of(base_env)
  env_loc = Env.of(
    base_env.set("VELLUM_AI_BASE_URL", "http://127.0.0.1:11434/v1/chat/completions")
  )

  # 1. Provision Owner (@ada) and non-member Member (@bob) via OIDC
  oidc_cfg = case Auth.oidc_config(env_ext)
    Ok(c): c
    Error(_): stop "oidc_config failed"
  end

  guest_a = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_a = ApiTest.send(
    Main,
    WebTest.prepare(guest_a, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert start_a.status == 302
  (st_a, ver_a, code_a, tok_a, ui_a) = make_oidc_mocks(
    "sub_ada_v",
    "ada@acme.io",
    "Ada Lovelace",
    "code_ada",
    start_a.header("Location") or "",
    start_a,
    env_ext,
    key_bytes
  )
  net_a = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, code_a, ver_a), Http.reply(200, tok_a)),
      (Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_ada_v"), Http.reply(200, ui_a))
    ])
  )
  gw_a = WebTest.absorb(guest_a, start_a)
  cb_a = ApiTest.send(
    Main,
    WebTest.prepare(gw_a, Api.get("/auth/oidc/callback?code=#{code_a}&state=#{st_a}")),
    files,
    clock,
    env_ext,
    rng,
    net_a
  )
  assert cb_a.status == 303
  ada = WebTest.absorb(gw_a, cb_a)

  guest_b = WebTest.new().with_header("Host", "127.0.0.1:8080")
  start_b = ApiTest.send(
    Main,
    WebTest.prepare(guest_b, Api.get("/auth/oidc/login?return_to=/")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert start_b.status == 302
  (st_b, ver_b, code_b, tok_b, ui_b) = make_oidc_mocks(
    "sub_bob_v",
    "bob@acme.io",
    "Bob Member",
    "code_bob",
    start_b.header("Location") or "",
    start_b,
    env_ext,
    key_bytes
  )
  net_b = Network.fake(
    Http.replies([
      (Oidc.token_exchange_request(oidc_cfg, code_b, ver_b), Http.reply(200, tok_b)),
      (Oidc.userinfo_request("https://auth.example.com/userinfo", "at_sub_bob_v"), Http.reply(200, ui_b))
    ])
  )
  gw_b = WebTest.absorb(guest_b, start_b)
  cb_b = ApiTest.send(
    Main,
    WebTest.prepare(gw_b, Api.get("/auth/oidc/callback?code=#{code_b}&state=#{st_b}")),
    files,
    clock,
    env_ext,
    rng,
    net_b
  )
  assert cb_b.status == 303
  bob = WebTest.absorb(gw_b, cb_b)

  # 2. Create Standard & FERPA Vault collections, pages (with cross-collection link), DB + row, local attachment, ContextPack & Agent
  std_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/collections").with_json(
        Json.Object({
          "slug": Json.String("standard-ops"),
          "name": Json.String("Standard Ops"),
          "description": Json.Null,
          "icon": Json.Null,
          "write_policy": Json.String("direct_with_audit"),
          "freshness_ttl_days": Json.Null
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert std_col_res.status == 201
  std_col_id = must_json(std_col_res.text).text_at("id") or stop "std_col_id"

  ferpa_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/collections").with_json(
        Json.Object({
          "slug": Json.String("student-care"),
          "name": Json.String("Student Care"),
          "description": Json.Null,
          "icon": Json.Null,
          "write_policy": Json.String("direct_with_audit"),
          "freshness_ttl_days": Json.Null
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ferpa_col_res.status == 201
  ferpa_col_id = must_json(ferpa_col_res.text).text_at("id") or stop "ferpa_col_id"

  std_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(std_col_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Public Triage Guide"),
          "markdown": Json.String("Standard publicops112 triage procedure."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("seed standard page")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert std_pg_res.status == 201
  std_pg_id = must_json(std_pg_res.text).text_at("page.id") or stop "std_pg_id"

  ferpa_pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/pages").with_json(
        Json.Object({
          "collection_id": Json.String(ferpa_col_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Student Case Alpha"),
          "markdown": Json.String("Protected ferpazebra991 record referencing [[#{std_pg_id}|Public Triage Guide]]."),
          "icon": Json.Null,
          "freshness_ttl_days": Json.Null,
          "reason": Json.String("seed ferpa page")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ferpa_pg_res.status == 201
  ferpa_pg_id = must_json(ferpa_pg_res.text).text_at("page.id") or stop "ferpa_pg_id"

  # Relational DB + row in student-care
  db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/databases").with_json(
        Json.Object({
          "collection_id": Json.String(ferpa_col_id),
          "parent_page_id": Json.Null,
          "title": Json.String("Student Cases DB"),
          "description": Json.Null,
          "properties": Json.Array([
            Json.Object({
              "id": Json.String("title"),
              "name": Json.String("Title"),
              "kind": Json.String("title"),
              "required": Json.Boolean(true),
              "sort_order": Json.String("a")
            })
          ])
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert db_res.status == 201
  ferpa_db_id = must_json(db_res.text).text_at("database.id") or stop "ferpa_db_id"

  row_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/databases/#{ferpa_db_id}/rows").with_json(
        Json.Object({
          "cells": Json.Object({
            "title": Json.Object({"text_val": Json.String("Case 001 ferpadb772")})
          }),
          "markdown": Json.Null,
          "reason": Json.String("seed ferpa db row")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert row_res.status == 201

  # Local attachment on ferpa_pg
  att_bytes = "ferpa-confidential-pdf-bytes\n".bytes
  pre_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/attachments/presign").with_json(
        Json.Object({
          "page_id": Json.String(ferpa_pg_id),
          "filename": Json.String("transcript.txt"),
          "content_type": Json.String("text/plain"),
          "size_bytes": Json.int(att_bytes.size),
          "sha256_hex": Json.Null
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert pre_res.status == 201
  pre_j = must_json(pre_res.text)
  att_id = pre_j.text_at("attachment.id") or stop "att_id"
  up_url = pre_j.text_at("upload_url") or stop "upload_url"
  assert up_url.contains?("X-Amz-Signature=")
  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.post("/api/attachments/#{att_id}/commit")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    200

  # ContextPack scoped to student-care
  pk_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/packs").with_json(
        Json.Object({
          "slug": Json.String("ferpa-pack"),
          "name": Json.String("FERPA Case Pack"),
          "description": Json.Null,
          "collection_ids": Json.Array([Json.String(ferpa_col_id)]),
          "pinned_page_ids": Json.Array([]),
          "database_ids": Json.Array([]),
          "query_hint": Json.Null,
          "fresh_only": Json.Boolean(false),
          "include_full_blocks": Json.Boolean(true),
          "token_budget": Json.int(2000)
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert pk_res.status == 201

  # Workspace-wide Agent (@bot, allowed_collections: null)
  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("ws-bot"),
          "display_name": Json.String("Workspace Bot"),
          "model_id": Json.String("gpt-4o-mini"),
          "label": Json.String("wildcard"),
          "allowed_actions": Json.Array([
            Json.String("read"),
            Json.String("comment"),
            Json.String("propose")
          ]),
          "allowed_collections": Json.Null,
          "max_calls": Json.int(50),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert mint_res.status == 201
  bot_tok = must_json(mint_res.text).text_at("raw_token") or stop "bot_tok"
  bot = WebTest.new().with_header("Authorization", "Bearer #{bot_tok}")

  # 3. Non-admin Member (@bob) cannot manage Vault or Department Groups (403)
  assert ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.get("/api/admin/vault/status")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    403

  # Look up Ada's principal id via vault status
  vstat0 = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/admin/vault/status")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert vstat0.status == 200
  prs0 = must_json(vstat0.text).list_at("principals") or []
  var ada_pid_opt = None
  for p in prs0
    if p.text_at("email") == Some("ada@acme.io") or p.text_at("role") == Some("owner")
      ada_pid_opt = p.text_at("id")
      break
    end
  end
  ada_pid = ada_pid_opt or stop "ada_pid"

  # Create Department Group "Registrar" containing only @ada
  grp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/admin/groups").with_json(
        Json.Object({
          "name": Json.String("Registrar"),
          "slug": Json.Null,
          "description": Json.String("Campus registrar staff"),
          "member_principal_ids": Json.Array([Json.String(ada_pid)])
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert grp_res.status == 201
  grp_id = must_json(grp_res.text).text_at("group.id") or stop "grp_id"

  # Reject empty allowlist on ferpa_restricted (422)
  bad_sec = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/collections/#{ferpa_col_id}/security").with_json(
        Json.Object({
          "security_tier": Json.String("ferpa_restricted"),
          "allowed_group_ids": Json.Array([]),
          "allowed_principal_ids": Json.Array([]),
          "allow_local_ai": Json.Boolean(false),
          "reason": Json.String("missing allowlist")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert bad_sec.status == 422

  # Enable FERPA / Restricted Vault with Registrar group + allow_local_ai: false
  sec_on = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/collections/#{ferpa_col_id}/security").with_json(
        Json.Object({
          "security_tier": Json.String("ferpa_restricted"),
          "allowed_group_ids": Json.Array([Json.String(grp_id)]),
          "allowed_principal_ids": Json.Array([]),
          "allow_local_ai": Json.Boolean(false),
          "reason": Json.String("enable FERPA Vault")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert sec_on.status == 200
  assert must_json(sec_on.text).text_at("policy.security_tier") == Some("ferpa_restricted")

  # Deleting sole allowlist group for a FERPA collection returns 409 Conflict
  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.delete("/api/admin/groups/#{grp_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    409

  # 4. Non-member Member (@bob) AND workspace:* Agent (@bot) fail closed globally across all surfaces
  for caller in [bob, bot]
    assert ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/pages/#{ferpa_pg_id}")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    ).status ==
      403
    assert ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/databases/#{ferpa_db_id}")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    ).status ==
      403
    assert ApiTest.send(
      Main,
      WebTest.prepare(
        caller,
        Api.post("/api/databases/#{ferpa_db_id}/query").with_json(
          Json.Object({
            "view_id": Json.Null,
            "filters": Json.Array([]),
            "filter_match_all": Json.Boolean(true),
            "sorts": Json.Array([]),
            "from_date": Json.Null,
            "to_date": Json.Null
          })
        )
      ),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    ).status ==
      403
    assert ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/attachments/#{att_id}/download")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    ).status ==
      403

    sr = ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/search?q=ferpazebra991")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    )
    assert sr.status == 200
    assert (must_json(sr.text).list_at("results") or []).empty?

    bl = ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/pages/#{std_pg_id}/backlinks")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    )
    assert bl.status == 200 and not bl.text.contains?(ferpa_pg_id)

    ll = ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/llms.txt")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    )
    assert ll.status == 200
    assert not ll.text.contains?("student-care") and not ll.text.contains?("ferpa-pack")

    pks = ApiTest.send(
      Main,
      WebTest.prepare(caller, Api.get("/api/packs")),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    )
    assert pks.status == 200 and not pks.text.contains?("ferpa-pack")

    mcp_pg = ApiTest.send(
      Main,
      WebTest.prepare(
        caller,
        Api.post("/mcp").with_json(
          Json.Object({
            "jsonrpc": Json.String("2.0"),
            "id": Json.int(1),
            "method": Json.String("tools/call"),
            "params": Json.Object({
              "name": Json.String("vellum.read_page"),
              "arguments": Json.Object({"page_id": Json.String(ferpa_pg_id)})
            })
          })
        )
      ),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    )
    assert mcp_pg.status == 200 and must_json(mcp_pg.text).bool_at("result.isError") == Some(true)

    mcp_rlm = ApiTest.send(
      Main,
      WebTest.prepare(
        caller,
        Api.post("/mcp").with_json(
          Json.Object({
            "jsonrpc": Json.String("2.0"),
            "id": Json.int(2),
            "method": Json.String("tools/call"),
            "params": Json.Object({
              "name": Json.String("vellum.rlm_query"),
              "arguments": Json.Object({
                "question": Json.String("ferpazebra991"),
                "collection_id": Json.String(ferpa_col_id),
                "max_subcalls": Json.int(0)
              })
            })
          })
        )
      ),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    )
    assert mcp_rlm.status == 200 and
      must_json(mcp_rlm.text).bool_at("result.isError") == Some(true)

    assert ApiTest.send(
      Main,
      WebTest.prepare(
        caller,
        Api.post("/api/ai/ask").with_json(
          Json.Object({
            "question": Json.String("ferpazebra991"),
            "collection_id": Json.String(ferpa_col_id),
            "max_sources": Json.int(3),
            "stream": Json.Boolean(false)
          })
        )
      ),
      files,
      clock,
      env_ext,
      rng,
      empty_net
    ).status ==
      403
  end

  # 5. Permitted Registrar member (@ada) accesses page, DB, query, attachment, sync snapshot -> Modb.Ledger FERPA audit logs created
  ada_pg = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/pages/#{ferpa_pg_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ada_pg.status == 200
  assert must_json(ada_pg.text).text_at("collection_security.security_tier") ==
    Some("ferpa_restricted")

  ada_db = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/databases/#{ferpa_db_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ada_db.status == 200

  ada_q = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/databases/#{ferpa_db_id}/query").with_json(
        Json.Object({
          "view_id": Json.Null,
          "filters": Json.Array([]),
          "filter_match_all": Json.Boolean(true),
          "sorts": Json.Array([]),
          "from_date": Json.Null,
          "to_date": Json.Null
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ada_q.status == 200 and must_json(ada_q.text).int_at("total_count") == Some(1)

  ada_dl = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/attachments/#{att_id}/download")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ada_dl.status == 302 and
    (ada_dl.header("Location") or "").contains?("X-Amz-Signature=")

  ada_snap = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/sync/snapshot?collections=#{ferpa_col_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ada_snap.status == 200

  aud_res = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/api/admin/ferpa/audit?collection_id=#{ferpa_col_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert aud_res.status == 200
  aud_txt = aud_res.text
  assert aud_txt.contains?("ferpa.page.viewed")
  assert aud_txt.contains?("ferpa.db_row.viewed")
  assert aud_txt.contains?("ferpa.attachment.downloaded")
  assert aud_txt.contains?("ferpa.export.requested")

  # Verify cryptographic Modb.Ledger hash chain holds across FERPA audit writes
  vrep = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    fn(e) e end,
    fn(db) Ledger.verify_all(db) end
  )
  assert vrep is Ok(_)

  # 6. Zero-Exfiltration Lock even for Owner (@ada)
  ada_llms = ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.get("/llms.txt")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  )
  assert ada_llms.status == 200
  assert ada_llms.text.contains?("standard-ops")
  assert not ada_llms.text.contains?("student-care")
  assert not ada_llms.text.contains?("Student Case Alpha")
  assert not ada_llms.text.contains?("ferpa-pack")

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/webhooks").with_json(
        Json.Object({
          "collection_id": Json.String(ferpa_col_id),
          "url": Json.String("https://hooks.acme.io/ferpa"),
          "events": Json.Array([Json.String("page.updated")])
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    403

  # External AI blocked on ferpa_col_id across Ask, Draft & Deep Research
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/ai/ask").with_json(
        Json.Object({
          "question": Json.String("nomatchtoken8899"),
          "collection_id": Json.String(ferpa_col_id),
          "max_sources": Json.int(3),
          "stream": Json.Boolean(false)
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    403

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/ai/draft").with_json(
        Json.Object({
          "page_id": Json.String(ferpa_pg_id),
          "instruction": Json.String("Summarize"),
          "as_proposal": Json.Boolean(true)
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    403

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/ai/deep-research").with_json(
        Json.Object({
          "question": Json.String("Case summary"),
          "collection_id": Json.String(ferpa_col_id)
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    403

  # Enable allow_local_ai: true -> external HTTPS still 403, loopback http://127.0.0.1 succeeds (200)
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/collections/#{ferpa_col_id}/security").with_json(
        Json.Object({
          "security_tier": Json.String("ferpa_restricted"),
          "allowed_group_ids": Json.Array([Json.String(grp_id)]),
          "allowed_principal_ids": Json.Array([]),
          "allow_local_ai": Json.Boolean(true),
          "reason": Json.String("enable local campus AI")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    200

  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/ai/ask").with_json(
        Json.Object({
          "question": Json.String("nomatchtoken8899"),
          "collection_id": Json.String(ferpa_col_id),
          "max_sources": Json.int(3),
          "stream": Json.Boolean(false)
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    403

  loc_cfg = case Ai.ai_config(env_loc)
    Ok(c): c
    Error(_): stop "loc_cfg"
  end
  ask_sys = "You are Vellum Workspace Assistant. Answer strictly from the provided workspace excerpts and cite [Title §block_id]."
  ask_usr = "Question: nomatchtoken8899\n\nWorkspace Sources:\n(No permitted workspace excerpts matched this query.)"
  loc_net = Network.fake(
    Http.replies([
      (
        Ai.build_llm_request(loc_cfg, ask_sys, ask_usr),
        Http.reply(
          200,
          Json.Object({
            "choices": Json.Array([
              Json.Object({
                "message": Json.Object({"content": Json.String("Local campus answer only.")})
              })
            ])
          }).to_text
        )
      )
    ])
  )
  loc_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.post("/api/ai/ask").with_json(
        Json.Object({
          "question": Json.String("nomatchtoken8899"),
          "collection_id": Json.String(ferpa_col_id),
          "max_sources": Json.int(3),
          "stream": Json.Boolean(false)
        })
      )
    ),
    files,
    clock,
    env_loc,
    rng,
    loc_net
  )
  assert loc_ok.status == 200

  # 7. Flip back to standard -> @bob regains access & group delete succeeds
  assert ApiTest.send(
    Main,
    WebTest.prepare(
      ada,
      Api.patch("/api/collections/#{ferpa_col_id}/security").with_json(
        Json.Object({
          "security_tier": Json.String("standard"),
          "allowed_group_ids": Json.Array([]),
          "allowed_principal_ids": Json.Array([]),
          "allow_local_ai": Json.Boolean(false),
          "reason": Json.String("declassify vault")
        })
      )
    ),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    200

  assert ApiTest.send(
    Main,
    WebTest.prepare(bob, Api.get("/api/pages/#{ferpa_pg_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    200

  assert ApiTest.send(
    Main,
    WebTest.prepare(ada, Api.delete("/api/admin/groups/#{grp_id}")),
    files,
    clock,
    env_ext,
    rng,
    empty_net
  ).status ==
    200
end
