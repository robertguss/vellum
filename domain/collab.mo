## Stage 3 collaboration domain models: Change Proposal metadata (`Modb.World`),
## replayable patch action arguments (`Modb.Replay`), resource lease keys (`Modb.Claims`),
## and webhook subscription/delivery payloads (`Arvo.Webhooks`).
module Domain.Collab
expose ProposalMeta(..),
ProposalComment(..),
WorldPatchArgs(..),
WorldMutation(..),
WorldBranchArgs(..),
DecimalDelta(..),
WebhookSub(..),
WebhookJobPayload(..),
claim_resource_for_page,
claim_resource_for_block,
claim_resource_for_row,
webhook_matches_event?
use Domain.DatabaseModel{AiCellMeta, CellValue, PropertyDef}
use Domain.Types{AuthorKind, BlockOp, Provenance}
use Json

## Persistent metadata row in `vlm_proposals` pairing a friendly `ProposalMeta` with a `Modb.World` branch ID.
struct ProposalMeta
  id: Text
  world_id: Text
  collection_id: Text
  target_page_id: Text
  target_database_id: Option(Text)
  branch_kind: Text
  title: Text
  reason: Text
  author_id: Text
  author_handle: Text
  grant_id: Text
  status: Text
  created_at: Time
  updated_at: Time
  decided_by: Option(Text)
  decided_at: Option(Time)
end

## Anchored Patchwork/Review discussion or Steer-in-Place thread attached to a `Modb.World` Change Proposal.
struct ProposalComment
  id: Text
  proposal_id: Text
  target_kind: Text
  target_ref: Option(Text)
  parent_comment_id: Option(Text)
  author_id: Text
  author_handle: Text
  author_kind: AuthorKind
  body_markdown: Text
  steer_requested: Bool
  resolved_at: Option(Time)
  created_at: Time
end

## JSON-serializable arguments stored in `Modb.World` steps and `Modb.Replay` call history
## so landed proposals can be replayed or selectively rolled back deterministically.
struct WorldPatchArgs
  page_id: Text
  ops: List(BlockOp)
  new_ids: List(Text)
  provenance: Provenance
  expected_versions: Map(Text, Int)
  updated_at: Time
end

## Unified multi-resource speculative mutation recorded inside `Modb.World` branches.
enum WorldMutation
  PatchPageBlocks(
    page_id: Text,
    ops: List(BlockOp),
    new_ids: List(Text),
    provenance: Provenance,
    expected_versions: Map(Text, Int)
  )
  CreateDbRow(
    database_id: Text,
    row_id: Text,
    page_id: Text,
    cells: Map(Text, CellValue),
    markdown: Option(Text),
    block_prefix: Text,
    provenance: Provenance
  )
  UpdateDbRow(
    database_id: Text,
    row_id: Text,
    cells: Map(Text, CellValue),
    expected_version: Option(Int),
    provenance: Provenance
  )
  DeleteDbRow(database_id: Text, row_id: Text)
  UpdateDbSchema(
    database_id: Text,
    title: Option(Text),
    description: Option(Text),
    properties: Option(List(PropertyDef)),
    expected_version: Option(Int)
  )
  PutAiCellMeta(meta: AiCellMeta)
end

## JSON-serializable envelope wrapping a `WorldMutation` inside `Modb.World` `CallStep`s.
struct WorldBranchArgs
  mutation: WorldMutation
  updated_at: Time
end

## Exact-Decimal summary comparing a numeric or rollup column between Live and Scenario state.
struct DecimalDelta
  database_id: Text
  database_title: Text
  prop_id: Text
  prop_name: Text
  format: Text
  is_rollup: Bool
  live_total: Text
  scenario_total: Text
  delta: Text
  changed: Bool
end

## Outbound webhook subscription record stored in `vlm_webhooks`.
struct WebhookSub
  id: Text
  workspace_id: Text
  collection_id: Option(Text)
  url: Text
  secret: Text
  events: List(Text)
  enabled: Bool
  created_by: Text
  created_at: Time
end

## Enqueued payload inside `Arvo.Modb.Jobs` (`vellum.webhook.deliver`).
struct WebhookJobPayload
  webhook_id: Text
  delivery_id: Text
  url: Text
  secret: Text
  event: Text
  body_json: Json
  taint_session_id: Option(Text)
end

## Canonical `Modb.Claims` resource identifier for a whole page.
fn claim_resource_for_page(page_id: Text) : Text
  "page:#{page_id.trim}"
end

## Canonical `Modb.Claims` resource identifier for a single block inside a page.
fn claim_resource_for_block(page_id: Text, block_id: Text) : Text
  "page:#{page_id.trim}:block:#{block_id.trim}"
end

## Canonical `Modb.Claims` resource identifier for a database row.
fn claim_resource_for_row(db_id: Text, row_id: Text) : Text
  "db:#{db_id.trim}:row:#{row_id.trim}"
end

## Whether webhook subscription `sub` should fire for `(event, collection_id)`.
fn webhook_matches_event?(sub: WebhookSub, event: Text, collection_id: Option(Text)) : Bool
  return false if not sub.enabled
  event_ok = sub.events.contains?(event) or sub.events.contains?("*")
  return false if not event_ok
  case sub.collection_id
    None: true
    Some(target_col):
      case collection_id
        Some(ev_col): target_col == ev_col
        None: false
      end
  end
end
