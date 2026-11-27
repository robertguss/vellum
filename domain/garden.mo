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
build_pr_search_query
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
  j = try Json.decode_strict[Json](body).map_error(fn(e) "invalid GitHub JSON: #{e.to_text}" end)
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
    case Json.decode_strict[Text](item.to_text.bytes)
      Ok(f) if not f.trim.empty?: changed_files = changed_files.append(f.trim)
      Ok(_) | Error(_): Unit
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
