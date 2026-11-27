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

fn is_ascii_digit(c: Char) : Bool
  c.code >= 48 and c.code <= 57
end

fn is_pii_boundary(c: Char) : Bool
  not is_word_or_dash(c) and c != '.'
end

fn boundary_before?(chars: List(Char), idx: Int) : Bool
  if idx <= 0
    true
  else
    prev = chars.get(idx - 1) or ' '
    not is_word_or_dash(prev)
  end
end

fn pii_boundary_before?(chars: List(Char), idx: Int) : Bool
  if idx <= 0
    true
  else
    prev = chars.get(idx - 1) or ' '
    is_pii_boundary(prev)
  end
end

fn pii_boundary_after?(chars: List(Char), idx: Int) : Bool
  if idx >= chars.size
    true
  else
    nxt = chars.get(idx) or ' '
    is_pii_boundary(nxt)
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

fn slice_digits(chars: List(Char), start: Int, count: Int) : Option(Text)
  return None if start < 0 or start + count > chars.size
  var out = []
  var j = 0
  while j < count
    c = chars.get(start + j) or '\u{0}'
    return None if not is_ascii_digit(c)
    out = out.append(c)
    j += 1
  end
  Some(Text.from_chars(out))
end

fn last_n_digits(raw: Text, n: Int) : Text
  var digs = []
  for c in raw.chars
    if is_ascii_digit(c)
      digs = digs.append(c)
    end
  end
  if digs.size <= n
    Text.from_chars(digs)
  else
    Text.from_chars(digs.drop(digs.size - n))
  end
end

fn valid_aba_routing?(digits: Text) : Bool
  ds = digits.chars.map(fn(c) c.code - 48 end)
  return false if ds.size != 9
  d0 = ds.get(0) or 0
  d1 = ds.get(1) or 0
  d2 = ds.get(2) or 0
  d3 = ds.get(3) or 0
  d4 = ds.get(4) or 0
  d5 = ds.get(5) or 0
  d6 = ds.get(6) or 0
  d7 = ds.get(7) or 0
  d8 = ds.get(8) or 0
  fed = d0 * 10 + d1
  fed_ok? = (fed >= 0 and fed <= 12) or (fed >= 21 and fed <= 32) or
    (fed >= 61 and fed <= 72) or
    fed == 80
  return false if not fed_ok?
  sum = 3 * (d0 + d3 + d6) + 7 * (d1 + d4 + d7) + (d2 + d5 + d8)
  sum % 10 == 0
end

fn luhn_valid?(digits: List(Int)) : Bool
  return false if digits.size < 13 or digits.size > 19
  var sum = 0
  var double? = false
  var idx = digits.size - 1
  while idx >= 0
    d = digits.get(idx) or 0
    if double?
      dbl = d * 2
      sum += (if dbl > 9: dbl - 9 else: dbl)
    else
      sum += d
    end
    double? = not double?
    idx -= 1
  end
  sum % 10 == 0
end

fn valid_card_iin?(digits: List(Int)) : Bool
  return false if digits.size < 4
  d0 = digits.get(0) or 0
  d1 = digits.get(1) or 0
  d2 = digits.get(2) or 0
  d3 = digits.get(3) or 0
  p2 = d0 * 10 + d1
  p4 = p2 * 100 + d2 * 10 + d3
  d0 == 4 or (p2 >= 51 and p2 <= 55) or p2 == 34 or p2 == 37 or p4 == 6011 or p2 == 65 or
    (p4 >= 2221 and p4 <= 2720)
end

fn skip_ws(chars: List(Char), start: Int) : Int
  var k = start
  while k < chars.size
    c = chars.get(k) or '\u{0}'
    break if c != ' ' and c != '\t'
    k += 1
  end
  k
end

fn starts_ci_at?(chars: List(Char), idx: Int, low_pat: Text) : Bool
  pchars = low_pat.chars
  return false if idx < 0 or idx + pchars.size > chars.size
  slice_text(chars, idx, idx + pchars.size).ascii_lowercase == low_pat
end

fn match_labeled_student_id(chars: List(Char), idx: Int) : Option((Text, Int))
  prefixes = ["student_id", "student id", "campus id", "banner id"]
  var matched_len = 0
  for p in prefixes
    if starts_ci_at?(chars, idx, p)
      matched_len = p.chars.size
      break
    end
  end
  return None if matched_len == 0
  var k = skip_ws(chars, idx + matched_len)
  var saw_sep? = false
  while k < chars.size
    c = chars.get(k) or '\u{0}'
    if c == ':' or c == '#' or c == '=' or c == '-'
      saw_sep? = true
      k += 1
    else
      break
    end
  end
  return None if k == idx + matched_len and not saw_sep?
  k = skip_ws(chars, k)
  e = take_while_from(chars, k, is_ascii_digit)
  dlen = e - k
  return None if dlen < 7 or dlen > 10 or not pii_boundary_after?(chars, e)
  Some((slice_text(chars, k, e), e - idx))
end

fn match_labeled_routing(chars: List(Char), idx: Int) : Option((Text, Int))
  var p_len = 0
  if starts_ci_at?(chars, idx, "routing")
    p_len = 7
  else if starts_ci_at?(chars, idx, "aba")
    p_len = 3
  else if starts_ci_at?(chars, idx, "rtn")
    p_len = 3
  end
  return None if p_len == 0
  var k = idx + p_len
  return None if k >= chars.size
  next_c = chars.get(k) or '\u{0}'
  return None if is_alnum_or_underscore(next_c)
  k = skip_ws(chars, k)
  if starts_ci_at?(chars, k, "number")
    k = skip_ws(chars, k + 6)
  else if starts_ci_at?(chars, k, "num")
    k = skip_ws(chars, k + 3)
  else if starts_ci_at?(chars, k, "no")
    k = skip_ws(chars, k + 2)
  end
  while k < chars.size
    c = chars.get(k) or '\u{0}'
    if c == ':' or c == '#' or c == '=' or c == '.'
      k += 1
    else
      break
    end
  end
  k = skip_ws(chars, k)
  case slice_digits(chars, k, 9)
    Some(digs):
      if pii_boundary_after?(chars, k + 9) and valid_aba_routing?(digs)
        Some((digs, (k + 9) - idx))
      else
        None
      end
    None: None
  end
end

fn match_payment_card(chars: List(Char), idx: Int) : Option((Text, Int))
  c0 = chars.get(idx) or '\u{0}'
  return None if not is_ascii_digit(c0)
  return None if not pii_boundary_before?(chars, idx)
  var k = idx
  var sep_opt = None
  var digits = []
  var last_was_sep = false
  while k < chars.size and digits.size <= 19
    c = chars.get(k) or '\u{0}'
    if is_ascii_digit(c)
      digits = digits.append(c.code - 48)
      last_was_sep = false
      k += 1
    else if (c == '-' or c == ' ') and not last_was_sep and not digits.empty?
      sep_ok = case sep_opt
        None: true
        Some(s): s == c
      end
      break if not sep_ok
      sep_opt = Some(c)
      last_was_sep = true
      k += 1
    else
      break
    end
  end
  if last_was_sep
    k -= 1
  end
  return None if digits.size < 13 or digits.size > 19
  return None if not pii_boundary_after?(chars, k)
  return None if not valid_card_iin?(digits) or not luhn_valid?(digits)
  Some((slice_text(chars, idx, k), k - idx))
end

fn mask_finding_preview(kind: Text, raw: Text) : Text
  if kind == "us_ssn"
    "***-**-#{last_n_digits(raw, 4)}"
  else if kind == "student_id"
    "***#{last_n_digits(raw, 4)}"
  else if kind == "bank_routing"
    "ABA-*****#{last_n_digits(raw, 4)}"
  else if kind == "payment_card"
    "****-****-****-#{last_n_digits(raw, 4)}"
  else
    mask_secret(raw)
  end
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
    masked_preview: mask_finding_preview(kind, raw),
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

## Fast native substring pre-check avoiding per-character work when no secret prefix can match.
fn maybe_has_secret?(text: Text) : Bool
  for p in [
    "-----BEGIN ",
    "vlm_ag_",
    "whsec_",
    "github_pat_",
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "ghr_",
    "sk-",
    "sk_live_",
    "sk_test_",
    "rk_live_",
    "xoxb-",
    "xoxp-",
    "xoxa-",
    "xoxr-",
    "AKIA",
    "ASIA",
    "AIDA",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9"
  ]
    return true if text.contains?(p)
  end
  false
end

## Scans `text` for exposed credentials (API keys, cloud/VCS tokens, Vellum agent/webhook secrets,
## and PEM private keys), deduplicated in deterministic appearance order.
fn scan_text(text: Text) : List(SecretFinding)
  if text.empty? or not maybe_has_secret?(text)
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
      else if starts_ci_at?(chars, i, "sid-") or starts_ci_at?(chars, i, "stu-") or
        starts_ci_at?(chars, i, "student-") or
        starts_ci_at?(chars, i, "ferpa-")
        plen = if starts_ci_at?(chars, i, "student-")
          8
        else if starts_ci_at?(chars, i, "ferpa-")
          6
        else
          4
        end
        e = take_while_from(chars, i + plen, is_ascii_digit)
        dlen = e - (i + plen)
        if dlen >= 6 and dlen <= 10 and pii_boundary_after?(chars, e)
          tok = slice_text(chars, i, e)
          matched_opt = Some(
            make_finding("student_id", "Student / Institutional ID", "high", tok)
          )
          step = e - i
        end
      else
        case match_labeled_student_id(chars, i)
          Some((tok, slen)):
            matched_opt = Some(
              make_finding("student_id", "Student / Institutional ID", "high", tok)
            )
            step = slen
          None:
            case match_labeled_routing(chars, i)
              Some((rtok, rlen)):
                matched_opt = Some(
                  make_finding("bank_routing", "US Bank Routing Number (ABA)", "high", rtok)
                )
                step = rlen
              None: Unit
            end
        end
      end
    end

    if matched_opt == None and pii_boundary_before?(chars, i) and
      is_ascii_digit(chars.get(i) or '\u{0}')
      if i + 11 <= chars.size and (chars.get(i + 3) or '\u{0}') == '-' and
        (chars.get(i + 6) or '\u{0}') == '-' and
        pii_boundary_after?(chars, i + 11)
        case (slice_digits(chars, i, 3), slice_digits(chars, i + 4, 2), slice_digits(chars, i + 7, 4))
          (Some(aaa), Some(gg), Some(ssss)):
            if aaa != "000" and aaa != "666" and not aaa.starts_with?("9") and gg != "00" and
              ssss != "0000"
              tok = "#{aaa}-#{gg}-#{ssss}"
              matched_opt = Some(
                make_finding("us_ssn", "US Social Security Number", "critical", tok)
              )
              step = 11
            end
          (_, _, _): Unit
        end
      end
      if matched_opt == None
        case match_payment_card(chars, i)
          Some((ctok, clen)):
            matched_opt = Some(
              make_finding("payment_card", "Payment Card Number", "critical", ctok)
            )
            step = clen
          None: Unit
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
