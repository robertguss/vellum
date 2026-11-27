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
tx_index_page_with_extra,
tx_save_page_and_blocks,
tx_delete_page_and_blocks,
blueprints_by_slug,
blueprints_table,
page_meta_by_blueprint,
page_meta_table,
summaries_by_collection,
summaries_table,
packs_by_slug,
packs_table,
page_summary_key,
db_summary_key,
tx_refresh_db_summary,
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
proposals_by_database,
tx_clean_removed_db_properties,
tx_enrich_rows_with_rollups,
materialize_world_tx,
world_touches_schema?,
world_touched_resources,
compute_db_decimal_deltas,
tx_apply_world_patch,
world_catalog,
replay_catalog,
AiFeedSyncResult(..),
ai_cell_meta_by_database,
ai_cell_meta_table,
ai_col_usage_table,
proposal_comments_by_proposal,
proposal_comments_table,
map_feeds_error,
ai_col_feed_id,
ensure_ai_col_feed_locked,
sync_ai_col_feed_locked
use Domain.Blocks
use Domain.Blueprints{BlueprintDef, PageBlueprintMeta}
use Domain.FeedBridge
use Domain.Packs{ContextPack, LivingSummary}
use Domain.Collab{
  DecimalDelta,
  ProposalComment,
  ProposalMeta,
  WebhookSub,
  WorldBranchArgs,
  WorldMutation,
  WorldPatchArgs
}
use Domain.DatabaseModel{
  AiCellMeta,
  AiColumnMode,
  AiColumnUsage,
  AiOutputKind,
  CellValue,
  DatabaseDef,
  DbRow,
  DbViewDef,
  DbViewKind,
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
  BlockOp,
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
use Modb.Feeds
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

fn proposals_by_database() : Table.Index(Text, ProposalMeta, Text)
  Table.text_index[Text, ProposalMeta]("vlm_proposals_by_database", fn(p) p.target_database_id or "" end)
end

fn proposals_table() : Table.Table(Text, ProposalMeta)
  Table.text_key[ProposalMeta]("vlm_proposals").with_index(proposals_by_status()).with_index(
    proposals_by_page()
  ).with_index(proposals_by_database())
end

fn webhooks_by_workspace() : Table.Index(Text, WebhookSub, Text)
  Table.text_index[Text, WebhookSub]("vlm_webhooks_by_workspace", fn(w) w.workspace_id end)
end

fn webhooks_table() : Table.Table(Text, WebhookSub)
  Table.text_key[WebhookSub]("vlm_webhooks").with_index(webhooks_by_workspace())
end

fn blueprints_by_slug() : Table.Index(Text, BlueprintDef, Text)
  Table.unique_text_index[Text, BlueprintDef]("vlm_blueprints_by_slug", fn(bp) bp.slug end)
end

fn blueprints_table() : Table.Table(Text, BlueprintDef)
  Table.text_key[BlueprintDef]("vlm_blueprints").with_index(blueprints_by_slug())
end

fn page_meta_by_blueprint() : Table.Index(Text, PageBlueprintMeta, Text)
  Table.text_index[Text, PageBlueprintMeta]("vlm_page_meta_by_blueprint", fn(pm) pm.blueprint_id end)
end

fn page_meta_table() : Table.Table(Text, PageBlueprintMeta)
  Table.text_key[PageBlueprintMeta]("vlm_page_meta").with_index(page_meta_by_blueprint())
end

fn page_summary_key(page_id: Text) : Text
  "page:#{page_id}"
end

fn db_summary_key(db_id: Text) : Text
  "db:#{db_id}"
end

fn summaries_by_collection() : Table.Index(Text, LivingSummary, Text)
  Table.text_index[Text, LivingSummary]("vlm_summaries_by_collection", fn(s) s.collection_id end)
end

fn summaries_table() : Table.Table(Text, LivingSummary)
  Table.text_key[LivingSummary]("vlm_summaries").with_index(summaries_by_collection())
end

fn packs_by_slug() : Table.Index(Text, ContextPack, Text)
  Table.unique_text_index[Text, ContextPack]("vlm_packs_by_slug", fn(p) p.slug end)
end

fn packs_table() : Table.Table(Text, ContextPack)
  Table.text_key[ContextPack]("vlm_packs").with_index(packs_by_slug())
end

## Deterministic `Modb.Feeds` subscription ID tracking source changes for a database's `AiDerived` columns.
fn ai_col_feed_id(db_id: Text) : Text
  "ai-col:#{db_id}"
end

fn ai_cell_meta_by_database() : Table.Index(Text, AiCellMeta, Text)
  Table.text_index[Text, AiCellMeta]("vlm_ai_cell_meta_by_db", fn(m) m.database_id end)
end

fn ai_cell_meta_table() : Table.Table(Text, AiCellMeta)
  Table.text_key[AiCellMeta]("vlm_ai_cell_meta").with_index(ai_cell_meta_by_database())
end

fn ai_col_usage_table() : Table.Table(Text, AiColumnUsage)
  Table.text_key[AiColumnUsage]("vlm_ai_col_usage")
end

fn proposal_comments_by_proposal() : Table.Index(Text, ProposalComment, Text)
  Table.text_index[Text, ProposalComment]("vlm_proposal_comments_by_proposal", fn(c)
    c.proposal_id
  end)
end

fn proposal_comments_table() : Table.Table(Text, ProposalComment)
  Table.text_key[ProposalComment]("vlm_proposal_comments").with_index(
    proposal_comments_by_proposal()
  )
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

## Converts `Modb.Feeds` errors to `AppError`.
fn map_feeds_error(err: Feeds.FeedError) : AppError
  case err
    Feeds.LedgerFailure(le): map_ledger_error(le)
    Feeds.GrantFailure(ge): map_grants_error(ge)
    Feeds.PolicyFailure(_): Forbidden(reason: Feeds.to_text(err))
    Feeds.FeedNotFound(id: fid): Missing(entity: "feed", id: fid)
    Feeds.FeedAlreadyExists(id: _) | Feeds.CursorStale(
      feed_id: _,
      expected_txid: _,
      actual_txid: _
    ): Conflict(reason: Feeds.to_text(err))
    Feeds.InvalidFeed(reason: _) | Feeds.PinMissing(feed_id: _, pin_id: _): BadInput(
      reason: Feeds.to_text(err)
    )
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
      ) | Checkbox | Person | Url | Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): Unit
    end
  end
  Ok(None)
end

fn check_single_page_meta(
  tx: WriteTx,
  bps_tbl: Table.Table(Text, BlueprintDef),
  pages_tbl: Table.Table(Text, Page),
  pid: Text,
  meta: PageBlueprintMeta
) : Result(Option(Text), Table.TableError)
  if meta.page_id != pid
    return Ok(Some("page_meta '#{pid}' has mismatched page_id '#{meta.page_id}'"))
  end
  case try Table.tx_get(tx, pages_tbl, pid)
    Some(p) if p.archived_at == None and p.kind == Document: Unit
    Some(_) | None: return Ok(
      Some("page_meta '#{pid}' references missing, archived, or non-Document page")
    )
  end
  bp = case try Table.tx_get(tx, bps_tbl, meta.blueprint_id)
    Some(b): b
    None: return Ok(Some("page_meta '#{pid}' references missing blueprint '#{meta.blueprint_id}'"))
  end
  Ok(Blueprints.validate_page_meta(bp, meta.values))
end

## Declarative `Modb.Ledger` schema enforcing mandatory write reasons, v1 bootstrap,
## and incremental `$O(\text{touched})$` invariants across collections, pages, blocks, databases, and blueprints.
fn vellum_schema() : Ledger.Schema
  cols = collections_table()
  pages = pages_table()
  blocks = blocks_table()
  dbs = databases_table()
  db_rows = db_rows_table()
  bps = blueprints_table()
  page_metas = page_meta_table()
  packs = packs_table()
  ai_metas = ai_cell_meta_table()
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
        bad_block = case b.kind
          Heading(level: lvl): lvl < 1 or lvl > 3
          DatabaseViewEmbed(database_id: db_id, view_id: _): db_id.trim.empty?
          AiBrief(prompt: pr, source_scope: _, refreshed_at: _): pr.trim.empty?
          Paragraph | BulletListItem | OrderedListItem(start: _) | TaskItem(checked: _) | Quote | Callout(
            tone: _,
            icon: _
          ) | CodeBlock(language: _) | Divider | Image(attachment_id: _, caption: _) | FileEmbed(
            attachment_id: _,
            filename: _
          ) | PageLink(target_page_id: _): false
        end
        if bad_block or b.version < 1
          Some("block '#{id}' has invalid heading level, empty embed target, or version < 1")
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
  ).with_invariant(
    Ledger.row_invariant("blueprint_valid", bps, fn(_id, bp) Blueprints.validate_blueprint_def(bp) end)
  ).with_invariant(
    Ledger.invariant(
      "page_meta_integrity",
      fn(tx)
        if Modb.tx_is_tracked?(tx) and not Modb.tx_bucket_deleted?(tx, page_metas.bucket)
          for kb in Modb.tx_touched_puts(tx, page_metas.bucket)
            case try Modb.tx_get(tx, page_metas.bucket, kb).map_error(fn(e) Table.Storage(e) end)
              Some(raw):
                meta = try page_metas.decode_value(raw).map_error(
                  fn(e) Table.DecodeValue(e) end
                )
                case try check_single_page_meta(tx, bps, pages, meta.page_id, meta)
                  Some(detail): return Ok(Some(detail))
                  None: Unit
                end
              None: Unit
            end
          end
          Ok(None)
        else
          all_metas = try Table.tx_scan(tx, page_metas, None, None, 0)
          for (pid, meta) in all_metas
            case try check_single_page_meta(tx, bps, pages, pid, meta)
              Some(detail): return Ok(Some(detail))
              None: Unit
            end
          end
          Ok(None)
        end
      end
    )
  ).with_invariant(
    Ledger.row_invariant("pack_valid", packs, fn(_id, p) Packs.validate_context_pack(p) end)
  ).with_invariant(
    Ledger.row_invariant(
      "ai_cell_meta_valid",
      ai_metas,
      fn(id, m)
        if m.database_id.trim.empty? or m.row_id.trim.empty? or m.prop_id.trim.empty? or m.model
          .trim
          .empty?
          Some("ai_cell_meta '#{id}' requires database_id, row_id, prop_id, and model")
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

## Indexes `page`, optional extra plain text (e.g. blueprint fields or DB properties), and `blocks`
## into both `Modb.Fts` and `Modb.Vec` (sketch index) inside `tx`.
fn tx_index_page_with_extra(
  tx: WriteTx,
  page: Page,
  blocks: List(Block),
  extra_text: Option(Text)
) : Result(WriteTx, AppError)
  body_plain = Blocks.blocks_plain_text(blocks)
  extra_trimmed = case extra_text
    Some(e): e.trim
    None: ""
  end
  combined_body = if extra_trimmed.empty?
    body_plain
  else if body_plain.trim.empty?
    extra_trimmed
  else
    "#{extra_trimmed}\n#{body_plain}"
  end
  doc = Fts.DocumentInput(
    doc_id: page.id,
    scope: page.collection_id,
    fields: [
      Fts.FieldInput(name: "title", text: page.title, weight: 3),
      Fts.FieldInput(name: "body", text: combined_body, weight: 1)
    ]
  )
  t1 = try Fts.tx_index_document(tx, fts_index(), doc).map_error(map_fts_error)
  embed_txt = truncate_text_bytes(page_embedding_text(page, blocks, extra_text), 4096)
  vec_inp = Vec.VectorInput(
    doc_id: page.id,
    scope: page.collection_id,
    values: Vec.text_sketch_embedding(embed_txt, sketch_vec_dims)
  )
  Vec.tx_put_vector(t1, sketch_vec_index(), vec_inp).map_error(map_vec_error)
end

## Indexes `page`, its attached blueprint metadata (for `Document` pages), and its `blocks`
## into both `Modb.Fts` and `Modb.Vec` (sketch index) inside `tx`.
fn tx_index_page(tx: WriteTx, page: Page, blocks: List(Block)) : Result(WriteTx, AppError)
  extra = if page.kind == Document
    case try Table.tx_get(tx, page_meta_table(), page.id).map_error(map_table_error)
      Some(pm):
        case try Table.tx_get(tx, blueprints_table(), pm.blueprint_id).map_error(map_table_error)
          Some(bp): Some(Blueprints.page_meta_plain_text(bp, pm))
          None: None
        end
      None: None
    end
  else
    None
  end
  tx_index_page_with_extra(tx, page, blocks, extra)
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

fn tx_refresh_page_summary(tx: WriteTx, page: Page, blocks: List(Block)) : Result(WriteTx, AppError)
  pm_opt = try Table.tx_get(tx, page_meta_table(), page.id).map_error(map_table_error)
  bp_opt = case pm_opt
    Some(pm): try Table.tx_get(tx, blueprints_table(), pm.blueprint_id).map_error(map_table_error)
    None: None
  end
  key = page_summary_key(page.id)
  prev_opt = try Table.tx_get(tx, summaries_table(), key).map_error(map_table_error)
  summary = Packs.build_page_summary(page, blocks, bp_opt, pm_opt, prev_opt, page.updated_at)
  Table.put(tx, summaries_table(), summary.id, summary).map_error(map_table_error)
end

## Atomically persists `page`, replaces its blocks, and updates `Modb.Fts`, `Modb.Vec`, and `LivingSummary` inside `tx`.
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
    t_idx = try tx_index_page(cur, page, blocks)
    if page.kind == Document
      tx_refresh_page_summary(t_idx, page, blocks)
    else
      Ok(t_idx)
    end
  else
    t_fts = try Fts.tx_remove_document(cur, fts_index(), page.id).map_error(map_fts_error)
    t_vec = try tx_remove_page_vectors(t_fts, page.id)
    sum_key = page_summary_key(page.id)
    case try Table.tx_get(t_vec, summaries_table(), sum_key).map_error(map_table_error)
      Some(_sm): Table.delete(t_vec, summaries_table(), sum_key).map_error(map_table_error)
      None: Ok(t_vec)
    end
  end
end

## Atomically removes `page_id`, any attached blueprint metadata, its living summary, all of its blocks,
## its FTS entry, and its vector index entries inside `tx`.
fn tx_delete_page_and_blocks(tx: WriteTx, page_id: Text) : Result(WriteTx, AppError)
  btbl = blocks_table()
  bidx = blocks_by_page()
  existing = try Table.tx_lookup(tx, btbl, bidx, page_id).map_error(map_table_error)
  var cur = tx
  for (bid, _b) in existing
    cur = try Table.delete(cur, btbl, bid).map_error(map_table_error)
  end
  case try Table.tx_get(cur, page_meta_table(), page_id).map_error(map_table_error)
    Some(_pm): cur = try Table.delete(cur, page_meta_table(), page_id).map_error(map_table_error)
    None: Unit
  end
  sum_key = page_summary_key(page_id)
  case try Table.tx_get(cur, summaries_table(), sum_key).map_error(map_table_error)
    Some(_sm): cur = try Table.delete(cur, summaries_table(), sum_key).map_error(map_table_error)
    None: Unit
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

fn tx_refresh_db_summary(tx: WriteTx, def: DatabaseDef, now: Time) : Result(WriteTx, AppError)
  pairs = try Table.tx_lookup(tx, db_rows_table(), db_rows_by_database(), def.id).map_error(
    map_table_error
  )
  active = pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end)
  enriched = try tx_enrich_rows_with_rollups(tx, def, active)
  key = db_summary_key(def.id)
  prev_opt = try Table.tx_get(tx, summaries_table(), key).map_error(map_table_error)
  sum = Packs.build_database_summary(def, enriched, prev_opt, now)
  Table.put(tx, summaries_table(), sum.id, sum).map_error(map_table_error)
end

## Atomically persists a `DbRow`, its `vlm_db_cells` composite indexes, its backing `Page` + `Block`s,
## combined title + properties + body text in `Modb.Fts`, and the database `LivingSummary`.
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
    t5 = try Vec.tx_put_vector(t4, sketch_vec_index(), vec_inp).map_error(map_vec_error)
    tx_refresh_db_summary(t5, def, row.updated_at)
  else
    tx_refresh_db_summary(t3, def, row.updated_at)
  end
end

## Atomically deletes a `DbRow`, its `vlm_db_cells` entries, backing `Page` + `Block`s, FTS entry,
## and updates the parent database `LivingSummary`.
fn tx_delete_db_row(tx: WriteTx, def: DatabaseDef, row_id: Text) : Result(WriteTx, AppError)
  old_row = case try Table.tx_get(tx, db_rows_table(), row_id).map_error(map_table_error)
    Some(r): r
    None: return Error(Missing(entity: "db_row", id: row_id))
  end
  t1 = try tx_update_db_cell_index(tx, def.id, Some(old_row), None)
  t2 = try Table.delete(t1, db_rows_table(), row_id).map_error(map_table_error)
  t3 = try tx_delete_page_and_blocks(t2, old_row.page_id)
  var t4 = t3
  for p in def.properties
    mk = DatabaseModel.ai_cell_meta_key(def.id, row_id, p.id)
    if (try Table.tx_get(t4, ai_cell_meta_table(), mk).map_error(map_table_error)) != None
      t4 = try Table.delete(t4, ai_cell_meta_table(), mk).map_error(map_table_error)
    end
  end
  tx_refresh_db_summary(t4, def, old_row.updated_at)
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
      ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): Unit
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

## Resolves all `Rollup` columns for `rows` of `def` by fetching referenced target rows from an open `WriteTx`.
fn tx_enrich_rows_with_rollups(tx: WriteTx, def: DatabaseDef, rows: List(DbRow)) : Result(
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
      ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): Unit
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
            fetched = try Table.tx_get(tx, rtbl, rid).map_error(map_table_error)
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

fn clean_view_removed_props(v: DbViewDef, removed_set: Set(Text)) : Result(
  (DbViewDef, Bool),
  AppError
)
  next_kind = case v.kind
    TableView(visible_prop_ids: vpids, column_widths: cw):
      nvpids = vpids.filter(fn(pid) not removed_set.has?(pid) end)
      var next_cw = {}
      for (k, w) in cw.entries
        if not removed_set.has?(k)
          next_cw = next_cw.set(k, w)
        end
      end
      TableView(visible_prop_ids: nvpids, column_widths: next_cw)
    BoardView(group_by_prop_id: gb_id, card_prop_ids: cpids, hide_empty_groups: hide):
      if removed_set.has?(gb_id)
        return Error(
          BadInput(reason: "cannot remove property '#{gb_id}' used to group view '#{v.name}'")
        )
      end
      ncpids = cpids.filter(fn(pid) not removed_set.has?(pid) end)
      BoardView(group_by_prop_id: gb_id, card_prop_ids: ncpids, hide_empty_groups: hide)
    CalendarView(date_prop_id: dp_id, card_prop_ids: cpids):
      if removed_set.has?(dp_id)
        return Error(
          BadInput(reason: "cannot remove date property '#{dp_id}' used by view '#{v.name}'")
        )
      end
      ncpids = cpids.filter(fn(pid) not removed_set.has?(pid) end)
      CalendarView(date_prop_id: dp_id, card_prop_ids: ncpids)
  end
  next_filters = v.filters.filter(fn(f) not removed_set.has?(f.prop_id) end)
  next_sorts = v.sorts.filter(fn(s) not removed_set.has?(s.prop_id) end)
  next_v = DbViewDef(
    id: v.id,
    database_id: v.database_id,
    name: v.name,
    kind: next_kind,
    filters: next_filters,
    filter_match_all: v.filter_match_all,
    sorts: next_sorts,
    sort_order: v.sort_order
  )
  Ok((next_v, next_v != v))
end

## Validates existing rows against `next_def`, strips removed column cells & cell indexes,
## cleans/validates saved views referencing removed columns, and saves `next_def`.
fn tx_clean_removed_db_properties(tx: WriteTx, old_def: DatabaseDef, next_def: DatabaseDef) : Result(
  WriteTx,
  AppError
)
  next_prop_ids = next_def.properties.map(fn(p) p.id end).to_set
  var removed_ids = []
  for p in old_def.properties
    if not next_prop_ids.has?(p.id)
      removed_ids = removed_ids.append(p.id)
    end
  end
  removed_set = removed_ids.to_set

  var cur = tx
  row_pairs = try Table.tx_lookup(cur, db_rows_table(), db_rows_by_database(), old_def.id)
    .map_error(map_table_error)
  for (_rid, row) in row_pairs
    if row.archived_at == None
      var next_cells = row.cells
      var changed? = false
      if not removed_set.empty?
        var kept = {}
        for (cid, cval) in row.cells.entries
          if removed_set.has?(cid)
            changed? = true
          else
            kept = kept.set(cid, cval)
          end
        end
        next_cells = kept
      end
      cleaned_row = DbRow(
        id: row.id,
        database_id: row.database_id,
        page_id: row.page_id,
        cells: next_cells,
        created_by: row.created_by,
        created_at: row.created_at,
        updated_at: row.updated_at,
        archived_at: row.archived_at,
        version: row.version
      )
      case DatabaseModel.validate_row_cells(next_def, cleaned_row)
        Some(msg): return Error(
          BadInput(reason: "schema update incompatible with row '#{row.id}': #{msg}")
        )
        None: Unit
      end
      if changed?
        cur = try tx_update_db_cell_index(cur, old_def.id, Some(row), Some(cleaned_row))
        cur = try Table.put(cur, db_rows_table(), cleaned_row.id, cleaned_row).map_error(
          map_table_error
        )
      end
      for rem_pid in removed_ids
        mk = DatabaseModel.ai_cell_meta_key(old_def.id, row.id, rem_pid)
        if (try Table.tx_get(cur, ai_cell_meta_table(), mk).map_error(map_table_error)) != None
          cur = try Table.delete(cur, ai_cell_meta_table(), mk).map_error(map_table_error)
        end
      end
    end
  end

  if not removed_set.empty?
    view_pairs = try Table.tx_lookup(cur, db_views_table(), db_views_by_database(), old_def.id)
      .map_error(map_table_error)
    for (_vid, v) in view_pairs
      (next_v, v_changed?) = try clean_view_removed_props(v, removed_set)
      if v_changed?
        cur = try Table.put(cur, db_views_table(), next_v.id, next_v).map_error(map_table_error)
      end
    end
  end

  Table.put(cur, databases_table(), next_def.id, next_def).map_error(map_table_error)
end

fn tx_apply_page_patch_inner(
  tx: WriteTx,
  page_id: Text,
  ops: List(BlockOp),
  new_ids: List(Text),
  provenance: Provenance,
  expected_versions: Map(Text, Int),
  updated_at: Time
) : Result((WriteTx, Json), Text)
  old_page = case try Table.tx_get(tx, pages_table(), page_id).map_error(fn(e) e.to_text end)
    Some(p) if p.archived_at == None: p
    Some(_) | None: return Error("page '#{page_id}' not found or archived")
  end

  existing_rows = try Table.tx_lookup(tx, blocks_table(), blocks_by_page(), page_id).map_error(
    fn(e) e.to_text end
  )
  existing_blocks = Blocks.sort_blocks(existing_rows.map(fn(x) x.1 end))

  var ver_by_id = {}
  for b in existing_blocks
    ver_by_id = ver_by_id.set(b.id, b.version)
  end
  for (bid, exp_ver) in expected_versions.entries
    case ver_by_id.get(bid)
      None: return Error("block '#{bid}' not found")
      Some(actual_ver):
        if actual_ver != exp_ver
          return Error("expected version #{exp_ver} on block '#{bid}', found #{actual_ver}")
        end
    end
  end

  updated_blocks = try Blocks.apply_block_ops(existing_blocks, ops, page_id, provenance, new_ids)
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
    updated_at: updated_at,
    archived_at: old_page.archived_at,
    version: old_page.version + 1
  )
  next_tx = try tx_save_page_and_blocks(tx, bumped_page, updated_blocks).map_error(to_text)
  Ok((
    next_tx,
    Json.Object({
      "kind": Json.String("page_patch"),
      "page_id": Json.String(bumped_page.id),
      "page_version": Json.int(bumped_page.version),
      "block_count": Json.int(updated_blocks.size)
    })
  ))
end

## Replayable `Modb.World` + `Modb.Replay` action handler supporting both legacy `WorldPatchArgs`
## and unified multi-resource `WorldBranchArgs` (`PatchPageBlocks`, DB row/schema mutations) inside `tx`.
fn tx_apply_world_patch(tx: WriteTx, args_json: Json) : Result((WriteTx, Json), Text)
  if args_json.get("mutation") != None
    bargs = try Json.decode_strict[WorldBranchArgs](args_json.to_text.bytes).map_error(
      fn(e) e.to_text end
    )
    return case bargs.mutation
      PatchPageBlocks(
        page_id: pid,
        ops: ops,
        new_ids: nids,
        provenance: prov,
        expected_versions: exp_vers
      ): tx_apply_page_patch_inner(tx, pid, ops, nids, prov, exp_vers, bargs.updated_at)
      CreateDbRow(
        database_id: did,
        row_id: rid,
        page_id: pid,
        cells: cells,
        markdown: md_opt,
        block_prefix: blk_pref,
        provenance: prov
      ):
        def = case try Table.tx_get(tx, databases_table(), did).map_error(fn(e) e.to_text end)
          Some(d): d
          None: return Error("database '#{did}' not found")
        end
        row = DbRow(
          id: rid,
          database_id: def.id,
          page_id: pid,
          cells: cells,
          created_by: prov.author_id,
          created_at: bargs.updated_at,
          updated_at: bargs.updated_at,
          archived_at: None,
          version: 1
        )
        case DatabaseModel.validate_row_cells(def, row)
          Some(msg): return Error(msg)
          None: Unit
        end
        blocks = case md_opt
          Some(md) if not md.trim.empty?: Blocks.parse_markdown_blocks(pid, md, prov, blk_pref)
          Some(_) | None: []
        end
        page = Page(
          id: pid,
          collection_id: def.collection_id,
          parent_page_id: Some(def.page_id),
          title: DatabaseModel.extract_row_title(def, cells),
          icon: None,
          cover_attachment_id: None,
          kind: DatabaseRow(database_id: def.id, row_id: rid),
          sort_order: rid,
          database_id: Some(def.id),
          freshness_ttl_days: None,
          verified_at: None,
          verified_by: None,
          created_by: prov.author_id,
          created_at: bargs.updated_at,
          updated_at: bargs.updated_at,
          archived_at: None,
          version: 1
        )
        next_tx = try tx_put_db_row(tx, def, row, page, blocks).map_error(to_text)
        Ok((
          next_tx,
          Json.Object({
            "kind": Json.String("db_row_create"),
            "database_id": Json.String(def.id),
            "row_id": Json.String(row.id),
            "page_id": Json.String(page.id)
          })
        ))
      UpdateDbRow(
        database_id: did,
        row_id: rid,
        cells: cell_updates,
        expected_version: exp_ver_opt,
        provenance: _
      ):
        def = case try Table.tx_get(tx, databases_table(), did).map_error(fn(e) e.to_text end)
          Some(d): d
          None: return Error("database '#{did}' not found")
        end
        old_row = case try Table.tx_get(tx, db_rows_table(), rid).map_error(fn(e) e.to_text end)
          Some(r) if r.database_id == def.id and r.archived_at == None: r
          Some(_) | None: return Error("db_row '#{rid}' not found")
        end
        case exp_ver_opt
          Some(ev) if old_row.version != ev: return Error(
            "db_row '#{rid}' version mismatch: expected #{ev}, found #{old_row.version}"
          )
          Some(_) | None: Unit
        end
        var merged_cells = old_row.cells
        for (k, v) in cell_updates.entries
          merged_cells = merged_cells.set(k, v)
        end
        bumped_row = DbRow(
          id: old_row.id,
          database_id: old_row.database_id,
          page_id: old_row.page_id,
          cells: merged_cells,
          created_by: old_row.created_by,
          created_at: old_row.created_at,
          updated_at: bargs.updated_at,
          archived_at: old_row.archived_at,
          version: old_row.version + 1
        )
        case DatabaseModel.validate_row_cells(def, bumped_row)
          Some(msg): return Error(msg)
          None: Unit
        end
        old_page = case try Table.tx_get(tx, pages_table(), old_row.page_id).map_error(
          fn(e) e.to_text end
        )
          Some(p): p
          None: return Error("page '#{old_row.page_id}' not found")
        end
        block_rows = try Table.tx_lookup(tx, blocks_table(), blocks_by_page(), old_page.id)
          .map_error(fn(e) e.to_text end)
        existing_blocks = Blocks.sort_blocks(block_rows.map(fn(x) x.1 end))
        bumped_page = Page(
          id: old_page.id,
          collection_id: old_page.collection_id,
          parent_page_id: old_page.parent_page_id,
          title: DatabaseModel.extract_row_title(def, merged_cells),
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
          updated_at: bargs.updated_at,
          archived_at: old_page.archived_at,
          version: old_page.version + 1
        )
        next_tx = try tx_put_db_row(tx, def, bumped_row, bumped_page, existing_blocks).map_error(
          to_text
        )
        Ok((
          next_tx,
          Json.Object({
            "kind": Json.String("db_row_update"),
            "database_id": Json.String(def.id),
            "row_id": Json.String(bumped_row.id),
            "version": Json.int(bumped_row.version)
          })
        ))
      DeleteDbRow(database_id: did, row_id: rid):
        def = case try Table.tx_get(tx, databases_table(), did).map_error(fn(e) e.to_text end)
          Some(d): d
          None: return Error("database '#{did}' not found")
        end
        _old_row = case try Table.tx_get(tx, db_rows_table(), rid).map_error(fn(e) e.to_text end)
          Some(r) if r.database_id == def.id and r.archived_at == None: r
          Some(_) | None: return Error("db_row '#{rid}' not found")
        end
        next_tx = try tx_delete_db_row(tx, def, rid).map_error(to_text)
        Ok((
          next_tx,
          Json.Object({
            "kind": Json.String("db_row_delete"),
            "database_id": Json.String(def.id),
            "row_id": Json.String(rid)
          })
        ))
      UpdateDbSchema(
        database_id: did,
        title: title_opt,
        description: desc_opt,
        properties: props_opt,
        expected_version: exp_ver_opt
      ):
        old_def = case try Table.tx_get(tx, databases_table(), did).map_error(fn(e) e.to_text end)
          Some(d): d
          None: return Error("database '#{did}' not found")
        end
        case exp_ver_opt
          Some(ev) if old_def.version != ev: return Error(
            "database '#{did}' version mismatch: expected #{ev}, found #{old_def.version}"
          )
          Some(_) | None: Unit
        end
        next_def = DatabaseDef(
          id: old_def.id,
          collection_id: old_def.collection_id,
          page_id: old_def.page_id,
          title: case title_opt
            Some(t): t.trim
            None: old_def.title
          end,
          description: case desc_opt
            Some(d): d.trim
            None: old_def.description
          end,
          properties: case props_opt
            Some(ps): ps
            None: old_def.properties
          end,
          version: old_def.version + 1
        )
        case DatabaseModel.validate_database_def(next_def)
          Some(msg): return Error(msg)
          None: Unit
        end
        next_tx = try tx_clean_removed_db_properties(tx, old_def, next_def).map_error(to_text)
        Ok((
          next_tx,
          Json.Object({
            "kind": Json.String("db_schema_update"),
            "database_id": Json.String(next_def.id),
            "version": Json.int(next_def.version)
          })
        ))
      PutAiCellMeta(meta: m):
        next_tx = try Table.put(tx, ai_cell_meta_table(), m.id, m).map_error(fn(e) e.to_text end)
        Ok((
          next_tx,
          Json.Object({
            "kind": Json.String("put_ai_cell_meta"),
            "database_id": Json.String(m.database_id),
            "row_id": Json.String(m.row_id),
            "prop_id": Json.String(m.prop_id)
          })
        ))
    end
  end

  args = try Json.decode_strict[WorldPatchArgs](args_json.to_text.bytes).map_error(
    fn(e) e.to_text end
  )
  tx_apply_page_patch_inner(
    tx,
    args.page_id,
    args.ops,
    args.new_ids,
    args.provenance,
    args.expected_versions,
    args.updated_at
  )
end

## Reconstructs `(base_tx, speculative_tx)` in memory for an open `WorldRecord` (zero disk writes).
fn materialize_world_tx(store: Store, world: World.WorldRecord) : Result((WriteTx, WriteTx), AppError)
  pin = case try Modb.get_pin(store, world.base_pin_id).map_error(fn(e)
    ServerFailed(reason: e.to_text)
  end)
    Some(p): p
    None: return Error(
      Conflict(reason: "world '#{world.id}' base pin '#{world.base_pin_id}' is no longer active")
    )
  end
  base_tx = Modb.begin_write_from_root(store, pin.catalog_root)
  var spec_tx = base_tx
  for step in world.steps
    case step
      World.ReadStep(query: _, args: _, answer_hash: _, answer: _): Unit
      World.CallStep(action: act_name, args: args_json, reason: _):
        if act_name == "propose"
          (next_tx, _reply) = try tx_apply_world_patch(spec_tx, args_json).map_error(fn(msg)
            Conflict(reason: msg)
          end)
          spec_tx = next_tx
        end
    end
  end
  Ok((base_tx, spec_tx))
end

## Whether any step in `world` stages a database schema mutation (`UpdateDbSchema`).
fn world_touches_schema?(world: World.WorldRecord) : Bool
  for step in world.steps
    case step
      World.ReadStep(query: _, args: _, answer_hash: _, answer: _): Unit
      World.CallStep(action: act_name, args: args_json, reason: _):
        if act_name == "propose" and args_json.get("mutation") != None
          case Json.decode_strict[WorldBranchArgs](args_json.to_text.bytes)
            Ok(bargs):
              case bargs.mutation
                UpdateDbSchema(
                  database_id: _,
                  title: _,
                  description: _,
                  properties: _,
                  expected_version: _
                ): return true
                PatchPageBlocks(
                  page_id: _,
                  ops: _,
                  new_ids: _,
                  provenance: _,
                  expected_versions: _
                ) | CreateDbRow(
                  database_id: _,
                  row_id: _,
                  page_id: _,
                  cells: _,
                  markdown: _,
                  block_prefix: _,
                  provenance: _
                ) | UpdateDbRow(
                  database_id: _,
                  row_id: _,
                  cells: _,
                  expected_version: _,
                  provenance: _
                ) | DeleteDbRow(database_id: _, row_id: _) | PutAiCellMeta(meta: _): Unit
              end
            Error(_): Unit
          end
        end
    end
  end
  false
end

fn append_unique_text(xs: List(Text), item: Text) : List(Text)
  t = item.trim
  return xs if t.empty? or xs.contains?(t)
  xs.append(t)
end

## Collects deduplicated `(page_ids, database_ids)` referenced across a `WorldRecord`'s steps.
fn world_touched_resources(
  world: World.WorldRecord,
  fallback_page_id: Text,
  fallback_db_id: Option(Text)
) : (List(Text), List(Text))
  var page_ids = case fallback_db_id
    Some(_): []
    None: append_unique_text([], fallback_page_id)
  end
  var db_ids = case fallback_db_id
    Some(did): append_unique_text([], did)
    None: []
  end
  for step in world.steps
    case step
      World.ReadStep(query: _, args: _, answer_hash: _, answer: _): Unit
      World.CallStep(action: act_name, args: args_json, reason: _):
        if act_name == "propose"
          if args_json.get("mutation") != None
            case Json.decode_strict[WorldBranchArgs](args_json.to_text.bytes)
              Ok(bargs):
                case bargs.mutation
                  PatchPageBlocks(
                    page_id: pid,
                    ops: _,
                    new_ids: _,
                    provenance: _,
                    expected_versions: _
                  ): page_ids = append_unique_text(page_ids, pid)
                  CreateDbRow(
                    database_id: did,
                    row_id: _,
                    page_id: _,
                    cells: _,
                    markdown: _,
                    block_prefix: _,
                    provenance: _
                  ) | UpdateDbRow(
                    database_id: did,
                    row_id: _,
                    cells: _,
                    expected_version: _,
                    provenance: _
                  ) | DeleteDbRow(database_id: did, row_id: _) | UpdateDbSchema(
                    database_id: did,
                    title: _,
                    description: _,
                    properties: _,
                    expected_version: _
                  ): db_ids = append_unique_text(db_ids, did)
                  PutAiCellMeta(meta: m): db_ids = append_unique_text(db_ids, m.database_id)
                end
              Error(_): Unit
            end
          else
            case Json.decode_strict[WorldPatchArgs](args_json.to_text.bytes)
              Ok(pargs): page_ids = append_unique_text(page_ids, pargs.page_id)
              Error(_): Unit
            end
          end
        end
    end
  end
  (page_ids, db_ids)
end

## Computes exact `Decimal` column and numeric `Rollup` sums & deltas between Live and Scenario rows.
fn compute_db_decimal_deltas(
  def: DatabaseDef,
  live_rows: List(EnrichedRow),
  scenario_rows: List(EnrichedRow)
) : List(DecimalDelta)
  var out = []
  for p in def.properties
    (include?, fmt, is_roll) = case p.kind
      Number(format: f): (true, f, false)
      AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: AiNumber(format: f),
        mode: _,
        daily_call_cap: _
      ): (true, f, false)
      Rollup(relation_prop_id: _, target_prop_id: _, agg: agg):
        always_num = case agg
          CountAll | CountValues | SumValues: true
          MinValue | MaxValue: false
        end
        (always_num, "plain", true)
      Title | RichText | DateProp(include_time: _) | Select(options: _) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
        target_db_id: _,
        inverse_prop_id: _
      ) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): (false, "plain", false)
    end
    var live_sum = 0.0
    var scen_sum = 0.0
    var saw_num = false
    for er in live_rows
      case DatabaseModel.effective_cell(er, p.id)
        NumberVal(d):
          live_sum += d
          saw_num = true
        Empty | TextVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
          option_ids: _
        ) | BoolVal(_) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
      end
    end
    for er in scenario_rows
      case DatabaseModel.effective_cell(er, p.id)
        NumberVal(d):
          scen_sum += d
          saw_num = true
        Empty | TextVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
          option_ids: _
        ) | BoolVal(_) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
      end
    end
    should_emit = if is_roll
      include? or saw_num
    else
      include?
    end
    if should_emit
      diff = scen_sum - live_sum
      out = out.append(
        DecimalDelta(
          database_id: def.id,
          database_title: def.title,
          prop_id: p.id,
          prop_name: p.name,
          format: fmt,
          is_rollup: is_roll,
          live_total: live_sum.to_text,
          scenario_total: scen_sum.to_text,
          delta: diff.to_text,
          changed: scen_sum != live_sum
        )
      )
    end
  end
  out
end

## Result returned by consuming the `Modb.Feeds` reactive subscription for an AI-compiled database.
struct AiFeedSyncResult
  feed_id: Text
  from_txid: Int
  to_txid: Int
  events_seen: Int
  pages_read: Int
  subtrees_skipped: Int
  marked_stale_count: Int
end

## Ensures a persistent CoW-pinned `Modb.Feeds` cursor (`ai-col:<db_id>`) exists for `db_id`.
fn ensure_ai_col_feed_locked(files: Files, db_id: Text, now: Time) : Result(Unit, AppError)
  fid = ai_col_feed_id(db_id)
  existing = if files.read_only.exists?(ledger_db_path)
    try Ledger.read_locked(
      files.read_only,
      ledger_db_path,
      vellum_schema(),
      map_ledger_error,
      fn(db) Feeds.get_feed(Ledger.store(db), fid).map_error(map_feeds_error) end
    )
  else
    None
  end
  return Ok(Unit) if existing != None

  spec = Feeds.FeedSpec(
    id: fid,
    principal: "system:ai-columns",
    grant_id: None,
    buckets: [db_rows_table().bucket, blocks_table().bucket],
    include_internal: false,
    from_beginning: false
  )
  case Feeds.subscribe_locked(
    files,
    ledger_db_path,
    vellum_schema(),
    spec,
    "track AI column staleness for #{db_id}",
    now
  )
    Ok(_): Ok(Unit)
    Error(Feeds.FeedAlreadyExists(id: _)): Ok(Unit)
    Error(e): Error(map_feeds_error(e))
  end
end

## Consumes O(diff) `Modb.Feeds` events for `db_id` and marks drifted `AiCellMeta` entries stale.
fn sync_ai_col_feed_locked(files: Files, db_id: Text, now: Time) : Result(
  AiFeedSyncResult,
  AppError
)
  try ensure_ai_col_feed_locked(files, db_id, now)
  fid = ai_col_feed_id(db_id)
  (batch, _sub) = try Feeds.consume_feed_locked(
    files,
    ledger_db_path,
    vellum_schema(),
    FeedBridge.empty_sensitivity_policy(),
    fid,
    true,
    500,
    now
  ).map_error(map_feeds_error)

  row_bucket = db_rows_table().bucket
  var touched_rows = {}
  for ev in batch.events
    if ev.bucket == row_bucket
      case ev.key_text
        Some(rk): touched_rows = touched_rows.set(rk, true)
        None: Unit
      end
    end
  end

  stale_updates = try Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    vellum_schema(),
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      def = case try Table.get(store, databases_table(), db_id).map_error(map_table_error)
        Some(d): d
        None: return Ok([])
      end
      var prop_by_id = {}
      for p in def.properties
        prop_by_id = prop_by_id.set(p.id, p)
      end
      r_pairs = try Table.lookup(store, db_rows_table(), db_rows_by_database(), db_id).map_error(
        map_table_error
      )
      var row_by_id = {}
      for (_rid, r) in r_pairs
        if r.archived_at == None
          row_by_id = row_by_id.set(r.id, r)
        end
      end
      meta_pairs = try Table.lookup(store, ai_cell_meta_table(), ai_cell_meta_by_database(), db_id)
        .map_error(map_table_error)
      var to_mark = []
      for (_mid, m) in meta_pairs
        continue if m.stale
        prop = case prop_by_id.get(m.prop_id)
          Some(p): p
          None: continue
        end
        row = case row_by_id.get(m.row_id)
          Some(r): r
          None: continue
        end
        (pr_hash, body?) = case prop.kind
          AiDerived(
            prompt: pr,
            source_prop_ids: _,
            include_row_body: inc,
            output_kind: out_k,
            mode: _,
            daily_call_cap: _
          ): (DatabaseModel.compute_ai_prompt_hash(pr, out_k), inc)
          Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
            options: _
          ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | Rollup(
            relation_prop_id: _,
            target_prop_id: _,
            agg: _
          ): continue
        end
        body_plain = if body?
          Blocks.blocks_plain_text(try load_page_blocks(store, row.page_id))
        else
          ""
        end
        in_hash = DatabaseModel.compute_ai_input_hash(def, prop, row, body_plain)
        row_touched? = touched_rows.get(row.id) != None
        if pr_hash != m.prompt_hash or in_hash != m.input_hash or row_touched?
          if pr_hash != m.prompt_hash or in_hash != m.input_hash
            to_mark = to_mark.append(m)
          end
        end
      end
      Ok(to_mark)
    end
  )

  var marked = 0
  if not stale_updates.empty?
    wmeta = Ledger.WriteMeta(
      principal: "system:ai-columns",
      action: "ai_column.feed_sync",
      reason: "mark drifted AI-compiled cells stale via Modb.Feeds on #{db_id}",
      at: now
    )
    marked = try Ledger.transact_locked(
      files,
      ledger_db_path,
      vellum_schema(),
      wmeta,
      "marked stale AI cells on #{db_id}",
      Json.Object({"database_id": Json.String(db_id)}),
      map_ledger_error,
      fn(tx)
        var t = tx
        var cnt = 0
        for stale_m in stale_updates
          case try Table.tx_get(t, ai_cell_meta_table(), stale_m.id).map_error(map_table_error)
            Some(cur) if not cur.stale and cur.input_hash == stale_m.input_hash:
              next_m = AiCellMeta(
                id: cur.id,
                database_id: cur.database_id,
                row_id: cur.row_id,
                prop_id: cur.prop_id,
                model: cur.model,
                prompt_hash: cur.prompt_hash,
                input_hash: cur.input_hash,
                stale: true,
                rationale: cur.rationale,
                citations: cur.citations,
                proposal_id: cur.proposal_id,
                computed_at: cur.computed_at
              )
              t = try Table.put(t, ai_cell_meta_table(), next_m.id, next_m).map_error(
                map_table_error
              )
              cnt += 1
            Some(_) | None: Unit
          end
        end
        Ok((t, cnt))
      end
    )
  end

  Ok(
    AiFeedSyncResult(
      feed_id: fid,
      from_txid: batch.from_txid,
      to_txid: batch.to_txid,
      events_seen: batch.events.size,
      pages_read: batch.pages_read,
      subtrees_skipped: batch.subtrees_skipped,
      marked_stale_count: marked
    )
  )
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
      return Error(BadInput(reason: "expected 9 invariants")) if rep.invariants_checked != 9
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
      return Error(BadInput(reason: "expected 9 invariants")) if rep.invariants_checked != 9
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

test "blueprints and page_meta integrity, FTS indexing, and delete cleanup"
  files = Files.in_memory({})
  schema = vellum_schema()
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "usr_ada", action: "test.bp", reason: "bp test", at: t0)
  bp = BlueprintDef(
    id: "bp_rfc",
    slug: "architecture-rfc",
    name: "Architecture RFC",
    description: "Proposal template",
    icon: Some("file-text"),
    fields: [
      PropertyDef(
        id: "tier",
        name: "Tier",
        kind: Select(options: [SelectOption(id: "t1", label: "CriticalTier", color: Red)]),
        required: true,
        sort_order: "a"
      )
    ],
    default_template_markdown: "## Summary",
    version: 1
  )
  pg = Page(
    id: "pg_rfc1",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Storage Engine",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "i",
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
  pm = PageBlueprintMeta(
    page_id: pg.id,
    blueprint_id: bp.id,
    values: {"tier": SelectVal(option_id: "t1")},
    updated_at: t0
  )

  ins_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "save bp and page meta",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, blueprints_table(), bp.id, bp).map_error(map_table_error)
      t2 = try Table.put(t1, pages_table(), pg.id, pg).map_error(map_table_error)
      t3 = try Table.put(t2, page_meta_table(), pm.page_id, pm).map_error(map_table_error)
      t4 = try tx_save_page_and_blocks(t3, pg, [])
      Ok((t4, Unit))
    end
  )
  assert ins_res is Ok(Unit)

  # FTS matches structured metadata label "CriticalTier"
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
  fts_res = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      search_pages(store, auth, "CriticalTier", 10, false, None)
    end
  )
  assert fts_res.map(fn(hs) hs.map(fn(h) h.page_id end) end) == Ok([pg.id])

  # Deleting page removes page_meta automatically inside transaction
  del_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "delete page cleans meta",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_delete_page_and_blocks(tx, pg.id)
      rem = try Table.tx_get(t1, page_meta_table(), pg.id).map_error(map_table_error)
      Ok((t1, rem))
    end
  )
  assert del_res == Ok(None)
end

test "living summaries auto-persist on page/db writes, clean up on delete, and enforce pack_valid invariant"
  files = Files.in_memory({})
  schema = vellum_schema()
  t0 = Time.parse("2026-11-27T10:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "usr_ada", action: "test.packs", reason: "pack test", at: t0)
  prov = Provenance(
    author_id: "usr_ada",
    author_kind: HumanAuthor,
    grant_id: None,
    proposal_id: None,
    reason: None,
    citations: [],
    updated_at: t0
  )
  pg = Page(
    id: "pg_ls1",
    collection_id: default_collection_id,
    parent_page_id: None,
    title: "Release Checklist",
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
  blk = Block(
    id: "blk_ls1",
    page_id: pg.id,
    parent_block_id: None,
    rank: "i0001",
    kind: Heading(level: 2),
    markdown: "Rollback Plan",
    provenance: prov,
    version: 1
  )
  pk = ContextPack(
    id: "pk_ls1",
    slug: "release-pack",
    name: "Release Pack",
    description: "Essential release context",
    collection_ids: [default_collection_id],
    pinned_page_ids: [pg.id],
    database_ids: [],
    query_hint: None,
    fresh_only: false,
    include_full_blocks: true,
    token_budget: 2048,
    created_by: "usr_ada",
    updated_at: t0,
    version: 1
  )

  w_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "save page and context pack",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_save_page_and_blocks(tx, pg, [blk])
      t2 = try Table.put(t1, packs_table(), pk.id, pk).map_error(map_table_error)
      Ok((t2, Unit))
    end
  )
  assert w_res is Ok(Unit)

  chk_res = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      s_opt = try Table.get(store, summaries_table(), page_summary_key(pg.id)).map_error(
        map_table_error
      )
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      Ok((s_opt, rep.invariants_checked))
    end
  )
  case chk_res
    Ok((Some(s), inv_cnt)):
      assert s.title == "Release Checklist"
      assert s.headings == ["Rollback Plan"]
      assert inv_cnt == 9
    Ok((None, _)) | Error(_): assert false
  end

  del_res = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "delete page removes living summary",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_delete_page_and_blocks(tx, pg.id)
      s_rem = try Table.tx_get(t1, summaries_table(), page_summary_key(pg.id)).map_error(
        map_table_error
      )
      Ok((t1, s_rem))
    end
  )
  assert del_res == Ok(None)
end

test "AiDerived Modb.Feeds O(diff) staleness detection, World PutAiCellMeta landing, and 9 invariants"
  files = Files.in_memory({})
  schema = vellum_schema()
  t0 = Time.parse("2026-12-01T10:00:00Z") or stop "t0"
  meta = Ledger.WriteMeta(principal: "usr_ada", action: "test.ai_cols", reason: "seed ai db", at: t0)
  opt_low = SelectOption(id: "low", label: "Low", color: Green)
  opt_high = SelectOption(id: "high", label: "High", color: Red)
  ai_prop = PropertyDef(
    id: "tier",
    name: "Tier",
    kind: AiDerived(
      prompt: "Classify tier",
      source_prop_ids: ["title"],
      include_row_body: false,
      output_kind: AiSelect(options: [opt_low, opt_high]),
      mode: StageProposal,
      daily_call_cap: 10
    ),
    required: false,
    sort_order: "b"
  )
  def = DatabaseDef(
    id: "db_feed1",
    collection_id: default_collection_id,
    page_id: "pg_db_feed1",
    title: "Alerts",
    description: "Feed staleness test",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      ai_prop
    ],
    version: 1
  )
  row1 = DbRow(
    id: "row_f1",
    database_id: def.id,
    page_id: "pg_rf1",
    cells: {"title": TextVal("Minor latency"), "tier": SelectVal(option_id: "low")},
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  row_pg = Page(
    id: "pg_rf1",
    collection_id: default_collection_id,
    parent_page_id: Some(def.page_id),
    title: "Minor latency",
    icon: None,
    cover_attachment_id: None,
    kind: DatabaseRow(database_id: def.id, row_id: row1.id),
    sort_order: row1.id,
    database_id: Some(def.id),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  host_pg = Page(
    id: def.page_id,
    collection_id: default_collection_id,
    parent_page_id: None,
    title: def.title,
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "a",
    database_id: Some(def.id),
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_ada",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  m1 = AiCellMeta(
    id: DatabaseModel.ai_cell_meta_key(def.id, row1.id, ai_prop.id),
    database_id: def.id,
    row_id: row1.id,
    prop_id: ai_prop.id,
    model: "gpt-4o-mini",
    prompt_hash: DatabaseModel.compute_ai_prompt_hash("Classify tier", AiSelect(options: [opt_low, opt_high])),
    input_hash: DatabaseModel.compute_ai_input_hash(def, ai_prop, row1, ""),
    stale: false,
    rationale: Some("Initial low latency"),
    citations: [],
    proposal_id: None,
    computed_at: t0
  )

  w0 = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "seed db and ai meta",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, pages_table(), host_pg.id, host_pg).map_error(map_table_error)
      t2 = try Table.put(t1, databases_table(), def.id, def).map_error(map_table_error)
      t3 = try tx_put_db_row(t2, def, row1, row_pg, [])
      t4 = try Table.put(t3, ai_cell_meta_table(), m1.id, m1).map_error(map_table_error)
      Ok((t4, Unit))
    end
  )
  assert w0 is Ok(Unit)

  assert ensure_ai_col_feed_locked(files, def.id, t0) is Ok(Unit)
  idle_sync = sync_ai_col_feed_locked(files, def.id, t0)
  case idle_sync
    Ok(s):
      assert s.events_seen == 0
      assert s.marked_stale_count == 0
    Error(_): assert false
  end

  # Mutate source title -> Modb.Feeds O(diff) detects delta and marks m1 stale!
  row1_v2 = DbRow(
    id: row1.id,
    database_id: def.id,
    page_id: row1.page_id,
    cells: {"title": TextVal("Critical DB Outage"), "tier": SelectVal(option_id: "low")},
    created_by: row1.created_by,
    created_at: row1.created_at,
    updated_at: t0 + 10.seconds,
    archived_at: None,
    version: 2
  )
  pg_v2 = Page(
    id: row_pg.id,
    collection_id: row_pg.collection_id,
    parent_page_id: row_pg.parent_page_id,
    title: "Critical DB Outage",
    icon: None,
    cover_attachment_id: None,
    kind: row_pg.kind,
    sort_order: row_pg.sort_order,
    database_id: row_pg.database_id,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: row_pg.created_by,
    created_at: row_pg.created_at,
    updated_at: t0 + 10.seconds,
    archived_at: None,
    version: 2
  )
  w1 = Ledger.transact_locked(
    files,
    ledger_db_path,
    schema,
    meta,
    "mutate source cell",
    Json.Null,
    map_ledger_error,
    fn(tx)
      t1 = try tx_put_db_row(tx, def, row1_v2, pg_v2, [])
      Ok((t1, Unit))
    end
  )
  assert w1 is Ok(Unit)

  dirty_sync = sync_ai_col_feed_locked(files, def.id, t0 + 15.seconds)
  case dirty_sync
    Ok(s):
      assert s.events_seen >= 1
      assert s.marked_stale_count == 1
    Error(_): assert false
  end

  chk = Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    schema,
    map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      got_m = try Table.get(store, ai_cell_meta_table(), m1.id).map_error(map_table_error)
      rep = try Ledger.verify_all(db).map_error(map_ledger_error)
      Ok((got_m.map(fn(x) x.stale end), rep.invariants_checked))
    end
  )
  assert chk == Ok((Some(true), 9))
end
