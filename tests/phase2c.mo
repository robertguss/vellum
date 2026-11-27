## Vellum Tests.Phase2c Integration Tests (split for Mo lowering budget).
module Tests.Phase2c
use Main
use Api
use Arvo.WebTest
use Db
use Domain.DatabaseModel{
  CellValue,
  PropertyDef,
  PropertyKind
}
use Domain.Types{CollectionWritePolicy}
use Http
use Json
use Routes.Ai
use Routes.Collab
use Routes.Databases
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

