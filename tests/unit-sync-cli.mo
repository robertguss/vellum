## Extracted unit tests for Sync CLI.
module Tests.UnitSyncCli
use Crypto
use Http
use Json
use Sync{SyncCliConfig, SyncRunSummary, run_sync_command}

test "SyncCli pull, clean local push, and conflict routing to Proposal without clobber or merge markers"
  files = Files.in_memory({})
  console = Console.fake()
  t0 = Time.parse("2026-12-05T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)

  v1_doc = "---\nid: \"pg_1\"\ntitle: \"Runbook\"\ncollection_id: \"col_eng\"\nversion: 1\n---\n\n<!-- blk:blk_1 -->\nLive step one."
  v1_sha = Crypto.sha256(v1_doc.bytes).to_hex
  rel = "eng/runbook--pg_1.md"

  cfg = SyncCliConfig(
    subcommand: "sync",
    root_dir: "docs",
    server_url: "http://127.0.0.1:8080",
    token: "vlm_ag_test",
    collections: None,
    reason: Some("cli test")
  )

  snap1_req = Http.get("http://127.0.0.1:8080/api/sync/snapshot").header(
    "Authorization",
    "Bearer vlm_ag_test"
  ).header("Accept", "application/json")
  snap1_body = Json.Object({
    "txid": Json.int(1),
    "collections": Json.Array([Json.Object({"id": Json.String("col_eng"), "slug": Json.String("eng")})]),
    "pages": Json.Array([
      Json.Object({
        "page_id": Json.String("pg_1"),
        "collection_id": Json.String("col_eng"),
        "collection_slug": Json.String("eng"),
        "title": Json.String("Runbook"),
        "version": Json.int(1),
        "rel_path": Json.String(rel),
        "content_sha256": Json.String(v1_sha),
        "markdown_document": Json.String(v1_doc)
      })
    ])
  }).to_text
  net1 = Network.fake(Http.replies([(snap1_req, Http.reply(200, snap1_body))]))
  r1 = run_sync_command(cfg, files, console, clock, net1)
  assert r1 == Ok(SyncRunSummary(pulled: 1, pushed: 0, proposals_opened: 0, conflicts_skipped: 0, clean: 0))
  assert files.read_text("docs/#{rel}") == Ok(v1_doc)

  local_edit = "---\nid: \"pg_1\"\ntitle: \"Runbook\"\ncollection_id: \"col_eng\"\nversion: 1\n---\n\n<!-- blk:blk_1 -->\nLocal developer edit."
  assert files.write_text("docs/#{rel}", local_edit) is Ok(Unit)

  v2_remote = "---\nid: \"pg_1\"\ntitle: \"Runbook\"\ncollection_id: \"col_eng\"\nversion: 2\n---\n\n<!-- blk:blk_1 -->\nRemote web edit."
  v2_sha = Crypto.sha256(v2_remote.bytes).to_hex
  snap2_body = Json.Object({
    "txid": Json.int(2),
    "collections": Json.Array([Json.Object({"id": Json.String("col_eng"), "slug": Json.String("eng")})]),
    "pages": Json.Array([
      Json.Object({
        "page_id": Json.String("pg_1"),
        "collection_id": Json.String("col_eng"),
        "collection_slug": Json.String("eng"),
        "title": Json.String("Runbook"),
        "version": Json.int(2),
        "rel_path": Json.String(rel),
        "content_sha256": Json.String(v2_sha),
        "markdown_document": Json.String(v2_remote)
      })
    ])
  }).to_text
  push_req = Http.post("http://127.0.0.1:8080/api/sync/push").json(
    Json.Object({
      "page_id": Json.String("pg_1"),
      "collection_id": Json.String("col_eng"),
      "rel_path": Json.String(rel),
      "markdown_document": Json.String(local_edit),
      "expected_version": Json.int(1),
      "reason": Json.String("cli test")
    })
  ).header("Authorization", "Bearer vlm_ag_test").header("Accept", "application/json")
  push_reply = Json.Object({
    "outcome": Json.String("proposal_opened"),
    "conflict_reason": Json.String("version_mismatch"),
    "expected_version": Json.int(1),
    "live_version": Json.int(2),
    "ops_staged": Json.int(1),
    "proposal": Json.Object({"id": Json.String("prop_conflict_1")})
  }).to_text
  net2 = Network.fake(
    Http.replies([
      (snap1_req, Http.reply(200, snap2_body)),
      (push_req, Http.reply(202, push_reply))
    ])
  )
  r2 = run_sync_command(cfg, files, console, clock, net2)
  assert r2 == Ok(SyncRunSummary(pulled: 0, pushed: 0, proposals_opened: 1, conflicts_skipped: 0, clean: 0))
  preserved = case files.read_text("docs/#{rel}")
    Ok(t): t
    Error(_): ""
  end
  assert preserved == local_edit
  assert not preserved.contains?("<<<<<<<")
end
