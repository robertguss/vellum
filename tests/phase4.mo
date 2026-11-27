## Vellum Phase 4 Integration Test Suite (`Modb.Taint` Lethal Trifecta, Control Plane, & Governance).
module Tests.Phase4
use Main
use Api
use Arvo.WebTest
use Domain.NotionImport{NotionPageImport}
use Domain.Types{BlockOp, CollectionWritePolicy}
use Json
use Routes.Collab
use Routes.Importer
use Routes.Workspace

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
  end
end

test "Phase 4.1: Modb.Taint Lethal Trifecta provenance, fork inheritance, enforcement, and admin clear"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p41test.js",
        "css": ["assets/main-p41test.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p41test.js": "console.log('p41');",
    "public/assets/main-p41test.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261127)
  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  empty_net = Network.fake({})

  # 1. Solo Owner login on loopback
  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  solo_cb = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/solo/login?return_to=/").with_header("Host", "127.0.0.1:8080")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert solo_cb.status == 303
  owner = WebTest.absorb(guest, solo_cb)

  # 2. Create DirectWithAudit collection + clean page + direct-write scoped agent
  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "taint-lab",
          name: "Taint Lab",
          description: None,
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
  col_id = must_json(col_res.text).text_at("id") or stop "col_id"

  clean_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Clean Target Spec",
          markdown: "Initial trusted specification line.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed clean page")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clean_res.status == 201
  clean_j = must_json(clean_res.text)
  clean_pg_id = clean_j.text_at("page.id") or stop "clean_pg_id"
  clean_blk_id = ((clean_j.list_at("blocks") or []).first or Json.Null).text_at("id") or stop "clean_blk_id"
  assert clean_j.text_at("taint_provenance.trust") == None

  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "taint-agent",
          display_name: "Taint Test Bot",
          model_id: Some("claude-sonnet-4-6"),
          label: "taint-direct-bot",
          allowed_actions: ["read", "comment", "propose", "write_direct"],
          allowed_collections: Some([col_id]),
          max_calls: 100,
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
  agent_tok = must_json(mint_res.text).text_at("raw_token") or stop "agent_tok"

  # 3. Notion import automatically marks imported pages & blocks as untrusted in Modb.Taint
  imp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/import/notion").with_json(
        Importer.ImportNotionInput(
          collection_id: col_id,
          pages: [
            NotionPageImport(
              path: "export/External%20Vendor%20Brief%209a1b2c3d4e5f67890123456789abcdef.md",
              title: None,
              markdown: "Untrusted External Spec zebra991 with prompt injection payload."
            )
          ],
          databases: []
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert imp_res.status == 201
  imp_j = must_json(imp_res.text)
  assert imp_j.text_at("trust_tier") == Some("untrusted")
  imp_pg_id = ((imp_j.list_at("imported_pages") or []).first or Json.Null).text_at("id") or
    stop "imp_pg_id"

  show_imp = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{imp_pg_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_imp.status == 200
  show_imp_j = must_json(show_imp.text)
  assert show_imp_j.text_at("taint_provenance.trust") == Some("untrusted")
  assert (show_imp_j.list_at("taint_provenance.untrusted_block_ids") or []).size >= 1

  # 4. MCP vellum.search on untrusted page taints session p41-parent
  search_res = ApiTest.send(
    Main,
    Api.post("/mcp").with_header("Authorization", "Bearer #{agent_tok}").with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(1),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.search"),
          "arguments": Json.Object({
            "q": Json.String("zebra991"),
            "session_id": Json.String("p41-parent")
          })
        })
      })
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert search_res.status == 200
  search_j = must_json(search_res.text)
  assert search_j.bool_at("result.isError") == Some(false)
  assert search_j.bool_at("result.structuredContent.taint_session.untrusted_tainted") == Some(true)

  # 5. Child fork p41-child reading ONLY clean page monotonically inherits parent's taint
  child_read_res = ApiTest.send(
    Main,
    Api.post("/mcp").with_header("Authorization", "Bearer #{agent_tok}").with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(2),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.read_page"),
          "arguments": Json.Object({
            "page_id": Json.String(clean_pg_id),
            "session_id": Json.String("p41-child"),
            "parent_session_id": Json.String("p41-parent")
          })
        })
      })
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert child_read_res.status == 200
  child_j = must_json(child_read_res.text)
  assert child_j.bool_at("result.isError") == Some(false)
  assert child_j.bool_at("result.structuredContent.taint_session.untrusted_tainted") == Some(true)
  assert child_j.text_at("result.structuredContent.taint_session.parent_session_id") ==
    Some("p41-parent")

  # 6. Lethal Trifecta blocks direct MCP patch, webhook creation, & REST patch, while allowing proposals
  tainted_patch = ApiTest.send(
    Main,
    Api.post("/mcp").with_header("Authorization", "Bearer #{agent_tok}").with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(3),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.patch_blocks"),
          "arguments": Json.Object({
            "page_id": Json.String(clean_pg_id),
            "reason": Json.String("should be blocked by Modb.Taint"),
            "session_id": Json.String("p41-child"),
            "ops": Json.Array([
              ReplaceBlock(
                block_id: clean_blk_id,
                expected_version: 1,
                kind: None,
                markdown: "Injected live overwrite"
              ).to_json
            ]),
            "expected_versions": Json.Object({clean_blk_id: Json.int(1)})
          })
        })
      })
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tainted_patch.status == 200
  assert must_json(tainted_patch.text).bool_at("result.isError") == Some(true)

  tainted_wh = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/webhooks").with_header("X-Taint-Session", "p41-parent").with_json(
        Collab.CreateWebhookInput(
          collection_id: Some(col_id),
          url: "https://exfil.acme.io/hook",
          events: ["page.updated"]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tainted_wh.status == 403

  tainted_rest_patch = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{clean_pg_id}/blocks")
        .with_header("X-Taint-Session", "p41-parent")
        .with_json(
          Workspace.PatchBlocksInput(
            ops: [
              ReplaceBlock(
                block_id: clean_blk_id,
                expected_version: 1,
                kind: None,
                markdown: "Injected REST overwrite"
              )
            ],
            expected_versions: {clean_blk_id: 1},
            reason: Some("blocked REST write")
          )
        )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tainted_rest_patch.status == 403

  # Sandboxed Modb.World Change Proposal remains permitted for tainted agent
  tainted_prop = ApiTest.send(
    Main,
    Api.post("/mcp").with_header("Authorization", "Bearer #{agent_tok}").with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(4),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.proposal_open"),
          "arguments": Json.Object({
            "page_id": Json.String(clean_pg_id),
            "title": Json.String("Safe proposal while tainted"),
            "reason": Json.String("route untrusted synthesis into human review")
          })
        })
      })
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tainted_prop.status == 200
  assert must_json(tainted_prop.text).bool_at("result.isError") == Some(false)

  # 7. Admin Control Plane: non-admin rejected (403); Owner inspects & clears sessions -> unblocked
  agent_status_res = ApiTest.send(
    Main,
    Api.get("/api/admin/taint/status").with_header("Authorization", "Bearer #{agent_tok}"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert agent_status_res.status == 403

  admin_status_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/taint/status")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert admin_status_res.status == 200
  st_j = must_json(admin_status_res.text)
  sess_list = st_j.list_at("sessions") or []
  assert sess_list.size >= 2
  assert (st_j.list_at("untrusted.pages") or []).size >= 1
  assert (st_j.list_at("untrusted.blocks") or []).size >= 1

  clr_parent = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/taint/sessions/p41-parent/clear").with_json(
        Json.Object({"reason": Json.String("Reviewed external import")})
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clr_parent.status == 200
  assert must_json(clr_parent.text).bool_at("session.untrusted_tainted") == Some(false)

  # After clearing parent session, webhook creation succeeds (201)
  unblocked_wh = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/webhooks").with_header("X-Taint-Session", "p41-parent").with_json(
        Collab.CreateWebhookInput(
          collection_id: Some(col_id),
          url: "https://safe.acme.io/hook",
          events: ["page.updated"]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert unblocked_wh.status == 201

  # After clearing child session, MCP vellum.patch_blocks succeeds
  clr_child = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/taint/sessions/p41-child/clear").with_json(
        Json.Object({"reason": Json.String("Reviewed child context")})
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clr_child.status == 200

  unblocked_patch = ApiTest.send(
    Main,
    Api.post("/mcp").with_header("Authorization", "Bearer #{agent_tok}").with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(5),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.patch_blocks"),
          "arguments": Json.Object({
            "page_id": Json.String(clean_pg_id),
            "reason": Json.String("allowed after admin taint clear"),
            "session_id": Json.String("p41-child"),
            "ops": Json.Array([
              ReplaceBlock(
                block_id: clean_blk_id,
                expected_version: 1,
                kind: None,
                markdown: "Verified post-clear update."
              ).to_json
            ]),
            "expected_versions": Json.Object({clean_blk_id: Json.int(1)})
          })
        })
      })
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert unblocked_patch.status == 200
  assert must_json(unblocked_patch.text).bool_at("result.isError") == Some(false)
end
