## Unit tests extracted from `Domain.Blocks` to keep production module lowering lean.
module Tests.UnitBlocks
use Domain.Blocks{
  MetricRef,
  apply_block_ops,
  blocks_metric_refs,
  blocks_plain_text,
  diff_blocks_to_ops,
  insert_block_sorted,
  parse_markdown_blocks,
  reconcile_blocks_from_markdown,
  sort_blocks,
  to_anchored_markdown
}
use Domain.Types{AuthorKind, Block, BlockKind, BlockOp, Citation, Provenance}

test "lossless anchored Markdown round-trip and surgical BlockOp patching"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: Some("gr_ada"),
    proposal_id: None,
    reason: Some("initial draft"),
    citations: [],
    updated_at: t0
  )

  blocks = [
    Block(
      id: "blk_01",
      page_id: "pag_1",
      parent_block_id: None,
      rank: "i0001",
      kind: Heading(level: 2),
      markdown: "Runbook",
      provenance: prov,
      version: 1
    ),
    Block(
      id: "blk_02",
      page_id: "pag_1",
      parent_block_id: None,
      rank: "i0002",
      kind: Paragraph,
      markdown: "Run mo serve to launch.",
      provenance: prov,
      version: 1
    ),
    Block(
      id: "blk_03",
      page_id: "pag_1",
      parent_block_id: None,
      rank: "i0003",
      kind: CodeBlock(language: "sh"),
      markdown: "mo serve main.mo --workers 8",
      provenance: prov,
      version: 1
    ),
    Block(
      id: "blk_04",
      page_id: "pag_1",
      parent_block_id: None,
      rank: "i0004",
      kind: TaskItem(checked: true),
      markdown: "Verify health",
      provenance: prov,
      version: 1
    )
  ]

  md = to_anchored_markdown(blocks)
  assert md.contains?("<!-- blk:blk_01 -->\n## Runbook")
  assert md.contains?("<!-- blk:blk_03 -->\n```sh\nmo serve main.mo --workers 8\n```")

  reparsed = parse_markdown_blocks("pag_1", md, prov, "blk")
  assert reparsed == blocks

  ## Apply surgical ops and reject stale version cleanly.
  ops = [
    ReplaceBlock(
      block_id: "blk_02",
      expected_version: 1,
      kind: None,
      markdown: "Run mo serve --workers 8."
    ),
    InsertBlockAfter(
      after_block_id: Some("blk_01"),
      parent_block_id: None,
      kind: Callout(tone: "NOTE", icon: None),
      markdown: "Requires OIDC + S3 config."
    )
  ]
  assert apply_block_ops(blocks, ops, "pag_1", prov, ["blk_new"]) is Ok(patched)
  assert patched.size == 5
  assert (patched.get(1) or stop "inserted").id == "blk_new"
  assert (patched.get(2) or stop "replaced").version == 2
  assert (patched.get(2) or stop "replaced").markdown == "Run mo serve --workers 8."

  stale_op = [ReplaceBlock(block_id: "blk_02", expected_version: 1, kind: None, markdown: "stale")]
  assert apply_block_ops(patched, stale_op, "pag_1", prov, []) is Error(_)

  # sort_blocks fast-path, (rank, id) tie-breaking, MoveBlock, AttachCitations, and DeleteBlock
  assert sort_blocks(patched) == patched
  tie_b = Block(
    id: "blk_z",
    page_id: "pag_1",
    parent_block_id: None,
    rank: "i0005",
    kind: Paragraph,
    markdown: "Z",
    provenance: prov,
    version: 1
  )
  tie_a = Block(
    id: "blk_a",
    page_id: "pag_1",
    parent_block_id: None,
    rank: "i0005",
    kind: Paragraph,
    markdown: "A",
    provenance: prov,
    version: 1
  )
  tied_sorted = sort_blocks([tie_b, tie_a])
  assert tied_sorted == [tie_a, tie_b]
  assert sort_blocks(tied_sorted) == tied_sorted
  assert insert_block_sorted([tie_a], tie_b) == [tie_a, tie_b]
  assert insert_block_sorted([tie_b], tie_a) == [tie_a, tie_b]

  cites = [
    Citation(
      source_kind: "url",
      source_ref: "https://example.com",
      label: "Spec",
      excerpt: None
    )
  ]
  extra_ops = [
    MoveBlock(block_id: "blk_04", new_parent_id: None, after_block_id: Some("blk_01")),
    AttachCitations(block_id: "blk_01", citations: cites),
    DeleteBlock(block_id: "blk_03", expected_version: 1)
  ]
  assert apply_block_ops(patched, extra_ops, "pag_1", prov, []) is Ok(after_extra)
  assert after_extra.size == 4
  assert after_extra == sort_blocks(after_extra)
  assert (after_extra.get(1) or stop "moved").id == "blk_04"
  assert (after_extra.get(0) or stop "cited").provenance.citations == cites
end

test "database view embed round-trip and metric ref extraction"
  now = Time.parse("2026-11-26T12:00:00Z") or stop "now"
  prov = Provenance(
    author_id: "usr_1",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: now
  )
  md = "<!-- blk:blk_intro -->\nTotal budget: {{metric:db_01.p_cost:sum}} across {{metric:db_01.p_cost:count}} items.\n\n<!-- blk:blk_view -->\n<!-- db_embed:db_01|view_99 -->\n\n<!-- blk:blk_view2 -->\n<!-- db_embed:db_02 -->"
  blks = parse_markdown_blocks("pg_1", md, prov, "blk")
  assert blks.size == 3
  b1 = blks.get(1) or Block(
    id: "",
    page_id: "",
    parent_block_id: None,
    rank: "",
    kind: Paragraph,
    markdown: "",
    provenance: prov,
    version: 0
  )
  b2 = blks.get(2) or b1
  assert b1.id == "blk_view"
  assert b1.kind == DatabaseViewEmbed(database_id: "db_01", view_id: Some("view_99"))
  assert b2.kind == DatabaseViewEmbed(database_id: "db_02", view_id: None)
  round = to_anchored_markdown(blks)
  assert round == md

  refs = blocks_metric_refs(blks)
  assert refs.size == 2
  m0 = refs.get(0) or MetricRef(raw_token: "", database_id: "", property_id: "", agg: "")
  m1 = refs.get(1) or m0
  assert m0.raw_token == "{{metric:db_01.p_cost:sum}}"
  assert m1.agg == "count"
end

test "ai-brief living card markdown round-trip"
  now = Time.parse("2026-11-27T10:00:00Z") or stop "now"
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: now
  )
  md = "<!-- blk:blk_brief1 -->\n:::ai-brief Summarize open security risks\nCurrent critical items are mitigation-ready.\n:::\n\n<!-- blk:blk_brief2 -->\n:::ai-brief [scope=col_eng refreshed=2026-11-27T09:00:00Z] Weekly SLA pulse\n- P99 latency: 14ms\n:::"
  blks = parse_markdown_blocks("pg_b", md, prov, "blk")
  assert blks.size == 2
  b0 = blks.get(0) or Block(
    id: "",
    page_id: "",
    parent_block_id: None,
    rank: "",
    kind: Paragraph,
    markdown: "",
    provenance: prov,
    version: 0
  )
  b1 = blks.get(1) or b0
  assert b0.kind == AiBrief(
    prompt: "Summarize open security risks",
    source_scope: None,
    refreshed_at: None
  )
  assert b0.markdown == "Current critical items are mitigation-ready."
  assert b1.kind == AiBrief(
    prompt: "Weekly SLA pulse",
    source_scope: Some("col_eng"),
    refreshed_at: Some("2026-11-27T09:00:00Z")
  )
  assert b1.markdown == "- P99 latency: 14ms"
  assert to_anchored_markdown(blks) == md
end

test "diff_blocks_to_ops round-trips edits, inserts, deletes, reorders, and no-ops via apply_block_ops"
  t0 = Time.parse("2026-12-05T10:00:00Z") or stop "t0"
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: Some("sync diff"),
    citations: [],
    updated_at: t0
  )
  b1 = Block(
    id: "blk_1",
    page_id: "pg_d",
    parent_block_id: None,
    rank: "i0001",
    kind: Heading(level: 2),
    markdown: "Intro",
    provenance: prov,
    version: 1
  )
  b2 = Block(
    id: "blk_2",
    page_id: "pg_d",
    parent_block_id: None,
    rank: "i0002",
    kind: Paragraph,
    markdown: "Original paragraph.",
    provenance: prov,
    version: 1
  )
  b3 = Block(
    id: "blk_3",
    page_id: "pg_d",
    parent_block_id: None,
    rank: "i0003",
    kind: Paragraph,
    markdown: "To be deleted.",
    provenance: prov,
    version: 1
  )
  existing = [b1, b2, b3]

  (noop_ops, noop_ids) = diff_blocks_to_ops(existing, existing)
  assert noop_ops.empty?
  assert noop_ids.empty?

  # Swap b2 before b1, edit b2, delete b3, insert new block between b2 and b1
  local_md = "<!-- blk:blk_2 -->\nEdited paragraph.\n\nInserted paragraph.\n\n<!-- blk:blk_1 -->\n## Intro"
  incoming = reconcile_blocks_from_markdown("pg_d", existing, local_md, prov, "sync1")
  assert incoming.size == 3
  (ops, new_ids) = diff_blocks_to_ops(existing, incoming)
  assert not ops.empty?
  applied = case apply_block_ops(existing, ops, "pg_d", prov, new_ids)
    Ok(xs): xs
    Error(_): stop "apply_block_ops"
  end
  assert applied.map(fn(b) (b.id, b.markdown) end) == incoming.map(fn(b) (b.id, b.markdown) end)
end

test "v3 Slice 1.1: Heading(4..6), GFM Table, Toggle (:::toggle & <details>), and TableOfContents round-trip"
  t0 = Time.parse("2026-12-06T09:00:00Z") or stop "t0"
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: Some("m1.1 block parity"),
    citations: [],
    updated_at: t0
  )
  src_md = """
    <!-- blk:blk_toc -->
    <!-- toc -->

    <!-- blk:blk_h4 -->
    #### Sub-section Rubric

    <!-- blk:blk_tbl -->
    | Service | Status | Owners |
    | --- | --- | --- |
    | Roster Sync | Active | Ops |

    <!-- blk:blk_tog -->
    :::toggle [open] Advanced Migration Notes
    Ensure all relations pass validation.
    :::

    <details>
    <summary>Legacy Export Toggle</summary>
    Imported details body line.
    </details>
    """
  parsed = parse_markdown_blocks("pg_m1", src_md, prov, "m1")
  assert parsed.size == 5
  assert (parsed.get(0) or stop "toc").kind == TableOfContents
  assert (parsed.get(1) or stop "h4").kind == Heading(level: 4)
  assert (parsed.get(2) or stop "tbl").kind == TableBlock(has_header: true)
  assert (parsed.get(3) or stop "tog1").kind == Toggle(summary: "Advanced Migration Notes", open: true)
  assert (parsed.get(4) or stop "tog2").kind == Toggle(summary: "Legacy Export Toggle", open: false)

  rendered = to_anchored_markdown(parsed)
  reparsed = parse_markdown_blocks("pg_m1", rendered, prov, "m2")
  assert reparsed.map(fn(b) (b.id, b.kind, b.markdown) end) ==
    parsed.map(fn(b) (b.id, b.kind, b.markdown) end)

  plain = blocks_plain_text(parsed)
  assert plain.contains?("Roster Sync")
  assert plain.contains?("Advanced Migration Notes")
  assert plain.contains?("Legacy Export Toggle")
end
