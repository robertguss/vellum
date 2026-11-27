## Pure deterministic secret detector, masker, and redactor for Vellum (`Modb.Erasure` hints).
module Domain.Secrets
expose SecretFinding(..),
scan_text,
redact_tokens,
mask_secret,
finding_to_public_json
use Crypto
use Json

## Detected secret candidate returned by `scan_text`. Never serialize `raw_token` in API responses.
struct SecretFinding
  kind: Text
  label: Text
  severity: Text
  masked_preview: Text
  match_sha256: Text
  raw_token: Text
end

fn is_upper_alnum(c: Char) : Bool
  (c.code >= 65 and c.code <= 90) or (c.code >= 48 and c.code <= 57)
end

fn is_alnum(c: Char) : Bool
  is_upper_alnum(c) or (c.code >= 97 and c.code <= 122)
end

fn is_word_or_dash(c: Char) : Bool
  is_alnum(c) or c == '_' or c == '-'
end

fn is_alnum_or_underscore(c: Char) : Bool
  is_alnum(c) or c == '_'
end

fn boundary_before?(chars: List(Char), idx: Int) : Bool
  if idx <= 0
    true
  else
    prev = chars.get(idx - 1) or ' '
    not is_word_or_dash(prev)
  end
end

fn starts_prefix_at?(chars: List(Char), idx: Int, pat: List(Char)) : Bool
  if idx < 0 or idx + pat.size > chars.size
    return false
  end
  var j = 0
  while j < pat.size
    if (chars.get(idx + j) or '\u{0}') != (pat.get(j) or '\u{1}')
      return false
    end
    j += 1
  end
  true
end

fn take_while_from(chars: List(Char), start: Int, pred: fn(Char) : Bool) : Int
  var k = start
  while k < chars.size
    c = chars.get(k) or '\u{0}'
    if not pred(c)
      return k
    end
    k += 1
  end
  k
end

fn slice_text(chars: List(Char), start: Int, stop_idx: Int) : Text
  if stop_idx <= start
    return ""
  end
  Text.from_chars(chars.drop(start).take(stop_idx - start))
end

fn mask_secret(raw: Text) : Text
  if raw.starts_with?("-----BEGIN ")
    return "-----BEGIN ... PRIVATE KEY-----"
  end
  cs = raw.chars
  if cs.size <= 10
    "***"
  else
    head = Text.from_chars(cs.take(6))
    tail = Text.from_chars(cs.drop(cs.size - 4))
    "#{head}...#{tail}"
  end
end

fn make_finding(kind: Text, label: Text, severity: Text, raw: Text) : SecretFinding
  SecretFinding(
    kind: kind,
    label: label,
    severity: severity,
    masked_preview: mask_secret(raw),
    match_sha256: Crypto.sha256(raw.bytes).to_hex,
    raw_token: raw
  )
end

fn find_pem_end(chars: List(Char), start: Int) : Option(Int)
  pat = "PRIVATE KEY-----".chars
  var i = start
  limit = if start + 4096 < chars.size: start + 4096 else: chars.size
  while i + pat.size <= limit
    if starts_prefix_at?(chars, i, pat)
      return Some(i + pat.size)
    end
    i += 1
  end
  None
end

## Scans `text` for exposed credentials (API keys, cloud/VCS tokens, Vellum agent/webhook secrets,
## and PEM private keys), deduplicated in deterministic appearance order.
fn scan_text(text: Text) : List(SecretFinding)
  if text.empty?
    return []
  end
  chars = text.chars
  pem_begin = "-----BEGIN ".chars
  pem_end_hdr = "PRIVATE KEY-----".chars
  sk_proj = "sk-proj-".chars
  sk_ant = "sk-ant-".chars
  sk_open = "sk-".chars
  sk_live = "sk_live_".chars
  sk_test = "sk_test_".chars
  rk_live = "rk_live_".chars
  gh_pat = "github_pat_".chars
  gh_p = "ghp_".chars
  gh_o = "gho_".chars
  gh_u = "ghu_".chars
  gh_s = "ghs_".chars
  gh_r = "ghr_".chars
  xoxb = "xoxb-".chars
  xoxp = "xoxp-".chars
  xoxa = "xoxa-".chars
  xoxr = "xoxr-".chars
  aws_akia = "AKIA".chars
  aws_asia = "ASIA".chars
  aws_aida = "AIDA".chars
  vlm_ag = "vlm_ag_".chars
  whsec = "whsec_".chars

  var out = []
  var seen = Set.empty
  var i = 0
  while i < chars.size
    var step = 1
    var matched_opt = None

    if starts_prefix_at?(chars, i, pem_begin)
      case find_pem_end(chars, i + pem_begin.size)
        Some(hdr_end):
          case find_pem_end(chars, hdr_end)
            Some(full_end):
              tok = slice_text(chars, i, full_end)
              matched_opt = Some(make_finding("pem_private_key", "PEM Private Key", "critical", tok))
              step = full_end - i
            None: Unit
          end
        None: Unit
      end
      if matched_opt == None and starts_prefix_at?(chars, i, pem_begin)
        _ignored = pem_end_hdr
      end
    else if boundary_before?(chars, i)
      if starts_prefix_at?(chars, i, vlm_ag)
        e = take_while_from(chars, i + vlm_ag.size, is_word_or_dash)
        if e - i >= 20
          tok = slice_text(chars, i, e)
          matched_opt = Some(
            make_finding("vellum_agent_token", "Vellum Agent Token", "critical", tok)
          )
          step = e - i
        end
      else if starts_prefix_at?(chars, i, whsec)
        e = take_while_from(chars, i + whsec.size, is_word_or_dash)
        if e - i >= 20
          tok = slice_text(chars, i, e)
          matched_opt = Some(
            make_finding("webhook_secret", "Webhook Signing Secret", "high", tok)
          )
          step = e - i
        end
      else if starts_prefix_at?(chars, i, gh_pat)
        e = take_while_from(chars, i + gh_pat.size, is_alnum_or_underscore)
        if e - i >= 20
          tok = slice_text(chars, i, e)
          matched_opt = Some(make_finding("github_token", "GitHub Token", "critical", tok))
          step = e - i
        end
      else if starts_prefix_at?(chars, i, gh_p) or starts_prefix_at?(chars, i, gh_o) or
        starts_prefix_at?(chars, i, gh_u) or
        starts_prefix_at?(chars, i, gh_s) or
        starts_prefix_at?(chars, i, gh_r)
        e = take_while_from(chars, i + 4, is_alnum_or_underscore)
        if e - i >= 20
          tok = slice_text(chars, i, e)
          matched_opt = Some(make_finding("github_token", "GitHub Token", "critical", tok))
          step = e - i
        end
      else if starts_prefix_at?(chars, i, sk_proj) or starts_prefix_at?(chars, i, sk_ant) or
        starts_prefix_at?(chars, i, sk_open)
        plen = if starts_prefix_at?(chars, i, sk_proj)
          8
        else if starts_prefix_at?(chars, i, sk_ant)
          7
        else
          3
        end
        e = take_while_from(chars, i + plen, is_word_or_dash)
        if e - i >= 20
          tok = slice_text(chars, i, e)
          matched_opt = Some(make_finding("ai_api_key", "OpenAI / Anthropic API Key", "critical", tok))
          step = e - i
        end
      else if starts_prefix_at?(chars, i, sk_live) or starts_prefix_at?(chars, i, sk_test) or
        starts_prefix_at?(chars, i, rk_live)
        e = take_while_from(chars, i + 8, is_alnum)
        if e - i >= 20
          tok = slice_text(chars, i, e)
          matched_opt = Some(
            make_finding("stripe_secret_key", "Stripe Secret Key", "critical", tok)
          )
          step = e - i
        end
      else if starts_prefix_at?(chars, i, xoxb) or starts_prefix_at?(chars, i, xoxp) or
        starts_prefix_at?(chars, i, xoxa) or
        starts_prefix_at?(chars, i, xoxr)
        e = take_while_from(chars, i + 5, is_word_or_dash)
        if e - i >= 18
          tok = slice_text(chars, i, e)
          matched_opt = Some(make_finding("slack_token", "Slack Token", "high", tok))
          step = e - i
        end
      else if starts_prefix_at?(chars, i, aws_akia) or starts_prefix_at?(chars, i, aws_asia) or
        starts_prefix_at?(chars, i, aws_aida)
        e = take_while_from(chars, i + 4, is_upper_alnum)
        if e - i == 20
          after_ok = if e >= chars.size
            true
          else
            not is_word_or_dash(chars.get(e) or ' ')
          end
          if after_ok
            tok = slice_text(chars, i, e)
            matched_opt = Some(make_finding("aws_access_key", "AWS Access Key ID", "high", tok))
            step = e - i
          end
        end
      end
    end

    case matched_opt
      Some(f):
        if not seen.has?(f.raw_token)
          seen = seen.add(f.raw_token)
          out = out.append(f)
        end
      None: Unit
    end
    i += (if step > 0: step else: 1)
  end
  out
end

## Formats a finding as safe API JSON (`raw_token` omitted).
fn finding_to_public_json(f: SecretFinding) : Json
  Json.Object({
    "kind": Json.String(f.kind),
    "label": Json.String(f.label),
    "severity": Json.String(f.severity),
    "masked_preview": Json.String(f.masked_preview),
    "match_sha256": Json.String(f.match_sha256)
  })
end

## Replaces every occurrence of each unique non-empty token in `tokens` with `[REDACTED]`.
fn redact_tokens(text: Text, tokens: List(Text)) : (Text, Int)
  var cur = text
  var count = 0
  var seen = Set.empty
  for raw in tokens
    tok = raw.trim
    if not tok.empty? and not seen.has?(tok)
      seen = seen.add(tok)
      parts = cur.split(tok)
      if parts.size > 1
        count += parts.size - 1
        cur = parts.join("[REDACTED]")
      end
    end
  end
  (cur, count)
end
