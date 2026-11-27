## Knowledge Gardening domain helpers: block-citation reference parsing,
## contradiction detection across near-duplicate pages, and HMAC-SHA256 GitHub PR webhook verification.
module Domain.Garden
expose GardenDuplicatePair(..),
GardenCitationDrift(..),
GithubPrEvent(..),
parse_block_citation_ref,
detect_contradiction_signal,
verify_github_signature,
parse_github_pr_webhook,
build_pr_search_query,
extract_text_backlink_refs
use Crypto
use Json

## High-similarity page pair flagged by `Modb.Vec` near-duplicate & contradiction detection.
struct GardenDuplicatePair
  page_a_id: Text
  page_a_title: Text
  collection_a_id: Text
  page_b_id: Text
  page_b_title: Text
  collection_b_id: Text
  similarity: Float
  possible_contradiction: Bool
  contradiction_reason: Option(Text)
end

## Cited source block drift detected when a cited `blk_...` was edited after the dependent block/page verification.
struct GardenCitationDrift
  dependent_page_id: Text
  dependent_page_title: Text
  dependent_collection_id: Text
  dependent_block_id: Text
  cited_page_id: Text
  cited_page_title: Text
  cited_block_id: Text
  cited_block_version: Int
  dependent_updated_at: Time
  cited_updated_at: Time
  summary: Text
end

## Parsed GitHub `pull_request` webhook event routed into Proposals-Only runbook sync.
struct GithubPrEvent
  action: Text
  pr_number: Int
  title: Text
  body: Text
  html_url: Text
  repo_full_name: Text
  head_sha: Text
  merged: Bool
  changed_files: List(Text)
end

## Extracts optional `(page_id, block_id)` from `Citation.source_ref` formats:
## `"blk_..."`, `"pg_...:blk_..."`, `"page:pg_...:block:blk_..."`, or `"/p/pg_...#blk_..."`.
fn parse_block_citation_ref(source_ref: Text) : Option((Option(Text), Text))
  clean = source_ref.trim
  return None if clean.empty?
  if clean.starts_with?("blk_")
    return Some((None, clean))
  end
  if clean.starts_with?("page:") and clean.contains?(":block:blk_")
    parts = clean.split(":block:")
    if parts.size == 2
      pg = (parts.first or "").drop_prefix("page:") or ""
      blk = (parts.get(1) or "").trim
      if not pg.empty? and blk.starts_with?("blk_")
        return Some((Some(pg), blk))
      end
    end
  end
  if clean.starts_with?("/p/") and clean.contains?("#blk_")
    parts = clean.drop_prefix("/p/").map(fn(s) s.split("#") end) or []
    if parts.size == 2
      pg = (parts.first or "").trim
      blk = (parts.get(1) or "").trim
      if not pg.empty? and blk.starts_with?("blk_")
        return Some((Some(pg), blk))
      end
    end
  end
  if clean.contains?(":blk_")
    parts = clean.split(":blk_")
    if parts.size == 2
      pg = (parts.first or "").trim
      blk = "blk_#{(parts.get(1) or "").trim}"
      if not pg.empty? and blk.byte_count > 4
        return Some((Some(pg), blk))
      end
    end
  end
  None
end

fn extract_numeric_tokens(raw: Text) : List(Text)
  var tokens = []
  var cur = []
  for ch in raw.chars
    is_num_ch = ch.ascii_digit? or (not cur.empty? and (ch == '.' or ch == '%'))
    if is_num_ch
      cur = cur.append(ch)
    else if not cur.empty?
      tok = Text.from_chars(cur).drop_suffix(".") or Text.from_chars(cur)
      if tok.chars.any?(fn(c) c.ascii_digit? end)
        tokens = tokens.append(tok)
      end
      cur = []
    end
  end
  if not cur.empty?
    tok = Text.from_chars(cur).drop_suffix(".") or Text.from_chars(cur)
    if tok.chars.any?(fn(c) c.ascii_digit? end)
      tokens = tokens.append(tok)
    end
  end
  var seen = Set.empty
  var out = []
  for t in tokens
    if not seen.has?(t)
      seen = seen.add(t)
      out = out.append(t)
    end
  end
  out
end

fn has_any_phrase?(low: Text, phrases: List(Text)) : Bool
  phrases.any?(fn(p) low.contains?(p) end)
end

## Detects deterministic numeric/threshold divergence or polarity conflicts between near-duplicate docs.
fn detect_contradiction_signal(text_a: Text, text_b: Text) : Option(Text)
  nums_a = extract_numeric_tokens(text_a)
  nums_b = extract_numeric_tokens(text_b)
  if not nums_a.empty? and not nums_b.empty?
    set_a = nums_a.to_set
    set_b = nums_b.to_set
    diff_a = nums_a.any?(fn(n) not set_b.has?(n) end)
    diff_b = nums_b.any?(fn(n) not set_a.has?(n) end)
    if diff_a and diff_b
      return Some(
        "Numeric/threshold divergence (#{nums_a.take(3).join(", ")} vs #{nums_b.take(3).join(", ")})"
      )
    end
  end

  low_a = text_a.ascii_lowercase
  low_b = text_b.ascii_lowercase
  neg_markers = ["deprecated", "do not", "never ", "disabled", "removed", "forbidden"]
  pos_markers = ["required", "always ", "enabled", "recommended", "must use"]
  a_neg = has_any_phrase?(low_a, neg_markers)
  b_neg = has_any_phrase?(low_b, neg_markers)
  a_pos = has_any_phrase?(low_a, pos_markers)
  b_pos = has_any_phrase?(low_b, pos_markers)
  if (a_neg and not b_neg and b_pos) or (b_neg and not a_neg and a_pos)
    return Some("Directive/polarity conflict between near-duplicate pages")
  end
  None
end

## Constant-time verification of GitHub `X-Hub-Signature-256: sha256=<hex>` HMAC over raw request bytes.
fn verify_github_signature(secret: Text, raw_body: Bytes, sig_header: Option(Text)) : Bool
  clean_secret = secret.trim
  return false if clean_secret.empty?
  raw_sig = case sig_header
    Some(s): s.trim.ascii_lowercase
    None: return false
  end
  return false if not raw_sig.starts_with?("sha256=")
  expected_hex = Crypto.hmac_sha256(clean_secret.bytes, raw_body).to_hex.ascii_lowercase
  expected = "sha256=#{expected_hex}"
  Crypto.constant_time_eq?(expected.bytes, raw_sig.bytes)
end

## Parses a GitHub `pull_request` webhook JSON payload into a typed `GithubPrEvent`.
fn parse_github_pr_webhook(body: Bytes) : Result(GithubPrEvent, Text)
  raw_txt = try body.decode_utf8.or_fail("invalid GitHub JSON: non-UTF8 body")
  j = try Json.parse(raw_txt).map_error(fn(e) "invalid GitHub JSON: #{e.to_text}" end)
  action = (j.text_at("action") or "").trim.ascii_lowercase
  pr = case j.get("pull_request")
    Some(p): p
    None: return Error("missing 'pull_request' object in webhook payload")
  end
  pr_num = try pr.int_at("number").or_fail("missing pull_request.number")
  title = (pr.text_at("title") or "").trim
  if title.empty?
    return Error("missing pull_request.title")
  end
  pr_body = (pr.text_at("body") or "").trim
  html_url = (pr.text_at("html_url") or "https://github.com/pull/#{pr_num}").trim
  head_sha = (pr.text_at("head.sha") or "").trim
  merged = pr.bool_at("merged") or false
  repo_name = (j.text_at("repository.full_name") or "unknown/repo").trim

  raw_files = case j.list_at("changed_files")
    Some(xs): xs
    None: j.list_at("pull_request.changed_files_list") or []
  end
  var changed_files = []
  for item in raw_files
    case item
      Json.String(f) if not f.trim.empty?: changed_files = changed_files.append(f.trim)
      Json.String(_) | Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(
        _
      ): Unit
    end
  end

  Ok(
    GithubPrEvent(
      action: action,
      pr_number: pr_num,
      title: title,
      body: pr_body,
      html_url: html_url,
      repo_full_name: repo_name,
      head_sha: head_sha,
      merged: merged,
      changed_files: changed_files
    )
  )
end

## Builds a compact hybrid search query from PR title, file stems, and summary body.
fn build_pr_search_query(ev: GithubPrEvent) : Text
  files_txt = ev.changed_files.take(6).map(fn(f)
    f.replace("/", " ").replace(".", " ").replace("_", " ").replace("-", " ")
  end).join(" ")
  body_snip = if ev.body.byte_count > 180
    ev.body.bytes.slice(0, 180).decode_utf8 or ev.body
  else
    ev.body
  end
  "#{ev.title} #{files_txt} #{body_snip}".trim
end

fn scan_leading_id_token(raw: Text) : Option(Text)
  var chars = []
  for ch in raw.chars
    if ch.ascii_letter? or ch.ascii_digit? or ch == '_' or ch == '-'
      chars = chars.append(ch)
    else
      break
    end
  end
  if chars.empty?: None else: Some(Text.from_chars(chars))
end

## Extracts deduplicated `(page_refs, bare_block_ids)` from block markdown links and citation refs.
fn extract_text_backlink_refs(markdown: Text, citation_refs: List(Text)) : (
  List(Text),
  List(Text)
)
  var raw_pages = []
  var bare_bids = []

  if markdown.contains?("[[")
    for seg in markdown.split("[[").drop(1)
      if seg.contains?("]]")
        raw_inner = seg.split("]]").first or ""
        raw_pages = raw_pages.append(raw_inner.split("|").first or "")
      end
    end
  end

  if markdown.contains?("/p/")
    for seg in markdown.split("/p/").drop(1)
      case scan_leading_id_token(seg)
        Some(tid): raw_pages = raw_pages.append(tid)
        None: Unit
      end
    end
  end

  for raw_sr in citation_refs
    sr = raw_sr.trim
    if sr.starts_with?("/p/")
      case scan_leading_id_token(sr.drop_prefix("/p/") or "")
        Some(tid): raw_pages = raw_pages.append(tid)
        None: Unit
      end
    else
      case parse_block_citation_ref(sr)
        Some((Some(pg_id), _bid)): raw_pages = raw_pages.append(pg_id)
        Some((None, bid)):
          if not bid.empty? and not bare_bids.contains?(bid)
            bare_bids = bare_bids.append(bid)
          end
        None: raw_pages = raw_pages.append(sr)
      end
    end
  end

  var page_refs = []
  for r in raw_pages
    c = r.trim
    if not c.empty? and not c.contains?("|") and not c.contains?(" ") and not c.contains?("\n") and
      not c.contains?("\r") and
      not c.contains?("\t") and
      not page_refs.contains?(c)
      page_refs = page_refs.append(c)
    end
  end
  (page_refs, bare_bids)
end
