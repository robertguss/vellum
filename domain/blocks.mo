## Canonical Block Tree, lexicographic rank ordering, lossless anchored Markdown projection,
## and surgical `BlockOp` mutation engine for Vellum pages.
module Domain.Blocks
expose MetricRef(..),
rank_between,
sort_blocks,
to_anchored_markdown,
parse_markdown_blocks,
blocks_plain_text,
extract_metric_refs,
blocks_metric_refs,
apply_block_ops,
reconcile_blocks_from_markdown,
diff_blocks_to_ops
use Domain.Types{AuthorKind, Block, BlockKind, BlockOp, Citation, Provenance}

alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"

fn char_rank_idx(ch: Char) : Int
  for (i, c) in alphabet.chars.enumerate
    return i if c == ch
  end
  18
end

fn rank_char_at(idx: Int) : Char
  clamped = if idx < 0
    0
  else if idx > 35
    35
  else
    idx
  end
  alphabet.chars.get(clamped) or 'i'
end

fn valid_rank?(s: Text) : Bool
  not s.empty? and s.chars.all?(fn(c) c.ascii_digit? or (c.code >= 97 and c.code <= 122) end)
end

## Computes a base-36 lexicographic rank key strictly between `prev` and `next` (when `prev < next`).
fn rank_between(prev: Option(Text), next: Option(Text)) : Text
  examples
    rank_between(None, None) == "i"
    rank_between(None, Some("i")) == "9"
    rank_between(Some("i"), None) == "r"
    rank_between(Some("a"), Some("b")) == "ai"
    rank_between(Some("a"), Some("ai")) == "a9"
  end

  promise "rank_between yields a non-empty key strictly ordered between valid base-36 bounds"
    not result.empty? and
      case prev
        Some(p):
          case next
            Some(n): (valid_rank?(p) and valid_rank?(n) and p < n) implies (
              p < result and result < n
            )
            None: valid_rank?(p) implies (p < result)
          end
        None:
          case next
            Some(n): (valid_rank?(n) and n.chars.any?(fn(c) c != '0' end)) implies (result < n)
            None: true
          end
      end
  end

  p_str = prev or ""
  p_chars = p_str.chars
  n_chars = case next
    Some(n): n.chars
    None: []
  end
  has_next = next != None

  case (prev, next)
    (Some(p), Some(n)):
      if p >= n
        return "#{p}i"
      end
    (Some(_), None) | (None, Some(_)) | (None, None): Unit
  end

  var out = []
  var below_hi = false
  var step = 0
  while step < 64
    lo = if step < p_chars.size
      char_rank_idx(p_chars.get(step) or '0')
    else
      0
    end
    hi = if below_hi or not has_next or step >= n_chars.size
      36
    else
      char_rank_idx(n_chars.get(step) or 'z')
    end

    if hi - lo > 1
      mid = (lo + hi).floor_div(2)
      out = out.append(rank_char_at(mid))
      return Text.from_chars(out)
    else
      out = out.append(rank_char_at(lo))
      if hi > lo
        below_hi = true
      end
    end
    step += 1
  end
  Text.from_chars(out)
end

fn block_before_or_eq?(a: Block, b: Block) : Bool
  a.rank < b.rank or (a.rank == b.rank and a.id <= b.id)
end

fn blocks_sorted?(blocks: List(Block)) : Bool
  return true if blocks.size <= 1
  var prev = case blocks.first
    Some(b): b
    None: return true
  end
  var i = 1
  while i < blocks.size
    cur = case blocks.get(i)
      Some(b): b
      None: return true
    end
    return false if not block_before_or_eq?(prev, cur)
    prev = cur
    i += 1
  end
  true
end

fn insert_block_sorted(blocks: List(Block), blk: Block) : List(Block)
  var ins = 0
  while ins < blocks.size
    cur = case blocks.get(ins)
      Some(b): b
      None: break
    end
    break if not block_before_or_eq?(cur, blk)
    ins += 1
  end
  blocks.take(ins).append(blk).concat(blocks.drop(ins))
end

## Orders blocks stably by lexicographic `rank` ascending, breaking ties by `id`.
fn sort_blocks(blocks: List(Block)) : List(Block)
  return blocks if blocks_sorted?(blocks)
  blocks.sort_by(fn(b) b.id end).sort_by(fn(b) b.rank end)
end

fn render_block_body(blk: Block) : Text
  case blk.kind
    Paragraph: blk.markdown
    Heading(level: lvl):
      clamped = if lvl < 1
        1
      else if lvl > 6
        6
      else
        lvl
      end
      "#{"#".repeat(clamped)} #{blk.markdown}"
    BulletListItem: "- #{blk.markdown}"
    OrderedListItem(start: s): "#{s}. #{blk.markdown}"
    TaskItem(checked: c):
      mark = if c: "x" else: " "
      "- [#{mark}] #{blk.markdown}"
    Quote:
      lines = blk.markdown.lines
      if lines.empty?
        "> "
      else
        lines.map(fn(l) "> #{l}" end).join("\n")
      end
    Callout(tone: t, icon: ic):
      head = case ic
        Some(icon_name): "> [!#{t}|#{icon_name}]"
        None: "> [!#{t}]"
      end
      lines = blk.markdown.lines
      if lines.empty?
        head
      else
        body = lines.map(fn(l) "> #{l}" end).join("\n")
        "#{head}\n#{body}"
      end
    CodeBlock(language: lang): "```#{lang}\n#{blk.markdown}\n```"
    Divider: "---"
    TableBlock(has_header: _): blk.markdown
    Toggle(summary: sum_txt, open: open?):
      clean_s = sum_txt.replace("\n", " ").trim
      head = if open?: ":::toggle [open] #{clean_s}" else: ":::toggle #{clean_s}"
      if blk.markdown.empty?
        "#{head}\n:::"
      else
        "#{head}\n#{blk.markdown}\n:::"
      end
    TableOfContents: "<!-- toc -->"
    Image(attachment_id: aid, caption: cap): "![#{cap}](vellum://attachment/#{aid})"
    FileEmbed(attachment_id: aid, filename: fname): "[#{fname}](vellum://attachment/#{aid})"
    PageLink(target_page_id: tid): "[[#{tid}|#{blk.markdown}]]"
    DatabaseViewEmbed(database_id: did, view_id: vid):
      case vid
        Some(v) if not v.trim.empty?: "<!-- db_embed:#{did}|#{v.trim} -->"
        Some(_) | None: "<!-- db_embed:#{did} -->"
      end
    AiBrief(prompt: p, source_scope: scope_opt, refreshed_at: ref_opt):
      clean_p = p.replace("\n", " ").trim
      var tags = []
      case scope_opt
        Some(sc) if not sc.trim.empty?: tags = tags.append("scope=#{sc.trim}")
        Some(_) | None: Unit
      end
      case ref_opt
        Some(rf) if not rf.trim.empty?: tags = tags.append("refreshed=#{rf.trim}")
        Some(_) | None: Unit
      end
      head = if tags.empty?
        ":::ai-brief #{clean_p}"
      else
        ":::ai-brief [#{tags.join(" ")}] #{clean_p}"
      end
      if blk.markdown.empty?
        "#{head}\n:::"
      else
        "#{head}\n#{blk.markdown}\n:::"
      end
  end
end

## Projects ordered blocks into clean Markdown annotated with `<!-- blk:<id> -->` HTML anchors.
fn to_anchored_markdown(blocks: List(Block)) : Text
  sorted = sort_blocks(blocks)
  sorted.map(fn(b) "<!-- blk:#{b.id} -->\n#{render_block_body(b)}" end).join("\n\n")
end

fn zero_pad4(n: Int) : Text
  s = n.to_text
  if s.byte_count >= 4: s else: "#{"0".repeat(4 - s.byte_count)}#{s}"
end

fn parse_anchor_comment(line: Text) : Option(Text)
  t = line.trim
  rest = try t.drop_prefix("<!-- blk:")
  id_part = try rest.drop_suffix("-->")
  clean = id_part.trim
  if clean.empty?: None else: Some(clean)
end

fn parse_ordered_prefix(line: Text) : Option((Int, Text))
  dot_parts = line.split(". ")
  return None if dot_parts.size < 2
  num_str = dot_parts.first or ""
  return None if num_str.empty? or not num_str.chars.all?(fn(c) c.ascii_digit? end)
  num = try num_str.to_int
  body = dot_parts.drop(1).join(". ")
  Some((num, body))
end

fn parse_attachment_link(line: Text, is_image?: Bool) : Option((Text, Text))
  prefix = if is_image?: "![" else: "["
  after_open = try line.drop_prefix(prefix)
  mid_parts = after_open.split("](vellum://attachment/")
  return None if mid_parts.size != 2
  label = mid_parts.first or ""
  tail = mid_parts.get(1) or ""
  aid = try tail.drop_suffix(")")
  return None if aid.empty?
  Some((aid, label))
end

fn parse_page_link(line: Text) : Option((Text, Text))
  after_open = try line.drop_prefix("[[")
  inner = try after_open.drop_suffix("]]")
  parts = inner.split("|")
  return None if parts.size < 2
  tid = (parts.first or "").trim
  label = parts.drop(1).join("|")
  return None if tid.empty?
  Some((tid, label))
end

fn parse_callout_header(line: Text) : Option((Text, Option(Text)))
  after_open = try line.drop_prefix("> [!")
  inner = try after_open.drop_suffix("]")
  parts = inner.split("|")
  tone = (parts.first or "").trim
  return None if tone.empty?
  icon = if parts.size > 1
    raw_ic = parts.drop(1).join("|").trim
    if raw_ic.empty?: None else: Some(raw_ic)
  else
    None
  end
  Some((tone, icon))
end

fn parse_db_embed(line: Text) : Option((Text, Option(Text)))
  t = line.trim
  rest = try t.drop_prefix("<!-- db_embed:")
  inner = (try rest.drop_suffix("-->")).trim
  return None if inner.empty?
  parts = inner.split("|")
  db_id = (parts.first or "").trim
  return None if db_id.empty?
  vid = if parts.size > 1
    raw_v = parts.drop(1).join("|").trim
    if raw_v.empty?: None else: Some(raw_v)
  else
    None
  end
  Some((db_id, vid))
end

## Inline live metric token parsed from `{{metric:<database_id>.<property_id>:<agg>}}`.
struct MetricRef
  raw_token: Text
  database_id: Text
  property_id: Text
  agg: Text
end

## Scans `markdown` for valid `{{metric:<database_id>.<property_id>:<agg>}}` tokens in source order.
fn extract_metric_refs(markdown: Text) : List(MetricRef)
  parts = markdown.split("{{metric:")
  return [] if parts.size <= 1
  var out = []
  var seen = {}
  for seg in parts.drop(1)
    close_parts = seg.split("}}")
    if close_parts.size < 2
      continue
    end
    inner = close_parts.first or ""
    if inner.contains?("\n") or inner.contains?("\r")
      continue
    end
    colon_parts = inner.split(":")
    if colon_parts.size != 2
      continue
    end
    target = (colon_parts.first or "").trim
    agg = (colon_parts.get(1) or "").trim
    dot_parts = target.split(".")
    if dot_parts.size != 2
      continue
    end
    db_id = (dot_parts.first or "").trim
    prop_id = (dot_parts.get(1) or "").trim
    if db_id.empty? or prop_id.empty? or agg.empty?
      continue
    end
    if db_id.contains?(" ") or prop_id.contains?(" ") or agg.contains?(" ")
      continue
    end
    raw = "{{metric:#{inner}}}"
    if seen.get(raw) == None
      seen = seen.set(raw, true)
      out = out.append(MetricRef(raw_token: raw, database_id: db_id, property_id: prop_id, agg: agg))
    end
  end
  out
end

## Collects unique `MetricRef` tokens across an ordered list of canonical `Block`s.
fn blocks_metric_refs(blocks: List(Block)) : List(MetricRef)
  var out = []
  var seen = {}
  for b in sort_blocks(blocks)
    for m in extract_metric_refs(b.markdown)
      if seen.get(m.raw_token) == None
        seen = seen.set(m.raw_token, true)
        out = out.append(m)
      end
    end
  end
  out
end

fn parse_single_line_block(line: Text) : Option((BlockKind, Text))
  if line == "---"
    return Some((Divider, ""))
  end
  if line.trim == "<!-- toc -->"
    return Some((TableOfContents, ""))
  end
  if line.starts_with?("###### ")
    return Some((Heading(level: 6), line.drop_prefix("###### ") or ""))
  end
  if line.starts_with?("##### ")
    return Some((Heading(level: 5), line.drop_prefix("##### ") or ""))
  end
  if line.starts_with?("#### ")
    return Some((Heading(level: 4), line.drop_prefix("#### ") or ""))
  end
  if line.starts_with?("### ")
    return Some((Heading(level: 3), line.drop_prefix("### ") or ""))
  end
  if line.starts_with?("## ")
    return Some((Heading(level: 2), line.drop_prefix("## ") or ""))
  end
  if line.starts_with?("# ")
    return Some((Heading(level: 1), line.drop_prefix("# ") or ""))
  end
  if line.starts_with?("- [x] ") or line.starts_with?("- [X] ")
    body = line.drop_prefix("- [x] ") or (line.drop_prefix("- [X] ") or "")
    return Some((TaskItem(checked: true), body))
  end
  if line.starts_with?("- [ ] ")
    return Some((TaskItem(checked: false), line.drop_prefix("- [ ] ") or ""))
  end
  if line.starts_with?("- ")
    return Some((BulletListItem, line.drop_prefix("- ") or ""))
  end
  case parse_ordered_prefix(line)
    Some((start_n, body)): return Some((OrderedListItem(start: start_n), body))
    None: Unit
  end
  case parse_attachment_link(line, true)
    Some((aid, cap)): return Some((Image(attachment_id: aid, caption: cap), ""))
    None: Unit
  end
  case parse_attachment_link(line, false)
    Some((aid, fname)): return Some((FileEmbed(attachment_id: aid, filename: fname), ""))
    None: Unit
  end
  case parse_page_link(line)
    Some((tid, label)): return Some((PageLink(target_page_id: tid), label))
    None: Unit
  end
  case parse_db_embed(line)
    Some((did, vid)): return Some((DatabaseViewEmbed(database_id: did, view_id: vid), ""))
    None: Unit
  end
  None
end

fn is_gfm_table_separator?(line: Text) : Bool
  t = line.trim
  return false if t.empty? or not t.contains?("|") or not t.contains?("-")
  t.chars.all?(fn(c) c == '|' or c == '-' or c == ':' or c == ' ' or c == '\t' end)
end

fn parse_toggle_header(line: Text) : Option((Text, Bool))
  rest_opt = line.drop_prefix(":::toggle")
  rest = (try rest_opt).trim
  return None if rest.empty?
  if rest.starts_with?("[open]")
    sum = (rest.drop_prefix("[open]") or "").trim
    return None if sum.empty?
    return Some((sum, true))
  end
  Some((rest, false))
end

fn parse_details_summary_text(line: Text) : Option(Text)
  open_parts = line.split("<summary>")
  return None if open_parts.size < 2
  rest = open_parts.drop(1).join("<summary>")
  close_parts = rest.split("</summary>")
  return None if close_parts.size < 2
  clean = (close_parts.first or "").trim
  if clean.empty?: Some("Toggle") else: Some(clean)
end

fn strip_quote_prefix(line: Text) : Text
  if line.starts_with?("> ")
    line.drop_prefix("> ") or ""
  else if line == ">"
    ""
  else
    line
  end
end

fn parse_ai_brief_header(line: Text) : Option((Text, Option(Text), Option(Text)))
  rest_opt = line.drop_prefix(":::ai-brief")
  rest = (try rest_opt).trim
  return None if rest.empty?
  if rest.starts_with?("[")
    close_parts = (rest.drop_prefix("[") or "").split("]")
    if close_parts.size >= 2
      tag_str = close_parts.first or ""
      prompt = close_parts.drop(1).join("]").trim
      return None if prompt.empty?
      var scope_opt = None
      var refreshed_opt = None
      for tok in tag_str.split(" ")
        t = tok.trim
        if t.starts_with?("scope=")
          sv = (t.drop_prefix("scope=") or "").trim
          if not sv.empty?
            scope_opt = Some(sv)
          end
        else if t.starts_with?("refreshed=")
          rv = (t.drop_prefix("refreshed=") or "").trim
          if not rv.empty?
            refreshed_opt = Some(rv)
          end
        end
      end
      return Some((prompt, scope_opt, refreshed_opt))
    end
  end
  Some((rest, None, None))
end

## Parses Markdown (with optional `<!-- blk:<id> -->` anchors) into ordered canonical `Block`s.
fn parse_markdown_blocks(page_id: Text, markdown: Text, prov: Provenance, id_prefix: Text) : List(
  Block
)
  lines = markdown.lines
  n = lines.size
  var blocks = []
  var i = 0
  var pending_id = None
  var synth_idx = 0

  while i < n
    line = lines.get(i) or ""
    trimmed = line.trim

    if trimmed.empty?
      pending_id = None
      i += 1
      continue
    end

    case parse_anchor_comment(trimmed)
      Some(blk_id):
        pending_id = Some(blk_id)
        i += 1
        continue
      None: Unit
    end

    synth_idx += 1
    blk_id = pending_id or "#{id_prefix}_#{zero_pad4(synth_idx)}"
    pending_id = None
    rank = "i#{zero_pad4(synth_idx)}"

    if trimmed.starts_with?(":::ai-brief")
      case parse_ai_brief_header(trimmed)
        Some((prompt, scope_opt, ref_opt)):
          var brief_lines = []
          i += 1
          while i < n
            bl = lines.get(i) or ""
            if bl.trim == ":::"
              i += 1
              break
            end
            brief_lines = brief_lines.append(bl)
            i += 1
          end
          blocks = blocks.append(
            Block(
              id: blk_id,
              page_id: page_id,
              parent_block_id: None,
              rank: rank,
              kind: AiBrief(prompt: prompt, source_scope: scope_opt, refreshed_at: ref_opt),
              markdown: brief_lines.join("\n"),
              provenance: prov,
              version: 1
            )
          )
          continue
        None: Unit
      end
    end

    if trimmed.starts_with?(":::toggle")
      case parse_toggle_header(trimmed)
        Some((summary, open?)):
          var t_lines = []
          i += 1
          while i < n
            tl = lines.get(i) or ""
            if tl.trim == ":::"
              i += 1
              break
            end
            t_lines = t_lines.append(tl)
            i += 1
          end
          blocks = blocks.append(
            Block(
              id: blk_id,
              page_id: page_id,
              parent_block_id: None,
              rank: rank,
              kind: Toggle(summary: summary, open: open?),
              markdown: t_lines.join("\n"),
              provenance: prov,
              version: 1
            )
          )
          continue
        None: Unit
      end
    end

    if trimmed.starts_with?("<details")
      open? = trimmed.contains?("open")
      var summary = parse_details_summary_text(trimmed) or ""
      var t_lines = []
      i += 1
      while i < n
        dl = lines.get(i) or ""
        dt = dl.trim
        if dt == "</details>" or dt.starts_with?("</details>")
          i += 1
          break
        end
        if summary.empty?
          case parse_details_summary_text(dt)
            Some(s):
              summary = s
              i += 1
              continue
            None: Unit
          end
        end
        t_lines = t_lines.append(dl)
        i += 1
      end
      final_sum = if summary.trim.empty?: "Toggle" else: summary.trim
      blocks = blocks.append(
        Block(
          id: blk_id,
          page_id: page_id,
          parent_block_id: None,
          rank: rank,
          kind: Toggle(summary: final_sum, open: open?),
          markdown: t_lines.join("\n").trim,
          provenance: prov,
          version: 1
        )
      )
      continue
    end

    if trimmed.starts_with?("|") and trimmed.contains?("|") and
      is_gfm_table_separator?(lines.get(i + 1) or "")
      var tbl_lines = [line]
      i += 1
      while i < n
        tl = lines.get(i) or ""
        break if not tl.trim.starts_with?("|")
        tbl_lines = tbl_lines.append(tl)
        i += 1
      end
      blocks = blocks.append(
        Block(
          id: blk_id,
          page_id: page_id,
          parent_block_id: None,
          rank: rank,
          kind: TableBlock(has_header: true),
          markdown: tbl_lines.join("\n"),
          provenance: prov,
          version: 1
        )
      )
      continue
    end

    if line.starts_with?("```")
      lang = (line.drop_prefix("```") or "").trim
      var code_lines = []
      i += 1
      while i < n
        cl = lines.get(i) or ""
        if cl.trim == "```"
          i += 1
          break
        end
        code_lines = code_lines.append(cl)
        i += 1
      end
      blocks = blocks.append(
        Block(
          id: blk_id,
          page_id: page_id,
          parent_block_id: None,
          rank: rank,
          kind: CodeBlock(language: lang),
          markdown: code_lines.join("\n"),
          provenance: prov,
          version: 1
        )
      )
      continue
    end

    case parse_callout_header(trimmed)
      Some((tone, icon)):
        var c_lines = []
        i += 1
        while i < n
          ql = lines.get(i) or ""
          break if not ql.starts_with?(">")
          c_lines = c_lines.append(strip_quote_prefix(ql))
          i += 1
        end
        blocks = blocks.append(
          Block(
            id: blk_id,
            page_id: page_id,
            parent_block_id: None,
            rank: rank,
            kind: Callout(tone: tone, icon: icon),
            markdown: c_lines.join("\n"),
            provenance: prov,
            version: 1
          )
        )
        continue
      None: Unit
    end

    if line.starts_with?(">")
      var q_lines = [strip_quote_prefix(line)]
      i += 1
      while i < n
        ql = lines.get(i) or ""
        break if not ql.starts_with?(">")
        q_lines = q_lines.append(strip_quote_prefix(ql))
        i += 1
      end
      blocks = blocks.append(
        Block(
          id: blk_id,
          page_id: page_id,
          parent_block_id: None,
          rank: rank,
          kind: Quote,
          markdown: q_lines.join("\n"),
          provenance: prov,
          version: 1
        )
      )
      continue
    end

    case parse_single_line_block(line)
      Some((kind, body)):
        blocks = blocks.append(
          Block(
            id: blk_id,
            page_id: page_id,
            parent_block_id: None,
            rank: rank,
            kind: kind,
            markdown: body,
            provenance: prov,
            version: 1
          )
        )
        i += 1
        continue
      None: Unit
    end

    var p_lines = [line]
    i += 1
    while i < n
      nl = lines.get(i) or ""
      nt = nl.trim
      break if nt.empty?
      break if parse_anchor_comment(nt) != None
      break if nl.starts_with?("```") or nl.starts_with?(">")
      break if nt.starts_with?(":::ai-brief") or nt.starts_with?(":::toggle") or nt.starts_with?(
        "<details"
      )
      break if nt.starts_with?("|") and nt.contains?("|") and
        is_gfm_table_separator?(lines.get(i + 1) or "")
      break if parse_single_line_block(nl) != None
      p_lines = p_lines.append(nl)
      i += 1
    end
    blocks = blocks.append(
      Block(
        id: blk_id,
        page_id: page_id,
        parent_block_id: None,
        rank: rank,
        kind: Paragraph,
        markdown: p_lines.join("\n"),
        provenance: prov,
        version: 1
      )
    )
  end

  blocks
end

## Extracts searchable plain text from `blocks` for `Modb.Fts` indexing.
fn blocks_plain_text(blocks: List(Block)) : Text
  sorted = sort_blocks(blocks)
  var parts = []
  for b in sorted
    piece = case b.kind
      Paragraph | Heading(level: _) | BulletListItem | OrderedListItem(start: _) | TaskItem(
        checked: _
      ) | Quote | Callout(tone: _, icon: _) | CodeBlock(language: _) | PageLink(target_page_id: _) | DatabaseViewEmbed(
        database_id: _,
        view_id: _
      ) | AiBrief(prompt: _, source_scope: _, refreshed_at: _): b.markdown
      Divider | TableOfContents: ""
      TableBlock(has_header: _):
        b.markdown.lines.filter(fn(l) not is_gfm_table_separator?(l) end)
          .map(fn(l) l.replace("|", " ").trim end)
          .filter(fn(l) not l.empty? end)
          .join(" ")
      Toggle(summary: sum_txt, open: _):
        if b.markdown.trim.empty?: sum_txt else: "#{sum_txt}\n#{b.markdown}"
      Image(attachment_id: _, caption: cap): cap
      FileEmbed(attachment_id: _, filename: fname): fname
    end
    if not piece.trim.empty?
      parts = parts.append(piece)
    end
  end
  parts.join("\n")
end

fn find_block_idx(sorted: List(Block), target_id: Text) : Option(Int)
  for (i, b) in sorted.enumerate
    return Some(i) if b.id == target_id
  end
  None
end

fn compute_insert_rank(sorted: List(Block), after_block_id: Option(Text)) : Result(Text, Text)
  case after_block_id
    None:
      first_rank = sorted.first.map(fn(b) b.rank end)
      Ok(rank_between(None, first_rank))
    Some(aid):
      idx = try find_block_idx(sorted, aid).or_fail("after_block_id '#{aid}' not found")
      prev_b = sorted.get(idx) or stop "block idx"
      next_rank = sorted.get(idx + 1).map(fn(b) b.rank end)
      Ok(rank_between(Some(prev_b.rank), next_rank))
  end
end

## Applies surgical `BlockOp` mutations to `existing`, enforcing per-block `expected_version`
## optimistic concurrency checks and assigning `new_ids` to inserted blocks.
fn apply_block_ops(
  existing: List(Block),
  ops: List(BlockOp),
  page_id: Text,
  prov: Provenance,
  new_ids: List(Text)
) : Result(List(Block), Text)
  var cur = sort_blocks(existing)
  var id_cursor = 0

  for op in ops
    case op
      ReplaceBlock(block_id: bid, expected_version: exp_v, kind: k_opt, markdown: md):
        idx = try find_block_idx(cur, bid).or_fail("block '#{bid}' not found")
        old_b = cur.get(idx) or stop "block idx"
        if old_b.version != exp_v
          return Error("block '#{bid}' version mismatch: expected #{exp_v}, found #{old_b.version}")
        end
        next_kind = k_opt or old_b.kind
        updated = Block(
          id: old_b.id,
          page_id: page_id,
          parent_block_id: old_b.parent_block_id,
          rank: old_b.rank,
          kind: next_kind,
          markdown: md,
          provenance: prov,
          version: old_b.version + 1
        )
        cur = cur.set(idx, updated) or cur
      InsertBlockAfter(
        after_block_id: after_opt,
        parent_block_id: parent_opt,
        kind: kind,
        markdown: md
      ):
        new_id = case new_ids.get(id_cursor)
          Some(nid): nid
          None: return Error("insufficient generated block IDs for InsertBlockAfter")
        end
        id_cursor += 1
        new_rank = try compute_insert_rank(cur, after_opt)
        inserted = Block(
          id: new_id,
          page_id: page_id,
          parent_block_id: parent_opt,
          rank: new_rank,
          kind: kind,
          markdown: md,
          provenance: prov,
          version: 1
        )
        cur = insert_block_sorted(cur, inserted)
      DeleteBlock(block_id: bid, expected_version: exp_v):
        idx = try find_block_idx(cur, bid).or_fail("block '#{bid}' not found")
        old_b = cur.get(idx) or stop "block idx"
        if old_b.version != exp_v
          return Error("block '#{bid}' version mismatch: expected #{exp_v}, found #{old_b.version}")
        end
        cur = cur.remove_at(idx) or cur
      MoveBlock(block_id: bid, new_parent_id: new_parent, after_block_id: after_opt):
        idx = try find_block_idx(cur, bid).or_fail("block '#{bid}' not found")
        old_b = cur.get(idx) or stop "block idx"
        without = cur.remove_at(idx) or cur
        new_rank = try compute_insert_rank(without, after_opt)
        moved = Block(
          id: old_b.id,
          page_id: page_id,
          parent_block_id: new_parent,
          rank: new_rank,
          kind: old_b.kind,
          markdown: old_b.markdown,
          provenance: prov,
          version: old_b.version + 1
        )
        cur = insert_block_sorted(without, moved)
      AttachCitations(block_id: bid, citations: cites):
        idx = try find_block_idx(cur, bid).or_fail("block '#{bid}' not found")
        old_b = cur.get(idx) or stop "block idx"
        var next_cites = old_b.provenance.citations
        for c in cites
          if not next_cites.contains?(c)
            next_cites = next_cites.append(c)
          end
        end
        merged_reason = case prov.reason
          Some(r): Some(r)
          None: old_b.provenance.reason
        end
        next_prov = Provenance(
          author_id: old_b.provenance.author_id,
          author_kind: old_b.provenance.author_kind,
          grant_id: old_b.provenance.grant_id,
          proposal_id: old_b.provenance.proposal_id,
          reason: merged_reason,
          citations: next_cites,
          updated_at: prov.updated_at
        )
        updated = Block(
          id: old_b.id,
          page_id: page_id,
          parent_block_id: old_b.parent_block_id,
          rank: old_b.rank,
          kind: old_b.kind,
          markdown: old_b.markdown,
          provenance: next_prov,
          version: old_b.version + 1
        )
        cur = cur.set(idx, updated) or cur
    end
  end
  Ok(cur)
end

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

fn sync_zero_pad4(n: Int) : Text
  s = n.to_text
  if s.byte_count >= 4: s else: "#{"0".repeat(4 - s.byte_count)}#{s}"
end

## Reconciles body Markdown back into canonical blocks, preserving existing `blk_...` IDs, ranks,
## and unmodified block versions/provenance while minting IDs (`blk_<prefix>_0001`) for new blocks.
fn reconcile_blocks_from_markdown(
  page_id: Text,
  existing_blocks: List(Block),
  body_markdown: Text,
  prov: Provenance,
  id_prefix: Text
) : List(Block)
  parsed = parse_markdown_blocks(page_id, body_markdown, prov, "tmp_#{id_prefix}")
  return [] if parsed.empty?

  sorted_old = sort_blocks(existing_blocks)
  var old_by_id = {}
  var old_idx_by_id = {}
  for (oi, ob) in sorted_old.enumerate
    old_by_id = old_by_id.set(ob.id, ob)
    old_idx_by_id = old_idx_by_id.set(ob.id, oi)
  end

  var seen_ids = {}
  var staged = []
  var in_order? = true
  var last_old_idx = -1
  var last_old_rank = None

  for p in parsed
    matched_opt = if seen_ids.get(p.id) == None
      case old_by_id.get(p.id)
        Some(ob):
          seen_ids = seen_ids.set(ob.id, true)
          idx = old_idx_by_id.get(ob.id) or 0
          rank_ok = case last_old_rank
            Some(pr): ob.rank > pr
            None: true
          end
          if idx <= last_old_idx or not rank_ok
            in_order? = false
          else
            last_old_idx = idx
            last_old_rank = Some(ob.rank)
          end
          Some(ob)
        None: None
      end
    else
      None
    end
    staged = staged.append((matched_opt, p.kind, p.markdown))
  end

  if in_order?
    var out = []
    var prev_rank = None
    var fresh_idx = 0
    var i = 0
    n = staged.size
    while i < n
      entry = staged.get(i) or (None, Paragraph, "")
      case entry.0
        Some(ob):
          updated = if ob.kind == entry.1 and ob.markdown == entry.2
            ob
          else
            Block(
              id: ob.id,
              page_id: page_id,
              parent_block_id: ob.parent_block_id,
              rank: ob.rank,
              kind: entry.1,
              markdown: entry.2,
              provenance: prov,
              version: ob.version + 1
            )
          end
          prev_rank = Some(ob.rank)
          out = out.append(updated)
          i += 1
        None:
          var j = i + 1
          var next_rank = None
          while j < n
            nxt = staged.get(j) or (None, Paragraph, "")
            case nxt.0
              Some(ob2):
                next_rank = Some(ob2.rank)
                break
              None: j += 1
            end
          end
          var k = i
          var cur_left = prev_rank
          while k < j
            new_e = staged.get(k) or (None, Paragraph, "")
            fresh_idx += 1
            fid = "blk_#{id_prefix}_#{sync_zero_pad4(fresh_idx)}"
            r = rank_between(cur_left, next_rank)
            cur_left = Some(r)
            out = out.append(
              Block(
                id: fid,
                page_id: page_id,
                parent_block_id: None,
                rank: r,
                kind: new_e.1,
                markdown: new_e.2,
                provenance: prov,
                version: 1
              )
            )
            k += 1
          end
          prev_rank = cur_left
          i = j
      end
    end
    out
  else
    var out = []
    var fresh_idx = 0
    for (pos0, entry) in staged.enumerate
      new_rank = "i#{sync_zero_pad4(pos0 + 1)}"
      case entry.0
        Some(ob):
          if ob.kind == entry.1 and ob.markdown == entry.2 and ob.rank == new_rank
            out = out.append(ob)
          else
            out = out.append(
              Block(
                id: ob.id,
                page_id: page_id,
                parent_block_id: ob.parent_block_id,
                rank: new_rank,
                kind: entry.1,
                markdown: entry.2,
                provenance: prov,
                version: ob.version + 1
              )
            )
          end
        None:
          fresh_idx += 1
          fid = "blk_#{id_prefix}_#{sync_zero_pad4(fresh_idx)}"
          out = out.append(
            Block(
              id: fid,
              page_id: page_id,
              parent_block_id: None,
              rank: new_rank,
              kind: entry.1,
              markdown: entry.2,
              provenance: prov,
              version: 1
            )
          )
      end
    end
    out
  end
end

## Computes minimal ordered surgical `(BlockOp list, new_ids)` transforming `existing` into `incoming`.
fn diff_blocks_to_ops(existing: List(Block), incoming: List(Block)) : (List(BlockOp), List(Text))
  sorted_old = sort_blocks(existing)
  sorted_new = sort_blocks(incoming)
  var old_by_id = {}
  for ob in sorted_old
    old_by_id = old_by_id.set(ob.id, ob)
  end
  new_id_set = sorted_new.map(fn(b) b.id end).to_set

  var ops = []
  var new_ids = []
  var sim = []

  # 1. Deletes for blocks absent in incoming
  for ob in sorted_old
    if new_id_set.has?(ob.id)
      sim = sim.append(ob)
    else
      ops = ops.append(DeleteBlock(block_id: ob.id, expected_version: ob.version))
    end
  end

  # 2. Replaces for surviving blocks with changed kind or markdown
  for nb in sorted_new
    case old_by_id.get(nb.id)
      Some(ob):
        if ob.kind != nb.kind or ob.markdown != nb.markdown
          ops = ops.append(
            ReplaceBlock(
              block_id: ob.id,
              expected_version: ob.version,
              kind: Some(nb.kind),
              markdown: nb.markdown
            )
          )
        end
      None: Unit
    end
  end

  # 3. Inserts and MoveBlocks simulating exact post-op position in `sim`
  var prev_id_opt = None
  for nb in sorted_new
    expected_pos = case prev_id_opt
      None: 0
      Some(pid): (find_block_idx(sim, pid) or -1) + 1
    end
    case old_by_id.get(nb.id)
      None:
        ops = ops.append(
          InsertBlockAfter(
            after_block_id: prev_id_opt,
            parent_block_id: nb.parent_block_id,
            kind: nb.kind,
            markdown: nb.markdown
          )
        )
        new_ids = new_ids.append(nb.id)
        sim = sim.take(expected_pos).append(nb).concat(sim.drop(expected_pos))
      Some(ob):
        cur_pos = find_block_idx(sim, ob.id) or -1
        if cur_pos != expected_pos or ob.parent_block_id != nb.parent_block_id
          ops = ops.append(
            MoveBlock(
              block_id: ob.id,
              new_parent_id: nb.parent_block_id,
              after_block_id: prev_id_opt
            )
          )
          without = sim.remove_at(cur_pos) or sim
          ins_pos = case prev_id_opt
            None: 0
            Some(pid): (find_block_idx(without, pid) or -1) + 1
          end
          sim = without.take(ins_pos).append(ob).concat(without.drop(ins_pos))
        end
    end
    prev_id_opt = Some(nb.id)
  end

  (ops, new_ids)
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
