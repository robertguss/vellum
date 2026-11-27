## Vellum Tests.Phase1c Integration Tests (split for Mo lowering budget).
module Tests.Phase1c
use Main
use Api
use Arvo.Oidc
use Arvo.WebTest
use Crypto
use Db
use Domain.DatabaseModel{
  CellValue,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor
}
use Domain.Types{BlockKind, BlockOp}
use Http
use Json
use Modb.Ledger
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

