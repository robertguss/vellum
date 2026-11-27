## Vellum v3 Milestone 1 Slice 1.3 Integration Tests:
## Nested Notion ZIP Import (depth-6 hierarchy, *_all.csv priority, Untitled view deduplication,
## DatabaseViewEmbed links, Status/Email inference) and PATCH /api/pages/:id (reparenting,
## cover attachment binding, cycle guards, and BM25 FTS index sync).
module Tests.V3m1c
use Main
use Api
use Arvo.WebTest
use Crypto
use Domain.DatabaseModel{DatabaseDef, PropertyKind}
use Domain.NotionImport{NotionCsvImport, NotionPageImport}
use Domain.Types{CollectionWritePolicy, Page}
use Json
use Routes.Importer
use Routes.Workspace

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
  end
end

fn decode_pages_list(j: Json) : List(Page)
  case Json.decode_strict[List(Page)](j.to_text.bytes)
    Ok(xs): xs
    Error(_): stop "expected Page list"
  end
end

fn decode_dbs_list(j: Json) : List(DatabaseDef)
  case Json.decode_strict[List(DatabaseDef)](j.to_text.bytes)
    Ok(xs): xs
    Error(_): stop "expected DatabaseDef list"
  end
end

test "v3 M1.3: Nested Notion batch import + CSV deduplication + PATCH /api/pages/:id hierarchy, cover & cycle guard"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m1c.js",
        "css": ["assets/main-v3m1c.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m1c.js": "console.log('v3m1c');",
    "public/assets/main-v3m1c.css": "body{margin:0}"
  })
  t0 = Time.parse("2026-12-06T12:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  rng = SecureRandom.seeded(20261209)
  empty_net = Network.fake({})

  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  cb = ApiTest.send(
    Main,
    WebTest.prepare(
      guest,
      Api.get("/auth/solo/login?return_to=/").with_header("Host", "127.0.0.1:8080")
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cb.status == 303
  owner = WebTest.absorb(guest, cb)

  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "migration-lab",
          name: "Migration Lab",
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
  assert col_res.status == 201
  col_id = must_json(col_res.text).text_at("id") or stop "col_id"

  id_root = "00000000000000000000000000000001"
  id_l2 = "00000000000000000000000000000002"
  id_l3 = "00000000000000000000000000000003"
  id_l4 = "00000000000000000000000000000004"
  id_l5 = "00000000000000000000000000000005"
  id_l6 = "00000000000000000000000000000006"
  id_db = "aaaa0000000000000000000000000010"
  id_dup = "bbbb0000000000000000000000000020"

  # 1. Batch import with out-of-order depth-6 pages, _all.csv priority, duplicate Untitled CSV, and embedded DB link
  imp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/import/notion").with_json(
        Importer.ImportNotionInput(
          collection_id: col_id,
          pages: [
            NotionPageImport(
              path: "Root #{id_root}/L2 #{id_l2}/L3 #{id_l3}/L4 #{id_l4}/L5 #{id_l5}/Leaf #{id_l6}.md",
              title: None,
              markdown: "Deep leaf content"
            ),
            NotionPageImport(
              path: "Root #{id_root}/L2 #{id_l2}/L3 #{id_l3}/L4 #{id_l4}/L5 #{id_l5}.md",
              title: None,
              markdown: "Level 5 note"
            ),
            NotionPageImport(
              path: "Root #{id_root}/L2 #{id_l2}/L3 #{id_l3}/L4 #{id_l4}.md",
              title: None,
              markdown: "Level 4 note"
            ),
            NotionPageImport(
              path: "Root #{id_root}/L2 #{id_l2}/L3 #{id_l3}.md",
              title: None,
              markdown: "Level 3 note"
            ),
            NotionPageImport(
              path: "Root #{id_root}/L2 #{id_l2}.md",
              title: None,
              markdown: "Level 2 note"
            ),
            NotionPageImport(
              path: "Root #{id_root}.md",
              title: None,
              markdown: "# Root Hub\n\n[Work Items](Work%20Items%20#{id_db}.csv)\n\n[[L2 #{id_l2}]]"
            )
          ],
          databases: [
            NotionCsvImport(
              title: "Work Items #{id_db}.csv",
              csv_text: "Item,Status\nShort row,Open\n"
            ),
            NotionCsvImport(
              title: "Work Items #{id_db}_all.csv",
              csv_text: "Item,Status,Owner Email\nShip engine,Done,ops@acme.io\nWrite tests,In Progress,eng@acme.io\n"
            ),
            NotionCsvImport(
              title: "Untitled #{id_dup}.csv",
              csv_text: "Item,Status,Owner Email\nShip engine,Done,ops@acme.io\n"
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
  assert imp_res.status == 201
  imp_json = must_json(imp_res.text)
  assert imp_json.int_at("page_count") == Some(6)
  assert imp_json.int_at("nested_page_count") == Some(5)
  assert imp_json.int_at("database_count") == Some(1)
  assert imp_json.int_at("skipped_duplicate_databases") == Some(2)
  assert imp_json.int_at("row_count") == Some(2)

  pages = decode_pages_list(imp_json.get("imported_pages") or Json.Null)
  dbs = decode_dbs_list(imp_json.get("imported_databases") or Json.Null)
  assert pages.size == 6
  assert dbs.size == 1

  leaf_pg = pages.get(0) or stop "leaf_pg"
  l5_pg = pages.get(1) or stop "l5_pg"
  l4_pg = pages.get(2) or stop "l4_pg"
  l3_pg = pages.get(3) or stop "l3_pg"
  l2_pg = pages.get(4) or stop "l2_pg"
  root_pg = pages.get(5) or stop "root_pg"

  assert leaf_pg.parent_page_id == Some(l5_pg.id)
  assert l5_pg.parent_page_id == Some(l4_pg.id)
  assert l4_pg.parent_page_id == Some(l3_pg.id)
  assert l3_pg.parent_page_id == Some(l2_pg.id)
  assert l2_pg.parent_page_id == Some(root_pg.id)
  assert root_pg.parent_page_id == None

  db_def = dbs.first or stop "db_def"
  assert db_def.properties.size == 3
  st_ok = if (db_def.properties.get(1) or stop "status_prop").kind is Status(
    options: _,
    done_option_ids: dids
  )
    dids.contains?("done")
  else
    false
  end
  assert st_ok
  assert (db_def.properties.get(2) or stop "email_prop").kind == Email

  # Verify Root page contains DatabaseViewEmbed and PageLink blocks
  show_root = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{root_pg.id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert show_root.status == 200
  root_md = must_json(show_root.text).text_at("anchored_markdown") or ""
  assert root_md.contains?("<!-- db_embed:#{db_def.id} -->")
  assert root_md.contains?("[[#{l2_pg.id}|L2]]")

  # 2. Upload & commit local attachment to Root, then PATCH /api/pages/:id (cover, icon, rename, reparent)
  cov_bytes = "PNGCOVER".bytes
  cov_sha = Crypto.sha256(cov_bytes).to_hex
  pres_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: root_pg.id,
          filename: "cover.png",
          content_type: "image/png",
          size_bytes: cov_bytes.size,
          sha256_hex: Some(cov_sha)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pres_res.status == 201
  pres_json = must_json(pres_res.text)
  att_id = must_json(pres_res.text).text_at("attachment.id") or stop "att_id"
  upload_url = pres_json.text_at("upload_url") or stop "upload_url"

  put_res = ApiTest.send(
    Main,
    Api.put(upload_url).with_bytes(cov_bytes, "image/png"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert put_res.status == 200

  comm_res = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.post("/api/attachments/#{att_id}/commit").with_json(Json.Object({}))),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert comm_res.status == 200

  # Patch Leaf: set cover, icon, title, and reparent under L3
  patch_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{leaf_pg.id}").with_json(
        Workspace.UpdatePageInput(
          title: Some("Renamed Nebula Leaf"),
          parent_page_id: Some(l3_pg.id),
          clear_parent: None,
          icon: Some("sparkles"),
          cover_attachment_id: Some(att_id),
          clear_cover: None,
          reason: Some("attach cover and reparent")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert patch_ok.status == 200
  pj = must_json(patch_ok.text)
  assert pj.text_at("page.title") == Some("Renamed Nebula Leaf")
  assert pj.text_at("page.icon") == Some("sparkles")
  assert pj.text_at("page.parent_page_id") == Some(l3_pg.id)
  assert pj.text_at("page.cover_attachment_id") == Some(att_id)
  assert pj.int_at("page.version") == Some(2)

  # FTS search reflects updated title immediately
  srch = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=Nebula&mode=bm25")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert srch.status == 200
  assert srch.text.contains?(leaf_pg.id)

  # Negative guards: self-parent (422), 3-hop cycle Root -> L2 -> L3 <- Root (422), missing cover (404)
  self_err = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{root_pg.id}").with_json(
        Workspace.UpdatePageInput(
          title: None,
          parent_page_id: Some(root_pg.id),
          clear_parent: None,
          icon: None,
          cover_attachment_id: None,
          clear_cover: None,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert self_err.status == 422

  cyc_err = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{root_pg.id}").with_json(
        Workspace.UpdatePageInput(
          title: None,
          parent_page_id: Some(l3_pg.id),
          clear_parent: None,
          icon: None,
          cover_attachment_id: None,
          clear_cover: None,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cyc_err.status == 422

  miss_cov = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{root_pg.id}").with_json(
        Workspace.UpdatePageInput(
          title: None,
          parent_page_id: None,
          clear_parent: None,
          icon: None,
          cover_attachment_id: Some("att_missing"),
          clear_cover: None,
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert miss_cov.status == 404

  # Clear parent and cover
  clr_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{leaf_pg.id}").with_json(
        Workspace.UpdatePageInput(
          title: None,
          parent_page_id: None,
          clear_parent: Some(true),
          icon: Some(""),
          cover_attachment_id: None,
          clear_cover: Some(true),
          reason: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert clr_res.status == 200
  cj = must_json(clr_res.text)
  assert cj.get("page.parent_page_id") == None or clr_res.text.contains?("\"parent_page_id\":null")
  assert clr_res.text.contains?("\"cover_attachment_id\":null")
end
