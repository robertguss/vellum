## Extracted unit tests for Domain.Blueprints, Domain.Sync,
## Domain.Collab, Domain.Garden, Domain.Secrets, and Domain.NotionImport.
module Tests.UnitDomainMisc
use Crypto
use Domain.Blueprints{
  BlueprintDef,
  PageBlueprintMeta,
  page_meta_plain_text,
  parse_yaml_frontmatter,
  parse_yaml_meta_values,
  to_yaml_frontmatter,
  validate_blueprint_def,
  validate_page_meta
}
use Domain.Collab{
  WebhookSub,
  claim_resource_for_block,
  claim_resource_for_page,
  claim_resource_for_row,
  webhook_matches_event?
}
use Domain.DatabaseModel{CellValue, PropertyDef, PropertyKind, SelectOption, SelectOptionColor}
use Domain.Garden{
  build_pr_search_query,
  detect_contradiction_signal,
  parse_block_citation_ref,
  parse_github_pr_webhook,
  verify_github_signature
}
use Domain.NotionImport{
  NotionPageImport,
  infer_database_from_csv,
  notion_page_title,
  parse_csv,
  rewrite_notion_links
}
use Domain.Secrets{finding_to_public_json, redact_tokens, scan_text}
use Domain.Sync{
  SyncManifestEntry,
  classify_file_sync,
  derive_title_from_markdown,
  page_rel_path,
  sha256_text,
  slugify_title
}
use Domain.Types{Page, PageKind}
use Json

test "blueprint validation, page meta validation, plain text, and yaml frontmatter"
  opt_open = SelectOption(id: "open", label: "Open", color: Green)
  opt_closed = SelectOption(id: "closed", label: "Closed", color: Red)
  bp = BlueprintDef(
    id: "bp_decision",
    slug: "decision-record",
    name: "Decision Record",
    description: "Architectural or budget decision",
    icon: Some("scale"),
    fields: [
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(options: [opt_open, opt_closed]),
        required: true,
        sort_order: "a"
      ),
      PropertyDef(
        id: "budget",
        name: "Budget",
        kind: Number(format: "currency"),
        required: false,
        sort_order: "b"
      ),
      PropertyDef(
        id: "owner",
        name: "Owner",
        kind: Person,
        required: false,
        sort_order: "c"
      )
    ],
    default_template_markdown: "## Decision Context\n\n## Recommendation",
    version: 1
  )
  assert validate_blueprint_def(bp) == None

  bad_slug_bp = BlueprintDef(
    id: bp.id,
    slug: "Invalid Slug!",
    name: bp.name,
    description: bp.description,
    icon: bp.icon,
    fields: bp.fields,
    default_template_markdown: bp.default_template_markdown,
    version: bp.version
  )
  assert validate_blueprint_def(bad_slug_bp) != None

  now = Time.parse("2026-11-26T12:00:00Z") or stop "now"
  budget_dec = "1250.50".to_decimal or stop "dec"
  page = Page(
    id: "pg_1",
    collection_id: "col_1",
    parent_page_id: None,
    title: "Migrate Storage",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "i",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_1",
    created_at: now,
    updated_at: now,
    archived_at: None,
    version: 3
  )

  missing_req = PageBlueprintMeta(
    page_id: "pg_1",
    blueprint_id: "bp_decision",
    values: {"budget": NumberVal(budget_dec)},
    updated_at: now
  )
  assert validate_page_meta(bp, missing_req.values) != None

  unknown_key = {"status": SelectVal(option_id: "open"), "extra": TextVal("bad")}
  assert validate_page_meta(bp, unknown_key) != None

  good_meta = PageBlueprintMeta(
    page_id: "pg_1",
    blueprint_id: "bp_decision",
    values: {
      "status": SelectVal(option_id: "open"),
      "budget": NumberVal(budget_dec),
      "owner": PrincipalVal(["usr_alice"])
    },
    updated_at: now
  )
  assert validate_page_meta(bp, good_meta.values) == None

  plain = page_meta_plain_text(bp, good_meta)
  assert plain.contains?("Status: Open")
  assert plain.contains?("Budget: 1250.5")

  yaml = to_yaml_frontmatter(page, Some(bp), Some(good_meta), "Hello")
  assert yaml.starts_with?("---\nid: \"pg_1\"\n")
  assert yaml.contains?("blueprint: \"decision-record\"")
  assert yaml.contains?("  status: \"open\"")
  assert yaml.contains?("  budget: 1250.5")
  assert yaml.ends_with?("---\n\nHello")

  parsed_fm = case parse_yaml_frontmatter(yaml)
    Ok(p): p
    Error(_): stop "parse_yaml_frontmatter"
  end
  assert parsed_fm.has_frontmatter
  assert parsed_fm.page_id == Some("pg_1")
  assert parsed_fm.title == Some("Migrate Storage")
  assert parsed_fm.collection_id == Some("col_1")
  assert parsed_fm.version == Some(3)
  assert parsed_fm.blueprint_slug == Some("decision-record")
  assert parsed_fm.body_markdown == "Hello"
  assert parse_yaml_meta_values(bp, parsed_fm.meta_raw) == Ok(good_meta.values)

  plain_md = case parse_yaml_frontmatter("# Just Markdown\n\nBody")
    Ok(p): p
    Error(_): stop "plain_md"
  end
  assert not plain_md.has_frontmatter
  assert plain_md.body_markdown == "# Just Markdown\n\nBody"
end

test "Sync deterministic paths, title derivation, SHA-256, and 3-way conflict classification"
  assert slugify_title("Gateway / Failover Runbook!!") == "gateway-failover-runbook"
  assert page_rel_path("eng-ops", "Gateway Runbook", "pg_123") == "eng-ops/gateway-runbook--pg_123.md"
  assert derive_title_from_markdown("eng-ops/new-sop.md", "Intro") == "new sop"
  assert derive_title_from_markdown("eng-ops/a.md", "# Service Failover Plan\n\nSteps") ==
    "Service Failover Plan"

  base_sha = sha256_text("v1 content")
  local_sha = sha256_text("v1 local edit")
  remote_sha = sha256_text("v2 remote edit")
  entry = SyncManifestEntry(
    page_id: "pg_1",
    collection_id: "col_1",
    collection_slug: "eng",
    rel_path: "eng/doc--pg_1.md",
    version: 1,
    content_sha256: base_sha,
    synced_at: "2026-12-05T10:00:00Z"
  )

  assert classify_file_sync(None, None, Some(1), Some(base_sha)) == "pull_new"
  assert classify_file_sync(None, Some(local_sha), None, None) == "push_create"
  assert classify_file_sync(Some(entry), Some(base_sha), Some(1), Some(base_sha)) == "clean"
  assert classify_file_sync(Some(entry), Some(local_sha), Some(1), Some(base_sha)) == "push_update"
  assert classify_file_sync(Some(entry), Some(base_sha), Some(2), Some(remote_sha)) == "pull_update"
  assert classify_file_sync(Some(entry), Some(local_sha), Some(2), Some(remote_sha)) ==
    "conflict_proposal"
  assert classify_file_sync(Some(entry), None, Some(1), Some(base_sha)) == "pull_update"
  assert classify_file_sync(Some(entry), Some(local_sha), None, None) == "remote_deleted"
end

test "Collab claim resources and webhook subscription event/collection matching"
  assert claim_resource_for_page("pg_1") == "page:pg_1"
  assert claim_resource_for_block("pg_1", "blk_2") == "page:pg_1:block:blk_2"
  assert claim_resource_for_row("db_1", "row_3") == "db:db_1:row:row_3"

  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  sub_scoped = WebhookSub(
    id: "wh_1",
    workspace_id: "ws_default",
    collection_id: Some("col_eng"),
    url: "https://agent.acme.io/hook",
    secret: "whsec_test",
    events: ["proposal.opened", "proposal.accepted"],
    enabled: true,
    created_by: "usr_1",
    created_at: t0
  )
  assert webhook_matches_event?(sub_scoped, "proposal.opened", Some("col_eng"))
  assert not webhook_matches_event?(sub_scoped, "proposal.opened", Some("col_other"))
  assert not webhook_matches_event?(sub_scoped, "page.created", Some("col_eng"))
  assert not webhook_matches_event?(sub_scoped, "proposal.opened", None)

  sub_wildcard = WebhookSub(
    id: "wh_2",
    workspace_id: "ws_default",
    collection_id: None,
    url: "https://agent.acme.io/all",
    secret: "whsec_all",
    events: ["*"],
    enabled: false,
    created_by: "usr_1",
    created_at: t0
  )
  assert not webhook_matches_event?(sub_wildcard, "proposal.opened", Some("col_eng"))
end

test "Garden parses block citation refs, detects contradictions, and verifies GitHub HMAC signatures"
  assert parse_block_citation_ref("blk_abc123") == Some((None, "blk_abc123"))
  assert parse_block_citation_ref("pg_1:blk_abc") == Some((Some("pg_1"), "blk_abc"))
  assert parse_block_citation_ref("page:pg_1:block:blk_abc") == Some((Some("pg_1"), "blk_abc"))
  assert parse_block_citation_ref("/p/pg_1#blk_abc") == Some((Some("pg_1"), "blk_abc"))
  assert parse_block_citation_ref("https://example.com") == None

  assert detect_contradiction_signal(
    "API gateway SLA target is 99.95% with 30 days log retention.",
    "API gateway SLA target is 99.5% with 7 days log retention."
  ) != None
  assert detect_contradiction_signal(
    "Gateway quorum v2 is deprecated and must never run.",
    "Gateway quorum v2 is required and always enabled."
  ) != None
  assert detect_contradiction_signal("Hello world", "Hello world") == None

  secret = "gh-secret-test"
  payload = Json.Object({
    "action": Json.String("opened"),
    "pull_request": Json.Object({
      "number": Json.int(42),
      "title": Json.String("Update gateway quorum port to 8443"),
      "body": Json.String("Change healthz port."),
      "html_url": Json.String("https://github.com/acme/infra/pull/42"),
      "head": Json.Object({"sha": Json.String("abc1234")}),
      "merged": Json.Boolean(false)
    }),
    "repository": Json.Object({"full_name": Json.String("acme/infra")}),
    "changed_files": Json.Array([Json.String("deploy/gateway.mo")])
  }).to_text
  sig = "sha256=#{Crypto.hmac_sha256(secret.bytes, payload.bytes).to_hex}"
  assert verify_github_signature(secret, payload.bytes, Some(sig))
  assert not verify_github_signature(secret, payload.bytes, Some("sha256=0000"))
  assert not verify_github_signature("", payload.bytes, Some(sig))

  ev = case parse_github_pr_webhook(payload.bytes)
    Ok(e): e
    Error(_): stop "parse_github_pr_webhook"
  end
  assert ev.pr_number == 42
  assert ev.changed_files == ["deploy/gateway.mo"]
  q = build_pr_search_query(ev)
  assert q.contains?("gateway")
end

test "Domain.Secrets scans every secret class, avoids false positives, masks safely, and redacts"
  clean = "Runbook summary: rotate deployment certificates quarterly and check gateway quorum v2."
  assert scan_text(clean) == []

  sample = "OpenAI: sk-proj-AbCdEf1234567890XyZ\nGitHub: ghp_Token1234567890abcdef123456\nStripe: sk_live_51TestKey9876543210\nSlack: xoxb-123456789012-abcdef\nAWS: AKIAIOSFODNN7EXAMPLE\nAgent: vlm_ag_testtoken1234567890\nHook: whsec_secretvalue1234567890\nPEM:\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAK\n-----END RSA PRIVATE KEY-----"
  found = scan_text(sample)
  kinds = found.map(fn(f) f.kind end)
  assert kinds == [
    "ai_api_key",
    "github_token",
    "stripe_secret_key",
    "slack_token",
    "aws_access_key",
    "vellum_agent_token",
    "webhook_secret",
    "pem_private_key"
  ]

  for f in found
    pub = finding_to_public_json(f).to_text
    assert not pub.contains?(f.raw_token)
    assert f.masked_preview != f.raw_token
  end

  tokens = found.map(fn(f) f.raw_token end)
  (redacted, n_repl) = redact_tokens(sample, tokens)
  assert n_repl == 8
  assert scan_text(redacted) == []
  assert not redacted.contains?("sk-proj-AbCdEf1234567890XyZ")
  assert redacted.contains?("[REDACTED]")
end

test "NotionImport ID stripping, internal link rewriting, RFC 4180 CSV parsing, and typed schema inference"
  p1 = NotionPageImport(
    path: "docs/Gateway%20Spec%209a1b2c3d4e5f67890123456789abcdef.md",
    title: None,
    markdown: "# Spec\n\n[[Runbook 0123456789abcdef0123456789abcdef]]\n\n[Read Runbook](Runbook%200123456789abcdef0123456789abcdef.md)"
  )
  assert notion_page_title(p1) == "Gateway Spec"
  rewritten = rewrite_notion_links(p1.markdown, {"Runbook": "pg_runbook"})
  assert rewritten.contains?("[[pg_runbook|Runbook]]")
  assert rewritten.contains?("[[pg_runbook|Read Runbook]]")

  csv_raw = "Incident,Severity,Cost,Date,Resolved,Link\n\"API, 502 spike\",Critical,125.50,2026-11-20,true,https://status.acme.io/1\nDB timeout,Warning,0.25,2026-11-21,false,https://status.acme.io/2\n"
  table = case parse_csv(csv_raw)
    Ok(t): t
    Error(_m): stop "parse_csv failed"
  end
  assert table.headers == ["Incident", "Severity", "Cost", "Date", "Resolved", "Link"]
  assert table.rows.size == 2
  inferred = case infer_database_from_csv(table)
    Ok(inf): inf
    Error(_m): stop "infer_database_from_csv failed"
  end
  assert inferred.properties.size == 6
  assert (inferred.properties.get(0) or stop "p0").kind == Title
  assert (inferred.properties.get(1) or stop "p1").kind is Select(options: _)
  assert (inferred.properties.get(2) or stop "p2").kind == Number(format: "plain")
  assert (inferred.properties.get(3) or stop "p3").kind == DateProp(include_time: false)
  assert (inferred.properties.get(4) or stop "p4").kind == Checkbox
  assert (inferred.properties.get(5) or stop "p5").kind == Url

  row0 = inferred.row_cells.first or stop "row0"
  assert row0.get("title") == Some(TextVal("API, 502 spike"))
  assert row0.get("cost") == Some(NumberVal("125.50".to_decimal or stop "dec"))
  assert row0.get("resolved") == Some(BoolVal(true))
end
