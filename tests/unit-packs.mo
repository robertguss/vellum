## Unit tests extracted from `Domain.Packs` to keep production module lowering lean.
module Tests.UnitPacks
use Domain.Packs{
  ContextPack,
  PackPageInput,
  build_page_summary,
  compile_pack,
  page_is_stale?,
  render_llms_txt,
  validate_context_pack
}
use Domain.Types{
  AuthorKind,
  Block,
  BlockKind,
  Collection,
  CollectionWritePolicy,
  Page,
  PageKind,
  Provenance
}

test "LivingSummary, llms.txt index, and hard token-budget ContextPack compilation"
  t0 = Time.parse("2026-11-27T10:00:00Z") or stop "t0"
  stale_t = Time.parse("2026-10-01T10:00:00Z") or stop "stale_t"
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: t0
  )

  p1 = Page(
    id: "pg_pin",
    collection_id: "col_eng",
    parent_page_id: None,
    title: "Production Incident Runbook",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: Some(30),
    verified_at: Some(t0),
    verified_by: Some("usr_ada"),
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 2
  )
  p_stale = Page(
    id: "pg_stale",
    collection_id: "col_eng",
    parent_page_id: None,
    title: "Old Runbook",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "b",
    database_id: None,
    freshness_ttl_days: Some(7),
    verified_at: Some(stale_t),
    verified_by: Some("usr_ada"),
    created_by: "usr_ada",
    created_at: stale_t,
    updated_at: stale_t,
    archived_at: None,
    version: 1
  )
  p_long = Page(
    id: "pg_long",
    collection_id: "col_eng",
    parent_page_id: None,
    title: "Large Telemetry Archive",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "c",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  assert not page_is_stale?(p1, t0)
  assert page_is_stale?(p_stale, t0)

  b_pin = [
    Block(
      id: "blk_1",
      page_id: p1.id,
      parent_block_id: None,
      rank: "i0001",
      kind: Heading(level: 2),
      markdown: "Failover Steps",
      provenance: prov,
      version: 1
    ),
    Block(
      id: "blk_2",
      page_id: p1.id,
      parent_block_id: None,
      rank: "i0002",
      kind: TaskItem(checked: false),
      markdown: "Verify standby health",
      provenance: prov,
      version: 1
    )
  ]
  long_txt = "Telemetry signal sample line. ".repeat(120)
  b_long = [
    Block(
      id: "blk_big",
      page_id: p_long.id,
      parent_block_id: None,
      rank: "i0001",
      kind: Paragraph,
      markdown: long_txt,
      provenance: prov,
      version: 1
    )
  ]

  s1 = build_page_summary(p1, b_pin, None, None, None, t0)
  assert s1.headings == ["Failover Steps"]
  assert s1.open_tasks == 1
  assert s1.done_tasks == 0
  assert s1.structural_summary.contains?("Failover Steps")

  pack = ContextPack(
    id: "pk_oncall",
    slug: "oncall-pack",
    name: "On-Call Starter Pack",
    description: "Essential incident response docs",
    collection_ids: ["col_eng"],
    pinned_page_ids: [p1.id],
    database_ids: [],
    query_hint: None,
    fresh_only: true,
    include_full_blocks: true,
    token_budget: 280,
    created_by: "usr_ada",
    updated_at: t0,
    version: 1
  )
  assert validate_context_pack(pack) == None
  assert validate_context_pack(
    ContextPack(
      id: "pk_bad",
      slug: "bad slug!",
      name: "Bad",
      description: "",
      collection_ids: [],
      pinned_page_ids: [],
      database_ids: [],
      query_hint: None,
      fresh_only: false,
      include_full_blocks: true,
      token_budget: 500,
      created_by: "usr_ada",
      updated_at: t0,
      version: 1
    )
  ) != None

  compiled = compile_pack(
    pack,
    [
      PackPageInput(
        page: p1,
        blocks: b_pin,
        blueprint: None,
        meta: None,
        summary: Some(s1),
        pinned: true,
        stale: false
      ),
      PackPageInput(
        page: p_stale,
        blocks: [],
        blueprint: None,
        meta: None,
        summary: None,
        pinned: false,
        stale: true
      ),
      PackPageInput(
        page: p_long,
        blocks: b_long,
        blueprint: None,
        meta: None,
        summary: None,
        pinned: false,
        stale: false
      )
    ],
    [],
    t0
  )
  assert compiled.tokens_used <= pack.token_budget
  assert compiled.skipped_stale_count == 1
  assert compiled.markdown.contains?("Failover Steps")

  llms = render_llms_txt(
    [
      Collection(
        id: "col_eng",
        workspace_id: "ws_default",
        slug: "eng",
        name: "Engineering",
        description: "",
        icon: None,
        write_policy: DirectWithAudit,
        freshness_ttl_days: None,
        sort_order: "a",
        archived_at: None
      )
    ],
    [pack],
    [s1]
  )
  assert llms.contains?("vellum://packs/oncall-pack")
  assert llms.contains?("Production Incident Runbook")
end
