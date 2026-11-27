## Vellum Phase 4 Integration Test Suite (`Modb.Taint` Lethal Trifecta, Control Plane, & Governance).
module Tests.Phase4
use Main
use Api
use Arvo.WebTest
use Db
use Domain.NotionImport{NotionPageImport}
use Domain.Types{BlockOp, CollectionWritePolicy}
use Json
use Modb.Ledger
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

test "Phase 4.2: One-click Modb.Erasure secret detection, crypto-shredding, compaction, and downloadable receipt"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p42test.js",
        "css": ["assets/main-p42test.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p42test.js": "console.log('p42');",
    "public/assets/main-p42test.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261128)
  t0 = Time.parse("2026-11-27T13:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  empty_net = Network.fake({})

  # 1. Solo Owner + Collection + Scoped Agent
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

  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "erasure-lab",
          name: "Erasure Lab",
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

  mint_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "erasure-nonadmin",
          display_name: "Non Admin Bot",
          model_id: Some("claude-sonnet-4-6"),
          label: "non-admin-bot",
          allowed_actions: ["read"],
          allowed_collections: Some([col_id]),
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
  agent_tok = must_json(mint_res.text).text_at("raw_token") or stop "agent_tok"

  # 2. Create Page 1 containing leaked OpenAI key (also echoed in audit reason) + Comment with GitHub token
  leaked_ai = "sk-proj-Phase42TestSecretKey1234567890"
  leaked_gh = "ghp_Phase42TestGithubToken9876543210"
  pg1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Incident Runbook",
          markdown: "Gateway key accidentally pasted: #{leaked_ai}\nFollow quorum SOP.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("pasted #{leaked_ai}")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg1_res.status == 201
  pg1_id = must_json(pg1_res.text).text_at("page.id") or stop "pg1_id"

  cmt_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages/#{pg1_id}/comments").with_json(
        Workspace.CreateCommentInput(
          block_id: None,
          parent_comment_id: None,
          body_markdown: "Deploy token mirror: #{leaked_gh}"
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

  # 3. GET /api/pages/:id surfaces masked secret_hints (never raw secrets!)
  show1 = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg1_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show1.status == 200
  show1_j = must_json(show1.text)
  hints1 = show1_j.list_at("secret_hints") or []
  assert hints1.size == 2
  hints_raw = (show1_j.get("secret_hints") or Json.Null).to_text
  assert not hints_raw.contains?(leaked_ai)
  assert not hints_raw.contains?(leaked_gh)

  # 4. Non-admin agent gets 403 on erasure status, purge, and receipt download; Owner sees both findings
  assert ApiTest.send(
    Main,
    Api.get("/api/admin/erasure/status").with_header("Authorization", "Bearer #{agent_tok}"),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    403
  assert ApiTest.send(
    Main,
    Api.post("/api/admin/erasure/purge")
      .with_header("Authorization", "Bearer #{agent_tok}")
      .with_json(Json.Object({"page_id": Json.String(pg1_id)})),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    403
  assert ApiTest.send(
    Main,
    Api.get("/api/admin/erasure/receipts/ers_missing/download")
      .with_header("Authorization", "Bearer #{agent_tok}"),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    403

  st_before = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/erasure/status")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert st_before.status == 200
  assert (must_json(st_before.text).list_at("findings") or []).size == 2

  # 5. Execute one-click Modb.Erasure purge (redact + compact)
  purge_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/erasure/purge").with_json(
        Json.Object({
          "page_id": Json.String(pg1_id),
          "mode": Json.String("redact"),
          "compact": Json.Boolean(true),
          "reason": Json.String("Purge incident key #{leaked_ai}")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert purge_res.status == 200
  assert not purge_res.text.contains?(leaked_ai)
  assert not purge_res.text.contains?(leaked_gh)
  pj = must_json(purge_res.text)
  rcpt_id = pj.text_at("receipt.id") or stop "rcpt_id"
  assert pj.bool_at("receipt.key_shredded") == Some(true)
  assert (pj.int_at("receipt.rows_deleted") or 0) >= 1
  assert (pj.int_at("receipt.fts_docs_deleted") or 0) >= 1
  assert (pj.int_at("receipt.vec_docs_deleted") or 0) >= 1
  assert (pj.int_at("receipt.audit_entries_redacted") or 0) >= 1
  assert pj.bool_at("receipt.compacted") == Some(true)
  assert pj.int_at("blocks_redacted") == Some(1)
  assert pj.int_at("comments_redacted") == Some(1)

  # 6. Verify sanitized live page, FTS re-indexing, and downloadable receipt
  show_after = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg1_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_after.status == 200
  after_j = must_json(show_after.text)
  assert (after_j.text_at("anchored_markdown") or "").contains?("[REDACTED]")
  assert not show_after.text.contains?(leaked_ai)
  assert not show_after.text.contains?(leaked_gh)
  assert (after_j.list_at("secret_hints") or []).size == 0

  sec_search = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=Phase42TestSecretKey1234567890")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_search.status == 200
  assert (must_json(sec_search.text).list_at("results") or []).size == 0

  clean_search = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=Incident")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clean_search.status == 200
  assert (must_json(clean_search.text).list_at("results") or []).any?(fn(r)
    r.text_at("page_id") == Some(pg1_id)
  end)

  dl_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/erasure/receipts/#{rcpt_id}/download")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dl_res.status == 200
  cdisp = dl_res.header("Content-Disposition") or ""
  assert cdisp.contains?("attachment;") and cdisp.contains?(rcpt_id)
  dl_j = must_json(dl_res.text)
  assert dl_j.text_at("receipt.id") == Some(rcpt_id)
  assert dl_j.bool_at("receipt.compacted") == Some(true)

  # 7. Verify ledger hash-chain integrity and zero raw secret bytes anywhere on disk
  assert Ledger.open(files, Db.ledger_db_path, Db.vellum_schema(), t0) is Ok(vdb)
  assert Ledger.verify_all(vdb) is Ok(_)
  assert Ledger.verify_fast(vdb, 16) is Ok(_)
  raw_disk = case files.read_only.read_bytes(Db.ledger_db_path)
    Ok(b): b
    Error(_): stop "read raw disk"
  end
  raw_hex = raw_disk.to_hex
  assert not raw_hex.contains?(leaked_ai.bytes.to_hex)
  assert not raw_hex.contains?(leaked_gh.bytes.to_hex)

  # 8. Also test delete_page mode on a second page with a Stripe live secret key
  leaked_stripe = ["sk_li", "ve_Phase42DeletePageSecret99999"].join("")
  pg2_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Scratch Secret Note",
          markdown: "Disposable key: #{leaked_stripe}",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed disposable secret page")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pg2_res.status == 201
  pg2_id = must_json(pg2_res.text).text_at("page.id") or stop "pg2_id"

  del_purge = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/erasure/purge").with_json(
        Json.Object({
          "page_id": Json.String(pg2_id),
          "mode": Json.String("delete_page"),
          "compact": Json.Boolean(true),
          "reason": Json.String("Delete whole compromised page")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_purge.status == 200
  assert must_json(del_purge.text).bool_at("receipt.compacted") == Some(true)
  assert ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{pg2_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    404
  raw_disk2 = case files.read_only.read_bytes(Db.ledger_db_path)
    Ok(b): b
    Error(_): stop "read raw disk 2"
  end
  assert not raw_disk2.to_hex.contains?(leaked_stripe.bytes.to_hex)
end

test "Phase 4.3: Sub-Delegation Control Plane (Modb.Grants tree, budget gauges, live SSE, cascade revoke & kill-all)"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p43test.js",
        "css": ["assets/main-p43test.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p43test.js": "console.log('p43');",
    "public/assets/main-p43test.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261129)
  t0 = Time.parse("2026-11-27T14:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  empty_net = Network.fake({})

  # 1. Solo Owner + Collection + Target Page
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

  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "deleg-lab",
          name: "Delegation Lab",
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
  assert col_res.status == 201
  col_id = must_json(col_res.text).text_at("id") or stop "col_id"

  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Control Plane Runbook",
          markdown: "Baseline hierarchy check page.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed page for delegation test")
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

  # 2. Mint Root Agent A (max_calls: 20) -> publishes grant.minted on "grants"
  mint_a = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Workspace.MintAgentTokenInput(
          handle: "root-planner",
          display_name: "Root Planner Agent",
          model_id: Some("claude-sonnet-4-6"),
          label: "root-planner",
          allowed_actions: ["read", "propose", "delegate"],
          allowed_collections: Some([col_id]),
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
  assert mint_a.status == 201
  assert mint_a.sse_published_events.any?(fn(e)
    e.topic == "grants" and e.event == Some("grant.minted")
  end)
  aj = must_json(mint_a.text)
  tok_a = aj.text_at("raw_token") or stop "tok_a"
  gr_a = aj.text_at("grant.id") or stop "gr_a"

  # 3. Agent A delegates Child B (max_calls: 8) -> publishes grant.delegated on "grants"
  del_b = ApiTest.send(
    Main,
    Api.post("/api/grants/delegate").with_header("Authorization", "Bearer #{tok_a}").with_json(
      Collab.DelegateGrantInput(
        handle: "child-researcher",
        display_name: "Child Researcher",
        model_id: Some("claude-haiku-4-5"),
        label: "child-researcher",
        allowed_actions: ["read", "propose", "delegate"],
        allowed_collections: Some([col_id]),
        max_calls: 8,
        ttl_days: 3
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_b.status == 201
  assert del_b.sse_published_events.any?(fn(e)
    e.topic == "grants" and e.event == Some("grant.delegated")
  end)
  bj = must_json(del_b.text)
  tok_b = bj.text_at("raw_token") or stop "tok_b"
  gr_b = bj.text_at("grant.id") or stop "gr_b"

  # 4. Child B delegates Grandchild C (max_calls: 3)
  del_c = ApiTest.send(
    Main,
    Api.post("/api/grants/delegate").with_header("Authorization", "Bearer #{tok_b}").with_json(
      Collab.DelegateGrantInput(
        handle: "leaf-writer",
        display_name: "Leaf Writer",
        model_id: Some("claude-haiku-4-5"),
        label: "leaf-writer",
        allowed_actions: ["read", "propose"],
        allowed_collections: Some([col_id]),
        max_calls: 3,
        ttl_days: 1
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert del_c.status == 201
  cj = must_json(del_c.text)
  tok_c = cj.text_at("raw_token") or stop "tok_c"
  gr_c = cj.text_at("grant.id") or stop "gr_c"

  # 5. Grandchild C opens a proposal via /mcp -> used_calls increments across C, B, and A
  prop_c = ApiTest.send(
    Main,
    Api.post("/mcp").with_header("Authorization", "Bearer #{tok_c}").with_json(
      Json.Object({
        "jsonrpc": Json.String("2.0"),
        "id": Json.int(1),
        "method": Json.String("tools/call"),
        "params": Json.Object({
          "name": Json.String("vellum.proposal_open"),
          "arguments": Json.Object({
            "page_id": Json.String(pg_id),
            "title": Json.String("Leaf grant budget debit"),
            "reason": Json.String("verify ancestor call budget propagation")
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
  assert prop_c.status == 200
  assert must_json(prop_c.text).bool_at("result.isError") == Some(false)

  # 6. Inspect GET /api/admin/grants/tree and GET /api/events?scope=grants
  assert ApiTest.send(
    Main,
    Api.get("/api/admin/grants/tree").with_header("Authorization", "Bearer #{tok_a}"),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    403
  assert ApiTest.send(
    Main,
    Api.get("/api/events?scope=grants").with_header("Authorization", "Bearer #{tok_a}"),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    403

  tree_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/grants/tree")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tree_res.status == 200
  tj = must_json(tree_res.text)
  assert (tj.int_at("summary.delegated_grants") or 0) >= 2
  assert (tj.int_at("summary.active_agent_grants") or 0) >= 3
  glist = tj.list_at("grants") or []
  node_a = glist.find(fn(g) g.text_at("id") == Some(gr_a) end) or stop "node_a"
  node_b = glist.find(fn(g) g.text_at("id") == Some(gr_b) end) or stop "node_b"
  node_c = glist.find(fn(g) g.text_at("id") == Some(gr_c) end) or stop "node_c"
  assert node_a.int_at("descendant_count") == Some(2)
  assert node_b.text_at("parent_id") == Some(gr_a)
  assert node_b.int_at("descendant_count") == Some(1)
  assert node_c.text_at("parent_id") == Some(gr_b)
  assert (node_a.int_at("used_calls") or 0) >= 2
  assert (node_b.int_at("used_calls") or 0) >= 2
  assert (node_c.int_at("used_calls") or 0) >= 1

  sse_grants = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/events?scope=grants")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sse_grants.status == 200
  assert sse_grants.sse_subscribe_topics == ["claims", "grants"]
  assert sse_grants.text.contains?("event: grants.snapshot")

  # 7. Cascading revoke on B disables both B & C while keeping A active
  rev_b = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/admin/grants/#{gr_b}/revoke").with_json(Json.Object({}))),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert rev_b.status == 200
  assert must_json(rev_b.text).int_at("cascaded_count") == Some(2)
  assert rev_b.sse_published_events.any?(fn(e)
    e.topic == "grants" and e.event == Some("grant.revoked")
  end)

  tree_after_rev = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/grants/tree")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tree_after_rev.status == 200
  glist2 = must_json(tree_after_rev.text).list_at("grants") or []
  assert (glist2.find(fn(g) g.text_at("id") == Some(gr_c) end) or Json.Null).text_at("status") ==
    Some("revoked")
  assert (glist2.find(fn(g) g.text_at("id") == Some(gr_c) end) or Json.Null).text_at("revoked_via") ==
    Some(gr_b)
  assert (glist2.find(fn(g) g.text_at("id") == Some(gr_a) end) or Json.Null).text_at("status") ==
    Some("active")

  c_denied = ApiTest.send(
    Main,
    Api.get("/api/pages/#{pg_id}").with_header("Authorization", "Bearer #{tok_c}"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert c_denied.status == 401 or c_denied.status == 403
  assert ApiTest.send(
    Main,
    Api.get("/api/pages/#{pg_id}").with_header("Authorization", "Bearer #{tok_a}"),
    files,
    clock,
    env,
    rng,
    empty_net
  ).status ==
    200

  # 8. Emergency Kill Switch revokes all remaining agents while Owner stays authenticated
  kill_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/grants/kill-all").with_json(
        Json.Object({"reason": Json.String("Phase 4.3 emergency stop")})
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert kill_res.status == 200
  assert (must_json(kill_res.text).int_at("revoked_count") or 0) >= 1
  assert kill_res.sse_published_events.any?(fn(e)
    e.topic == "grants" and e.event == Some("grants.kill_all")
  end)

  a_denied = ApiTest.send(
    Main,
    Api.get("/api/pages/#{pg_id}").with_header("Authorization", "Bearer #{tok_a}"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert a_denied.status == 401 or a_denied.status == 403

  final_tree = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/admin/grants/tree")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert final_tree.status == 200
  assert must_json(final_tree.text).int_at("summary.active_agent_grants") == Some(0)
end
