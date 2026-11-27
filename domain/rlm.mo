## RLM Tier 1 domain helpers: query keyword extraction, Living Summary ranking,
## block-kind tagging, heading-section & block-slice DSL, and bounded sub-call chunking.
module Domain.Rlm
expose RlmTraceStep(..),
RlmBlockSlice(..),
RlmDbSlice(..),
extract_query_keywords,
block_kind_tag,
normalize_block_kinds,
score_summary_row,
slice_block_rows,
chunk_block_slices,
format_slice_excerpt
use Domain.Types{BlockKind}
use Json

## One recorded inspection or synthesis step returned in the inspectable RLM trace.
struct RlmTraceStep
  step: Int
  op: Text
  target: Text
  detail: Text
  rows_scanned: Int
  ops_used: Int
  result_count: Int
  answer_hash: Option(Text)
end

## Extracted, scored, section-aware block slice returned by a `Modb.Views` `rlm_blocks` query.
struct RlmBlockSlice
  page_id: Text
  page_title: Text
  collection_id: Text
  block_id: Text
  rank: Text
  kind_tag: Text
  heading_level: Int
  heading_path: Option(Text)
  markdown: Text
  score: Int
end

## Compact relational database row slice returned by a `Modb.Views` `rlm_db_rows` query.
struct RlmDbSlice
  database_id: Text
  database_title: Text
  collection_id: Text
  row_id: Text
  page_id: Text
  title: Text
  cells_summary: Text
end

## Canonical lowercase string tag identifying each `BlockKind` variant inside `Modb.Views` filters.
fn block_kind_tag(k: BlockKind) : Text
  case k
    Paragraph: "paragraph"
    Heading(level: _): "heading"
    BulletListItem: "bullet_list_item"
    OrderedListItem(start: _): "ordered_list_item"
    TaskItem(checked: _): "task_item"
    Quote: "quote"
    Callout(tone: _, icon: _): "callout"
    CodeBlock(language: _): "code_block"
    Divider: "divider"
    TableBlock(has_header: _): "table"
    Toggle(summary: _, open: _): "toggle"
    TableOfContents: "table_of_contents"
    Image(attachment_id: _, caption: _): "image"
    FileEmbed(attachment_id: _, filename: _): "file_embed"
    PageLink(target_page_id: _): "page_link"
    DatabaseViewEmbed(database_id: _, view_id: _): "database_view_embed"
    AiBrief(prompt: _, source_scope: _, refreshed_at: _): "ai_brief"
  end
end

## Normalizes, deduplicates, and trims requested `block_kinds` filter tags.
fn normalize_block_kinds(raw_opt: Option(List(Text))) : List(Text)
  case raw_opt
    None: []
    Some(xs):
      var seen = Set.empty
      var out = []
      for raw in xs
        clean = raw.trim.ascii_lowercase
        if not clean.empty? and not seen.has?(clean)
          seen = seen.add(clean)
          out = out.append(clean)
        end
      end
      out
  end
end

fn is_keyword_char?(c: Char) : Bool
  (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-'
end

fn is_stop_word?(w: Text) : Bool
  w == "the" or w == "and" or w == "for" or w == "with" or w == "from" or w == "that" or
    w == "this" or w == "what" or w == "how" or w == "why" or w == "are" or w == "was" or
    w == "were" or w == "can" or w == "does" or w == "into" or w == "about" or w == "across" or
    w == "all" or w == "our" or w == "when" or w == "where" or w == "which"
end

## Extracts lowercase deduplicated keywords (up to 12) from a user research question.
fn extract_query_keywords(q: Text) : List(Text)
  low = q.trim.ascii_lowercase
  var tokens = []
  var cur = []
  for c in low.chars
    if is_keyword_char?(c)
      cur = cur.append(c)
    else if not cur.empty?
      tokens = tokens.append(Text.from_chars(cur))
      cur = []
    end
  end
  if not cur.empty?
    tokens = tokens.append(Text.from_chars(cur))
  end

  var seen = Set.empty
  var out = []
  for tok in tokens
    clean = tok.trim
    if clean.byte_count >= 3 and not is_stop_word?(clean) and not seen.has?(clean)
      seen = seen.add(clean)
      out = out.append(clean)
      if out.size >= 12
        return out
      end
    end
  end
  if out.empty?
    for tok in tokens
      clean = tok.trim
      if clean.byte_count >= 2 and not seen.has?(clean)
        seen = seen.add(clean)
        out = out.append(clean)
        if out.size >= 12
          return out
        end
      end
    end
  end
  out
end

## Scores a `rlm_summaries` row against extracted query keywords (`title` > `headings` > summaries).
fn score_summary_row(row: Json, keywords: List(Text)) : Int
  return 1 if keywords.empty?
  title = (row.text_at("title") or "").ascii_lowercase
  headings = (row.text_at("headings_text") or "").ascii_lowercase
  struct_s = (row.text_at("structural_summary") or "").ascii_lowercase
  sem_s = (row.text_at("semantic_summary") or "").ascii_lowercase
  var score = 0
  for kw in keywords
    if title.contains?(kw)
      score += 6
    end
    if headings.contains?(kw)
      score += 4
    end
    if sem_s.contains?(kw)
      score += 3
    end
    if struct_s.contains?(kw)
      score += 2
    end
  end
  score
end

fn sort_raw_blocks_by_rank(items: List((Int, Json))) : List((Int, Json))
  items.sort_by(fn(p)
    r = p.1.text_at("rank") or ""
    r
  end)
end

fn format_heading_path(h1: Option(Text), h2: Option(Text), h3: Option(Text)) : Option(Text)
  var parts = []
  case h1
    Some(s) if not s.empty?: parts = parts.append(s)
    Some(_) | None: Unit
  end
  case h2
    Some(s) if not s.empty?: parts = parts.append(s)
    Some(_) | None: Unit
  end
  case h3
    Some(s) if not s.empty?: parts = parts.append(s)
    Some(_) | None: Unit
  end
  if parts.empty?: None else: Some(parts.join(" / "))
end

fn slice_single_page_blocks(
  page_rows: List(Json),
  keywords: List(Text),
  heading_filter_opt: Option(Text),
  allowed_kinds: List(Text),
  max_per_page: Int
) : List(RlmBlockSlice)
  var indexed = []
  for (i, r) in page_rows.enumerate
    indexed = indexed.append((i, r))
  end
  ordered = sort_raw_blocks_by_rank(indexed)

  var h1 = None
  var h2 = None
  var h3 = None
  var in_match = heading_filter_opt is None
  var match_level = 99
  var candidates = []

  for (seq_idx, (_orig_i, row)) in ordered.enumerate
    kind_tag = (row.text_at("kind_tag") or "paragraph").trim.ascii_lowercase
    h_lvl = row.int_at("heading_level") or 0
    md = row.text_at("markdown") or ""
    low_md = md.ascii_lowercase

    if kind_tag == "heading" and h_lvl >= 1
      clean_h = md.trim
      if h_lvl == 1
        h1 = Some(clean_h)
        h2 = None
        h3 = None
      else if h_lvl == 2
        h2 = Some(clean_h)
        h3 = None
      else
        h3 = Some(clean_h)
      end

      case heading_filter_opt
        Some(hf):
          if low_md.contains?(hf)
            in_match = true
            match_level = h_lvl
          else if in_match and h_lvl <= match_level
            in_match = false
            match_level = 99
          end
        None: Unit
      end
    end

    kind_ok = allowed_kinds.empty? or allowed_kinds.contains?(kind_tag)
    if in_match and kind_ok
      h_path = format_heading_path(h1, h2, h3)
      low_hp = (h_path or "").ascii_lowercase
      var score = 1
      if heading_filter_opt is Some(_)
        score += 2
      end
      for kw in keywords
        if low_md.contains?(kw)
          score += 4
        end
        if low_hp.contains?(kw)
          score += 2
        end
      end
      slice = RlmBlockSlice(
        page_id: row.text_at("page_id") or "",
        page_title: row.text_at("page_title") or "",
        collection_id: row.text_at("collection_id") or "",
        block_id: row.text_at("block_id") or "",
        rank: row.text_at("rank") or "",
        kind_tag: kind_tag,
        heading_level: h_lvl,
        heading_path: h_path,
        markdown: md,
        score: score
      )
      candidates = candidates.append((seq_idx, slice))
    end
  end

  eff_cap = if max_per_page < 1: 1 else: max_per_page
  # Select top scoring candidates while preserving earliest appearance on ties, then restore rank order.
  by_score = candidates.sort_by(fn(p)
    -(p.1.score * 10000 - p.0)
  end)
  kept = by_score.take(eff_cap).sort_by(fn(p) p.0 end)
  kept.map(fn(p) p.1 end)
end

## Slices `rlm_blocks` JSON rows deterministically by active heading section, `block_kinds`, and `max_per_page`.
fn slice_block_rows(
  rows: List(Json),
  keywords: List(Text),
  heading_contains: Option(Text),
  allowed_kinds: List(Text),
  max_per_page: Int
) : List(RlmBlockSlice)
  heading_filter_opt = case heading_contains
    Some(h) if not h.trim.empty?: Some(h.trim.ascii_lowercase)
    Some(_) | None: None
  end
  var page_order = []
  var by_page = {}
  for r in rows
    pid = r.text_at("page_id") or ""
    if not pid.empty?
      case by_page.get(pid)
        Some(prev): by_page = by_page.set(pid, prev.append(r))
        None:
          page_order = page_order.append(pid)
          by_page = by_page.set(pid, [r])
      end
    end
  end

  var page_groups = []
  for (p_idx, pid) in page_order.enumerate
    prows = by_page.get(pid) or []
    sliced = slice_single_page_blocks(
      prows,
      keywords,
      heading_filter_opt,
      allowed_kinds,
      max_per_page
    )
    if not sliced.empty?
      var total_sc = 0
      for s in sliced
        total_sc += s.score
      end
      page_groups = page_groups.append((p_idx, total_sc, sliced))
    end
  end

  ranked_pages = page_groups.sort_by(fn(g) -(g.1 * 1000 - g.0) end)
  var out = []
  for g in ranked_pages
    for s in g.2
      out = out.append(s)
    end
  end
  out
end

## Partitions `slices` evenly into at most `max_chunks` non-empty chunks for bounded sub-LLM calls.
fn chunk_block_slices(slices: List(RlmBlockSlice), max_chunks: Int) : List(List(RlmBlockSlice))
  return [] if slices.empty? or max_chunks <= 0
  n = slices.size
  chunks_target = if n < max_chunks: n else: max_chunks
  base_size = n.floor_div(chunks_target)
  rem = n - base_size * chunks_target
  var out = []
  var idx = 0
  var c = 0
  while c < chunks_target and idx < n
    take_n = base_size + (if c < rem: 1 else: 0)
    chunk = slices.drop(idx).take(take_n)
    if not chunk.empty?
      out = out.append(chunk)
    end
    idx += take_n
    c += 1
  end
  out
end

## Compact single-line citation excerpt capped safely under 260 UTF-8 bytes.
fn format_slice_excerpt(s: RlmBlockSlice) : Text
  raw = s.markdown.trim
  if raw.byte_count <= 240
    raw
  else
    pref = raw.bytes.slice(0, 240).decode_utf8 or raw
    "#{pref}..."
  end
end
