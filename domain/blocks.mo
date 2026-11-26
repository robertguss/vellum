## Canonical Block Tree, lexicographic rank ordering, lossless anchored Markdown projection,
## and surgical `BlockOp` mutation engine for Vellum pages.
module Domain.Blocks
expose rank_between,
sort_blocks,
to_anchored_markdown,
parse_markdown_blocks,
blocks_plain_text,
apply_block_ops
use Domain.Types{AuthorKind, Block, BlockKind, BlockOp, Provenance}

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

## Orders blocks stably by lexicographic `rank` ascending, breaking ties by `id`.
fn sort_blocks(blocks: List(Block)) : List(Block)
  blocks.sort_by(fn(b) b.id end).sort_by(fn(b) b.rank end)
end

fn render_block_body(blk: Block) : Text
  case blk.kind
    Paragraph: blk.markdown
    Heading(level: lvl):
      clamped = if lvl < 1
        1
      else if lvl > 3
        3
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
    Image(attachment_id: aid, caption: cap): "![#{cap}](vellum://attachment/#{aid})"
    FileEmbed(attachment_id: aid, filename: fname): "[#{fname}](vellum://attachment/#{aid})"
    PageLink(target_page_id: tid): "[[#{tid}|#{blk.markdown}]]"
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

fn parse_single_line_block(line: Text) : Option((BlockKind, Text))
  if line == "---"
    return Some((Divider, ""))
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
  None
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
      ) | Quote | Callout(tone: _, icon: _) | CodeBlock(language: _) | PageLink(target_page_id: _): b
        .markdown
      Divider: ""
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
        cur = sort_blocks(cur.set(idx, updated) or cur)
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
        cur = sort_blocks(cur.append(inserted))
      DeleteBlock(block_id: bid, expected_version: exp_v):
        idx = try find_block_idx(cur, bid).or_fail("block '#{bid}' not found")
        old_b = cur.get(idx) or stop "block idx"
        if old_b.version != exp_v
          return Error("block '#{bid}' version mismatch: expected #{exp_v}, found #{old_b.version}")
        end
        cur = sort_blocks(cur.remove_at(idx) or cur)
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
        cur = sort_blocks(without.append(moved))
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
        cur = sort_blocks(cur.set(idx, updated) or cur)
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
end
