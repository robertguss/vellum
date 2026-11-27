## Progressive disclosure Context Packs (`vellum://packs/<slug>`, `/llms.txt`),
## automatic structural + semantic `LivingSummary` headers, and hard token-budget compilation.
module Domain.Packs
expose LivingSummary(..),
ContextPack(..),
CompiledPackItem(..),
CompiledPackResult(..),
PackPageInput(..),
PackDbInput(..),
estimate_tokens,
truncate_to_token_budget,
valid_pack_slug?,
validate_context_pack,
page_is_stale?,
build_page_summary,
build_database_summary,
render_llms_txt,
compile_pack
use Domain.Blocks
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta, to_yaml_frontmatter}
use Domain.DatabaseModel{CellValue, DatabaseDef, EnrichedRow, PropertyKind, effective_cell, extract_row_title}
use Domain.Policy{valid_collection_slug?}
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

## Compact ~50-token structural + optional semantic summary kept up-to-date on every Page and Database save.
struct LivingSummary
  id: Text
  entity_kind: Text
  entity_id: Text
  collection_id: Text
  title: Text
  structural_summary: Text
  semantic_summary: Option(Text)
  headings: List(Text)
  word_count: Int
  open_tasks: Int
  done_tasks: Int
  row_count: Int
  blueprint_slug: Option(Text)
  estimated_tokens: Int
  source_version: Int
  semantic_source_version: Int
  updated_at: Time
end

## Reusable token-budgeted knowledge bundle compiled into Markdown and exposed via `/api/packs/:slug` & MCP `vellum://packs/<slug>`.
struct ContextPack
  id: Text
  slug: Text
  name: Text
  description: Text
  collection_ids: List(Text)
  pinned_page_ids: List(Text)
  database_ids: List(Text)
  query_hint: Option(Text)
  fresh_only: Bool
  include_full_blocks: Bool
  token_budget: Int
  created_by: Text
  updated_at: Time
  version: Int
end

## Telemetry entry recording how a single page or database fit inside a compiled `ContextPack`.
struct CompiledPackItem
  entity_kind: Text
  entity_id: Text
  collection_id: Text
  title: Text
  inclusion_mode: Text
  tokens_used: Int
  pinned: Bool
end

## Token-budgeted Markdown artifact and audit report returned by `compile_pack`.
struct CompiledPackResult
  pack: ContextPack
  markdown: Text
  tokens_used: Int
  token_budget: Int
  budget_utilization_pct: Int
  included_items: List(CompiledPackItem)
  omitted_count: Int
  skipped_stale_count: Int
  compiled_at: Time
end

## Caller-supplied page bundle passed to `compile_pack` (already grant-filtered).
struct PackPageInput
  page: Page
  blocks: List(Block)
  blueprint: Option(BlueprintDef)
  meta: Option(PageBlueprintMeta)
  summary: Option(LivingSummary)
  pinned: Bool
  stale: Bool
end

## Caller-supplied database bundle passed to `compile_pack` (already grant-filtered).
struct PackDbInput
  def: DatabaseDef
  rows: List(EnrichedRow)
  summary: Option(LivingSummary)
end

## Deterministic byte-to-token estimator (~4 UTF-8 bytes per token).
fn estimate_tokens(text: Text) : Int
  return 0 if text.empty?
  (text.byte_count + 3) / 4
end

## Truncates `text` safely at a UTF-8 boundary so `estimate_tokens(result) <= max_tokens`.
fn truncate_to_token_budget(text: Text, max_tokens: Int) : Text
  return "" if max_tokens <= 0
  max_bytes = max_tokens * 4
  return text if text.byte_count <= max_bytes
  raw = text.bytes
  var cut = max_bytes
  while cut > 0
    case raw.slice(0, cut).decode_utf8
      Some(valid): return valid
      None: cut -= 1
    end
  end
  ""
end

## Validates URL-safe kebab-case slug format (`^[a-z0-9][a-z0-9-]{0,63}$`).
fn valid_pack_slug?(slug: Text) : Bool
  valid_collection_slug?(slug)
end

## Validates a `ContextPack` before persistence in `Modb.Table`.
fn validate_context_pack(p: ContextPack) : Option(Text)
  return Some("pack id must not be empty") if p.id.trim.empty?
  if not valid_pack_slug?(p.slug)
    return Some("pack slug '#{p.slug}' must match ^[a-z0-9][a-z0-9-]{0,63}$")
  end
  return Some("pack name must not be empty") if p.name.trim.empty?
  if p.token_budget < 256 or p.token_budget > 64000
    return Some("pack token_budget must be between 256 and 64000")
  end
  return Some("pack version must be >= 1") if p.version < 1
  None
end

## Returns `true` when `page` specifies `freshness_ttl_days > 0` and `now` exceeds its verification window.
fn page_is_stale?(page: Page, now: Time) : Bool
  case page.freshness_ttl_days
    None: false
    Some(ttl) if ttl <= 0: false
    Some(ttl):
      ref_at = page.verified_at or page.updated_at
      now > ref_at + ttl.days
  end
end

fn count_words(text: Text) : Int
  var count = 0
  for ln in text.lines
    for tok in ln.split(" ")
      if not tok.trim.empty?
        count += 1
      end
    end
  end
  count
end

## Builds a compact zero-LLM `LivingSummary` for `page`, preserving any existing `semantic_summary`.
fn build_page_summary(
  page: Page,
  blocks: List(Block),
  bp_opt: Option(BlueprintDef),
  meta_opt: Option(PageBlueprintMeta),
  prev_opt: Option(LivingSummary),
  now: Time
) : LivingSummary
  sorted = Blocks.sort_blocks(blocks)
  var headings = []
  var open_tasks = 0
  var done_tasks = 0
  var embeds = 0
  for b in sorted
    case b.kind
      Heading(level: _):
        ht = b.markdown.trim
        if not ht.empty? and headings.size < 8
          headings = headings.append(ht)
        end
      TaskItem(checked: c):
        if c
          done_tasks += 1
        else
          open_tasks += 1
        end
      DatabaseViewEmbed(database_id: _, view_id: _): embeds += 1
      Paragraph | BulletListItem | OrderedListItem(start: _) | Quote | Callout(tone: _, icon: _) | CodeBlock(
        language: _
      ) | Divider | Image(attachment_id: _, caption: _) | FileEmbed(attachment_id: _, filename: _) | PageLink(
        target_page_id: _
      ) | AiBrief(prompt: _, source_scope: _, refreshed_at: _): Unit
    end
  end

  plain = Blocks.blocks_plain_text(sorted)
  wc = count_words(plain)
  bp_slug = bp_opt.map(fn(b) b.slug end)

  var summary_parts = ["#{page.title} (#{wc}w, #{sorted.size} blocks)"]
  case bp_slug
    Some(s): summary_parts = summary_parts.append("bp=#{s}")
    None: Unit
  end
  if open_tasks + done_tasks > 0
    summary_parts = summary_parts.append("tasks=#{done_tasks}/#{open_tasks + done_tasks}")
  end
  if embeds > 0
    summary_parts = summary_parts.append("embeds=#{embeds}")
  end
  base_str = summary_parts.join(", ")
  struct_sum = if headings.empty?
    base_str
  else
    sec_preview = headings.take(5).join(" / ")
    "#{base_str} — #{sec_preview}"
  end

  anchored = Blocks.to_anchored_markdown(sorted)
  full_doc = to_yaml_frontmatter(page, bp_opt, meta_opt, anchored)
  est = estimate_tokens(full_doc)

  (sem_sum, sem_ver) = case prev_opt
    Some(prev): (prev.semantic_summary, prev.semantic_source_version)
    None: (None, 0)
  end

  LivingSummary(
    id: "page:#{page.id}",
    entity_kind: "page",
    entity_id: page.id,
    collection_id: page.collection_id,
    title: page.title,
    structural_summary: truncate_to_token_budget(struct_sum, 80),
    semantic_summary: sem_sum,
    headings: headings,
    word_count: wc,
    open_tasks: open_tasks,
    done_tasks: done_tasks,
    row_count: 0,
    blueprint_slug: bp_slug,
    estimated_tokens: est,
    source_version: page.version,
    semantic_source_version: sem_ver,
    updated_at: now
  )
end

## Builds a compact zero-LLM `LivingSummary` with exact `Decimal` column totals for a relational database.
fn build_database_summary(
  def: DatabaseDef,
  rows: List(EnrichedRow),
  prev_opt: Option(LivingSummary),
  now: Time
) : LivingSummary
  col_names = def.properties.map(fn(p) p.name end)
  var totals_parts = []
  for p in def.properties
    is_numeric? = case p.kind
      Number(format: _): true
      Title | RichText | DateProp(include_time: _) | Select(options: _) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
        target_db_id: _,
        inverse_prop_id: _
      ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): false
    end
    if is_numeric? and totals_parts.size < 3
      var acc = 0.0
      for er in rows
        case effective_cell(er, p.id)
          NumberVal(d): acc += d
          Empty | TextVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
            option_ids: _
          ) | BoolVal(_) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
        end
      end
      totals_parts = totals_parts.append("#{p.name}=#{acc.to_text}")
    end
  end

  base_str = "Database '#{def.title}': #{rows.size} rows, #{def.properties.size} properties"
  struct_sum = if totals_parts.empty?
    base_str
  else
    "#{base_str} (#{totals_parts.join(", ")})"
  end

  est = 30 + rows.size * 20
  (sem_sum, sem_ver) = case prev_opt
    Some(prev): (prev.semantic_summary, prev.semantic_source_version)
    None: (None, 0)
  end

  LivingSummary(
    id: "db:#{def.id}",
    entity_kind: "database",
    entity_id: def.id,
    collection_id: def.collection_id,
    title: def.title,
    structural_summary: truncate_to_token_budget(struct_sum, 80),
    semantic_summary: sem_sum,
    headings: col_names.take(10),
    word_count: 0,
    open_tasks: 0,
    done_tasks: 0,
    row_count: rows.size,
    blueprint_slug: None,
    estimated_tokens: est,
    source_version: def.version,
    semantic_source_version: sem_ver,
    updated_at: now
  )
end

## Renders the compact, grant-filtered `/llms.txt` Layer 1 workspace index.
fn render_llms_txt(
  cols: List(Collection),
  packs: List(ContextPack),
  summaries: List(LivingSummary)
) : Text
  var col_names = {}
  for c in cols
    col_names = col_names.set(c.id, c.name)
  end

  var lines = [
    "# Vellum Workspace Index (/llms.txt)",
    "",
    "> Progressive-disclosure index: read Context Packs via `vellum://packs/<slug>` or `/api/packs/<slug>/markdown`, then fetch surgical `blk_*` anchors or `vellum.db_query` only as needed.",
    ""
  ]

  lines = lines.append("## Context Packs (#{packs.size})")
  if packs.empty?
    lines = lines.append("- _No context packs defined yet._")
  else
    for p in packs
      desc = if p.description.trim.empty?: "Compiled workspace context pack" else: p.description.trim
      lines = lines.append(
        "- **#{p.name}** (`vellum://packs/#{p.slug}` | `/api/packs/#{p.slug}/markdown`, budget #{p.token_budget} tok): #{desc}"
      )
    end
  end
  lines = lines.append("")

  lines = lines.append("## Accessible Collections (#{cols.size})")
  for c in cols
    lines = lines.append("- **#{c.name}** (`#{c.slug}`, id=`#{c.id}`)")
  end
  lines = lines.append("")

  page_sums = summaries.filter(fn(s) s.entity_kind == "page" end)
  db_sums = summaries.filter(fn(s) s.entity_kind == "database" end)

  lines = lines.append("## Database Living Summaries (#{db_sums.size})")
  if db_sums.empty?
    lines = lines.append("- _No accessible databases yet._")
  else
    for s in db_sums
      cname = col_names.get(s.collection_id) or s.collection_id
      blurb = s.semantic_summary or s.structural_summary
      lines = lines.append(
        "- **#{s.title}** (`#{s.entity_id}`, col=#{cname}, ~#{s.estimated_tokens} tok): #{blurb}"
      )
    end
  end
  lines = lines.append("")

  lines = lines.append("## Page Living Summaries (#{page_sums.size})")
  if page_sums.empty?
    lines = lines.append("- _No accessible pages yet._")
  else
    for s in page_sums
      cname = col_names.get(s.collection_id) or s.collection_id
      blurb = s.semantic_summary or s.structural_summary
      lines = lines.append(
        "- **#{s.title}** (`vellum://pages/#{s.entity_id}`, col=#{cname}, ~#{s.estimated_tokens} tok): #{blurb}"
      )
    end
  end

  lines.join("\n")
end

fn format_db_pack_section(inp: PackDbInput) : Text
  def = inp.def
  sum_line = case inp.summary
    Some(s): s.semantic_summary or s.structural_summary
    None: "#{def.title} (#{inp.rows.size} rows)"
  end
  cols_line = def.properties.map(fn(p) "#{p.name} (`#{p.id}`)" end).join(", ")
  var lines = [
    "## Database: #{def.title} (`#{def.id}`)",
    "Summary: #{sum_line}",
    "Columns: #{cols_line}"
  ]
  if not inp.rows.empty?
    lines = lines.append("Sample Rows (up to 15):")
    for er in inp.rows.take(15)
      row_title = extract_row_title(def, er.row.cells)
      var cell_bits = []
      for p in def.properties
        val = effective_cell(er, p.id)
        if val != Empty
          vstr = case val
            TextVal(t): t
            NumberVal(d): d.to_text
            DateVal(start: s, end_date: _): s.to_iso
            SelectVal(option_id: o): o
            MultiSelectVal(option_ids: os): os.join(",")
            BoolVal(b): if b: "true" else: "false"
            PrincipalVal(ps): ps.join(",")
            UrlVal(u): u
            RelationVal(row_ids: rs): "#{rs.size} linked"
            Empty: ""
          end
          if not vstr.trim.empty? and cell_bits.size < 5
            cell_bits = cell_bits.append("#{p.name}=#{vstr}")
          end
        end
      end
      lines = lines.append("- **#{row_title}** (`#{er.row.id}`): #{cell_bits.join(" | ")}")
    end
  end
  lines.join("\n")
end

## Compiles a `ContextPack` into token-budgeted Markdown prioritizing pinned items and enforcing `used <= token_budget`.
fn compile_pack(
  pack: ContextPack,
  pages: List(PackPageInput),
  dbs: List(PackDbInput),
  now: Time
) : CompiledPackResult
  budget = if pack.token_budget < 256: 256 else: pack.token_budget
  header = "# Context Pack: #{pack.name} (`#{pack.slug}`)\nBudget: #{budget} tokens · Fresh-only: #{if pack
    .fresh_only: "yes" else: "no"}"
  var sections = [truncate_to_token_budget(header, budget)]
  var used_tok = estimate_tokens(sections.first or "")
  var included = []
  var omitted = 0
  var skipped_stale = 0

  ordered_pages = pages.filter(fn(p) p.pinned end).concat(pages.filter(fn(p) not p.pinned end))

  for pinp in ordered_pages
    if pack.fresh_only and pinp.stale
      skipped_stale += 1
      continue
    end
    cur_used = estimate_tokens(sections.join("\n\n"))
    rem = budget - cur_used - 2
    if rem <= 16
      omitted += 1
      continue
    end

    full_body = to_yaml_frontmatter(
      pinp.page,
      pinp.blueprint,
      pinp.meta,
      Blocks.to_anchored_markdown(pinp.blocks)
    )
    full_sec = "## Page: #{pinp.page.title} (`#{pinp.page.id}`)\n#{full_body}"
    summary_blurb = case pinp.summary
      Some(sm): sm.semantic_summary or sm.structural_summary
      None: build_page_summary(pinp.page, pinp.blocks, pinp.blueprint, pinp.meta, None, now)
        .structural_summary
    end
    sum_sec = "## Page Summary: #{pinp.page.title} (`#{pinp.page.id}`)\n#{summary_blurb}"

    if pack.include_full_blocks and estimate_tokens(full_sec) <= rem
      sections = sections.append(full_sec)
      tok = estimate_tokens(full_sec)
      included = included.append(
        CompiledPackItem(
          entity_kind: "page",
          entity_id: pinp.page.id,
          collection_id: pinp.page.collection_id,
          title: pinp.page.title,
          inclusion_mode: "full",
          tokens_used: tok,
          pinned: pinp.pinned
        )
      )
    else if estimate_tokens(sum_sec) <= rem
      sections = sections.append(sum_sec)
      tok = estimate_tokens(sum_sec)
      included = included.append(
        CompiledPackItem(
          entity_kind: "page",
          entity_id: pinp.page.id,
          collection_id: pinp.page.collection_id,
          title: pinp.page.title,
          inclusion_mode: "summary",
          tokens_used: tok,
          pinned: pinp.pinned
        )
      )
    else if pinp.pinned and rem >= 40
      trunc = truncate_to_token_budget(full_sec, rem)
      sections = sections.append(trunc)
      tok = estimate_tokens(trunc)
      included = included.append(
        CompiledPackItem(
          entity_kind: "page",
          entity_id: pinp.page.id,
          collection_id: pinp.page.collection_id,
          title: pinp.page.title,
          inclusion_mode: "truncated",
          tokens_used: tok,
          pinned: true
        )
      )
    else
      omitted += 1
    end
  end

  for db_inp in dbs
    cur_used = estimate_tokens(sections.join("\n\n"))
    rem = budget - cur_used - 2
    if rem <= 16
      omitted += 1
      continue
    end
    db_sec = format_db_pack_section(db_inp)
    if estimate_tokens(db_sec) <= rem
      sections = sections.append(db_sec)
      tok = estimate_tokens(db_sec)
      included = included.append(
        CompiledPackItem(
          entity_kind: "database",
          entity_id: db_inp.def.id,
          collection_id: db_inp.def.collection_id,
          title: db_inp.def.title,
          inclusion_mode: "database",
          tokens_used: tok,
          pinned: false
        )
      )
    else
      sum_blurb = case db_inp.summary
        Some(s): s.semantic_summary or s.structural_summary
        None: build_database_summary(db_inp.def, db_inp.rows, None, now).structural_summary
      end
      db_sum_sec = "## Database Summary: #{db_inp.def.title} (`#{db_inp.def.id}`)\n#{sum_blurb}"
      if estimate_tokens(db_sum_sec) <= rem
        sections = sections.append(db_sum_sec)
        tok = estimate_tokens(db_sum_sec)
        included = included.append(
          CompiledPackItem(
            entity_kind: "database",
            entity_id: db_inp.def.id,
            collection_id: db_inp.def.collection_id,
            title: db_inp.def.title,
            inclusion_mode: "summary",
            tokens_used: tok,
            pinned: false
          )
        )
      else
        omitted += 1
      end
    end
  end

  joined = truncate_to_token_budget(sections.join("\n\n"), budget)
  used_tok = estimate_tokens(joined)
  util_pct = (used_tok * 100) / budget

  CompiledPackResult(
    pack: pack,
    markdown: joined,
    tokens_used: used_tok,
    token_budget: budget,
    budget_utilization_pct: util_pct,
    included_items: included,
    omitted_count: omitted,
    skipped_stale_count: skipped_stale,
    compiled_at: now
  )
end

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
