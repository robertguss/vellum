## Vellum v3 Milestone 1 Slice 1.1 Integration Tests:
## Heading(4..6), Native GFM TableBlock, Toggle, TableOfContents & Chunked/Range Local Attachments.
module Tests.V3m1
use Main
use Api
use Arvo.WebTest
use Crypto
use Domain.Types{BlockKind, BlockOp, CollectionWritePolicy}
use Json
use Routes.Workspace

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
  end
end

test "v3 M1.1: Heading(4..6), TableBlock, Toggle, and TableOfContents page creation, patch & FTS"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m1.js",
        "css": ["assets/main-v3m1.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m1.js": "console.log('v3m1');",
    "public/assets/main-v3m1.css": "body{margin:0}"
  })
  t0 = Time.parse("2026-12-06T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  rng = SecureRandom.seeded(20261206)
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
          slug: "ops-docs",
          name: "Operations Docs",
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

  raw_md = """
    <!-- toc -->

    #### Quarter Ops Overview

    | Team | MetricToken | Target |
    | --- | --- | --- |
    | Platform | LatencyBudgetZebra | 120ms |

    <details>
    <summary>Escalation Runbook Toggle</summary>
    Contact ToggleDetailQuasar on-call rotation.
    </details>
    """
  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Block Parity Playbook",
          markdown: raw_md,
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed M1.1 block kinds")
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
  pj = must_json(pg_res.text)
  pg_id = pj.text_at("page.id") or stop "pg_id"
  blks = pj.list_at("blocks") or []
  assert blks.size == 4

  toc_blk = blks.get(0) or Json.Null
  h4_blk = blks.get(1) or Json.Null
  tbl_blk = blks.get(2) or Json.Null
  tog_blk = blks.get(3) or Json.Null
  assert toc_blk.get("kind") == Some(Json.String("table_of_contents"))
  assert (h4_blk.get("kind") or Json.Null).int_at("heading.level") == Some(4)
  assert (tbl_blk.get("kind") or Json.Null).bool_at("table_block.has_header") == Some(true)
  assert (tog_blk.get("kind") or Json.Null).text_at("toggle.summary") ==
    Some("Escalation Runbook Toggle")
  assert (tog_blk.get("kind") or Json.Null).bool_at("toggle.open") == Some(false)

  # BM25 search indexes both TableBlock cells and Toggle summary/body
  q_tbl = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=LatencyBudgetZebra&mode=bm25")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert q_tbl.status == 200
  assert (must_json(q_tbl.text).list_at("results") or []).any?(fn(r)
    r.text_at("page_id") == Some(pg_id)
  end)

  q_tog = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/search?q=ToggleDetailQuasar&mode=bm25")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert q_tog.status == 200
  assert (must_json(q_tog.text).list_at("results") or []).any?(fn(r)
    r.text_at("page_id") == Some(pg_id)
  end)

  # Surgical PATCH updates Toggle open state and preserves TableBlock round-trip
  tog_id = tog_blk.text_at("id") or stop "tog_id"
  patch_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{pg_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: tog_id,
              expected_version: 1,
              kind: Some(Toggle(summary: "Escalation Runbook Toggle", open: true)),
              markdown: "Contact UpdatedQuasar on-call rotation."
            )
          ],
          expected_versions: {tog_id: 1},
          reason: Some("open toggle and update body")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert patch_res.status == 200
  md_out = must_json(patch_res.text).text_at("anchored_markdown") or ""
  assert md_out.contains?("<!-- toc -->")
  assert md_out.contains?("#### Quarter Ops Overview")
  assert md_out.contains?("| LatencyBudgetZebra | 120ms |")
  assert md_out.contains?(":::toggle [open] Escalation Runbook Toggle")
end

test "v3 M1.1: Presign up to 500 MiB, chunked local attachment upload & HTTP Range 206 download"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m1b.js",
        "css": ["assets/main-v3m1b.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m1b.js": "console.log('v3m1b');",
    "public/assets/main-v3m1b.css": "body{margin:0}"
  })
  t0 = Time.parse("2026-12-06T11:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  rng = SecureRandom.seeded(20261207)
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
          slug: "media-vault",
          name: "Media Vault",
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

  pg_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Video Assets",
          markdown: "Demo video archive",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed media page")
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

  # 1. >500 MiB rejected with 422, while 250 MiB succeeds
  too_big = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: pg_id,
          filename: "huge.mp4",
          content_type: "video/mp4",
          size_bytes: 524288001,
          sha256_hex: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert too_big.status == 422

  large_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: pg_id,
          filename: "demo-250m.mp4",
          content_type: "video/mp4",
          size_bytes: 262144000,
          sha256_hex: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert large_ok.status == 201

  # 2. Chunked 2-part local upload + incomplete-commit 422 guard + full SHA-256 commit + Range 206
  full_bytes = "HelloChunkStream".bytes
  full_sha = Crypto.sha256(full_bytes).to_hex
  pre_chunk = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/attachments/presign").with_json(
        Workspace.PresignAttachmentInput(
          page_id: pg_id,
          filename: "walkthrough.mp4",
          content_type: "video/mp4",
          size_bytes: full_bytes.size,
          sha256_hex: Some(full_sha)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert pre_chunk.status == 201
  pre_j = must_json(pre_chunk.text)
  att_id = (pre_j.get("attachment") or Json.Null).text_at("id") or stop "att_id"
  upload_url = pre_j.text_at("upload_url") or stop "upload_url"

  part1 = "HelloChunk".bytes
  part2 = "Stream".bytes
  put1 = ApiTest.send(
    Main,
    Api.put("#{upload_url}&offset=0").with_bytes(part1, "application/octet-stream"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert put1.status == 200
  assert must_json(put1.text).int_at("file_size") == Some(10)

  # Committing before all 16 bytes arrive fails with 422
  early_commit = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/attachments/#{att_id}/commit").with_json(Json.Object({}))
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert early_commit.status == 422

  # Out-of-bounds offset fails with 422
  oob_put = ApiTest.send(
    Main,
    Api.put("#{upload_url}&offset=12").with_bytes(part2, "application/octet-stream"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert oob_put.status == 422

  put2 = ApiTest.send(
    Main,
    Api.put("#{upload_url}&offset=10").with_bytes(part2, "application/octet-stream"),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert put2.status == 200
  assert must_json(put2.text).int_at("file_size") == Some(16)

  final_commit = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/attachments/#{att_id}/commit").with_json(Json.Object({}))
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert final_commit.status == 200
  assert must_json(final_commit.text).text_at("status") == Some("ready")

  # Full download (200) + Accept-Ranges
  full_dl = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/attachments/#{att_id}/download")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert full_dl.status == 200
  assert full_dl.body == full_bytes
  assert full_dl.header("Accept-Ranges") == Some("bytes")

  # Partial Range bytes=0-4 -> 206 Partial Content
  range_head = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.get("/api/attachments/#{att_id}/download").with_header("Range", "bytes=0-4")
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert range_head.status == 206
  assert range_head.body == "Hello".bytes
  assert range_head.header("Content-Range") == Some("bytes 0-4/16")
  assert range_head.header("Accept-Ranges") == Some("bytes")

  # Suffix Range bytes=-6 -> 206 Partial Content ("Stream")
  range_tail = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.get("/api/attachments/#{att_id}/download").with_header("Range", "bytes=-6")
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert range_tail.status == 206
  assert range_tail.body == "Stream".bytes
  assert range_tail.header("Content-Range") == Some("bytes 10-15/16")
end
