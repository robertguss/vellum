## Stage 3 collaboration domain models: Change Proposal metadata (`Modb.World`),
## replayable patch action arguments (`Modb.Replay`), resource lease keys (`Modb.Claims`),
## and webhook subscription/delivery payloads (`Arvo.Webhooks`).
module Domain.Collab
expose ProposalMeta(..),
WorldPatchArgs(..),
WebhookSub(..),
WebhookJobPayload(..),
claim_resource_for_page,
claim_resource_for_block,
claim_resource_for_row,
webhook_matches_event?
use Domain.Types{BlockOp, Provenance}
use Json

## Persistent metadata row in `vlm_proposals` pairing a friendly `ProposalMeta` with a `Modb.World` branch ID.
struct ProposalMeta
  id: Text
  world_id: Text
  collection_id: Text
  target_page_id: Text
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

test "Collab claim resources and webhook subscription event/collection matching"
  assert claim_resource_for_page("pg_1") == "page:pg_1"
  assert claim_resource_for_block("pg_1", "blk_2") == "page:pg_1:block:blk_2"
  assert claim_resource_for_row("db_1", "row_3") == "db:db_1:row:row_3"

  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  sub_scoped = WebhookSub(
    id: "wh_1",
    workspace_id: "ws_default",
    collection_id: Some("col_eng"),
    url: "https://agent.acme.io/hook",
    secret: "whsec_test",
    events: ["proposal.opened", "proposal.accepted"],
    enabled: true,
    created_by: "usr_1",
    created_at: t0
  )
  assert webhook_matches_event?(sub_scoped, "proposal.opened", Some("col_eng"))
  assert not webhook_matches_event?(sub_scoped, "proposal.opened", Some("col_other"))
  assert not webhook_matches_event?(sub_scoped, "page.created", Some("col_eng"))
  assert not webhook_matches_event?(sub_scoped, "proposal.opened", None)

  sub_wildcard = WebhookSub(
    id: "wh_2",
    workspace_id: "ws_default",
    collection_id: None,
    url: "https://agent.acme.io/all",
    secret: "whsec_all",
    events: ["*"],
    enabled: false,
    created_by: "usr_1",
    created_at: t0
  )
  assert not webhook_matches_event?(sub_wildcard, "proposal.opened", Some("col_eng"))
end
