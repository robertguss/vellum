## Unified Vellum Chat storage, ACL & search helpers on raw `Modb` JSON buckets (`vellum.modb`).
## Uses `vlm_chat_*` raw byte buckets (zero new `Modb.Table` specializations to avoid `E1152`).
module ChatOps
expose channels_bucket,
messages_bucket,
idempotency_bucket,
reads_bucket,
inbox_bucket,
links_bucket,
link_key,
tx_put_chat_link,
scan_chat_links_for_target,
extract_entity_refs,
slugify_channel,
normalize_handle,
extract_mentions,
msg_preview,
channel_collection_id,
can_access_channel?,
require_channel_access,
msg_key,
read_cursor_key,
inbox_key,
get_channel,
tx_get_channel,
list_all_channels,
tx_put_channel,
find_existing_dm,
get_message,
tx_get_message,
tx_put_message,
scan_channel_raw_messages,
scan_channel_messages_window,
scan_all_messages,
tx_scan_all_messages,
tx_lookup_idempotency,
tx_put_idempotency,
get_read_cursor,
tx_put_read_cursor,
count_channel_unread,
list_inbox,
unread_inbox_count,
tx_put_inbox,
tx_scan_inbox,
tx_scan_all_inbox,
search_visible_messages
use Domain.Policy
use Domain.Types{AppError, AuthContext}
use Json
use Modb{Store, WriteTx}
use VaultOps

channels_bucket = "vlm_chat_channels"
messages_bucket = "vlm_chat_messages"
idempotency_bucket = "vlm_chat_idempotency"
reads_bucket = "vlm_chat_reads"
inbox_bucket = "vlm_chat_inbox"
links_bucket = "vlm_chat_links"

fn parse_bytes_json(raw: Bytes) : Option(Json)
  case raw.decode_utf8
    Some(txt):
      case Json.parse(txt)
        Ok(j): Some(j)
        Error(_): None
      end
    None: None
  end
end

## Normalizes any Vellum handle to lowercase without a leading `@`.
fn normalize_handle(raw: Text) : Text
  low = raw.trim.ascii_lowercase
  low.drop_prefix("@") or low
end

## Slugifies a channel name into lowercase `[a-z0-9-]` with collapsed hyphens.
fn slugify_channel(raw: Text) : Text
  var chars = []
  var prev_dash = true
  for ch in raw.trim.ascii_lowercase.chars
    if ch.ascii_letter? or ch.ascii_digit?
      chars = chars.append(ch)
      prev_dash = false
    else if not prev_dash
      chars = chars.append('-')
      prev_dash = true
    end
  end
  while not chars.empty? and chars.last == Some('-')
    chars = chars.take(chars.size - 1)
  end
  if chars.empty?: "channel" else: Text.from_chars(chars)
end

fn is_mention_prefix_blocker?(ch: Char) : Bool
  ch.ascii_letter? or ch.ascii_digit? or ch == '.' or ch == '_' or ch == '-' or ch == '+' or
    ch == '@'
end

fn is_mention_body_char?(ch: Char) : Bool
  ch.ascii_letter? or ch.ascii_digit? or ch == '_' or ch == '-' or ch == '.'
end

## Extracts unique lowercased `@handle` mentions from chat markdown while ignoring emails.
## Builds composite key for reverse lookup of chat messages referencing workspaces entities.
fn link_key(target_kind: Text, target_id: Text, channel_id: Text, msg_id: Text) : Text
  "#{target_kind}:#{target_id}:#{channel_id}:#{msg_id}"
end

## Persists a reverse link record in `vlm_chat_links` (`target_kind:target_id:channel_id:msg_id`).
fn tx_put_chat_link(
  tx: WriteTx,
  target_kind: Text,
  target_id: Text,
  channel_id: Text,
  msg_id: Text,
  link_json: Json
) : Result(WriteTx, AppError)
  key = link_key(target_kind, target_id, channel_id, msg_id)
  Modb.tx_put(tx, links_bucket, key.bytes, link_json.to_text.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
end

## Scans `vlm_chat_links` for all chat link records referencing `(target_kind, target_id)`.
fn scan_chat_links_for_target(
  store: Store,
  target_kind: Text,
  target_id: Text,
  limit: Int
) : Result(List(Json), AppError)
  prefix = "#{target_kind}:#{target_id}:"
  hi = "#{target_kind}:#{target_id};"
  rows = try Modb.scan(store, links_bucket, Some(prefix.bytes), Some(hi.bytes), limit).map_error(
    fn(e)
      ServerFailed(reason: e.to_text)
    end
  )
  var out = []
  for (k_bytes, v_bytes) in rows
    k_txt = k_bytes.decode_utf8 or ""
    if k_txt.starts_with?(prefix)
      case v_bytes.decode_utf8
        Some(txt):
          case Json.parse(txt)
            Ok(j): out = out.append(j)
            Error(_): Unit
          end
        None: Unit
      end
    end
  end
  Ok(out)
end

fn is_ref_id_char?(c: Char) : Bool
  c.ascii_letter? or c.ascii_digit? or c == '_' or c == '-'
end

fn parse_entity_ref_inner(inner: Text) : Option((Text, Text))
  clean = inner.trim
  if clean.empty? or clean.contains?(" ") or clean.contains?("\n") or clean.contains?("\r")
    return None
  end
  if clean.starts_with?("page:")
    pid = clean.drop_prefix("page:") or ""
    if pid.empty?
      None
    else
      Some(("page", pid))
    end
  else if clean.starts_with?("pg_")
    Some(("page", clean))
  else if clean.starts_with?("row:")
    rid = clean.drop_prefix("row:") or ""
    if rid.empty?
      None
    else
      Some(("row", rid))
    end
  else if clean.starts_with?("task:")
    rid = clean.drop_prefix("task:") or ""
    if rid.empty?
      None
    else
      Some(("row", rid))
    end
  else if clean.starts_with?("proposal:")
    prid = clean.drop_prefix("proposal:") or ""
    if prid.empty?
      None
    else
      Some(("proposal", prid))
    end
  else if clean.starts_with?("thread:")
    rest = clean.drop_prefix("thread:") or ""
    parts = rest.split(":")
    if parts.size == 2
      cid = parts.get(0) or ""
      mid = parts.get(1) or ""
      if not cid.empty? and not mid.empty?
        Some(("thread", "#{cid}:#{mid}"))
      else
        None
      end
    else
      None
    end
  else
    None
  end
end

fn try_append_entity_ref(
  out: List(Json),
  seen: List(Text),
  kind: Text,
  id: Text,
  raw: Text
) : (List(Json), List(Text))
  if out.size >= 20
    return (out, seen)
  end
  dedup_key = "#{kind}:#{id}"
  if seen.contains?(dedup_key)
    return (out, seen)
  end
  item = Json.Object({
    "kind": Json.String(kind),
    "id": Json.String(id),
    "raw": Json.String(raw)
  })
  (out.append(item), seen.append(dedup_key))
end

fn parse_bracket_entity_ref(chars: List(Char), start: Int) : Option((Text, Text, Text, Int))
  var j = start + 2
  max_end = if chars.size < start + 162
    chars.size
  else
    start + 162
  end
  var inner_chars = []
  var found_close? = false
  while j + 1 < max_end and not found_close?
    c = chars.get(j) or '\n'
    c2 = chars.get(j + 1) or '\n'
    if c == ']' and c2 == ']'
      found_close? = true
    else if c == '\n' or c == '\r' or c == '['
      j = max_end
    else
      inner_chars = inner_chars.append(c)
      j = j + 1
    end
  end
  if not found_close?
    return None
  end
  inner = Text.from_chars(inner_chars)
  case parse_entity_ref_inner(inner)
    Some((kind, id)): Some((kind, id, "[[#{inner.trim}]]", j + 2))
    None: None
  end
end

fn parse_at_entity_ref(chars: List(Char), at_idx: Int) : Option((Text, Text, Text, Int))
  if at_idx > 0
    prev = chars.get(at_idx - 1) or ' '
    if is_ref_id_char?(prev)
      return None
    end
  end
  var k = at_idx + 1
  var pfx_chars = []
  while k < chars.size and (chars.get(k) or ' ').ascii_letter?
    pfx_chars = pfx_chars.append(chars.get(k) or ' ')
    k = k + 1
  end
  if chars.get(k) != Some(':')
    return None
  end
  pfx = Text.from_chars(pfx_chars).ascii_lowercase
  is_supported? = pfx == "page" or pfx == "row" or pfx == "task" or pfx == "proposal" or pfx == "thread"
  if not is_supported?
    return None
  end
  norm_kind = if pfx == "task"
    "row"
  else
    pfx
  end
  var m = k + 1
  var part1 = []
  while m < chars.size and is_ref_id_char?(chars.get(m) or ' ')
    part1 = part1.append(chars.get(m) or ' ')
    m = m + 1
  end
  if part1.empty?
    return None
  end
  if norm_kind == "thread"
    if chars.get(m) != Some(':')
      return None
    end
    m = m + 1
    var part2 = []
    while m < chars.size and is_ref_id_char?(chars.get(m) or ' ')
      part2 = part2.append(chars.get(m) or ' ')
      m = m + 1
    end
    if part2.empty?
      return None
    end
    id = "#{Text.from_chars(part1)}:#{Text.from_chars(part2)}"
    return Some((norm_kind, id, "@#{pfx}:#{id}", m))
  end
  id = Text.from_chars(part1)
  Some((norm_kind, id, "@#{pfx}:#{id}", m))
end

## Extracts unique inline entity citations (`[[page:...]]`, `[[pg_...]]`, `[[row:...]]`, `[[task:...]]`,
## `[[proposal:...]]`, `[[thread:...:...]]`, and `@page:...`/`@row:...`/`@task:...`/`@proposal:...`/`@thread:...:...`)
## capped at 20 references per message.
fn extract_entity_refs(body: Text) : List(Json)
  chars = body.chars
  var out = []
  var seen = []
  var i = 0
  while i < chars.size and out.size < 20
    c = chars.get(i) or ' '
    if c == '[' and chars.get(i + 1) == Some('[')
      case parse_bracket_entity_ref(chars, i)
        Some((kind, id, raw, next_i)):
          (out2, seen2) = try_append_entity_ref(out, seen, kind, id, raw)
          out = out2
          seen = seen2
          i = next_i
        None: i = i + 1
      end
    else if c == '@'
      case parse_at_entity_ref(chars, i)
        Some((kind, id, raw, next_i)):
          (out2, seen2) = try_append_entity_ref(out, seen, kind, id, raw)
          out = out2
          seen = seen2
          i = next_i
        None: i = i + 1
      end
    else
      i = i + 1
    end
  end
  out
end

fn extract_mentions(body: Text) : List(Text)
  chars = body.chars
  var out = []
  var i = 0
  while i < chars.size
    if chars.get(i) == Some('@')
      prev_blocked? = if i == 0
        false
      else
        case chars.get(i - 1)
          Some(p): is_mention_prefix_blocker?(p)
          None: false
        end
      end
      if not prev_blocked?
        var j = i + 1
        var h_chars = []
        while j < chars.size
          case chars.get(j)
            Some(c) if is_mention_body_char?(c):
              h_chars = h_chars.append(c)
              j += 1
            Some(_) | None: break
          end
        end
        while not h_chars.empty? and (h_chars.last == Some('.') or h_chars.last == Some('-'))
          h_chars = h_chars.take(h_chars.size - 1)
        end
        if not h_chars.empty? and h_chars.any?(fn(c) c.ascii_letter? or c.ascii_digit? end)
          norm = Text.from_chars(h_chars).ascii_lowercase
          next_is_colon? = chars.get(j) == Some(':')
          is_entity_prefix? = next_is_colon? and (
            norm == "page" or norm == "row" or norm == "task" or norm == "proposal" or norm == "thread"
          )
          if not is_entity_prefix? and not out.contains?(norm)
            out = out.append(norm)
          end
        end
        i = j
      else
        i += 1
      end
    else
      i += 1
    end
  end
  out
end

## Builds a compact single-line preview for Calm Inbox items (capped at 140 chars).
fn msg_preview(body: Text) : Text
  single = body.trim.replace("\r\n", " ").replace("\n", " ").replace("\r", " ").trim
  if single.empty?
    "(attachment)"
  else
    chars = single.chars
    if chars.size <= 140
      single
    else
      "#{Text.from_chars(chars.take(137))}..."
    end
  end
end

## Extracts optional `collection_id` from a serialized channel JSON record.
fn channel_collection_id(ch: Json) : Option(Text)
  case ch.text_at("collection_id")
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
end

## Returns `true` iff `auth` is permitted to perform `action` on chat channel `ch`.
fn can_access_channel?(auth: AuthContext, ch: Json, action: Text) : Bool
  return false if auth.principal.suspended
  return false if not Policy.action_permitted?(auth, action)
  kind = ch.text_at("kind") or ""
  if kind == "dm"
    VaultOps.json_string_list(ch, "member_principal_ids").contains?(auth.principal.id)
  else if kind == "public"
    case channel_collection_id(ch)
      Some(cid): Policy.collection_permitted?(auth, cid)
      None: false
    end
  else if kind == "private"
    case channel_collection_id(ch)
      Some(cid):
        Policy.collection_permitted?(auth, cid) and
          VaultOps.json_string_list(ch, "member_principal_ids").contains?(auth.principal.id)
      None: false
    end
  else
    false
  end
end

## Fails closed with typed `Forbidden` if `auth` cannot perform `action` on `ch`.
fn require_channel_access(auth: AuthContext, ch: Json, action: Text) : Result(Unit, AppError)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  kind = ch.text_at("kind") or ""
  ch_id = ch.text_at("id") or ""
  if kind == "dm"
    if not Policy.action_permitted?(auth, action)
      return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit '#{action}'"))
    end
    if not VaultOps.json_string_list(ch, "member_principal_ids").contains?(auth.principal.id)
      return Error(Forbidden(reason: "principal is not a participant of DM '#{ch_id}'"))
    end
    Ok(Unit)
  else if kind == "public" or kind == "private"
    cid = case channel_collection_id(ch)
      Some(c): c
      None: return Error(Forbidden(reason: "channel '#{ch_id}' lacks a collection scope"))
    end
    try Policy.require_collection_access(auth, action, cid)
    if kind == "private" and not VaultOps.json_string_list(ch, "member_principal_ids").contains?(
      auth.principal.id
    )
      return Error(Forbidden(reason: "principal is not a member of private channel '#{ch_id}'"))
    end
    Ok(Unit)
  else
    Error(Forbidden(reason: "unsupported channel kind '#{kind}'"))
  end
end

fn msg_key(ch_id: Text, msg_id: Text) : Text
  "#{ch_id}:#{msg_id}"
end

fn idempotency_key(ch_id: Text, principal_id: Text, client_msg_id: Text) : Text
  "#{ch_id}:#{principal_id}:#{client_msg_id}"
end

fn read_cursor_key(principal_id: Text, ch_id: Text) : Text
  "#{principal_id}:#{ch_id}"
end

fn inbox_key(recipient_id: Text, notif_id: Text) : Text
  "#{recipient_id}:#{notif_id}"
end

## Fetches a single channel JSON record from `Store`.
fn get_channel(store: Store, id: Text) : Result(Option(Json), AppError)
  raw_opt = try Modb.get(store, channels_bucket, id.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  case raw_opt
    Some(b): Ok(parse_bytes_json(b))
    None: Ok(None)
  end
end

## Fetches a single channel JSON record inside `WriteTx`.
fn tx_get_channel(tx: WriteTx, id: Text) : Result(Option(Json), AppError)
  VaultOps.tx_get_json(tx, channels_bucket, id)
end

## Scans all channels in deterministic order.
fn list_all_channels(store: Store) : Result(List(Json), AppError)
  rows = try Modb.scan(store, channels_bucket, None, None, 0).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j): out = out.append(j)
      None: Unit
    end
  end
  Ok(
    out.sort_by(fn(c)
      k = c.text_at("kind") or ""
      ord = if k == "public": "0" else if k == "private": "1" else: "2"
      "#{ord}|#{c.text_at("slug") or ""}|#{c.text_at("id") or ""}"
    end)
  )
end

## Persists a channel JSON record inside `WriteTx`.
fn tx_put_channel(tx: WriteTx, ch_id: Text, ch: Json) : Result(WriteTx, AppError)
  VaultOps.tx_put_json(tx, channels_bucket, ch_id, ch)
end

## Returns an existing active 1:1 DM matching `member_ids` (order-independent) if present.
fn find_existing_dm(store: Store, member_ids: List(Text)) : Result(Option(Json), AppError)
  target_sorted = member_ids.sort_by(fn(x) x end)
  all_ch = try list_all_channels(store)
  for ch in all_ch
    if ch.text_at("kind") == Some("dm") and ch.text_at("archived_at") == None
      ch_members = VaultOps.json_string_list(ch, "member_principal_ids").sort_by(fn(x) x end)
      if ch_members == target_sorted
        return Ok(Some(ch))
      end
    end
  end
  Ok(None)
end

## Fetches a single message JSON record by `(ch_id, msg_id)` from `Store`.
fn get_message(store: Store, ch_id: Text, msg_id: Text) : Result(Option(Json), AppError)
  raw_opt = try Modb.get(store, messages_bucket, msg_key(ch_id, msg_id).bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  case raw_opt
    Some(b): Ok(parse_bytes_json(b))
    None: Ok(None)
  end
end

## Fetches a single message JSON record by `(ch_id, msg_id)` inside `WriteTx`.
fn tx_get_message(tx: WriteTx, ch_id: Text, msg_id: Text) : Result(Option(Json), AppError)
  VaultOps.tx_get_json(tx, messages_bucket, msg_key(ch_id, msg_id))
end

## Persists a message JSON record inside `WriteTx`.
fn tx_put_message(tx: WriteTx, ch_id: Text, msg_id: Text, msg: Json) : Result(WriteTx, AppError)
  VaultOps.tx_put_json(tx, messages_bucket, msg_key(ch_id, msg_id), msg)
end

## Scans all messages inside `ch_id` in chronological order (`[ch_id:, ch_id;)` prefix scan).
fn scan_channel_raw_messages(store: Store, ch_id: Text) : Result(List(Json), AppError)
  lo = Some("#{ch_id}:".bytes)
  hi = Some("#{ch_id};".bytes)
  rows = try Modb.scan(store, messages_bucket, lo, hi, 0).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j) if j.text_at("channel_id") == Some(ch_id): out = out.append(j)
      Some(_) | None: Unit
    end
  end
  Ok(out)
end

## Cursor-paginates channel root messages or side-thread replies (`(window, has_more, reply_counts)`).
fn scan_channel_messages_window(
  store: Store,
  ch_id: Text,
  before_opt: Option(Text),
  after_opt: Option(Text),
  parent_opt: Option(Text),
  decisions_only?: Bool,
  limit: Int
) : Result((List(Json), Bool, Map(Text, Int)), AppError)
  all_msgs = try scan_channel_raw_messages(store, ch_id)
  var reply_counts = {}
  for m in all_msgs
    if m.text_at("deleted_at") == None
      case m.text_at("parent_message_id")
        Some(pid) if not pid.empty?:
          prev = reply_counts.get(pid) or 0
          reply_counts = reply_counts.set(pid, prev + 1)
        Some(_) | None: Unit
      end
    end
  end

  before_clean = case before_opt
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
  after_clean = case after_opt
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
  parent_clean = case parent_opt
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end

  var filtered = []
  for m in all_msgs
    mid = m.text_at("id") or ""
    p_match? = case parent_clean
      Some(pid): m.text_at("parent_message_id") == Some(pid)
      None: m.text_at("parent_message_id") == None
    end
    continue if not p_match?
    if decisions_only?
      continue if m.bool_at("is_decision") != Some(true)
      continue if m.text_at("deleted_at") != None
    end
    case before_clean
      Some(b): continue if mid >= b
      None: Unit
    end
    case after_clean
      Some(a): continue if mid <= a
      None: Unit
    end
    filtered = filtered.append(m)
  end

  lim = if limit < 1: 1 else if limit > 100: 100 else: limit
  has_more? = filtered.size > lim
  window = if not has_more?
    filtered
  else if after_clean != None and before_clean == None
    filtered.take(lim)
  else
    filtered.drop(filtered.size - lim)
  end
  Ok((window, has_more?, reply_counts))
end

## Scans all messages across the workspace (`limit <= 0` for unbounded).
fn scan_all_messages(store: Store, limit: Int) : Result(List(Json), AppError)
  rows = try Modb.scan(store, messages_bucket, None, None, limit).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j): out = out.append(j)
      None: Unit
    end
  end
  Ok(out)
end

## Scans all messages inside a `WriteTx` (`limit <= 0` for unbounded).
fn tx_scan_all_messages(tx: WriteTx, limit: Int) : Result(List(Json), AppError)
  VaultOps.tx_scan_json(tx, messages_bucket, limit)
end

## Looks up a previously committed message ID for an idempotent `client_msg_id`.
fn tx_lookup_idempotency(
  tx: WriteTx,
  ch_id: Text,
  principal_id: Text,
  client_msg_id: Text
) : Result(Option(Text), AppError)
  key = idempotency_key(ch_id, principal_id, client_msg_id)
  raw_opt = try Modb.tx_get(tx, idempotency_bucket, key.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  case raw_opt
    Some(b):
      case b.decode_utf8
        Some(mid) if not mid.trim.empty?: Ok(Some(mid.trim))
        Some(_) | None: Ok(None)
      end
    None: Ok(None)
  end
end

## Persists an idempotent `(ch_id, principal_id, client_msg_id) -> msg_id` record inside `WriteTx`.
fn tx_put_idempotency(
  tx: WriteTx,
  ch_id: Text,
  principal_id: Text,
  client_msg_id: Text,
  msg_id: Text
) : Result(WriteTx, AppError)
  key = idempotency_key(ch_id, principal_id, client_msg_id)
  Modb.tx_put(tx, idempotency_bucket, key.bytes, msg_id.bytes).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
end

## Reads a principal's per-channel read cursor JSON record.
fn get_read_cursor(store: Store, principal_id: Text, ch_id: Text) : Result(Option(Json), AppError)
  raw_opt = try Modb.get(store, reads_bucket, read_cursor_key(principal_id, ch_id).bytes)
    .map_error(fn(e) ServerFailed(reason: e.to_text) end)
  case raw_opt
    Some(b): Ok(parse_bytes_json(b))
    None: Ok(None)
  end
end

## Persists a principal's per-channel read cursor inside `WriteTx`.
fn tx_put_read_cursor(
  tx: WriteTx,
  principal_id: Text,
  ch_id: Text,
  cursor: Json
) : Result(WriteTx, AppError)
  VaultOps.tx_put_json(tx, reads_bucket, read_cursor_key(principal_id, ch_id), cursor)
end

## Counts unread active root messages posted by other principals since `last_read_message_id`.
fn count_channel_unread(store: Store, principal_id: Text, ch_id: Text) : Result(Int, AppError)
  cursor_opt = try get_read_cursor(store, principal_id, ch_id)
  last_id_opt = case cursor_opt
    Some(cur):
      case cur.text_at("last_read_message_id")
        Some(s) if not s.trim.empty?: Some(s.trim)
        Some(_) | None: None
      end
    None: None
  end
  msgs = try scan_channel_raw_messages(store, ch_id)
  var cnt = 0
  for m in msgs
    if m.text_at("deleted_at") == None and m.text_at("parent_message_id") == None and
      m.text_at("author_id") != Some(principal_id)
      mid = m.text_at("id") or ""
      unread? = case last_id_opt
        Some(lr): mid > lr
        None: true
      end
      if unread?
        cnt += 1
      end
    end
  end
  Ok(cnt)
end

## Lists inbox notifications for `recipient_id` newest-first.
fn list_inbox(store: Store, recipient_id: Text, unread_only?: Bool, limit: Int) : Result(
  List(Json),
  AppError
)
  lo = Some("#{recipient_id}:".bytes)
  hi = Some("#{recipient_id};".bytes)
  rows = try Modb.scan(store, inbox_bucket, lo, hi, 0).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  lim = if limit < 1: 1 else if limit > 200: 200 else: limit
  var items = []
  for (_k, v) in rows.reverse
    case parse_bytes_json(v)
      Some(j) if j.text_at("recipient_principal_id") == Some(recipient_id):
        if not unread_only? or j.text_at("read_at") == None
          items = items.append(j)
          break if items.size >= lim
        end
      Some(_) | None: Unit
    end
  end
  Ok(items)
end

## Counts unread Calm Inbox items for `recipient_id`.
fn unread_inbox_count(store: Store, recipient_id: Text) : Result(Int, AppError)
  lo = Some("#{recipient_id}:".bytes)
  hi = Some("#{recipient_id};".bytes)
  rows = try Modb.scan(store, inbox_bucket, lo, hi, 0).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var cnt = 0
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j) if j.text_at("recipient_principal_id") == Some(recipient_id) and
        j.text_at("read_at") == None:
        cnt += 1
      Some(_) | None: Unit
    end
  end
  Ok(cnt)
end

## Persists an inbox notification inside `WriteTx`.
fn tx_put_inbox(
  tx: WriteTx,
  recipient_id: Text,
  notif_id: Text,
  item: Json
) : Result(WriteTx, AppError)
  VaultOps.tx_put_json(tx, inbox_bucket, inbox_key(recipient_id, notif_id), item)
end

## Scans one recipient's inbox notifications inside `WriteTx`.
fn tx_scan_inbox(tx: WriteTx, recipient_id: Text, limit: Int) : Result(List(Json), AppError)
  lo = Some("#{recipient_id}:".bytes)
  hi = Some("#{recipient_id};".bytes)
  rows = try Modb.tx_scan(tx, inbox_bucket, lo, hi, limit).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (_k, v) in rows
    case parse_bytes_json(v)
      Some(j) if j.text_at("recipient_principal_id") == Some(recipient_id): out = out.append(j)
      Some(_) | None: Unit
    end
  end
  Ok(out)
end

## Scans all inbox items across all recipients inside `WriteTx` (for `Modb.Erasure` scrubbing).
fn tx_scan_all_inbox(tx: WriteTx, limit: Int) : Result(List(Json), AppError)
  VaultOps.tx_scan_json(tx, inbox_bucket, limit)
end

## Searches ACL-visible chat messages newest-first across allowed channels and collections.
fn search_visible_messages(
  store: Store,
  auth: AuthContext,
  query: Text,
  channel_id_opt: Option(Text),
  col_id_opt: Option(Text),
  decisions_only?: Bool,
  limit: Int
) : Result(List(Json), AppError)
  return Ok([]) if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
  q_low = query.trim.ascii_lowercase
  return Ok([]) if q_low.empty? and not decisions_only?

  all_ch = try list_all_channels(store)
  var visible_chs = {}
  for ch in all_ch
    continue if ch.text_at("archived_at") != None
    continue if not can_access_channel?(auth, ch, "read")
    cid = ch.text_at("id") or ""
    case channel_id_opt
      Some(filter_ch) if not filter_ch.trim.empty?: continue if cid != filter_ch.trim
      Some(_) | None: Unit
    end
    case col_id_opt
      Some(filter_col) if not filter_col.trim.empty?:
        continue if ch.text_at("collection_id") != Some(filter_col.trim)
      Some(_) | None: Unit
    end
    visible_chs = visible_chs.set(cid, ch)
  end

  lim = if limit < 1: 1 else if limit > 100: 100 else: limit
  var all_hits = []
  for (_cid, ch) in visible_chs.entries
    cid = ch.text_at("id") or ""
    cname = ch.text_at("name") or cid
    ckind = ch.text_at("kind") or "public"
    ccol = ch.get("collection_id") or Json.Null
    msgs = try scan_channel_raw_messages(store, cid)
    for m in msgs
      continue if m.text_at("deleted_at") != None
      if decisions_only?
        continue if m.bool_at("is_decision") != Some(true)
      end
      body = m.text_at("body_markdown") or ""
      body_low = body.ascii_lowercase
      if q_low.empty? or body_low.contains?(q_low)
        all_hits = all_hits.append(
          Json.Object({
            "message_id": Json.String(m.text_at("id") or ""),
            "channel_id": Json.String(cid),
            "channel_name": Json.String(cname),
            "channel_kind": Json.String(ckind),
            "collection_id": ccol,
            "parent_message_id": m.get("parent_message_id") or Json.Null,
            "author_handle": Json.String(m.text_at("author_handle") or ""),
            "snippet": Json.String(msg_preview(body)),
            "is_decision": Json.Boolean(m.bool_at("is_decision") or false),
            "created_at": m.get("created_at") or Json.Null
          })
        )
      end
    end
  end

  sorted = all_hits.sort_by(fn(h) h.text_at("message_id") or "" end).reverse
  Ok(sorted.take(lim))
end
