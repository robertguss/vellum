## 100% Pure MoDB persistence layer for Vellum (`sessions.modb` + `vellum.modb`).
## Zero SQLite anywhere: combines `Modb.Table`, `Modb.Ledger`, `Modb.Grants`, `Modb.Fts`, and `Modb.Vec`.
module Db
expose sessions_db_path,
ledger_db_path,
default_workspace_id,
default_collection_id,
sketch_vec_dims,
sketch_min_vec_score,
fts_index,
sketch_vec_index,
neural_vec_index,
page_neural_dims_table,
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
map_vec_error,
not_found_ledger?,
verify_grant_chain_read_only,
page_embedding_text,
tx_index_page,
tx_save_page_and_blocks,
tx_delete_page_and_blocks,
tx_put_page_neural_vector,
tx_remove_page_vectors,
neural_vec_populated,
load_page_blocks,
search_pages,
search_pages_hybrid,
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
enrich_rows_with_rollups,
proposals_by_status,
proposals_by_page,
proposals_table,
webhooks_by_workspace,
webhooks_table,
map_claims_error,
map_world_error,
map_replay_error,
tx_apply_world_patch,
world_catalog,
replay_catalog
use Domain.Blocks
use Domain.Collab{ProposalMeta, WebhookSub, WorldPatchArgs}
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
  AuthorKind,
  Block,
  BlockKind,
  Collection,
  CollectionWritePolicy,
  Comment,
  Page,
  PageKind,
  Principal,
  PrincipalKind,
  Provenance,
  SearchResultItem,
  Workspace,
  WorkspaceRole,
  to_text
}
use Json
use Modb{Store, WriteTx}
use Modb.Claims
use Modb.Errors
use Modb.Fts
use Modb.Grants
use Modb.Ledger
use Modb.Replay
use Modb.Table
use Modb.Vec
use Modb.World

sessions_db_path = "sessions.modb"
ledger_db_path = "vellum.modb"
default_workspace_id = "ws_default"
default_collection_id = "col_general"
sketch_vec_dims = 256
sketch_min_vec_score = 0.28.to_float

## Handle to the transactional BM25 index inside `vellum.modb`.
fn fts_index() : Fts.FtsIndex
  Fts.index("vellum")
end

## Handle to the zero-dependency 256-dim Q16 Cosine subword sketch vector index inside `vellum.modb`.
fn sketch_vec_index() : Vec.VecIndex
  Vec.index("vellum_sketch", sketch_vec_dims)
end

## Dimension-namespaced handle to the neural embedding vector index inside `vellum.modb`.
fn neural_vec_index(dims: Int) : Vec.VecIndex
  Vec.index("vellum_neural_#{dims}", dims)
end

## Tracks each page's currently indexed neural embedding dimension for atomic cleanup across dimension changes.
fn page_neural_dims_table() : Table.Table(Text, Int)
  Table.text_key[Int]("vlm_page_neural_dims")
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

fn proposals_by_status() : Table.Index(Text, ProposalMeta, Text)
  Table.text_index[Text, ProposalMeta]("vlm_proposals_by_status", fn(p) p.status end)
end

fn proposals_by_page() : Table.Index(Text, ProposalMeta, Text)
  Table.text_index[Text, ProposalMeta]("vlm_proposals_by_page", fn(p) p.target_page_id end)
end

fn proposals_table() : Table.Table(Text, ProposalMeta)
  Table.text_key[ProposalMeta]("vlm_proposals").with_index(proposals_by_status()).with_index(
    proposals_by_page()
  )
end

fn webhooks_by_workspace() : Table.Index(Text, WebhookSub, Text)
  Table.text_index[Text, WebhookSub]("vlm_webhooks_by_workspace", fn(w) w.workspace_id end)
end

fn webhooks_table() : Table.Table(Text, WebhookSub)
  Table.text_key[WebhookSub]("vlm_webhooks").with_index(webhooks_by_workspace())
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

## Converts `Modb.Vec` errors to `AppError`.
fn map_vec_error(err: Vec.VecError) : AppError
  case err
    Vec.InvalidConfig(reason: _) | Vec.InvalidVector(reason: _) | Vec.DimensionMismatch(
      expected: _,
      actual: _
    ): BadInput(reason: Vec.to_text(err))
    Vec.Storage(_) | Vec.TableFailure(_) | Vec.FtsFailure(_): ServerFailed(reason: Vec.to_text(err))
  end
end

## Converts `Modb.Claims` errors to `AppError`.
fn map_claims_error(err: Claims.ClaimError) : AppError
  case err
    Claims.AlreadyClaimed(resource: _, holder: _, expires_at: _): Conflict(reason: err.to_text)
    Claims.ClaimNotFound(resource: _): Missing(entity: "claim", id: err.to_text)
    Claims.NotHolder(resource: _, expected: _, actual: _): Forbidden(reason: err.to_text)
    Claims.InvalidClaim(reason: _): BadInput(reason: err.to_text)
    Claims.LedgerFailure(le): map_ledger_error(le)
  end
end

## Converts `Modb.World` errors to `AppError`.
fn map_world_error(err: World.WorldError) : AppError
  case err
    World.WorldNotFound(id: wid): Missing(entity: "world", id: wid)
    World.WorldNotOpen(id: _, status: _) | World.WorldExpired(id: _) | World.StaleRead(
      query: _,
      args: _,
      expected: _,
      actual: _
    ): Conflict(reason: err.to_text)
    World.GrantFailure(ge): map_grants_error(ge)
    World.LedgerFailure(le): map_ledger_error(le)
    World.ActionRejected(action: _, detail: _) | World.InvariantRejected(name: _, detail: _) | World
      .UnknownQuery(name: _) | World.UnknownAction(name: _) | World.QueryFailed(query: _, detail: _) | World
      .WorldAlreadyExists(id: _): BadInput(reason: err.to_text)
  end
end

## Converts `Modb.Replay` errors to `AppError`.
fn map_replay_error(err: Replay.ReplayError) : AppError
  case err
    Replay.ProposalNotFound(id: pid): Missing(entity: "replay_proposal", id: pid)
    Replay.ProposalNotPending(id: _, status: _) | Replay.ProposalAlreadyExists(id: _) | Replay
      .ProposalStale(
        id: _,
        expected_audit_seq: _,
        actual_audit_seq: _,
        expected_call_seq: _,
        actual_call_seq: _
      ): Conflict(reason: err.to_text)
    Replay.GrantFailure(ge): map_grants_error(ge)
    Replay.LedgerFailure(le): map_ledger_error(le)
    Replay.ExportFailure(_) | Replay.UnknownReplayAction(action: _, schema_version: _) | Replay
      .MissingReplayMigration(version: _) | Replay.ReplayActionRejected(action: _, detail: _) | Replay
      .ReplayFailed(detail: _): BadInput(reason: err.to_text)
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

## Builds canonical embedding input text combining title, optional structured fields, and block body text.
fn page_embedding_text(page: Page, blocks: List(Block), extra_text: Option(Text)) : Text
  var parts = []
  t = page.title.trim
  if not t.empty?
    parts = parts.append(t)
  end
  case extra_text
    Some(et) if not et.trim.empty?: parts = parts.append(et.trim)
    Some(_) | None: Unit
  end
  body = Blocks.blocks_plain_text(blocks).trim
  if not body.empty?
    parts = parts.append(body)
  end
  parts.join("\n")
end

fn truncate_text_bytes(s: Text, max_bytes: Int) : Text
  return "" if max_bytes <= 0
  return s if s.byte_count <= max_bytes
  raw = s.bytes
  var cut = max_bytes
  while cut > 0
    case raw.slice(0, cut).decode_utf8
      Some(valid): return valid
      None: cut -= 1
    end
  end
  ""
end

## Indexes `page` and its `blocks` into both `Modb.Fts` and `Modb.Vec` (sketch index) inside `tx`.
fn tx_index_page(tx: WriteTx, page: Page, blocks: List(Block)) : Result(WriteTx, AppError)
  body_plain = Blocks.blocks_plain_text(blocks)
  doc = Fts.DocumentInput(
    doc_id: page.id,
    scope: page.collection_id,
    fields: [
      Fts.FieldInput(name: "title", text: page.title, weight: 3),
      Fts.FieldInput(name: "body", text: body_plain, weight: 1)
    ]
  )
  t1 = try Fts.tx_index_document(tx, fts_index(), doc).map_error(map_fts_error)
  t = page.title.trim
  body_trimmed = body_plain.trim
  sketch_raw = if t.empty?
    body_trimmed
  else if body_trimmed.empty?
    t
  else
    "#{t}\n#{body_trimmed}"
  end
  embed_txt = truncate_text_bytes(sketch_raw, 4096)
  vec_inp = Vec.VectorInput(
    doc_id: page.id,
    scope: page.collection_id,
    values: Vec.text_sketch_embedding(embed_txt, sketch_vec_dims)
  )
  Vec.tx_put_vector(t1, sketch_vec_index(), vec_inp).map_error(map_vec_error)
end

## Atomically stores (or replaces across dimension/collection changes) a page's neural embedding vector.
fn tx_put_page_neural_vector(
  tx: WriteTx,
  page_id: Text,
  collection_id: Text,
  dims: Int,
  values: List(Float)
) : Result(WriteTx, AppError)
  var cur = tx
  case try Table.tx_get(cur, page_neural_dims_table(), page_id).map_error(map_table_error)
    Some(old_dims) if old_dims != dims: cur = try Vec.tx_remove_vector(
      cur,
      neural_vec_index(old_dims),
      page_id
    ).map_error(map_vec_error)
    Some(_) | None: Unit
  end
  vec_inp = Vec.VectorInput(doc_id: page_id, scope: collection_id, values: values)
  cur = try Vec.tx_put_vector(cur, neural_vec_index(dims), vec_inp).map_error(map_vec_error)
  Table.put(cur, page_neural_dims_table(), page_id, dims).map_error(map_table_error)
end

## Atomically removes `page_id` from both sketch and neural vector indexes inside `tx`.
fn tx_remove_page_vectors(tx: WriteTx, page_id: Text) : Result(WriteTx, AppError)
  var cur = try Vec.tx_remove_vector(tx, sketch_vec_index(), page_id).map_error(map_vec_error)
  case try Table.tx_get(cur, page_neural_dims_table(), page_id).map_error(map_table_error)
    Some(old_dims):
      cur = try Vec.tx_remove_vector(cur, neural_vec_index(old_dims), page_id).map_error(
        map_vec_error
      )
      cur = try Table.delete(cur, page_neural_dims_table(), page_id).map_error(map_table_error)
      Ok(cur)
    None: Ok(cur)
  end
end

## Atomically persists `page`, replaces its blocks, and updates `Modb.Fts` + `Modb.Vec` inside `tx`.
fn tx_save_page_and_blocks(tx: WriteTx, page: Page, blocks: List(Block)) : Result(WriteTx, AppError)
  btbl = blocks_table()
  bidx = blocks_by_page()
  existing = try Table.tx_lookup(tx, btbl, bidx, page.id).map_error(map_table_error)
  new_ids = blocks.map(fn(b) b.id end).to_set
  existing_by_id = existing.to_map

  var cur = try Table.put(tx, pages_table(), page.id, page).map_error(map_table_error)
  for (old_id, _old_blk) in existing
    if not new_ids.has?(old_id)
      cur = try Table.delete(cur, btbl, old_id).map_error(map_table_error)
    end
  end
  for blk in blocks
    changed? = case existing_by_id.get(blk.id)
      Some(old_blk): old_blk != blk
      None: true
    end
    if changed?
      cur = try Table.put(cur, btbl, blk.id, blk).map_error(map_table_error)
    end
  end
  if page.archived_at == None
    tx_index_page(cur, page, blocks)
  else
    t_fts = try Fts.tx_remove_document(cur, fts_index(), page.id).map_error(map_fts_error)
    tx_remove_page_vectors(t_fts, page.id)
  end
end

## Atomically removes `page_id`, all of its blocks, its FTS entry, and its vector index entries inside `tx`.
fn tx_delete_page_and_blocks(tx: WriteTx, page_id: Text) : Result(WriteTx, AppError)
  btbl = blocks_table()
  bidx = blocks_by_page()
  existing = try Table.tx_lookup(tx, btbl, bidx, page_id).map_error(map_table_error)
  var cur = tx
  for (bid, _b) in existing
    cur = try Table.delete(cur, btbl, bid).map_error(map_table_error)
  end
  cur = try Table.delete(cur, pages_table(), page_id).map_error(map_table_error)
  cur = try Fts.tx_remove_document(cur, fts_index(), page_id).map_error(map_fts_error)
  tx_remove_page_vectors(cur, page_id)
end

## Returns whether the dimension-namespaced neural vector index has at least one indexed page.
fn neural_vec_populated(store: Store, dims: Int) : Result(Bool, AppError)
  st = try Vec.stats(store, neural_vec_index(dims)).map_error(map_vec_error)
  Ok(st.doc_count > 0)
end

## Loads and sorts all blocks belonging to `page_id` from a committed `Store`.
fn load_page_blocks(store: Store, page_id: Text) : Result(List(Block), AppError)
  rows = try Table.lookup(store, blocks_table(), blocks_by_page(), page_id).map_error(
    map_table_error
  )
  Ok(Blocks.sort_blocks(rows.map(fn(p) p.1 end)))
end

fn make_allow_doc(auth: AuthContext) : fn(Text, Text) : Bool
  allowed_cols = auth.allowed_collections
  suspended = auth.principal.suspended
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
  allow_doc = make_allow_doc(auth)
  hits = try Fts.search_filtered(store, fts_index(), query, opts, allow_doc).map_error(
    map_fts_error
  )

  ptbl = pages_table()
  var out = []
  for (i, hit) in hits.enumerate
    case try Table.get(store, ptbl, hit.doc_id).map_error(map_table_error)
      Some(p) if p.archived_at == None: out = out.append(
        SearchResultItem(
          page_id: p.id,
          collection_id: p.collection_id,
          title: p.title,
          score: hit.score,
          matched_terms: hit.matched_terms,
          matched_fields: hit.matched_fields,
          fts_rank: Some(i + 1),
          vec_rank: None,
          vec_score: None
        )
      )
      Some(_) | None: Unit
    end
  end
  Ok(out)
end

## Executes fail-closed grant-filtered search in `"hybrid"` (RRF BM25 + Vec), `"bm25"`, or `"semantic"` mode.
fn search_pages_hybrid(
  store: Store,
  auth: AuthContext,
  query: Text,
  query_vec: Option(List(Float)),
  vec_idx: Vec.VecIndex,
  mode: Text,
  limit: Int,
  prefix_last?: Bool,
  collection_filter: Option(Text),
  min_vec_score: Option(Float)
) : Result(List(SearchResultItem), AppError)
  case collection_filter
    Some(cid):
      if not Policy.collection_permitted?(auth, cid)
        return Ok([])
      end
    None: Unit
  end

  if mode == "bm25"
    return search_pages(store, auth, query, limit, prefix_last?, collection_filter)
  end

  allow_doc = make_allow_doc(auth)
  ptbl = pages_table()

  if mode == "semantic"
    qv = case query_vec
      Some(v) if not v.empty?: v
      Some(_) | None: return Ok([])
    end
    vopts = Vec.VecSearchOptions(
      limit: limit,
      required_scope: collection_filter,
      min_score: min_vec_score
    )
    vhits = try Vec.search_filtered(store, vec_idx, qv, vopts, allow_doc).map_error(map_vec_error)
    var out = []
    for (i, vh) in vhits.enumerate
      case try Table.get(store, ptbl, vh.doc_id).map_error(map_table_error)
        Some(p) if p.archived_at == None: out = out.append(
          SearchResultItem(
            page_id: p.id,
            collection_id: p.collection_id,
            title: p.title,
            score: vh.score,
            matched_terms: [],
            matched_fields: ["semantic"],
            fts_rank: None,
            vec_rank: Some(i + 1),
            vec_score: Some(vh.score)
          )
        )
        Some(_) | None: Unit
      end
    end
    return Ok(out)
  end

  cand = if limit * 4 > 20: limit * 4 else: 20
  hopts = Vec.HybridOptions(
    limit: limit,
    prefix_last_term?: prefix_last?,
    required_scope: collection_filter,
    rrf_k: 60,
    fts_weight: 1.0.to_float,
    vec_weight: 1.0.to_float,
    candidate_limit: cand,
    min_vec_score: min_vec_score
  )
  hhits = try Vec.hybrid_search_filtered(
    store,
    fts_index(),
    vec_idx,
    query,
    query_vec,
    hopts,
    allow_doc
  ).map_error(map_vec_error)

  var out = []
  for hh in hhits
    case try Table.get(store, ptbl, hh.doc_id).map_error(map_table_error)
      Some(p) if p.archived_at == None:
        fields = if hh.matched_fields.empty? and hh.vec_rank != None
          ["semantic"]
        else
          hh.matched_fields
        end
        out = out.append(
          SearchResultItem(
            page_id: p.id,
            collection_id: p.collection_id,
            title: p.title,
            score: hh.score,
            matched_terms: hh.matched_terms,
            matched_fields: fields,
            fts_rank: hh.fts_rank,
            vec_rank: hh.vec_rank,
            vec_score: hh.vec_score
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
    t4 = try Fts.tx_index_document(t3, fts_index(), doc).map_error(map_fts_error)
    embed_txt = page_embedding_text(page, blocks, Some(row_text))
    vec_inp = Vec.VectorInput(
      doc_id: page.id,
      scope: page.collection_id,
      values: Vec.text_sketch_embedding(embed_txt, sketch_vec_dims)
    )
    Vec.tx_put_vector(t4, sketch_vec_index(), vec_inp).map_error(map_vec_error)
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

## Replayable `Modb.World` + `Modb.Replay` action handler applying surgical `BlockOp`s to a page inside `tx`.
fn tx_apply_world_patch(tx: WriteTx, args_json: Json) : Result((WriteTx, Json), Text)
  args = try Json.decode_strict[WorldPatchArgs](args_json.to_text.bytes).map_error(
    fn(e) e.to_text end
  )
  old_page = case try Table.tx_get(tx, pages_table(), args.page_id).map_error(fn(e) e.to_text end)
    Some(p) if p.archived_at == None: p
    Some(_) | None: return Error("page '#{args.page_id}' not found or archived")
  end

  existing_rows = try Table.tx_lookup(tx, blocks_table(), blocks_by_page(), args.page_id).map_error(
    fn(e) e.to_text end
  )
  existing_blocks = Blocks.sort_blocks(existing_rows.map(fn(x) x.1 end))

  var ver_by_id = {}
  for b in existing_blocks
    ver_by_id = ver_by_id.set(b.id, b.version)
  end
  for (bid, exp_ver) in args.expected_versions.entries
    case ver_by_id.get(bid)
      None: return Error("block '#{bid}' not found")
      Some(actual_ver):
        if actual_ver != exp_ver
          return Error("expected version #{exp_ver} on block '#{bid}', found #{actual_ver}")
        end
    end
  end

  updated_blocks = try Blocks.apply_block_ops(
    existing_blocks,
    args.ops,
    args.page_id,
    args.provenance,
    args.new_ids
  )
  bumped_page = Page(
    id: old_page.id,
    collection_id: old_page.collection_id,
    parent_page_id: old_page.parent_page_id,
    title: old_page.title,
    icon: old_page.icon,
    cover_attachment_id: old_page.cover_attachment_id,
    kind: old_page.kind,
    sort_order: old_page.sort_order,
    database_id: old_page.database_id,
    freshness_ttl_days: old_page.freshness_ttl_days,
    verified_at: old_page.verified_at,
    verified_by: old_page.verified_by,
    created_by: old_page.created_by,
    created_at: old_page.created_at,
    updated_at: args.updated_at,
    archived_at: old_page.archived_at,
    version: old_page.version + 1
  )
  next_tx = try tx_save_page_and_blocks(tx, bumped_page, updated_blocks).map_error(to_text)
  Ok((
    next_tx,
    Json.Object({
      "page_id": Json.String(bumped_page.id),
      "page_version": Json.int(bumped_page.version),
      "block_count": Json.int(updated_blocks.size)
    })
  ))
end

## Speculative `Modb.World` catalog registering `read_page` (O(diff) key-scoped) and `propose`.
fn world_catalog() : World.Catalog
  tcodec = Table.text_codec()
  p_bucket = pages_table().bucket
  World.with_action(
    World.with_key_scoped_query(
      World.catalog(),
      "read_page",
      p_bucket,
      fn(args)
        pid = try args.text_at("page_id").or_fail("read_page requires string 'page_id'")
        Ok(tcodec.encode(pid))
      end,
      fn(tx, args)
        pid = try args.text_at("page_id").or_fail("read_page requires string 'page_id'")
        case try Table.tx_get(tx, pages_table(), pid).map_error(fn(e) e.to_text end)
          Some(p): Ok(Json.Object({"id": Json.String(p.id), "version": Json.int(p.version)}))
          None: Error("page '#{pid}' not found")
        end
      end
    ),
    "propose",
    tx_apply_world_patch
  )
end

## Offline `Modb.Replay` catalog pairing the exact `"propose"` handler for selective agent undo.
fn replay_catalog() : Replay.ReplayCatalog
  Replay.with_action(Replay.catalog(), "propose", tx_apply_world_patch)
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

test "Db Modb.Vec hybrid RRF search, neural vector updates/dimension switches, archive cleanup, and fail-closed grants"
  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  schema = vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "db.vec_test",
    reason: "verify Modb.Vec hybrid RRF and fail-closed grant filtering",
    at: t0
  )

  sec_col = Collection(
    id: "col_secret",
    workspace_id: default_workspace_id,
    slug: "secret-exec",
    name: "Secret Executive",
    description: "",
    icon: None,
    write_policy: DirectWithAudit,
    freshness_ttl_days: None,
    sort_order: "z",
    archived_at: None
  )
  pg_pub = Page(
    id: "pg_pub_deploy",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Gateway Rollout Checklist",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  pg_other = Page(
    id: "pg_pub_lunch",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Catering Menu Notes",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "b",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  pg_sec = Page(
    id: "pg_sec_vault",
    collection_id: "col_secret",
    parent_page_id: None,
    title: "Executive Master Password",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "c",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )

  seed = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed hybrid vector test pages",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, collections_table(), sec_col.id, sec_col).map_error(map_table_error)
      t2 = try tx_save_page_and_blocks(t1, pg_pub, [])
      t3 = try tx_save_page_and_blocks(t2, pg_other, [])
      t4 = try tx_save_page_and_blocks(t3, pg_sec, [])
      # Attach 4-d neural embeddings where BOTH pg_pub and pg_sec match query [1,0,0,0] identically
      t5 = try tx_put_page_neural_vector(t4, pg_pub.id, pg_pub.collection_id, 4, [1.0, 0.0, 0.0, 0.0])
      t6 = try tx_put_page_neural_vector(
        t5,
        pg_other.id,
        pg_other.collection_id,
        4,
        [0.0, 1.0, 0.0, 0.0]
      )
      t7 = try tx_put_page_neural_vector(t6, pg_sec.id, pg_sec.collection_id, 4, [1.0, 0.0, 0.0, 0.0])
      Ok((t7, Unit))
    end
  )
  assert seed is Ok(Unit)

  owner_auth = AuthContext(
    principal: Principal(
      id: "usr_ada",
      kind: Human,
      handle: "@ada",
      display_name: "Ada",
      email: Some("ada@acme.io"),
      avatar_url: None,
      role: Owner,
      model_id: None,
      root_grant_id: "gr_ada",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_ada",
    session: None,
    allowed_collections: None,
    allowed_actions: ["read", "write_direct"]
  )
  scoped_auth = AuthContext(
    principal: Principal(
      id: "agt_1",
      kind: Agent,
      handle: "@agent1",
      display_name: "Scoped Agent",
      email: None,
      avatar_url: None,
      role: Member,
      model_id: Some("gpt-4o-mini"),
      root_grant_id: "gr_agt_1",
      suspended: false,
      created_at: t0,
      last_seen_at: None
    ),
    grant_id: "gr_agt_1",
    session: None,
    allowed_collections: Some(["collection:#{default_collection_id}"]),
    allowed_actions: ["read"]
  )

  verify = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      has_n = try neural_vec_populated(store, 4)
      return Error(BadInput(reason: "expected neural docs")) if not has_n

      # Zero lexical overlap query ("zero_overlap_concept"): BM25 finds nothing, Semantic + Hybrid find both permitted & secret for Owner
      owner_sem = try search_pages_hybrid(
        store,
        owner_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "semantic",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "owner should see 2 semantic hits")) if owner_sem.size != 2

      # Scoped agent MUST NOT see pg_sec_vault even though its cosine similarity is 1.0
      ag_sem = try search_pages_hybrid(
        store,
        scoped_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "semantic",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "agent leaked secret semantic hit")) if ag_sem.map(fn(h)
        h.page_id
      end) != [pg_pub.id]

      ag_hyb = try search_pages_hybrid(
        store,
        scoped_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "hybrid",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "agent hybrid mismatch")) if ag_hyb.map(fn(h) h.page_id end) != [
        pg_pub.id
      ]

      ag_bm25 = try search_pages_hybrid(
        store,
        scoped_auth,
        "zero_overlap_concept",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "bm25",
        10,
        true,
        None,
        None
      )
      return Error(BadInput(reason: "expected 0 bm25 hits")) if not ag_bm25.empty?

      # Hybrid RRF merges BM25 + Vector: query matches pg_other by keyword AND pg_pub by vector
      rrf_hits = try search_pages_hybrid(
        store,
        scoped_auth,
        "Catering",
        Some([1.0, 0.0, 0.0, 0.0]),
        neural_vec_index(4),
        "hybrid",
        10,
        true,
        None,
        Some(0.25.to_float)
      )
      return Error(BadInput(reason: "expected both BM25 & Vec hits in RRF")) if rrf_hits.size != 2

      # Sketch fallback index works with zero external embedding call
      sk_hits = try search_pages_hybrid(
        store,
        scoped_auth,
        "Gateway Rollout",
        Some(Vec.text_sketch_embedding("Gateway Rollout", sketch_vec_dims)),
        sketch_vec_index(),
        "hybrid",
        10,
        true,
        None,
        Some(sketch_min_vec_score)
      )
      first_sk = try sk_hits.first.or_fail(BadInput(reason: "missing sketch hit"))
      if first_sk.page_id != pg_pub.id or first_sk.fts_rank != Some(1) or first_sk.vec_rank != Some(1)
        return Error(BadInput(reason: "expected dual fts_rank+vec_rank on Gateway Rollout"))
      end
      Ok(Unit)
    end
  )
  assert verify is Ok(Unit)

  # Archiving pg_pub removes both sketch and neural vectors; switching pg_other to 8-d cleans up old 4-d slot
  archived_pub = Page(
    id: pg_pub.id,
    collection_id: pg_pub.collection_id,
    parent_page_id: None,
    title: pg_pub.title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: Some(t0),
    version: 2
  )
  cleanup_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "archive page and switch neural dim",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_save_page_and_blocks(tx, archived_pub, [])
      t2 = try tx_put_page_neural_vector(
        t1,
        pg_other.id,
        pg_other.collection_id,
        8,
        [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
      )
      Ok((t2, Unit))
    end
  )
  assert cleanup_res is Ok(Unit)

  verify_after = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pub_doc = try Vec.get_doc(store, neural_vec_index(4), pg_pub.id).map_error(map_vec_error)
      return Error(BadInput(reason: "expected archived pub neural vec gone")) if pub_doc != None
      old_other = try Vec.get_doc(store, neural_vec_index(4), pg_other.id).map_error(map_vec_error)
      return Error(BadInput(reason: "expected old 4d vector removed on 8d reindex")) if old_other !=
        None
      new_other = try Vec.get_doc(store, neural_vec_index(8), pg_other.id).map_error(map_vec_error)
      return Error(BadInput(reason: "expected 8d vector present")) if new_other == None
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      return Error(BadInput(reason: "expected 5 invariants")) if rep.invariants_checked != 5
      Ok(Unit)
    end
  )
  assert verify_after is Ok(Unit)
end

test "truncate_text_bytes, diff-only tx_save_page_and_blocks, and large-doc sketch search"
  assert truncate_text_bytes("hello", 0) == ""
  assert truncate_text_bytes("hello", 5) == "hello"
  assert truncate_text_bytes("hello 😀 world", 9) == "hello "
  assert truncate_text_bytes("hello 😀 world", 10) == "hello 😀"

  files = Files.in_memory({})
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  t1_time = Time.parse("2026-11-26T12:01:00Z") or stop "t1"
  schema = vellum_schema()
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "db.diff_test",
    reason: "verify diff-only block puts and truncated sketch indexing",
    at: t0
  )
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: t0
  )
  large_tail = " filler word".repeat(500)
  pg = Page(
    id: "pg_diff",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Kernel Runbook",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  b1 = Block(
    id: "blk_d1",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0001",
    kind: Paragraph,
    markdown: "Unchanged quantum telemetry lead paragraph.#{large_tail}",
    provenance: prov,
    version: 1
  )
  b2 = Block(
    id: "blk_d2",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0002",
    kind: Paragraph,
    markdown: "Original second paragraph.",
    provenance: prov,
    version: 1
  )
  b3 = Block(
    id: "blk_d3",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0003",
    kind: Paragraph,
    markdown: "Deleted third paragraph.",
    provenance: prov,
    version: 1
  )

  seed = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed diff test",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t_next = try tx_save_page_and_blocks(tx, pg, [b1, b2, b3])
      Ok((t_next, Unit))
    end
  )
  assert seed is Ok(Unit)

  pg_v2 = Page(
    id: pg.id,
    collection_id: pg.collection_id,
    parent_page_id: None,
    title: pg.title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t1_time,
    archived_at: None,
    version: 2
  )
  b2_v2 = Block(
    id: "blk_d2",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0002",
    kind: Paragraph,
    markdown: "Edited second paragraph.",
    provenance: prov,
    version: 2
  )
  b4 = Block(
    id: "blk_d4",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0004",
    kind: Paragraph,
    markdown: "Inserted fourth paragraph.",
    provenance: prov,
    version: 1
  )

  diff_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "diff update",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t_next = try tx_save_page_and_blocks(tx, pg_v2, [b1, b2_v2, b4])
      puts_cnt = Modb.tx_touched_puts(t_next, blocks_table().bucket).size
      Ok((t_next, puts_cnt))
    end
  )
  assert diff_res == Ok(2)

  verify = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      loaded = try load_page_blocks(store, pg.id)
      return Error(BadInput(reason: "expected 3 blocks after diff update")) if loaded != [
        b1,
        b2_v2,
        b4
      ]
      auth = AuthContext(
        principal: Principal(
          id: "usr_ada",
          kind: Human,
          handle: "ada",
          display_name: "Ada",
          email: Some("ada@example.com"),
          avatar_url: None,
          role: Owner,
          model_id: None,
          root_grant_id: "gr_root",
          suspended: false,
          created_at: t0,
          last_seen_at: None
        ),
        grant_id: "gr_root",
        session: None,
        allowed_collections: None,
        allowed_actions: ["read"]
      )
      q_txt = "Kernel Runbook quantum telemetry"
      hits = try search_pages_hybrid(
        store,
        auth,
        q_txt,
        Some(Vec.text_sketch_embedding(q_txt, sketch_vec_dims)),
        sketch_vec_index(),
        "hybrid",
        10,
        true,
        None,
        Some(sketch_min_vec_score)
      )
      first_h = try hits.first.or_fail(BadInput(reason: "expected sketch hit on >5KiB doc"))
      return Error(BadInput(reason: "wrong doc hit")) if first_h.page_id != pg.id
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      return Error(BadInput(reason: "expected invariants")) if rep.invariants_checked < 5
      Ok(Unit)
    end
  )
  assert verify is Ok(Unit)
end
