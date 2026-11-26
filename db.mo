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
tx_mint_agent,
databases_table,
databases_by_collection,
db_views_table,
db_views_by_database,
db_rows_table,
db_rows_by_database,
db_cells_bucket,
encode_db_cell_prefix,
encode_db_cell_key,
lookup_row_ids_by_cell,
tx_put_db_row,
tx_delete_db_row,
enrich_rows_with_rollups
use Domain.Blocks
use Domain.DatabaseModel{
  CellValue,
  DatabaseDef,
  DbRow,
  DbViewDef,
  EnrichedRow,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor
}
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
  PageKind,
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

db_cells_bucket = "vlm_db_cells"

fn databases_by_collection() : Table.Index(Text, DatabaseDef, Text)
  Table.text_index[Text, DatabaseDef]("vlm_databases_by_collection", fn(d) d.collection_id end)
end

fn databases_table() : Table.Table(Text, DatabaseDef)
  Table.text_key[DatabaseDef]("vlm_databases").with_index(databases_by_collection())
end

fn db_views_by_database() : Table.Index(Text, DbViewDef, Text)
  Table.text_index[Text, DbViewDef]("vlm_db_views_by_database", fn(v) v.database_id end)
end

fn db_views_table() : Table.Table(Text, DbViewDef)
  Table.text_key[DbViewDef]("vlm_db_views").with_index(db_views_by_database())
end

fn db_rows_by_database() : Table.Index(Text, DbRow, Text)
  Table.text_index[Text, DbRow]("vlm_db_rows_by_database", fn(r) r.database_id end)
end

fn db_rows_table() : Table.Table(Text, DbRow)
  Table.text_key[DbRow]("vlm_db_rows").with_index(db_rows_by_database())
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

fn check_single_db_row(
  tx: WriteTx,
  dbs_tbl: Table.Table(Text, DatabaseDef),
  rows_tbl: Table.Table(Text, DbRow),
  pages_tbl: Table.Table(Text, Page),
  row: DbRow
) : Result(Option(Text), Table.TableError)
  return Ok(None) if row.archived_at != None
  def = case try Table.tx_get(tx, dbs_tbl, row.database_id)
    Some(d): d
    None: return Ok(Some("db row '#{row.id}' references missing database '#{row.database_id}'"))
  end
  case DatabaseModel.validate_row_cells(def, row)
    Some(msg): return Ok(Some("db row '#{row.id}' invalid: #{msg}"))
    None: Unit
  end
  pg = case try Table.tx_get(tx, pages_tbl, row.page_id)
    Some(p) if p.archived_at == None: p
    Some(_) | None: return Ok(
      Some("db row '#{row.id}' references missing or archived page '#{row.page_id}'")
    )
  end
  expected_kind = DatabaseRow(database_id: row.database_id, row_id: row.id)
  if pg.kind != expected_kind or pg.collection_id != def.collection_id
    return Ok(Some("db row '#{row.id}' backing page '#{pg.id}' has mismatched kind/collection"))
  end

  for prop in def.properties
    case prop.kind
      Relation(target_db_id: tgt_db, inverse_prop_id: _):
        case row.cells.get(prop.id)
          Some(RelationVal(row_ids: rids)):
            for rid in rids
              case try Table.tx_get(tx, rows_tbl, rid)
                Some(tr) if tr.database_id == tgt_db and tr.archived_at == None: Unit
                Some(_) | None: return Ok(
                  Some(
                    "db row '#{row.id}' relation '#{prop.id}' points to missing target '#{rid}' in '#{tgt_db}'"
                  )
                )
              end
            end
          Some(_) | None: Unit
        end
      Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Checkbox | Person | Url | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): Unit
    end
  end
  Ok(None)
end

## Declarative `Modb.Ledger` schema enforcing mandatory write reasons, v1 bootstrap,
## and incremental `$O(\text{touched})$` invariants across collections, pages, blocks, and databases.
fn vellum_schema() : Ledger.Schema
  cols = collections_table()
  pages = pages_table()
  blocks = blocks_table()
  dbs = databases_table()
  db_rows = db_rows_table()
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
  ).with_invariant(
    Ledger.row_invariant(
      "database_valid",
      dbs,
      fn(_id, d) DatabaseModel.validate_database_def(d) end
    )
  ).with_invariant(
    Ledger.invariant(
      "db_row_integrity",
      fn(tx)
        if Modb.tx_is_tracked?(tx) and not Modb.tx_bucket_deleted?(tx, db_rows.bucket)
          for kb in Modb.tx_touched_puts(tx, db_rows.bucket)
            case try Modb.tx_get(tx, db_rows.bucket, kb).map_error(fn(e) Table.Storage(e) end)
              Some(raw):
                row = try db_rows.decode_value(raw).map_error(fn(e) Table.DecodeValue(e) end)
                case try check_single_db_row(tx, dbs, db_rows, pages, row)
                  Some(detail): return Ok(Some(detail))
                  None: Unit
                end
              None: Unit
            end
          end
          Ok(None)
        else
          all_rows = try Table.tx_scan(tx, db_rows, None, None, 0)
          for (_rid, row) in all_rows
            case try check_single_db_row(tx, dbs, db_rows, pages, row)
              Some(detail): return Ok(Some(detail))
              None: Unit
            end
          end
          Ok(None)
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

## Null-escaped composite prefix `(db_id, prop_id, encoded_val)` for `vlm_db_cells`.
fn encode_db_cell_prefix(db_id: Text, prop_id: Text, encoded_val: Text) : Bytes
  tcodec = Table.text_codec()
  p1 = Table.encode_composite_key(tcodec.encode(db_id), tcodec.encode(prop_id))
  Table.encode_composite_key(p1, tcodec.encode(encoded_val))
end

## Full composite cell index key `(db_id, prop_id, encoded_val, row_id)` stored in `vlm_db_cells`.
fn encode_db_cell_key(db_id: Text, prop_id: Text, encoded_val: Text, row_id: Text) : Bytes
  tcodec = Table.text_codec()
  prefix = encode_db_cell_prefix(db_id, prop_id, encoded_val)
  Table.encode_composite_key(prefix, tcodec.encode(row_id))
end

## Queries `vlm_db_cells` by exact `(db_id, prop_id, encoded_val)` and returns matching `row_id`s.
fn lookup_row_ids_by_cell(store: Store, db_id: Text, prop_id: Text, encoded_val: Text) : Result(
  List(Text),
  AppError
)
  tcodec = Table.text_codec()
  prefix = encode_db_cell_prefix(db_id, prop_id, encoded_val)
  lo = Table.encode_composite_key(prefix, Bytes.empty)
  ff = 255.to_byte or stop "ff byte"
  hi = Table.encode_composite_key(prefix, Bytes.from_list([ff]))
  rows = try Modb.scan(store, db_cells_bucket, Some(lo), Some(hi), 0).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
  var out = []
  for (raw_k, _v) in rows
    (ik, pk_bytes) = try Table.decode_composite_key(raw_k).map_error(map_table_error)
    if ik == prefix
      rid = try tcodec.decode(pk_bytes).map_error(map_table_error)
      out = out.append(rid)
    end
  end
  Ok(out)
end

fn tx_update_db_cell_index(tx: WriteTx, db_id: Text, old_row: Option(DbRow), new_row: Option(DbRow)) : Result(
  WriteTx,
  AppError
)
  var cur = tx
  case old_row
    Some(r):
      for (pid, cval) in r.cells.entries
        for (p_id, val_tok) in DatabaseModel.cell_index_tokens(pid, cval)
          k = encode_db_cell_key(db_id, p_id, val_tok, r.id)
          cur = try Modb.tx_delete(cur, db_cells_bucket, k).map_error(fn(e)
            ServerFailed(reason: e.to_text)
          end)
        end
      end
    None: Unit
  end
  case new_row
    Some(r) if r.archived_at == None:
      for (pid, cval) in r.cells.entries
        for (p_id, val_tok) in DatabaseModel.cell_index_tokens(pid, cval)
          k = encode_db_cell_key(db_id, p_id, val_tok, r.id)
          cur = try Modb.tx_put(cur, db_cells_bucket, k, Bytes.empty).map_error(fn(e)
            ServerFailed(reason: e.to_text)
          end)
        end
      end
    Some(_) | None: Unit
  end
  Ok(cur)
end

## Atomically persists a `DbRow`, its `vlm_db_cells` composite indexes, its backing `Page` + `Block`s,
## and combined title + properties + body text in `Modb.Fts`.
fn tx_put_db_row(tx: WriteTx, def: DatabaseDef, row: DbRow, page: Page, blocks: List(Block)) : Result(
  WriteTx,
  AppError
)
  old_row = try Table.tx_get(tx, db_rows_table(), row.id).map_error(map_table_error)
  t1 = try tx_update_db_cell_index(tx, def.id, old_row, Some(row))
  t2 = try Table.put(t1, db_rows_table(), row.id, row).map_error(map_table_error)
  t3 = try tx_save_page_and_blocks(t2, page, blocks)
  if row.archived_at == None and page.archived_at == None
    row_text = DatabaseModel.row_plain_text(def, row)
    body_text = Blocks.blocks_plain_text(blocks)
    combined = if row_text.empty?
      body_text
    else if body_text.empty?
      row_text
    else
      "#{row_text}\n#{body_text}"
    end
    doc = Fts.DocumentInput(
      doc_id: page.id,
      scope: page.collection_id,
      fields: [
        Fts.FieldInput(name: "title", text: page.title, weight: 3),
        Fts.FieldInput(name: "body", text: combined, weight: 1)
      ]
    )
    Fts.tx_index_document(t3, fts_index(), doc).map_error(map_fts_error)
  else
    Ok(t3)
  end
end

## Atomically deletes a `DbRow`, its `vlm_db_cells` entries, backing `Page` + `Block`s, and FTS entry.
fn tx_delete_db_row(tx: WriteTx, def: DatabaseDef, row_id: Text) : Result(WriteTx, AppError)
  old_row = case try Table.tx_get(tx, db_rows_table(), row_id).map_error(map_table_error)
    Some(r): r
    None: return Error(Missing(entity: "db_row", id: row_id))
  end
  t1 = try tx_update_db_cell_index(tx, def.id, Some(old_row), None)
  t2 = try Table.delete(t1, db_rows_table(), row_id).map_error(map_table_error)
  tx_delete_page_and_blocks(t2, old_row.page_id)
end

## Resolves all `Rollup` columns for `rows` of `def` by fetching referenced target rows from `Store`.
fn enrich_rows_with_rollups(store: Store, def: DatabaseDef, rows: List(DbRow)) : Result(
  List(EnrichedRow),
  AppError
)
  var rollup_props = []
  for p in def.properties
    case p.kind
      Rollup(relation_prop_id: rel_id, target_prop_id: tgt_id, agg: agg): rollup_props = rollup_props
        .append((p.id, rel_id, tgt_id, agg))
      Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _): Unit
    end
  end

  if rollup_props.empty?
    return Ok(rows.map(fn(r) EnrichedRow(row: r, rollups: {}) end))
  end

  rtbl = db_rows_table()
  var rel_cache = {}
  var enriched = []
  for r in rows
    var roll_map = {}
    for (roll_pid, rel_pid, tgt_pid, agg) in rollup_props
      rel_ids = case r.cells.get(rel_pid)
        Some(RelationVal(row_ids: rids)): rids
        Some(_) | None: []
      end
      var tgt_cells = []
      for rid in rel_ids
        cached_opt = case rel_cache.get(rid)
          Some(v): v
          None:
            fetched = try Table.get(store, rtbl, rid).map_error(map_table_error)
            rel_cache = rel_cache.set(rid, fetched)
            fetched
        end
        case cached_opt
          Some(tr) if tr.archived_at == None: tgt_cells = tgt_cells.append(
            tr.cells.get(tgt_pid) or Empty
          )
          Some(_) | None: Unit
        end
      end
      roll_map = roll_map.set(roll_pid, DatabaseModel.compute_rollup(agg, tgt_cells))
    end
    enriched = enriched.append(EnrichedRow(row: r, rollups: roll_map))
  end
  Ok(enriched)
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

test "Db relational database composite cell indexes, rollup enrichment, and Ledger invariants"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  schema = vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "db.test",
    reason: "verify database invariants and composite indexes",
    at: t0
  )

  tasks_def = DatabaseDef(
    id: "db_tasks",
    collection_id: default_collection_id,
    page_id: "pg_db_tasks",
    title: "Tasks",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "points",
        name: "Points",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "b"
      )
    ],
    version: 1
  )
  proj_def = DatabaseDef(
    id: "db_proj",
    collection_id: default_collection_id,
    page_id: "pg_db_proj",
    title: "Projects",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(
          options: [
            SelectOption(id: "active", label: "Active", color: Green),
            SelectOption(id: "paused", label: "Paused", color: Gray)
          ]
        ),
        required: true,
        sort_order: "b"
      ),
      PropertyDef(
        id: "tasks",
        name: "Tasks",
        kind: Relation(target_db_id: "db_tasks", inverse_prop_id: None),
        required: false,
        sort_order: "c"
      ),
      PropertyDef(
        id: "total_pts",
        name: "Total Pts",
        kind: Rollup(relation_prop_id: "tasks", target_prop_id: "points", agg: SumValues),
        required: false,
        sort_order: "d"
      )
    ],
    version: 1
  )

  p_host_t = Page(
    id: "pg_db_tasks",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Tasks",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: Some("db_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  p_host_p = Page(
    id: "pg_db_proj",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Projects",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "b",
    database_id: Some("db_proj"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  d1 = "0.1".to_decimal or stop "d1"
  d2 = "0.2".to_decimal or stop "d2"
  d3 = "0.3".to_decimal or stop "d3"

  task1_pg = Page(
    id: "pg_t1",
    collection_id: default_collection_id,
    parent_page_id: Some("pg_db_tasks"),
    title: "Task One",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: "db_tasks", row_id: "row_t1"),
    sort_order: "row_t1",
    database_id: Some("db_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  task2_pg = Page(
    id: "pg_t2",
    collection_id: default_collection_id,
    parent_page_id: Some("pg_db_tasks"),
    title: "Task Two",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: "db_tasks", row_id: "row_t2"),
    sort_order: "row_t2",
    database_id: Some("db_tasks"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  proj1_pg = Page(
    id: "pg_p1",
    collection_id: default_collection_id,
    parent_page_id: Some("pg_db_proj"),
    title: "Launch Vellum",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: "db_proj", row_id: "row_p1"),
    sort_order: "row_p1",
    database_id: Some("db_proj"),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  task1 = DbRow(
    id: "row_t1",
    database_id: "db_tasks",
    page_id: "pg_t1",
    cells: {"title": TextVal("Task One"), "points": NumberVal(d1)},
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  task2 = DbRow(
    id: "row_t2",
    database_id: "db_tasks",
    page_id: "pg_t2",
    cells: {"title": TextVal("Task Two"), "points": NumberVal(d2)},
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  proj1 = DbRow(
    id: "row_p1",
    database_id: "db_proj",
    page_id: "pg_p1",
    cells: {
      "title": TextVal("Launch Vellum"),
      "status": SelectVal(option_id: "active"),
      "tasks": RelationVal(row_ids: ["row_t1", "row_t2"])
    },
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  seed_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed related databases and rows",
    Json.Object({"seed": Json.Boolean(true)}),
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, pages_table(), p_host_t.id, p_host_t).map_error(map_table_error)
      t2 = try Table.put(t1, pages_table(), p_host_p.id, p_host_p).map_error(map_table_error)
      t3 = try Table.put(t2, databases_table(), tasks_def.id, tasks_def).map_error(map_table_error)
      t4 = try Table.put(t3, databases_table(), proj_def.id, proj_def).map_error(map_table_error)
      t5 = try tx_put_db_row(t4, tasks_def, task1, task1_pg, [])
      t6 = try tx_put_db_row(t5, tasks_def, task2, task2_pg, [])
      t7 = try tx_put_db_row(t6, proj_def, proj1, proj1_pg, [])
      Ok((t7, Unit))
    end
  )
  assert seed_res is Ok(Unit)

  ## Composite vlm_db_cells lookup + exact Decimal rollup + Ledger verify_all (5 invariants)
  check_res = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      by_status = try lookup_row_ids_by_cell(store, "db_proj", "status", "active")
      return Error(BadInput(reason: "expected row_p1")) if by_status != ["row_p1"]
      by_rel = try lookup_row_ids_by_cell(store, "db_proj", "tasks", "row_t2")
      return Error(BadInput(reason: "expected reverse relation")) if by_rel != ["row_p1"]

      enriched = try enrich_rows_with_rollups(store, proj_def, [proj1])
      first_e = try enriched.first.or_fail(BadInput(reason: "missing enriched"))
      if first_e.rollups.get("total_pts") != Some(NumberVal(d3))
        return Error(BadInput(reason: "rollup decimal mismatch"))
      end

      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      return Error(BadInput(reason: "expected 5 invariants")) if rep.invariants_checked != 5
      Ok(Unit)
    end
  )
  assert check_res is Ok(Unit)

  ## Commit-time invariant rejects dangling relation target
  bad_rel_proj = DbRow(
    id: "row_p1",
    database_id: "db_proj",
    page_id: "pg_p1",
    cells: {
      "title": TextVal("Launch Vellum"),
      "status": SelectVal(option_id: "active"),
      "tasks": RelationVal(row_ids: ["row_nonexistent"])
    },
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 2
  )
  bad_rel_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "attempt dangling relation",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_put_db_row(tx, proj_def, bad_rel_proj, proj1_pg, [])
      Ok((t1, Unit))
    end
  )
  assert bad_rel_res is Error(BadInput(reason: _))
end
