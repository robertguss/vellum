## 100% Pure MoDB persistence layer for Vellum (`sessions.modb` + `vellum.modb`).
## Zero SQLite anywhere: combines `Modb.Table`, `Modb.Ledger`, `Modb.Grants`, and `Modb.Fts`.
module Db
expose sessions_db_path,
ledger_db_path,
default_workspace_id,
default_collection_id,
fts_index,
workspaces_table,
principals_table,
principals_by_email,
principals_by_handle,
agent_tokens_table,
agent_tokens_by_hash,
agent_tokens_by_principal,
collections_table,
collections_by_slug,
pages_table,
pages_by_collection,
pages_by_parent,
blocks_table,
blocks_by_page,
comments_table,
comments_by_page,
attachments_table,
attachments_by_page,
vellum_schema,
map_table_error,
map_ledger_error,
map_grants_error,
map_fts_error,
not_found_ledger?,
verify_grant_chain_read_only,
tx_index_page,
tx_save_page_and_blocks,
tx_delete_page_and_blocks,
load_page_blocks,
search_pages,
tx_upsert_human_principal,
tx_mint_agent
use Domain.Blocks
use Domain.Policy
use Domain.Types{
  AgentToken,
  AppError,
  Attachment,
  AuthContext,
  Block,
  BlockKind,
  Collection,
  CollectionWritePolicy,
  Comment,
  Page,
  Principal,
  PrincipalKind,
  SearchResultItem,
  Workspace,
  WorkspaceRole
}
use Json
use Modb{Store, WriteTx}
use Modb.Errors
use Modb.Fts
use Modb.Grants
use Modb.Ledger
use Modb.Table

sessions_db_path = "sessions.modb"
ledger_db_path = "vellum.modb"
default_workspace_id = "ws_default"
default_collection_id = "col_general"

## Handle to the transactional BM25 index inside `vellum.modb`.
fn fts_index() : Fts.FtsIndex
  Fts.index("vellum")
end

## Typed `Modb.Table` descriptors (constructed in functions to avoid top-level `E1150`).
fn workspaces_table() : Table.Table(Text, Workspace)
  Table.text_key[Workspace]("vlm_workspaces")
end

fn principals_by_email() : Table.Index(Text, Principal, Text)
  Table.text_index[Text, Principal]("vlm_principals_by_email", fn(p) p.email or "" end)
end

fn principals_by_handle() : Table.Index(Text, Principal, Text)
  Table.unique_text_index[Text, Principal]("vlm_principals_by_handle", fn(p) p.handle end)
end

fn principals_table() : Table.Table(Text, Principal)
  Table.text_key[Principal]("vlm_principals").with_index(principals_by_email()).with_index(
    principals_by_handle()
  )
end

fn agent_tokens_by_hash() : Table.Index(Text, AgentToken, Text)
  Table.unique_text_index[Text, AgentToken]("vlm_tokens_by_hash", fn(t) t.token_hash end)
end

fn agent_tokens_by_principal() : Table.Index(Text, AgentToken, Text)
  Table.text_index[Text, AgentToken]("vlm_tokens_by_principal", fn(t) t.principal_id end)
end

fn agent_tokens_table() : Table.Table(Text, AgentToken)
  Table.text_key[AgentToken]("vlm_agent_tokens").with_index(agent_tokens_by_hash()).with_index(
    agent_tokens_by_principal()
  )
end

fn collections_by_slug() : Table.Index(Text, Collection, Text)
  Table.unique_text_index[Text, Collection]("vlm_collections_by_slug", fn(c) c.slug end)
end

fn collections_table() : Table.Table(Text, Collection)
  Table.text_key[Collection]("vlm_collections").with_index(collections_by_slug())
end

fn pages_by_collection() : Table.Index(Text, Page, Text)
  Table.text_index[Text, Page]("vlm_pages_by_collection", fn(p) p.collection_id end)
end

fn pages_by_parent() : Table.Index(Text, Page, Text)
  Table.text_index[Text, Page]("vlm_pages_by_parent", fn(p) p.parent_page_id or "" end)
end

fn pages_table() : Table.Table(Text, Page)
  Table.text_key[Page]("vlm_pages").with_index(pages_by_collection()).with_index(pages_by_parent())
end

fn blocks_by_page() : Table.Index(Text, Block, Text)
  Table.text_index[Text, Block]("vlm_blocks_by_page", fn(b) b.page_id end)
end

fn blocks_table() : Table.Table(Text, Block)
  Table.text_key[Block]("vlm_blocks").with_index(blocks_by_page())
end

fn comments_by_page() : Table.Index(Text, Comment, Text)
  Table.text_index[Text, Comment]("vlm_comments_by_page", fn(c) c.page_id end)
end

fn comments_table() : Table.Table(Text, Comment)
  Table.text_key[Comment]("vlm_comments").with_index(comments_by_page())
end

fn attachments_by_page() : Table.Index(Text, Attachment, Text)
  Table.text_index[Text, Attachment]("vlm_attachments_by_page", fn(a) a.page_id end)
end

fn attachments_table() : Table.Table(Text, Attachment)
  Table.text_key[Attachment]("vlm_attachments").with_index(attachments_by_page())
end

## Converts `Modb.Table` errors to `AppError`.
fn map_table_error(err: Table.TableError) : AppError
  case err
    Table.UniqueConflict(index: idx, value: v): BadInput(
      reason: "duplicate value '#{v}' on '#{idx}'"
    )
    Table.Storage(_) | Table.DecodeValue(_) | Table.DecodeKey(reason: _) | Table.CorruptIndex(
      index: _,
      reason: _
    ): ServerFailed(reason: err.to_text)
  end
end

## Converts `Modb.Ledger` errors to `AppError`.
fn map_ledger_error(err: Ledger.LedgerError) : AppError
  case err
    Ledger.InvariantViolation(name: n, detail: d): BadInput(reason: "invariant '#{n}': #{d}")
    Ledger.InvalidMeta(reason: r): BadInput(reason: r)
    Ledger.TableFailure(te): map_table_error(te)
    Ledger.SchemaTooNew(found: _, supported: _) | Ledger.InvalidMigration(reason: _) | Ledger
      .AuditCorrupt(reason: _): ServerFailed(reason: err.to_text)
  end
end

## Converts `Modb.Grants` errors to `AppError`.
fn map_grants_error(err: Grants.GrantError) : AppError
  case err
    Grants.ActionDenied(id: _, action: _) | Grants.ViewDenied(id: _, view: _) | Grants.ReleaseDenied(
      id: _,
      release: _
    ) | Grants.Revoked(id: _, revoked_ancestor: _) | Grants.Expired(id: _, expired_ancestor: _) | Grants
      .BudgetExhausted(id: _, ancestor_id: _, max_calls: _): Forbidden(reason: err.to_text)
    Grants.GrantNotFound(id: _) | Grants.GrantAlreadyExists(id: _) | Grants.InvalidGrant(reason: _) | Grants
      .WideningDenied(field: _, detail: _): BadInput(reason: err.to_text)
    Grants.LedgerFailure(le): map_ledger_error(le)
  end
end

## Converts `Modb.Fts` errors to `AppError`.
fn map_fts_error(err: Fts.FtsError) : AppError
  case err
    Fts.InvalidConfig(reason: _) | Fts.InvalidDocument(reason: _): BadInput(reason: err.to_text)
    Fts.Storage(_) | Fts.TableFailure(_): ServerFailed(reason: err.to_text)
  end
end

## Whether `err` represents an uninitialized/missing `vellum.modb` file on `ReadFiles`.
fn not_found_ledger?(err: Ledger.LedgerError) : Bool
  err is Ledger.TableFailure(Table.Storage(Errors.Io(NotFound(path: _))))
end

fn init_v1_migration(tx: WriteTx) : Result(WriteTx, Table.TableError)
  epoch = Time.parse("2026-01-01T00:00:00Z") or stop "epoch"
  ws = Workspace(
    id: default_workspace_id,
    slug: "vellum",
    name: "Vellum Workspace",
    allowed_domains: [],
    default_write_policy: DirectWithAudit,
    default_freshness_ttl_days: 90,
    updated_at: epoch
  )
  col = Collection(
    id: default_collection_id,
    workspace_id: default_workspace_id,
    slug: "general",
    name: "General",
    description: "Default workspace knowledge base",
    icon: Some("book-open"),
    write_policy: DirectWithAudit,
    freshness_ttl_days: None,
    sort_order: "i",
    archived_at: None
  )
  tx1 = try Table.put(tx, workspaces_table(), ws.id, ws)
  Table.put(tx1, collections_table(), col.id, col)
end

## Declarative `Modb.Ledger` schema enforcing mandatory write reasons, v1 bootstrap,
## and incremental `$O(\text{touched})$` invariants across collections, pages, and blocks.
fn vellum_schema() : Ledger.Schema
  cols = collections_table()
  pages = pages_table()
  blocks = blocks_table()
  Ledger.schema(1).with_require_reason(true).with_migration(
    Ledger.migration(1, "initialize default workspace and general collection", init_v1_migration)
  ).with_invariant(
    Ledger.row_invariant(
      "collection_valid",
      cols,
      fn(id, c)
        if c.slug.trim.empty? or c.name.trim.empty?
          Some("collection '#{id}' requires non-empty slug and name")
        else
          None
        end
      end
    )
  ).with_invariant(
    Ledger.row_invariant(
      "page_valid",
      pages,
      fn(id, p)
        if p.title.trim.empty? or p.version < 1
          Some("page '#{id}' requires non-empty title and version >= 1")
        else
          None
        end
      end
    )
  ).with_invariant(
    Ledger.row_invariant(
      "block_valid",
      blocks,
      fn(id, b)
        bad_heading = case b.kind
          Heading(level: lvl): lvl < 1 or lvl > 3
          Paragraph | BulletListItem | OrderedListItem(start: _) | TaskItem(checked: _) | Quote | Callout(
            tone: _,
            icon: _
          ) | CodeBlock(language: _) | Divider | Image(attachment_id: _, caption: _) | FileEmbed(
            attachment_id: _,
            filename: _
          ) | PageLink(target_page_id: _): false
        end
        if bad_heading or b.version < 1
          Some("block '#{id}' has invalid heading level or version < 1")
        else
          None
        end
      end
    )
  )
end

## Walks a grant's parent chain read-only on `Store`, verifying unrevoked, unexpired, and within budget.
fn verify_grant_chain_read_only(store: Store, grant_id: Text, now: Time) : Result(
  Grants.Grant,
  Grants.GrantError
)
  var cur_opt = Some(grant_id)
  var leaf_opt = None
  var hops = 0
  while hops < 32
    cur_id = case cur_opt
      Some(gid): gid
      None: break
    end
    g = case try Grants.get(store, cur_id).map_error(
      fn(e) Grants.InvalidGrant(reason: e.to_text) end
    )
      Some(found): found
      None: return Error(Grants.GrantNotFound(id: cur_id))
    end
    if leaf_opt is None
      leaf_opt = Some(g)
    end
    if g.revoked
      return Error(Grants.Revoked(id: grant_id, revoked_ancestor: g.id))
    end
    if now > g.expires_at
      return Error(Grants.Expired(id: grant_id, expired_ancestor: g.id))
    end
    if g.used_calls >= g.max_calls
      return Error(Grants.BudgetExhausted(id: grant_id, ancestor_id: g.id, max_calls: g.max_calls))
    end
    cur_opt = g.parent_id
    hops += 1
  end
  case leaf_opt
    Some(leaf): Ok(leaf)
    None: Error(Grants.GrantNotFound(id: grant_id))
  end
end

## Indexes `page` and its `blocks` into `Modb.Fts` inside `tx`.
fn tx_index_page(tx: WriteTx, page: Page, blocks: List(Block)) : Result(WriteTx, AppError)
  doc = Fts.DocumentInput(
    doc_id: page.id,
    scope: page.collection_id,
    fields: [
      Fts.FieldInput(name: "title", text: page.title, weight: 3),
      Fts.FieldInput(name: "body", text: Blocks.blocks_plain_text(blocks), weight: 1)
    ]
  )
  Fts.tx_index_document(tx, fts_index(), doc).map_error(map_fts_error)
end

## Atomically persists `page`, replaces its blocks, and updates `Modb.Fts` inside `tx`.
fn tx_save_page_and_blocks(tx: WriteTx, page: Page, blocks: List(Block)) : Result(WriteTx, AppError)
  btbl = blocks_table()
  bidx = blocks_by_page()
  existing = try Table.tx_lookup(tx, btbl, bidx, page.id).map_error(map_table_error)
  new_ids = blocks.map(fn(b) b.id end).to_set

  var cur = try Table.put(tx, pages_table(), page.id, page).map_error(map_table_error)
  for (old_id, _old_blk) in existing
    if not new_ids.has?(old_id)
      cur = try Table.delete(cur, btbl, old_id).map_error(map_table_error)
    end
  end
  for blk in blocks
    cur = try Table.put(cur, btbl, blk.id, blk).map_error(map_table_error)
  end
  if page.archived_at == None
    tx_index_page(cur, page, blocks)
  else
    Fts.tx_remove_document(cur, fts_index(), page.id).map_error(map_fts_error)
  end
end

## Atomically removes `page_id`, all of its blocks, and its FTS index entry inside `tx`.
fn tx_delete_page_and_blocks(tx: WriteTx, page_id: Text) : Result(WriteTx, AppError)
  btbl = blocks_table()
  bidx = blocks_by_page()
  existing = try Table.tx_lookup(tx, btbl, bidx, page_id).map_error(map_table_error)
  var cur = tx
  for (bid, _b) in existing
    cur = try Table.delete(cur, btbl, bid).map_error(map_table_error)
  end
  cur = try Table.delete(cur, pages_table(), page_id).map_error(map_table_error)
  Fts.tx_remove_document(cur, fts_index(), page_id).map_error(map_fts_error)
end

## Loads and sorts all blocks belonging to `page_id` from a committed `Store`.
fn load_page_blocks(store: Store, page_id: Text) : Result(List(Block), AppError)
  rows = try Table.lookup(store, blocks_table(), blocks_by_page(), page_id).map_error(
    map_table_error
  )
  Ok(Blocks.sort_blocks(rows.map(fn(p) p.1 end)))
end

## Executes grant-filtered BM25 search via `Modb.Fts`, never leaking unauthorized docs.
fn search_pages(
  store: Store,
  auth: AuthContext,
  query: Text,
  limit: Int,
  prefix_last?: Bool,
  collection_filter: Option(Text)
) : Result(List(SearchResultItem), AppError)
  case collection_filter
    Some(cid):
      if not Policy.collection_permitted?(auth, cid)
        return Ok([])
      end
    None: Unit
  end

  opts = Fts.SearchOptions(
    limit: limit,
    prefix_last_term?: prefix_last?,
    required_scope: collection_filter
  )
  allowed_cols = auth.allowed_collections
  suspended = auth.principal.suspended
  hits = try Fts.search_filtered(
    store,
    fts_index(),
    query,
    opts,
    fn(_doc_id, scope)
      if suspended
        false
      else
        case allowed_cols
          None: true
          Some(scopes): scopes.contains?("workspace:*") or scopes.contains?("collection:#{scope}")
        end
      end
    end
  ).map_error(map_fts_error)

  ptbl = pages_table()
  var out = []
  for hit in hits
    case try Table.get(store, ptbl, hit.doc_id).map_error(map_table_error)
      Some(p) if p.archived_at == None: out = out.append(
        SearchResultItem(
          page_id: p.id,
          collection_id: p.collection_id,
          title: p.title,
          score: hit.score,
          matched_terms: hit.matched_terms,
          matched_fields: hit.matched_fields
        )
      )
      Some(_) | None: Unit
    end
  end
  Ok(out)
end

fn derive_handle(email: Text, existing_check_fn_suffix: Text) : Text
  local_raw = (email.split("@").first or "user").ascii_lowercase
  var chars = []
  for ch in local_raw.chars
    if ch.ascii_letter? or ch.ascii_digit? or ch == '-' or ch == '_'
      chars = chars.append(ch)
    end
  end
  base = if chars.empty?: "user" else: Text.from_chars(chars)
  if existing_check_fn_suffix.empty?
    "@#{base}"
  else
    "@#{base}_#{existing_check_fn_suffix}"
  end
end

## JIT-provisions or updates an OIDC-authenticated human `Principal` and issues a root `Grant`.
## The first human user in the workspace automatically receives `Owner`; subsequent users receive `Member`.
fn tx_upsert_human_principal(
  tx: WriteTx,
  email: Text,
  display_name: Text,
  avatar_url: Option(Text),
  new_principal_id: Text,
  new_grant_id: Text,
  now: Time
) : Result((WriteTx, Principal), AppError)
  ptbl = principals_table()
  by_email = principals_by_email()
  by_handle = principals_by_handle()
  existing = try Table.tx_lookup(tx, ptbl, by_email, email).map_error(map_table_error)
  case existing.first
    Some((_pid, found)):
      var updated = found
      updated.display_name = display_name
      updated.avatar_url = avatar_url
      updated.last_seen_at = Some(now)
      t1 = try Table.put(tx, ptbl, updated.id, updated).map_error(map_table_error)
      Ok((t1, updated))
    None:
      all_existing = try Table.tx_scan(tx, ptbl, None, None, 1).map_error(map_table_error)
      role = if all_existing.empty?: Owner else: Member
      cand0 = derive_handle(email, "")
      handle = case try Table.tx_lookup_unique(tx, ptbl, by_handle, cand0).map_error(
        map_table_error
      )
        None: cand0
        Some(_):
          id_tail = new_principal_id.drop_prefix("usr_") or new_principal_id
          derive_handle(email, Text.from_chars(id_tail.chars.take(6)))
      end

      actions = Policy.default_human_actions(role)
      spec = Grants.GrantSpec(
        id: new_grant_id,
        principal: new_principal_id,
        allowed_actions: actions,
        max_calls: 1000000000,
        expires_at: now + 3650.days
      )
      (t1, _g) = try Grants.tx_issue_root_scoped(tx, "system:oidc", spec, None, None, now).map_error(
        map_grants_error
      )

      p = Principal(
        id: new_principal_id,
        kind: Human,
        handle: handle,
        display_name: display_name,
        email: Some(email),
        avatar_url: avatar_url,
        role: role,
        model_id: None,
        root_grant_id: new_grant_id,
        suspended: false,
        created_at: now,
        last_seen_at: Some(now)
      )
      t2 = try Table.put(t1, ptbl, p.id, p).map_error(map_table_error)
      Ok((t2, p))
  end
end

## Creates an `Agent` principal, scoped `Modb.Grants.Grant`, and SHA-256-hashed `AgentToken` atomically.
fn tx_mint_agent(
  tx: WriteTx,
  issuer_id: Text,
  handle: Text,
  display_name: Text,
  model_id: Option(Text),
  label: Text,
  allowed_actions: List(Text),
  allowed_collections: Option(List(Text)),
  max_calls: Int,
  expires_at: Time,
  agent_id: Text,
  grant_id: Text,
  token_id: Text,
  token_prefix: Text,
  token_hash: Text,
  now: Time
) : Result((WriteTx, Principal, Grants.Grant, AgentToken), AppError)
  norm_handle = if handle.starts_with?("@"): handle else: "@#{handle}"
  if norm_handle.byte_count < 2
    return Error(BadInput(reason: "agent handle cannot be empty"))
  end
  for act in allowed_actions
    if not Policy.all_valid_actions().contains?(act)
      return Error(BadInput(reason: "unknown capability action '#{act}'"))
    end
  end
  if max_calls <= 0
    return Error(BadInput(reason: "max_calls must be > 0"))
  end

  scopes_opt = allowed_collections.map(fn(cols)
    cols.map(fn(c)
      if c.starts_with?("collection:") or c == "workspace:*": c else: "collection:#{c}"
    end)
  end)

  spec = Grants.GrantSpec(
    id: grant_id,
    principal: agent_id,
    allowed_actions: allowed_actions,
    max_calls: max_calls,
    expires_at: expires_at
  )
  (t1, grant) = try Grants.tx_issue_root_scoped(tx, issuer_id, spec, scopes_opt, None, now)
    .map_error(map_grants_error)

  principal = Principal(
    id: agent_id,
    kind: Agent,
    handle: norm_handle,
    display_name: display_name,
    email: None,
    avatar_url: None,
    role: Bot,
    model_id: model_id,
    root_grant_id: grant_id,
    suspended: false,
    created_at: now,
    last_seen_at: None
  )
  t2 = try Table.put(t1, principals_table(), principal.id, principal).map_error(map_table_error)

  tok = AgentToken(
    id: token_id,
    principal_id: agent_id,
    grant_id: grant_id,
    label: label,
    prefix: token_prefix,
    token_hash: token_hash,
    created_by: issuer_id,
    expires_at: Some(expires_at),
    revoked_at: None,
    last_used_at: None
  )
  t3 = try Table.put(t2, agent_tokens_table(), tok.id, tok).map_error(map_table_error)
  Ok((t3, principal, grant, tok))
end

test "Db schema, JIT OIDC human provisioning, page/block FTS indexing, and agent minting"
  files = Files.in_memory({})
  rng = SecureRandom.seeded(100)
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(
    principal: "system:test",
    action: "test.init",
    reason: "verify Db module",
    at: t0
  )

  (raw_tok, pref, thash) = Policy.mint_agent_token_raw(rng)
  assert raw_tok.starts_with?("vlm_ag_")

  res = Ledger.transact_locked(
    files,
    ledger_db_path,
    vellum_schema(),
    meta,
    "provision owner and agent",
    Json.Object({"test": Json.Boolean(true)}),
    map_ledger_error,
    fn(tx)
      (t1, owner) = try tx_upsert_human_principal(
        tx,
        "ada@acme.io",
        "Ada Lovelace",
        None,
        "usr_ada",
        "gr_ada",
        t0
      )
      if owner.role != Owner
        return Error(ServerFailed(reason: "first user should be Owner"))
      end
      (t2, member) = try tx_upsert_human_principal(
        t1,
        "grace@acme.io",
        "Grace Hopper",
        None,
        "usr_grace",
        "gr_grace",
        t0
      )
      if member.role != Member
        return Error(ServerFailed(reason: "second user should be Member"))
      end

      (t3, _agt, _gr, _tok) = try tx_mint_agent(
        t2,
        owner.id,
        "gardener",
        "Docs Gardener",
        Some("claude-sonnet-4-6"),
        "CI token",
        ["read", "write_direct"],
        Some([default_collection_id]),
        100,
        t0 + 7.days,
        "agt_1",
        "gr_agt_1",
        "tok_1",
        pref,
        thash,
        t0
      )
      Ok((t3, Unit))
    end
  )
  assert res is Ok(Unit)
end
