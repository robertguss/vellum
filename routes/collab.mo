## Multi-actor collaboration routes: advisory resource leases (`Modb.Claims`),
## speculative Change Proposals (`Modb.World`), Selective Agent Rollback (`Modb.Replay`),
## monotonic Grant Sub-Delegation (`Modb.Grants`), Webhooks (`Arvo.Webhooks`), and SSE (`Arvo.Sse`).
module Routes.Collab
expose AcquireClaimInput(..),
HeartbeatClaimInput(..),
ReleaseClaimInput(..),
OpenProposalInput(..),
StageProposalOpsInput(..),
ProposalDecisionInput(..),
CreateProposalCommentInput(..),
ResolveProposalCommentInput(..),
RejectProposalHunkInput(..),
SimulateReplayInput(..),
DelegateGrantInput(..),
CreateWebhookInput(..),
list_claims,
acquire_claim,
heartbeat_claim,
release_claim,
list_proposals,
open_proposal,
open_db_scenario,
stage_proposal_ops,
stage_proposal_mutation,
query_db_scenario,
diff_proposal,
accept_proposal,
reject_proposal,
list_proposal_comments,
create_proposal_comment,
resolve_proposal_comment,
reject_proposal_hunk,
pin_replay_baseline,
replay_status,
simulate_replay,
accept_replay,
discard_replay,
page_replay_history,
page_time_travel,
delegate_grant,
list_webhooks,
create_webhook,
github_pr_webhook,
events_stream,
taint_status,
clear_taint_session
use Api
use Arvo.Id
use Arvo.Modb.Jobs
use Arvo.Sse
use Arvo.Webhooks
use Date
use Db
use Domain.Blocks
use Domain.Collab{
  ProposalComment,
  ProposalMeta,
  WebhookJobPayload,
  WebhookSub,
  WorldBranchArgs,
  WorldMutation,
  WorldPatchArgs
}
use Domain.Garden
use Domain.DatabaseModel{
  CellValue,
  DatabaseDef,
  DbRow,
  DbViewKind,
  EnrichedRow,
  PropertyDef,
  ViewQueryResult
}
use Domain.Policy
use Domain.TaintBridge
use Domain.Types{
  AgentToken,
  AppError,
  AuthContext,
  AuthorKind,
  Block,
  BlockKind,
  BlockOp,
  Citation,
  CollectionWritePolicy,
  Page,
  PageKind,
  Principal,
  PrincipalKind,
  Provenance,
  WorkspaceRole
}
use Http
use Json
use Modb{Store, WriteTx}
use Modb.Claims
use Modb.Grants
use Modb.Ledger
use Modb.Replay
use Modb.Table
use Modb.Vec
use Modb.World
use Routes.Ai
use Routes.Auth
use Routes.Databases

## JSON payload for `POST /api/claims`.
struct AcquireClaimInput
  resource: Text
  ttl_seconds: Int
  world_id: Option(Text)
  reason: Text
end

## JSON payload for `POST /api/claims/heartbeat`.
struct HeartbeatClaimInput
  resource: Text
  ttl_seconds: Int
end

## JSON payload for `POST /api/claims/release`.
struct ReleaseClaimInput
  resource: Text
end

## JSON payload for `POST /api/proposals`.
struct OpenProposalInput
  page_id: Text
  title: Text
  reason: Text
end

## JSON payload for `POST /api/proposals/:id/ops`.
struct StageProposalOpsInput
  ops: List(BlockOp)
  expected_versions: Map(Text, Int)
  reason: Text
end

## Optional JSON payload for `POST /api/proposals/:id/accept` or `/reject`.
struct ProposalDecisionInput
  reason: Option(Text)
end

## JSON payload for `POST /api/admin/replay/simulate`.
struct SimulateReplayInput
  filter_kind: Text
  target: Option(Text)
  seq: Option(Int)
  description: Text
end

## JSON payload for `POST /api/grants/delegate`.
struct DelegateGrantInput
  handle: Text
  display_name: Text
  model_id: Option(Text)
  label: Text
  allowed_actions: List(Text)
  allowed_collections: Option(List(Text))
  max_calls: Int
  ttl_days: Int
end

## JSON payload for `POST /api/webhooks`.
struct CreateWebhookInput
  collection_id: Option(Text)
  url: Text
  events: List(Text)
end

## JSON payload for `POST /api/proposals/:id/comments`.
struct CreateProposalCommentInput
  target_kind: Option(Text)
  target_ref: Option(Text)
  parent_comment_id: Option(Text)
  body_markdown: Text
  steer_requested: Option(Bool)
end

## JSON payload for `POST /api/proposals/:id/comments/:comment_id/resolve`.
struct ResolveProposalCommentInput
  resolved: Option(Bool)
end

## JSON payload for `POST /api/proposals/:id/hunks/reject`.
struct RejectProposalHunkInput
  target_kind: Text
  target_id: Text
  page_id: Option(Text)
  database_id: Option(Text)
  reason: Option(Text)
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn tx_authorize_if_agent(tx: WriteTx, auth: AuthContext, action: Text, now: Time) : Result(
  WriteTx,
  AppError
)
  if auth.principal.kind == Agent
    (t1, _g) = try Grants.tx_authorize(tx, auth.grant_id, action, now).map_error(
      Db.map_grants_error
    )
    Ok(t1)
  else
    Ok(tx)
  end
end

fn make_provenance(auth: AuthContext, reason: Option(Text), now: Time) : Provenance
  author_kind = case auth.principal.kind
    Human: HumanAuthor
    Agent: AgentAuthor(model: auth.principal.model_id)
  end
  grant_id = if auth.principal.kind == Agent: Some(auth.grant_id) else: None
  Provenance(
    author_id: auth.principal.id,
    author_kind: author_kind,
    grant_id: grant_id,
    proposal_id: None,
    reason: reason,
    citations: [],
    updated_at: now
  )
end

fn generate_insert_block_ids(ops: List(BlockOp), rng: SecureRandom, clock: Clock) : List(Text)
  var out = []
  for op in ops
    case op
      InsertBlockAfter(after_block_id: _, parent_block_id: _, kind: _, markdown: _): out = out
        .append("blk_#{Id.ulid(rng, clock)}")
      ReplaceBlock(block_id: _, expected_version: _, kind: _, markdown: _) | DeleteBlock(
        block_id: _,
        expected_version: _
      ) | MoveBlock(block_id: _, new_parent_id: _, after_block_id: _) | AttachCitations(
        block_id: _,
        citations: _
      ): Unit
    end
  end
  out
end

fn matching_webhooks_in_store(store: Store, event: Text, collection_id: Option(Text)) : Result(
  List(WebhookSub),
  AppError
)
  rows = try Table.scan(store, Db.webhooks_table(), None, None, 200).map_error(Db.map_table_error)
  var out = []
  for (_id, sub) in rows
    if Collab.webhook_matches_event?(sub, event, collection_id)
      out = out.append(sub)
    end
  end
  Ok(out)
end

fn caller_taint_sid(req: Api.Request, auth: AuthContext) : Option(Text)
  case req.header("X-Taint-Session")
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None:
      if auth.principal.kind == Agent
        Some("agent:#{auth.grant_id}")
      else
        None
      end
  end
end

fn prepare_webhook_jobs(
  subs: List(WebhookSub),
  event: Text,
  body_json: Json,
  taint_session_id: Option(Text),
  rng: SecureRandom,
  clock: Clock
) : List(Jobs.JobRecord)
  var out = []
  for sub in subs
    del_id = "del_#{Id.ulid(rng, clock)}"
    payload = WebhookJobPayload(
      webhook_id: sub.id,
      delivery_id: del_id,
      url: sub.url,
      secret: sub.secret,
      event: event,
      body_json: body_json,
      taint_session_id: taint_session_id
    )
    out = out.append(Jobs.prepare(rng, clock, "vellum.webhook.deliver", payload.to_json))
  end
  out
end

fn parse_replay_filter(input: SimulateReplayInput) : Result(Replay.ReplayFilter, AppError)
  fk = input.filter_kind.trim
  if fk == "replay_all"
    Ok(Replay.ReplayAll)
  else if fk == "exclude_principal"
    t = try input.target.or_fail(
      BadInput(reason: "target principal required for exclude_principal")
    )
    Ok(Replay.ExcludePrincipal(principal: t.trim))
  else if fk == "exclude_grant"
    t = try input.target.or_fail(BadInput(reason: "target grant_id required for exclude_grant"))
    Ok(Replay.ExcludeGrant(grant_id: t.trim))
  else if fk == "exclude_world"
    t = try input.target.or_fail(BadInput(reason: "target world_id required for exclude_world"))
    Ok(Replay.ExcludeWorld(world_id: t.trim))
  else if fk == "stop_before_seq"
    s = try input.seq.or_fail(BadInput(reason: "seq required for stop_before_seq"))
    Ok(Replay.StopBeforeSeq(seq: s))
  else
    Error(BadInput(reason: "unsupported filter_kind '#{fk}'"))
  end
end

## `GET /api/claims` — Lists active advisory `Modb.Claims` leases (`ReadFiles`-only).
fn list_claims(auth: AuthContext, rf: ReadFiles, clock: Clock) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"claims": Json.Array([])})))
  end
  now = clock.now
  claims = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) Claims.list_active(Ledger.store(db), now).map_error(Db.map_claims_error) end
  )
  Ok(json_ok(200, Json.Object({"claims": claims.to_json})))
end

## `POST /api/claims` — Acquires an advisory `Modb.Claims` lease (409 Conflict if held by another principal).
fn acquire_claim(
  req: Api.Request,
  auth: AuthContext,
  input: AcquireClaimInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not Policy.action_permitted?(auth, "claim")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'claim'"))
  end
  if input.ttl_seconds < 10 or input.ttl_seconds > 3600
    return Error(BadInput(reason: "ttl_seconds must be between 10 and 3600"))
  end
  res_key = input.resource.trim
  if res_key.empty? or input.reason.trim.empty?
    return Error(BadInput(reason: "resource and reason must not be empty"))
  end

  now = clock.now
  expires_at = now + input.ttl_seconds.seconds
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "claim.acquire",
    reason: input.reason.trim,
    at: now
  )
  payload = Json.Object({
    "resource": Json.String(res_key),
    "ttl_seconds": Json.int(input.ttl_seconds)
  })

  claim = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "acquire claim on #{res_key}",
    payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "claim", now)
      (t2, c) = try Claims.tx_acquire(
        t1,
        res_key,
        auth.principal.id,
        auth.grant_id,
        input.world_id,
        input.reason.trim,
        now,
        expires_at
      ).map_error(Db.map_claims_error)
      Ok((t2, c))
    end
  )
  Ok(
    json_ok(201, claim.to_json).with_sse_publish_json(
      "claims",
      "claim.acquired",
      Json.Object({"claim": claim.to_json, "actor": Json.String(auth.principal.handle)})
    )
  )
end

## `POST /api/claims/heartbeat` — Extends an active lease held by the caller.
fn heartbeat_claim(
  req: Api.Request,
  auth: AuthContext,
  input: HeartbeatClaimInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not Policy.action_permitted?(auth, "claim")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'claim'"))
  end
  if input.ttl_seconds < 10 or input.ttl_seconds > 3600
    return Error(BadInput(reason: "ttl_seconds must be between 10 and 3600"))
  end
  res_key = input.resource.trim
  now = clock.now
  new_exp = now + input.ttl_seconds.seconds
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "claim.heartbeat",
    reason: "extend lease on #{res_key}",
    at: now
  )

  claim = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "heartbeat claim on #{res_key}",
    Json.Object({"resource": Json.String(res_key)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "claim", now)
      (t2, c) = try Claims.tx_heartbeat(t1, res_key, auth.principal.id, now, new_exp).map_error(
        Db.map_claims_error
      )
      Ok((t2, c))
    end
  )
  Ok(
    json_ok(200, claim.to_json).with_sse_publish_json(
      "claims",
      "claim.heartbeat",
      Json.Object({"claim": claim.to_json, "actor": Json.String(auth.principal.handle)})
    )
  )
end

## `POST /api/claims/release` — Releases caller's claim (or force-releases for Owners/Admins).
fn release_claim(
  req: Api.Request,
  auth: AuthContext,
  input: ReleaseClaimInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not Policy.action_permitted?(auth, "claim")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'claim'"))
  end
  res_key = input.resource.trim
  now = clock.now
  is_admin? = auth.principal.role == Owner or auth.principal.role == Admin
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "claim.release",
    reason: "release lease on #{res_key}",
    at: now
  )

  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "release claim on #{res_key}",
    Json.Object({"resource": Json.String(res_key)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "claim", now)
      t2 = case Claims.tx_release(t1, res_key, auth.principal.id)
        Ok(next_tx): next_tx
        Error(Claims.NotHolder(resource: _, expected: _, actual: _)) if is_admin?: try Claims
          .tx_force_release(t1, res_key).map_error(Db.map_claims_error)
        Error(e): return Error(Db.map_claims_error(e))
      end
      Ok((t2, Unit))
    end
  )
  Ok(
    json_ok(200, Json.Object({"released": Json.String(res_key)})).with_sse_publish_json(
      "claims",
      "claim.released",
      Json.Object({"resource": Json.String(res_key), "actor": Json.String(auth.principal.handle)})
    )
  )
end

## `GET /api/proposals` — Lists Change Proposals visible to the caller's collection grants (`ReadFiles`-only).
fn list_proposals(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"proposals": Json.Array([])})))
  end
  props = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rows = try Table.scan(Ledger.store(db), Db.proposals_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      var out = []
      for (_id, pm) in rows
        if Policy.collection_permitted?(auth, pm.collection_id)
          out = out.append(pm)
        end
      end
      Ok(out)
    end
  )
  Ok(json_ok(200, Json.Object({"proposals": props.to_json})))
end

## `POST /api/proposals` — Opens a speculative `Modb.World` Change Proposal for a page and enqueues webhook events.
fn open_proposal(
  req: Api.Request,
  auth: AuthContext,
  input: OpenProposalInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  clean_title = input.title.trim
  clean_reason = input.reason.trim
  if clean_title.empty? or clean_reason.empty?
    return Error(BadInput(reason: "proposal title and reason must not be empty"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: input.page_id))
  end

  (page, matching_subs) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Table.get(store, Db.pages_table(), input.page_id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: input.page_id))
      end
      try Policy.require_collection_access(auth, "propose", pg.collection_id)
      subs = try matching_webhooks_in_store(store, "proposal.opened", Some(pg.collection_id))
      Ok((pg, subs))
    end
  )

  now = clock.now
  prop_id = "prop_#{Id.ulid(rng, clock)}"
  world_id = "w_#{Id.ulid(rng, clock)}"
  _wrec = try World.open_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    world_id,
    auth.grant_id,
    now,
    now + 7.days
  ).map_error(Db.map_world_error)

  proposal = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: page.collection_id,
    target_page_id: page.id,
    target_database_id: None,
    branch_kind: "proposal",
    title: clean_title,
    reason: clean_reason,
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    grant_id: auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  hook_jobs = prepare_webhook_jobs(
    matching_subs,
    "proposal.opened",
    Json.Object({"event": Json.String("proposal.opened"), "proposal": proposal.to_json}),
    caller_taint_sid(req, auth),
    rng,
    clock
  )

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "proposal.open",
    reason: clean_reason,
    at: now
  )
  audit_payload = Json.Object({
    "proposal_id": Json.String(prop_id),
    "world_id": Json.String(world_id),
    "page_id": Json.String(page.id)
  })
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "opened proposal #{prop_id} (#{clean_title})",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "propose", now)
      var cur = try Table.put(t1, Db.proposals_table(), proposal.id, proposal).map_error(
        Db.map_table_error
      )
      for job_rec in hook_jobs
        (next_tx, _jid) = try Jobs.tx_put(cur, job_rec).map_error(Db.map_table_error)
        cur = next_tx
      end
      Ok((cur, proposal))
    end
  )
  prop_payload = Json.Object({
    "proposal_id": Json.String(saved.id),
    "page_id": Json.String(saved.target_page_id),
    "collection_id": Json.String(saved.collection_id),
    "title": Json.String(saved.title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(201, saved.to_json).with_sse_publish_json(
      "collection:#{saved.collection_id}",
      "proposal.opened",
      prop_payload
    ).with_sse_publish_json("page:#{saved.target_page_id}", "proposal.opened", prop_payload)
  )
end

## `POST /api/databases/:id/scenarios` — Forks an isolated `Modb.World` What-If Scenario or Proposal anchored to a database.
fn open_db_scenario(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  raw_json = case Json.parse(req.text or "")
    Ok(j): j
    Error(_): return Error(BadInput(reason: "invalid JSON body"))
  end
  case raw_json
    Json.Object(_): Unit
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
      BadInput(reason: "expected JSON object")
    )
  end

  clean_title = (raw_json.text_at("title") or "").trim
  clean_reason = (raw_json.text_at("reason") or "").trim
  if clean_title.empty? or clean_reason.empty?
    return Error(BadInput(reason: "scenario title and reason must not be empty"))
  end
  branch_kind = case raw_json.get("branch_kind")
    None | Some(Json.Null): "scenario"
    Some(Json.String(k)):
      tk = k.trim
      if tk != "scenario" and tk != "proposal"
        return Error(BadInput(reason: "branch_kind must be 'scenario' or 'proposal'"))
      end
      tk
    Some(_): return Error(BadInput(reason: "invalid branch_kind"))
  end

  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end

  (def, matching_subs) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      found_def = case try Table.get(store, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "propose", found_def.collection_id)
      subs = try matching_webhooks_in_store(store, "proposal.opened", Some(found_def.collection_id))
      Ok((found_def, subs))
    end
  )

  now = clock.now
  prop_id = "prop_#{Id.ulid(rng, clock)}"
  world_id = "w_#{Id.ulid(rng, clock)}"
  _wrec = try World.open_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    world_id,
    auth.grant_id,
    now,
    now + 7.days
  ).map_error(Db.map_world_error)

  proposal = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: def.collection_id,
    target_page_id: def.page_id,
    target_database_id: Some(def.id),
    branch_kind: branch_kind,
    title: clean_title,
    reason: clean_reason,
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    grant_id: auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  hook_jobs = prepare_webhook_jobs(
    matching_subs,
    "proposal.opened",
    Json.Object({"event": Json.String("proposal.opened"), "proposal": proposal.to_json}),
    caller_taint_sid(req, auth),
    rng,
    clock
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "scenario.open",
    reason: clean_reason,
    at: now
  )
  audit_payload = Json.Object({
    "proposal_id": Json.String(prop_id),
    "world_id": Json.String(world_id),
    "database_id": Json.String(def.id)
  })
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "opened #{branch_kind} #{prop_id} on database #{def.id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "propose", now)
      var cur = try Table.put(t1, Db.proposals_table(), proposal.id, proposal).map_error(
        Db.map_table_error
      )
      for job_rec in hook_jobs
        (next_tx, _jid) = try Jobs.tx_put(cur, job_rec).map_error(Db.map_table_error)
        cur = next_tx
      end
      Ok((cur, proposal))
    end
  )
  prop_payload = Json.Object({
    "proposal_id": Json.String(saved.id),
    "database_id": Json.String(def.id),
    "page_id": Json.String(saved.target_page_id),
    "collection_id": Json.String(saved.collection_id),
    "branch_kind": Json.String(saved.branch_kind),
    "title": Json.String(saved.title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(201, saved.to_json).with_sse_publish_json(
      "collection:#{saved.collection_id}",
      "proposal.opened",
      prop_payload
    ).with_sse_publish_json("database:#{def.id}", "proposal.opened", prop_payload)
  )
end

## `POST /api/proposals/:id/ops` — Stages surgical `BlockOp`s inside a `Modb.World` branch without touching live pages.
fn stage_proposal_ops(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: StageProposalOpsInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if input.ops.empty? or input.reason.trim.empty?
    return Error(BadInput(reason: "ops and non-empty reason are required"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end

  pm = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      found = case try Table.get(Ledger.store(db), Db.proposals_table(), id).map_error(
        Db.map_table_error
      )
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, "propose", found.collection_id)
      Ok(found)
    end
  )
  if pm.status != "open"
    return Error(Conflict(reason: "proposal '#{id}' is '#{pm.status}', not 'open'"))
  end
  is_admin? = auth.principal.role == Owner or auth.principal.role == Admin
  if pm.author_id != auth.principal.id and not is_admin?
    return Error(Forbidden(reason: "only the proposal author or admin may stage ops"))
  end

  now = clock.now
  new_ids = generate_insert_block_ids(input.ops, rng, clock)
  prov = make_provenance(auth, Some(input.reason.trim), now)
  args = WorldPatchArgs(
    page_id: pm.target_page_id,
    ops: input.ops,
    new_ids: new_ids,
    provenance: prov,
    expected_versions: input.expected_versions,
    updated_at: now
  )
  step_reply = try World.world_call_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    pm.world_id,
    "propose",
    args.to_json,
    input.reason.trim,
    now
  ).map_error(Db.map_world_error)

  Ok(json_ok(200, Json.Object({"proposal": pm.to_json, "step_reply": step_reply})))
end

## `POST /api/proposals/:id/mutations` — Stages multi-resource page block patches or database row/schema mutations inside one `Modb.World` branch.
fn stage_proposal_mutation(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  raw_json = case Json.parse(req.text or "")
    Ok(j): j
    Error(_): return Error(BadInput(reason: "invalid JSON body"))
  end
  case raw_json
    Json.Object(_): Unit
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
      BadInput(reason: "expected JSON object")
    )
  end

  kind = (raw_json.text_at("kind") or "").trim
  clean_reason = (raw_json.text_at("reason") or "").trim
  if kind.empty? or clean_reason.empty?
    return Error(BadInput(reason: "kind and non-empty reason are required"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end

  pm = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      found = case try Table.get(Ledger.store(db), Db.proposals_table(), id).map_error(
        Db.map_table_error
      )
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, "propose", found.collection_id)
      Ok(found)
    end
  )
  if pm.status != "open"
    return Error(Conflict(reason: "proposal '#{id}' is '#{pm.status}', not 'open'"))
  end
  is_admin? = auth.principal.role == Owner or auth.principal.role == Admin
  if pm.author_id != auth.principal.id and not is_admin?
    return Error(Forbidden(reason: "only the proposal author or admin may stage mutations"))
  end

  now = clock.now
  prov = make_provenance(auth, Some(clean_reason), now)

  (mut, sse_col_id, sse_page_id, sse_db_id) = if kind == "page_patch"
    pid = case raw_json.text_at("page_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: pm.target_page_id
    end
    ops_json = try raw_json.get("ops").or_fail(BadInput(reason: "ops required for page_patch"))
    ops = try Json.decode_strict[List(BlockOp)](ops_json.to_text.bytes).map_error(fn(e)
      BadInput(reason: "invalid ops: #{e.to_text}")
    end)
    if ops.empty?
      return Error(BadInput(reason: "ops must not be empty"))
    end
    exp_vers = case raw_json.get("expected_versions")
      None | Some(Json.Null): {}
      Some(evj): try Json.decode_strict[Map(Text, Int)](evj.to_text.bytes).map_error(fn(e)
        BadInput(reason: "invalid expected_versions: #{e.to_text}")
      end)
    end
    pg = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        found_pg = case try Table.get(Ledger.store(db), Db.pages_table(), pid).map_error(
          Db.map_table_error
        )
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: pid))
        end
        try Policy.require_collection_access(auth, "propose", found_pg.collection_id)
        Ok(found_pg)
      end
    )
    new_ids = generate_insert_block_ids(ops, rng, clock)
    (
      PatchPageBlocks(
        page_id: pg.id,
        ops: ops,
        new_ids: new_ids,
        provenance: prov,
        expected_versions: exp_vers
      ),
      pg.collection_id,
      Some(pg.id),
      pm.target_database_id
    )
  else
    did_raw = case raw_json.text_at("database_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None:
        case pm.target_database_id
          Some(d) if not d.trim.empty?: d.trim
          Some(_) | None: return Error(BadInput(reason: "database_id required for #{kind}"))
        end
    end
    def = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        found_def = case try Table.get(Ledger.store(db), Db.databases_table(), did_raw).map_error(
          Db.map_table_error
        )
          Some(d): d
          None: return Error(Missing(entity: "database", id: did_raw))
        end
        try Policy.require_collection_access(auth, "propose", found_def.collection_id)
        Ok(found_def)
      end
    )
    if kind == "db_row_create"
      cells_json = try raw_json.get("cells").or_fail(
        BadInput(reason: "cells required for db_row_create")
      )
      cells = try Json.decode_strict[Map(Text, CellValue)](cells_json.to_text.bytes).map_error(fn(
        e
      )
        BadInput(reason: "invalid cells: #{e.to_text}")
      end)
      md_opt = raw_json.text_at("markdown")
      new_row_id = "row_#{Id.ulid(rng, clock)}"
      new_page_id = "pg_#{Id.ulid(rng, clock)}"
      blk_pref = "blk_#{Id.ulid(rng, clock)}"
      (
        CreateDbRow(
          database_id: def.id,
          row_id: new_row_id,
          page_id: new_page_id,
          cells: cells,
          markdown: md_opt,
          block_prefix: blk_pref,
          provenance: prov
        ),
        def.collection_id,
        None,
        Some(def.id)
      )
    else if kind == "db_row_update"
      rid = (raw_json.text_at("row_id") or "").trim
      if rid.empty?
        return Error(BadInput(reason: "row_id required for db_row_update"))
      end
      cells_json = try raw_json.get("cells").or_fail(
        BadInput(reason: "cells required for db_row_update")
      )
      cells = try Json.decode_strict[Map(Text, CellValue)](cells_json.to_text.bytes).map_error(fn(
        e
      )
        BadInput(reason: "invalid cells: #{e.to_text}")
      end)
      exp_ver = raw_json.int_at("expected_version")
      (
        UpdateDbRow(
          database_id: def.id,
          row_id: rid,
          cells: cells,
          expected_version: exp_ver,
          provenance: prov
        ),
        def.collection_id,
        None,
        Some(def.id)
      )
    else if kind == "db_row_delete"
      rid = (raw_json.text_at("row_id") or "").trim
      if rid.empty?
        return Error(BadInput(reason: "row_id required for db_row_delete"))
      end
      (DeleteDbRow(database_id: def.id, row_id: rid), def.collection_id, None, Some(def.id))
    else if kind == "db_schema_update"
      title_opt = case raw_json.get("title")
        None | Some(Json.Null): None
        Some(Json.String(s)): Some(s)
        Some(_): return Error(BadInput(reason: "invalid schema title"))
      end
      desc_opt = case raw_json.get("description")
        None | Some(Json.Null): None
        Some(Json.String(s)): Some(s)
        Some(_): return Error(BadInput(reason: "invalid schema description"))
      end
      props_opt = case raw_json.get("properties")
        None | Some(Json.Null): None
        Some(pj): Some(
          try Json.decode_strict[List(PropertyDef)](pj.to_text.bytes).map_error(fn(e)
            BadInput(reason: "invalid schema properties: #{e.to_text}")
          end)
        )
      end
      exp_ver = raw_json.int_at("expected_version")
      (
        UpdateDbSchema(
          database_id: def.id,
          title: title_opt,
          description: desc_opt,
          properties: props_opt,
          expected_version: exp_ver
        ),
        def.collection_id,
        None,
        Some(def.id)
      )
    else
      return Error(BadInput(reason: "unsupported mutation kind '#{kind}'"))
    end
  end

  bargs = WorldBranchArgs(mutation: mut, updated_at: now)
  step_reply = try World.world_call_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    pm.world_id,
    "propose",
    bargs.to_json,
    clean_reason,
    now
  ).map_error(Db.map_world_error)

  upd_ev = Json.Object({
    "proposal_id": Json.String(pm.id),
    "kind": Json.String(kind),
    "actor": Json.String(auth.principal.handle)
  })
  var res = json_ok(200, Json.Object({"proposal": pm.to_json, "step_reply": step_reply}))
    .with_sse_publish_json("collection:#{sse_col_id}", "proposal.updated", upd_ev)
  case sse_page_id
    Some(pid): res = res.with_sse_publish_json("page:#{pid}", "proposal.updated", upd_ev)
    None: Unit
  end
  case sse_db_id
    Some(did): res = res.with_sse_publish_json("database:#{did}", "proposal.updated", upd_ev)
    None: Unit
  end
  Ok(res)
end

## `POST /api/databases/:id/scenarios/:proposal_id/query` — Evaluates a live query against a forked Scenario branch with exact `Decimal` deltas (`ReadFiles`-only).
fn query_db_scenario(
  req: Api.Request,
  id: Text,
  proposal_id: Text,
  auth: AuthContext,
  input: Databases.QueryDatabaseInput,
  rf: ReadFiles
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  from_d = case input.from_date
    Some(s) if not s.trim.empty?:
      case Date.parse_iso(s.trim)
        Some(d): Some(d)
        None: return Error(BadInput(reason: "invalid ISO from_date '#{s}'"))
      end
    Some(_) | None: None
  end
  to_d = case input.to_date
    Some(s) if not s.trim.empty?:
      case Date.parse_iso(s.trim)
        Some(d): Some(d)
        None: return Error(BadInput(reason: "invalid ISO to_date '#{s}'"))
      end
    Some(_) | None: None
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end

  read_act = if Policy.action_permitted?(auth, "query_db")
    "query_db"
  else
    "read"
  end

  body_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      live_def = case try Table.get(store, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      pm = case try Table.get(store, Db.proposals_table(), proposal_id).map_error(
        Db.map_table_error
      )
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: proposal_id))
      end
      try Policy.require_collection_access(auth, read_act, live_def.collection_id)
      try Policy.require_collection_access(auth, read_act, pm.collection_id)
      if pm.status != "open"
        return Error(Conflict(reason: "scenario '#{proposal_id}' is '#{pm.status}', not 'open'"))
      end
      world = case try World.get_world(store, pm.world_id).map_error(Db.map_world_error)
        Some(w): w
        None: return Error(Missing(entity: "world", id: pm.world_id))
      end

      (_base_tx, spec_tx) = try Db.materialize_world_tx(store, world)

      live_pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), live_def.id)
        .map_error(Db.map_table_error)
      var live_rows = []
      var live_by_id = {}
      for (_rid, r) in live_pairs
        if r.archived_at == None
          live_rows = live_rows.append(r)
          live_by_id = live_by_id.set(r.id, r)
        end
      end
      live_enriched = try Db.enrich_rows_with_rollups(store, live_def, live_rows)

      spec_def = case try Table.tx_get(spec_tx, Db.databases_table(), id).map_error(
        Db.map_table_error
      )
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      spec_pairs = try Table.tx_lookup(
        spec_tx,
        Db.db_rows_table(),
        Db.db_rows_by_database(),
        spec_def.id
      ).map_error(Db.map_table_error)
      var spec_rows = []
      var spec_id_set = Set.empty
      for (_rid, r) in spec_pairs
        if r.archived_at == None
          spec_rows = spec_rows.append(r)
          spec_id_set = spec_id_set.add(r.id)
        end
      end
      spec_enriched = try Db.tx_enrich_rows_with_rollups(spec_tx, spec_def, spec_rows)

      var row_changes_map = {}
      for sr in spec_rows
        case live_by_id.get(sr.id)
          None: row_changes_map = row_changes_map.set(sr.id, Json.String("added"))
          Some(lr):
            if lr.cells != sr.cells
              row_changes_map = row_changes_map.set(sr.id, Json.String("modified"))
            end
        end
      end
      removed_rows = live_enriched.filter(fn(er) not spec_id_set.has?(er.row.id) end)
      deltas = Db.compute_db_decimal_deltas(spec_def, live_enriched, spec_enriched)

      view_opt = case input.view_id
        None: None
        Some(vid):
          found = case try Table.tx_get(spec_tx, Db.db_views_table(), vid).map_error(
            Db.map_table_error
          )
            Some(v) if v.database_id == spec_def.id: v
            Some(_) | None: return Error(Missing(entity: "db_view", id: vid))
          end
          Some(found)
      end

      filters = if not input.filters.empty?
        input.filters
      else
        case view_opt
          Some(v): v.filters
          None: []
        end
      end
      match_all? = case input.filter_match_all
        Some(b): b
        None:
          case view_opt
            Some(v): v.filter_match_all
            None: true
          end
      end
      sorts = if not input.sorts.empty?
        input.sorts
      else
        case view_opt
          Some(v): v.sorts
          None: []
        end
      end

      filtered = spec_enriched.filter(fn(er)
        DatabaseModel.matches_filters?(er, filters, match_all?)
      end)
      sorted = DatabaseModel.sort_enriched_rows(filtered, sorts)

      (final_rows, board_groups) = case view_opt
        Some(v):
          case v.kind
            TableView(visible_prop_ids: _, column_widths: _): (sorted, None)
            BoardView(group_by_prop_id: gb_id, card_prop_ids: _, hide_empty_groups: hide_empty):
              groups = DatabaseModel.group_rows_for_board(spec_def, sorted, gb_id, hide_empty)
              (sorted, Some(groups))
            CalendarView(date_prop_id: dp_id, card_prop_ids: _):
              ranged = DatabaseModel.filter_calendar_range(sorted, dp_id, from_d, to_d)
              (ranged, None)
            GalleryView(cover_prop_id: _, card_prop_ids: _, card_size: _): (sorted, None)
            TimelineView(start_date_prop_id: sp_id, end_date_prop_id: ep_opt, card_prop_ids: _):
              (DatabaseModel.filter_timeline_range(sorted, sp_id, ep_opt, from_d, to_d), None)
          end
        None: (sorted, None)
      end

      qres = ViewQueryResult(
        view: view_opt,
        rows: final_rows,
        board_groups: board_groups,
        total_count: final_rows.size
      )
      schema_changed = spec_def.properties != live_def.properties or
        spec_def.title != live_def.title or
        spec_def.description != live_def.description

      Ok(
        Json.Object({
          "proposal": pm.to_json,
          "database": spec_def.to_json,
          "query_result": qres.to_json,
          "deltas": deltas.to_json,
          "row_changes": Json.Object(row_changes_map),
          "removed_rows": removed_rows.to_json,
          "live_row_count": Json.int(live_enriched.size),
          "scenario_row_count": Json.int(spec_enriched.size),
          "schema_changed": Json.Boolean(schema_changed),
          "step_count": Json.int(world.steps.size)
        })
      )
    end
  )
  Ok(json_ok(200, body_json))
end

fn load_active_rows_tx(tx: WriteTx, db_id: Text) : Result(List(DbRow), AppError)
  pairs = try Table.tx_lookup(tx, Db.db_rows_table(), Db.db_rows_by_database(), db_id).map_error(
    Db.map_table_error
  )
  var out = []
  for (_rid, r) in pairs
    if r.archived_at == None
      out = out.append(r)
    end
  end
  Ok(out)
end

fn compute_db_schema_diffs(did: Text, base_opt: Option(DatabaseDef), spec_opt: Option(DatabaseDef)) : List(
  Json
)
  case (base_opt, spec_opt)
    (Some(bdef), Some(sdef)):
      var base_props = {}
      for p in bdef.properties
        base_props = base_props.set(p.id, p)
      end
      var spec_props = {}
      for p in sdef.properties
        spec_props = spec_props.set(p.id, p)
      end
      var diffs = []
      for p in bdef.properties
        case spec_props.get(p.id)
          None: diffs = diffs.append(
            Json.Object({
              "database_id": Json.String(did),
              "database_title": Json.String(sdef.title),
              "prop_id": Json.String(p.id),
              "prop_name": Json.String(p.name),
              "change": Json.String("removed"),
              "before_kind": p.kind.to_json,
              "after_kind": Json.Null,
              "before_required": Json.Boolean(p.required),
              "after_required": Json.Null
            })
          )
          Some(np):
            if np != p
              diffs = diffs.append(
                Json.Object({
                  "database_id": Json.String(did),
                  "database_title": Json.String(sdef.title),
                  "prop_id": Json.String(p.id),
                  "prop_name": Json.String(np.name),
                  "change": Json.String("modified"),
                  "before_kind": p.kind.to_json,
                  "after_kind": np.kind.to_json,
                  "before_required": Json.Boolean(p.required),
                  "after_required": Json.Boolean(np.required)
                })
              )
            end
        end
      end
      for np in sdef.properties
        if base_props.get(np.id) == None
          diffs = diffs.append(
            Json.Object({
              "database_id": Json.String(did),
              "database_title": Json.String(sdef.title),
              "prop_id": Json.String(np.id),
              "prop_name": Json.String(np.name),
              "change": Json.String("added"),
              "before_kind": Json.Null,
              "after_kind": np.kind.to_json,
              "before_required": Json.Null,
              "after_required": Json.Boolean(np.required)
            })
          )
        end
      end
      diffs
    (_, _): []
  end
end

fn union_props(base_opt: Option(DatabaseDef), spec_opt: Option(DatabaseDef)) : List(PropertyDef)
  var out = []
  var seen = Set.empty
  case spec_opt
    Some(sdef):
      for p in sdef.properties
        if not seen.has?(p.id)
          seen = seen.add(p.id)
          out = out.append(p)
        end
      end
    None: Unit
  end
  case base_opt
    Some(bdef):
      for p in bdef.properties
        if not seen.has?(p.id)
          seen = seen.add(p.id)
          out = out.append(p)
        end
      end
    None: Unit
  end
  out
end

fn compute_db_row_diffs(
  did: Text,
  base_opt: Option(DatabaseDef),
  spec_opt: Option(DatabaseDef),
  base_enr: List(EnrichedRow),
  spec_enr: List(EnrichedRow)
) : List(Json)
  eff_def = case spec_opt
    Some(s): s
    None:
      case base_opt
        Some(b): b
        None: return []
      end
  end
  db_title = eff_def.title
  all_props = union_props(base_opt, spec_opt)
  var base_map = {}
  for er in base_enr
    base_map = base_map.set(er.row.id, er)
  end
  var spec_map = {}
  for er in spec_enr
    spec_map = spec_map.set(er.row.id, er)
  end
  empty_val = Empty

  var diffs = []
  for ber in base_enr
    rid = ber.row.id
    case spec_map.get(rid)
      None:
        var cell_diffs = []
        for p in all_props
          bv = DatabaseModel.effective_cell(ber, p.id)
          if bv != empty_val
            cell_diffs = cell_diffs.append(
              Json.Object({
                "prop_id": Json.String(p.id),
                "prop_name": Json.String(p.name),
                "before": bv.to_json,
                "after": empty_val.to_json
              })
            )
          end
        end
        row_title = case base_opt
          Some(bd): DatabaseModel.extract_row_title(bd, ber.row.cells)
          None: rid
        end
        diffs = diffs.append(
          Json.Object({
            "database_id": Json.String(did),
            "database_title": Json.String(db_title),
            "row_id": Json.String(rid),
            "page_id": Json.String(ber.row.page_id),
            "change": Json.String("removed"),
            "row_title": Json.String(row_title),
            "cell_diffs": Json.Array(cell_diffs)
          })
        )
      Some(ser):
        var cell_diffs = []
        for p in all_props
          bv = DatabaseModel.effective_cell(ber, p.id)
          av = DatabaseModel.effective_cell(ser, p.id)
          if bv != av
            cell_diffs = cell_diffs.append(
              Json.Object({
                "prop_id": Json.String(p.id),
                "prop_name": Json.String(p.name),
                "before": bv.to_json,
                "after": av.to_json
              })
            )
          end
        end
        if not cell_diffs.empty?
          row_title = DatabaseModel.extract_row_title(eff_def, ser.row.cells)
          diffs = diffs.append(
            Json.Object({
              "database_id": Json.String(did),
              "database_title": Json.String(db_title),
              "row_id": Json.String(rid),
              "page_id": Json.String(ser.row.page_id),
              "change": Json.String("modified"),
              "row_title": Json.String(row_title),
              "cell_diffs": Json.Array(cell_diffs)
            })
          )
        end
    end
  end
  for ser in spec_enr
    rid = ser.row.id
    if base_map.get(rid) == None
      var cell_diffs = []
      for p in all_props
        av = DatabaseModel.effective_cell(ser, p.id)
        if av != empty_val
          cell_diffs = cell_diffs.append(
            Json.Object({
              "prop_id": Json.String(p.id),
              "prop_name": Json.String(p.name),
              "before": empty_val.to_json,
              "after": av.to_json
            })
          )
        end
      end
      row_title = DatabaseModel.extract_row_title(eff_def, ser.row.cells)
      diffs = diffs.append(
        Json.Object({
          "database_id": Json.String(did),
          "database_title": Json.String(db_title),
          "row_id": Json.String(rid),
          "page_id": Json.String(ser.row.page_id),
          "change": Json.String("added"),
          "row_title": Json.String(row_title),
          "cell_diffs": Json.Array(cell_diffs)
        })
      )
    end
  end
  diffs
end

fn block_diff_json(
  block_id: Text,
  change: Text,
  rank: Text,
  before_blk: Option(Block),
  after_blk: Option(Block),
  page_id: Text,
  page_title: Option(Text)
) : Json
  before_kind_json = case before_blk
    Some(b): b.kind.to_json
    None: Json.Null
  end
  after_kind_json = case after_blk
    Some(b): b.kind.to_json
    None: Json.Null
  end
  before_md_json = case before_blk
    Some(b): Json.String(b.markdown)
    None: Json.Null
  end
  after_md_json = case after_blk
    Some(b): Json.String(b.markdown)
    None: Json.Null
  end
  pt_json = case page_title
    Some(t): Json.String(t)
    None: Json.Null
  end
  Json.Object({
    "block_id": Json.String(block_id),
    "change": Json.String(change),
    "rank": Json.String(rank),
    "page_id": Json.String(page_id),
    "page_title": pt_json,
    "before_kind": before_kind_json,
    "after_kind": after_kind_json,
    "before_markdown": before_md_json,
    "after_markdown": after_md_json
  })
end

fn compute_block_diffs(
  before_blocks: List(Block),
  after_blocks: List(Block),
  page_id: Text,
  page_title: Option(Text)
) : List(Json)
  var before_map = {}
  for b in before_blocks
    before_map = before_map.set(b.id, b)
  end
  var after_map = {}
  for b in after_blocks
    after_map = after_map.set(b.id, b)
  end
  var entries = []
  for old_b in before_blocks
    case after_map.get(old_b.id)
      None:
        entries = entries.append(
          (
            old_b.rank,
            old_b.id,
            block_diff_json(old_b.id, "removed", old_b.rank, Some(old_b), None, page_id, page_title)
          )
        )
      Some(cur_b):
        if old_b.markdown != cur_b.markdown or old_b.kind != cur_b.kind
          entries = entries.append(
            (
              cur_b.rank,
              cur_b.id,
              block_diff_json(
                cur_b.id,
                "modified",
                cur_b.rank,
                Some(old_b),
                Some(cur_b),
                page_id,
                page_title
              )
            )
          )
        end
    end
  end
  for cur_b in after_blocks
    if before_map.get(cur_b.id) == None
      entries = entries.append(
        (
          cur_b.rank,
          cur_b.id,
          block_diff_json(cur_b.id, "added", cur_b.rank, None, Some(cur_b), page_id, page_title)
        )
      )
    end
  end
  entries.sort_by(fn(e) e.1 end).sort_by(fn(e) e.0 end).map(fn(e) e.2 end)
end

## `GET /api/proposals/:id/diff` — Inspects structural CoW diffs plus multi-page block diffs and DB row/schema/rollup diffs (`ReadFiles`-only).
fn diff_proposal(id: Text, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      found = case try Table.get(store, Db.proposals_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, "read", found.collection_id)

      page_opt = try Table.get(store, Db.pages_table(), found.target_page_id).map_error(
        Db.map_table_error
      )
      page_title_json = case page_opt.map(fn(p) p.title end)
        Some(t): Json.String(t)
        None: Json.Null
      end
      db_title_json = case found.target_database_id
        Some(did):
          case try Table.get(store, Db.databases_table(), did).map_error(Db.map_table_error)
            Some(d): Json.String(d.title)
            None: Json.Null
          end
        None: Json.Null
      end

      world_opt = try World.get_world(store, found.world_id).map_error(Db.map_world_error)
      step_count = case world_opt
        Some(w): w.steps.size
        None: 0
      end
      cmt_pairs = try Table.lookup(
        store,
        Db.proposal_comments_table(),
        Db.proposal_comments_by_proposal(),
        found.id
      ).map_error(Db.map_table_error)
      comments = cmt_pairs.map(fn(p) p.1 end).sort_by(fn(c) c.id end)

      if found.status != "open"
        return Ok(
          Json.Object({
            "proposal": found.to_json,
            "page_title": page_title_json,
            "database_title": db_title_json,
            "bucket_diffs": Json.Array([]),
            "block_diffs": Json.Array([]),
            "db_row_diffs": Json.Array([]),
            "db_schema_diffs": Json.Array([]),
            "rollup_deltas": Json.Array([]),
            "comments": comments.to_json,
            "step_count": Json.int(step_count)
          })
        )
      end

      diffs = try World.world_diff(db, Db.world_catalog(), found.world_id).map_error(
        Db.map_world_error
      )
      (block_diffs, db_row_diffs, db_schema_diffs, rollup_deltas) = case world_opt
        None: ([], [], [], [])
        Some(world):
          (base_tx, spec_tx) = try Db.materialize_world_tx(store, world)
          (touched_pages, touched_dbs) = Db.world_touched_resources(
            world,
            found.target_page_id,
            found.target_database_id
          )

          var all_bdiffs = []
          for pid in touched_pages
            pg_base = try Table.tx_get(base_tx, Db.pages_table(), pid).map_error(Db.map_table_error)
            pg_spec = try Table.tx_get(spec_tx, Db.pages_table(), pid).map_error(Db.map_table_error)
            ptitle = case pg_spec
              Some(p): Some(p.title)
              None: pg_base.map(fn(p) p.title end)
            end
            brows_before = try Table.tx_lookup(
              base_tx,
              Db.blocks_table(),
              Db.blocks_by_page(),
              pid
            ).map_error(Db.map_table_error)
            brows_after = try Table.tx_lookup(
              spec_tx,
              Db.blocks_table(),
              Db.blocks_by_page(),
              pid
            ).map_error(Db.map_table_error)
            b_before = Blocks.sort_blocks(brows_before.map(fn(x) x.1 end))
            b_after = Blocks.sort_blocks(brows_after.map(fn(x) x.1 end))
            for bd in compute_block_diffs(b_before, b_after, pid, ptitle)
              all_bdiffs = all_bdiffs.append(bd)
            end
          end

          var all_rdiffs = []
          var all_sdiffs = []
          var all_deltas = []
          for did in touched_dbs
            base_def_opt = try Table.tx_get(base_tx, Db.databases_table(), did).map_error(
              Db.map_table_error
            )
            spec_def_opt = try Table.tx_get(spec_tx, Db.databases_table(), did).map_error(
              Db.map_table_error
            )
            for sd in compute_db_schema_diffs(did, base_def_opt, spec_def_opt)
              all_sdiffs = all_sdiffs.append(sd)
            end
            base_enr = case base_def_opt
              Some(bdef):
                brows = try load_active_rows_tx(base_tx, did)
                try Db.tx_enrich_rows_with_rollups(base_tx, bdef, brows)
              None: []
            end
            spec_enr = case spec_def_opt
              Some(sdef):
                srows = try load_active_rows_tx(spec_tx, did)
                try Db.tx_enrich_rows_with_rollups(spec_tx, sdef, srows)
              None: []
            end
            for rd in compute_db_row_diffs(did, base_def_opt, spec_def_opt, base_enr, spec_enr)
              all_rdiffs = all_rdiffs.append(rd)
            end
            case spec_def_opt
              Some(eff):
                for dd in Db.compute_db_decimal_deltas(eff, base_enr, spec_enr)
                  all_deltas = all_deltas.append(dd)
                end
              None: Unit
            end
          end

          (all_bdiffs, all_rdiffs, all_sdiffs, all_deltas)
      end

      Ok(
        Json.Object({
          "proposal": found.to_json,
          "page_title": page_title_json,
          "database_title": db_title_json,
          "bucket_diffs": diffs.to_json,
          "block_diffs": Json.Array(block_diffs),
          "db_row_diffs": Json.Array(db_row_diffs),
          "db_schema_diffs": Json.Array(db_schema_diffs),
          "rollup_deltas": rollup_deltas.to_json,
          "comments": comments.to_json,
          "step_count": Json.int(step_count)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

fn map_land_world_error(err: World.WorldError) : AppError
  case err
    World.ActionRejected(action: _, detail: d):
      if d.contains?("version mismatch")
        Conflict(reason: err.to_text)
      else
        Db.map_world_error(err)
      end
    World.LedgerFailure(_) | World.GrantFailure(_) | World.WorldNotFound(id: _) | World
      .WorldAlreadyExists(id: _) | World.WorldNotOpen(id: _, status: _) | World.WorldExpired(id: _) | World
      .UnknownQuery(name: _) | World.UnknownAction(name: _) | World.QueryFailed(query: _, detail: _) | World
      .StaleRead(query: _, args: _, expected: _, actual: _) | World.InvariantRejected(
        name: _,
        detail: _
      ): Db.map_world_error(err)
  end
end

## `POST /api/proposals/:id/accept` — Validates & atomically lands a `Modb.World` proposal onto the live workspace.
fn accept_proposal(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end
  reason_override = if req.body.empty?
    None
  else
    case Json.decode_strict[ProposalDecisionInput](req.body)
      Ok(d): d.reason
      Error(_): None
    end
  end

  accept_act = if Policy.action_permitted?(auth, "publish")
    "publish"
  else
    "write_direct"
  end

  (pm, col, matching_subs, touched_pages, touched_dbs, touches_schema?, prop_untrusted) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      found = case try Table.get(store, Db.proposals_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, accept_act, found.collection_id)
      c = case try Table.get(store, Db.collections_table(), found.collection_id).map_error(
        Db.map_table_error
      )
        Some(col_rec): col_rec
        None: return Error(Missing(entity: "collection", id: found.collection_id))
      end

      (t_pages, t_dbs, t_schema?) = case try World.get_world(store, found.world_id).map_error(
        Db.map_world_error
      )
        Some(w):
          (ps, ds) = Db.world_touched_resources(w, found.target_page_id, found.target_database_id)
          (ps, ds, Db.world_touches_schema?(w))
        None: ([found.target_page_id], [], false)
      end

      if t_schema? and not Policy.action_permitted?(auth, "manage_schema")
        return Error(
          Forbidden(
            reason: "grant '#{auth.grant_id}' does not permit 'manage_schema' required to land schema changes"
          )
        )
      end

      for pid in t_pages
        case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
          Some(pg):
            try Policy.require_collection_access(auth, accept_act, pg.collection_id)
            case try Table.get(store, Db.collections_table(), pg.collection_id).map_error(
              Db.map_table_error
            )
              Some(pcol):
                if pcol.write_policy != DirectWithAudit and auth.principal.kind != Human
                  return Error(
                    Forbidden(
                      reason: "collection '#{pcol.slug}' write policy requires a Human reviewer to accept proposals"
                    )
                  )
                end
              None: return Error(Missing(entity: "collection", id: pg.collection_id))
            end
          None: Unit
        end
      end

      for did in t_dbs
        db_req_act = if t_schema?
          "manage_schema"
        else if Policy.action_permitted?(auth, "write_db")
          "write_db"
        else
          accept_act
        end
        case try Table.get(store, Db.databases_table(), did).map_error(Db.map_table_error)
          Some(ddef):
            try Policy.require_collection_access(auth, db_req_act, ddef.collection_id)
            case try Table.get(store, Db.collections_table(), ddef.collection_id).map_error(
              Db.map_table_error
            )
              Some(dcol):
                if dcol.write_policy != DirectWithAudit and auth.principal.kind != Human
                  return Error(
                    Forbidden(
                      reason: "collection '#{dcol.slug}' write policy requires a Human reviewer to accept proposals"
                    )
                  )
                end
              None: return Error(Missing(entity: "collection", id: ddef.collection_id))
            end
          None: return Error(Missing(entity: "database", id: did))
        end
      end

      prop_prov_opt = try TaintBridge.get_provenance_info(store, "vlm_proposals", found.id)
      prop_untrusted = case prop_prov_opt
        Some((tr, _w, _at)): tr == "untrusted"
        None: false
      end
      subs = try matching_webhooks_in_store(store, "proposal.accepted", Some(found.collection_id))
      Ok((found, c, subs, t_pages, t_dbs, t_schema?, prop_untrusted))
    end
  )
  if pm.status != "open"
    return Error(Conflict(reason: "proposal '#{id}' is '#{pm.status}', not 'open'"))
  end
  if col.write_policy != DirectWithAudit and auth.principal.kind != Human
    return Error(
      Forbidden(
        reason: "collection '#{col.slug}' write policy requires a Human reviewer to accept proposals"
      )
    )
  end

  now = clock.now
  land_reason = reason_override or "accept proposal '#{pm.title}' (#{pm.id})"
  land_res = try World.land_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    pm.world_id,
    land_reason,
    now
  ).map_error(map_land_world_error)

  accepted = ProposalMeta(
    id: pm.id,
    world_id: pm.world_id,
    collection_id: pm.collection_id,
    target_page_id: pm.target_page_id,
    target_database_id: pm.target_database_id,
    branch_kind: pm.branch_kind,
    title: pm.title,
    reason: pm.reason,
    author_id: pm.author_id,
    author_handle: pm.author_handle,
    grant_id: pm.grant_id,
    status: "accepted",
    created_at: pm.created_at,
    updated_at: now,
    decided_by: Some(auth.principal.id),
    decided_at: Some(now)
  )

  var idx_page_ids = [pm.target_page_id]
  for pid in touched_pages
    if not idx_page_ids.contains?(pid)
      idx_page_ids = idx_page_ids.append(pid)
    end
  end
  var idx_jobs = []
  for ipid in idx_page_ids
    idx_jobs = idx_jobs.append(
      Jobs.prepare(rng, clock, "vellum.page.indexed", Json.Object({"page_id": Json.String(ipid)}))
    )
  end

  hook_jobs = prepare_webhook_jobs(
    matching_subs,
    "proposal.accepted",
    Json.Object({
      "event": Json.String("proposal.accepted"),
      "proposal": accepted.to_json,
      "commit_txid": Json.int(land_res.commit_txid)
    }),
    caller_taint_sid(req, auth),
    rng,
    clock
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "proposal.accept",
    reason: land_reason,
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "accepted proposal #{accepted.id}",
    Json.Object({
      "proposal_id": Json.String(accepted.id),
      "commit_txid": Json.int(land_res.commit_txid)
    }),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, accept_act, now)
      var cur = try Table.put(t1, Db.proposals_table(), accepted.id, accepted).map_error(
        Db.map_table_error
      )
      if prop_untrusted
        cur = try TaintBridge.tx_mark_provenance(
          cur,
          "vlm_pages",
          accepted.target_page_id,
          "proposal:#{accepted.id}",
          "untrusted",
          now
        )
        for ipid in idx_page_ids
          b_rows = try Table.tx_lookup(cur, Db.blocks_table(), Db.blocks_by_page(), ipid).map_error(
            Db.map_table_error
          )
          for (bid, blk) in b_rows
            if blk.provenance.proposal_id == Some(accepted.id)
              cur = try TaintBridge.tx_mark_provenance(
                cur,
                "vlm_blocks",
                bid,
                "proposal:#{accepted.id}",
                "untrusted",
                now
              )
            end
          end
        end
      end
      for ij in idx_jobs
        (cur_idx, _idx_jid) = try Jobs.tx_put(cur, ij).map_error(Db.map_table_error)
        cur = cur_idx
      end
      for job_rec in hook_jobs
        (next_tx, _jid) = try Jobs.tx_put(cur, job_rec).map_error(Db.map_table_error)
        cur = next_tx
      end
      Ok((cur, accepted))
    end
  )
  prop_payload = Json.Object({
    "proposal_id": Json.String(saved.id),
    "page_id": Json.String(saved.target_page_id),
    "collection_id": Json.String(saved.collection_id),
    "status": Json.String("accepted"),
    "commit_txid": Json.int(land_res.commit_txid),
    "actor": Json.String(auth.principal.handle)
  })
  var resp = json_ok(
    200,
    Json.Object({"proposal": saved.to_json, "land_result": land_res.to_json})
  ).with_sse_publish_json("collection:#{saved.collection_id}", "proposal.accepted", prop_payload)
    .with_sse_publish_json("page:#{saved.target_page_id}", "proposal.accepted", prop_payload)
  for did in touched_dbs
    db_ev = Json.Object({
      "database_id": Json.String(did),
      "proposal_id": Json.String(saved.id),
      "commit_txid": Json.int(land_res.commit_txid),
      "actor": Json.String(auth.principal.handle)
    })
    resp = resp.with_sse_publish_json("database:#{did}", "proposal.accepted", prop_payload)
      .with_sse_publish_json("database:#{did}", "db.row_updated", db_ev)
    if touches_schema?
      resp = resp.with_sse_publish_json("database:#{did}", "db.schema_updated", db_ev)
    end
  end
  Ok(resp)
end

## `POST /api/proposals/:id/reject` — Drops a pending `Modb.World` branch and marks the proposal rejected.
fn reject_proposal(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end

  pm = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      found = case try Table.get(Ledger.store(db), Db.proposals_table(), id).map_error(
        Db.map_table_error
      )
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      Ok(found)
    end
  )
  if pm.status != "open"
    return Error(Conflict(reason: "proposal '#{id}' is '#{pm.status}', not 'open'"))
  end
  can_reject? = pm.author_id == auth.principal.id or
    Policy.collection_permitted?(auth, pm.collection_id) and
      Policy.action_permitted?(auth, "publish")
  if not can_reject?
    return Error(Forbidden(reason: "not permitted to reject proposal '#{id}'"))
  end

  now = clock.now
  case World.drop_world_locked(files, Db.ledger_db_path, Db.vellum_schema(), pm.world_id, now)
    Ok(_): Unit
    Error(World.WorldNotOpen(id: _, status: _)) | Error(World.WorldExpired(id: _)): Unit
    Error(e): return Error(Db.map_world_error(e))
  end

  rejected = ProposalMeta(
    id: pm.id,
    world_id: pm.world_id,
    collection_id: pm.collection_id,
    target_page_id: pm.target_page_id,
    target_database_id: pm.target_database_id,
    branch_kind: pm.branch_kind,
    title: pm.title,
    reason: pm.reason,
    author_id: pm.author_id,
    author_handle: pm.author_handle,
    grant_id: pm.grant_id,
    status: "rejected",
    created_at: pm.created_at,
    updated_at: now,
    decided_by: Some(auth.principal.id),
    decided_at: Some(now)
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "proposal.reject",
    reason: "reject proposal '#{pm.id}'",
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "rejected proposal #{rejected.id}",
    Json.Object({"proposal_id": Json.String(rejected.id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, Db.proposals_table(), rejected.id, rejected).map_error(
        Db.map_table_error
      )
      Ok((t1, rejected))
    end
  )
  prop_payload = Json.Object({
    "proposal_id": Json.String(saved.id),
    "page_id": Json.String(saved.target_page_id),
    "collection_id": Json.String(saved.collection_id),
    "status": Json.String("rejected"),
    "actor": Json.String(auth.principal.handle)
  })
  var resp = json_ok(200, saved.to_json)
    .with_sse_publish_json("collection:#{saved.collection_id}", "proposal.rejected", prop_payload)
    .with_sse_publish_json("page:#{saved.target_page_id}", "proposal.rejected", prop_payload)
  case saved.target_database_id
    Some(did): resp = resp.with_sse_publish_json("database:#{did}", "proposal.rejected", prop_payload)
    None: Unit
  end
  Ok(resp)
end

## `POST /api/admin/replay/baseline` — Pins current CoW catalog root as `Modb.Replay` starting point.
fn pin_replay_baseline(req: Api.Request, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may pin replay baselines"))
  end
  bl = try Replay.pin_baseline_locked(files, Db.ledger_db_path, Db.vellum_schema(), clock.now)
    .map_error(Db.map_replay_error)
  Ok(json_ok(201, bl.to_json))
end

fn replay_call_targets_page?(args: Json, page_id: Text) : Bool
  args.text_at("page_id") == Some(page_id) or
    args.text_at("mutation.patch_page.page_id") == Some(page_id) or
    args.text_at("mutation.create_db_row.page_id") == Some(page_id)
end

fn first_some_text(opts: List(Option(Text))) : Option(Text)
  for o in opts
    case o
      Some(v): return Some(v)
      None: Unit
    end
  end
  None
end

fn replay_call_target_ids(args: Json) : (Option(Text), Option(Text))
  pg = first_some_text([
    args.text_at("page_id"),
    args.text_at("mutation.patch_page.page_id"),
    args.text_at("mutation.create_db_row.page_id")
  ])
  dbid = first_some_text([
    args.text_at("database_id"),
    args.text_at("mutation.update_db_row.database_id"),
    args.text_at("mutation.create_db_row.database_id")
  ])
  (pg, dbid)
end

fn replay_proposal_summary_json(prop: Replay.ReplayProposal) : Json
  Json.Object({
    "id": Json.String(prop.id),
    "description": Json.String(prop.description),
    "filter": prop.filter.to_json,
    "base_call_seq": Json.int(prop.base_call_seq),
    "created_by": Json.String(prop.created_by),
    "created_at": prop.created_at.to_json,
    "status": prop.status.to_json,
    "summary": prop.summary.to_json,
    "outcomes": prop.outcomes.to_json,
    "bucket_diffs": prop.bucket_diffs.to_json
  })
end

## `GET /api/admin/replay/status` — Returns CoW baseline, recorded `Modb.Replay` call history,
## and compact `ReplayProposal` summaries without giant snapshot blobs (`ReadFiles`-only).
fn replay_status(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may inspect replay status"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "baseline": Json.Null,
          "call_count": Json.int(0),
          "calls": Json.Array([]),
          "proposals": Json.Array([])
        })
      )
    )
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      bl = try Replay.get_baseline(store).map_error(Db.map_replay_error)
      cnt = try Replay.call_count(store).map_error(Db.map_replay_error)
      calls = try Replay.list_calls_tail(store, 100).map_error(Db.map_replay_error)
      props = try Replay.list_proposals(store).map_error(Db.map_replay_error)
      calls_json = calls.map(fn(c)
        (pg_opt, db_opt) = replay_call_target_ids(c.args)
        Json.Object({
          "seq": Json.int(c.seq),
          "audit_seq": c.audit_seq.to_json,
          "principal": Json.String(c.principal),
          "grant_id": c.grant_id.to_json,
          "world_id": c.world_id.to_json,
          "action": Json.String(c.action),
          "reason": Json.String(c.reason),
          "at": c.at.to_json,
          "page_id": pg_opt.to_json,
          "database_id": db_opt.to_json,
          "outcome": c.outcome.to_json
        })
      end)
      props_json = props.reverse.take(25).map(replay_proposal_summary_json)
      Ok(
        Json.Object({
          "baseline": bl.to_json,
          "call_count": Json.int(cnt),
          "calls": Json.Array(calls_json),
          "proposals": Json.Array(props_json)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/admin/replay/simulate` — Runs offline selective rollback simulation via `Modb.Replay`.
fn simulate_replay(
  req: Api.Request,
  auth: AuthContext,
  input: SimulateReplayInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may simulate replay rollbacks"))
  end
  filter = try parse_replay_filter(input)
  now = clock.now
  rprop_id = "rpl_#{Id.ulid(rng, clock)}"
  prop = try Replay.simulate_replay_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.replay_catalog(),
    filter,
    rprop_id,
    input.description.trim,
    auth.principal.id,
    now
  ).map_error(Db.map_replay_error)

  Ok(
    json_ok(
      201,
      Json.Object({
        "proposal_id": Json.String(prop.id),
        "description": Json.String(prop.description),
        "filter": prop.filter.to_json,
        "base_call_seq": Json.int(prop.base_call_seq),
        "summary": prop.summary.to_json,
        "outcomes": prop.outcomes.to_json,
        "bucket_diffs": prop.bucket_diffs.to_json,
        "status": prop.status.to_json
      })
    )
  )
end

## `GET /api/pages/:id/history` — Lists point-in-time `Modb.Replay` timeline stops for page `id`.
fn page_replay_history(id: Text, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: id))
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      page = case try Table.get(store, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      try Policy.require_collection_access(auth, "read", page.collection_id)
      bl_opt = try Replay.get_baseline(store).map_error(Db.map_replay_error)
      calls = try Replay.list_calls(store).map_error(Db.map_replay_error)
      page_calls = calls.filter(fn(c) replay_call_targets_page?(c.args, id) end)
      var stops = []
      case bl_opt
        Some(bl):
          stops = stops.append(
            Json.Object({
              "seq": Json.int(0),
              "stop_before_seq": Json.int(1),
              "label": Json.String("Pinned Baseline"),
              "principal": Json.String("system"),
              "action": Json.String("baseline"),
              "reason": Json.String("CoW baseline snapshot"),
              "world_id": Json.Null,
              "grant_id": Json.Null,
              "at": bl.pinned_at.to_json
            })
          )
        None: Unit
      end
      for c in page_calls
        stops = stops.append(
          Json.Object({
            "seq": Json.int(c.seq),
            "stop_before_seq": Json.int(c.seq + 1),
            "label": Json.String("Call ##{c.seq} · #{c.principal}"),
            "principal": Json.String(c.principal),
            "action": Json.String(c.action),
            "reason": Json.String(c.reason),
            "world_id": c.world_id.to_json,
            "grant_id": c.grant_id.to_json,
            "at": c.at.to_json
          })
        )
      end
      Ok(
        Json.Object({
          "page_id": Json.String(page.id),
          "current_version": Json.int(page.version),
          "baseline": bl_opt.to_json,
          "can_scrub": Json.Boolean(bl_opt != None),
          "total_replay_calls": Json.int(calls.size),
          "stops": Json.Array(stops)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `GET /api/pages/:id/time-travel` — Runs offline `Modb.Replay.preview_replay` at `stop_before_seq`
## and returns historical reconstructed blocks + diff count against live without mutating storage.
fn page_time_travel(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  rf: ReadFiles,
  clock: Clock
) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: id))
  end
  now = clock.now
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      page = case try Table.get(store, Db.pages_table(), id).map_error(Db.map_table_error)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: id))
      end
      try Policy.require_collection_access(auth, "read", page.collection_id)
      bl_opt = try Replay.get_baseline(store).map_error(Db.map_replay_error)
      if bl_opt == None
        return Error(
          BadInput(
            reason: "No Modb.Replay baseline pinned yet; pin a replay baseline in Admin -> Selective Undo."
          )
        )
      end
      total_calls = try Replay.call_count(store).map_error(Db.map_replay_error)
      stop_before_seq = case req.query_param("stop_before_seq")
        Some(s): try s.trim.to_int.or_fail(BadInput(reason: "stop_before_seq must be an integer"))
        None: total_calls + 1
      end
      if stop_before_seq < 1
        return Error(BadInput(reason: "stop_before_seq must be >= 1"))
      end
      prop = try Replay.preview_replay(
        db,
        Db.replay_catalog(),
        Replay.StopBeforeSeq(seq: stop_before_seq),
        "tt_#{id}_#{stop_before_seq}",
        "Point-in-time preview for #{id}",
        auth.principal.id,
        now
      ).map_error(Db.map_replay_error)
      (hist_page_opt, hist_blocks) = try Db.reconstruct_page_from_replay_proposal(store, id, prop)
      live_blocks = try Db.load_page_blocks(store, id)
      (diff_ops, _) = Blocks.diff_blocks_to_ops(hist_blocks, live_blocks)
      hist_md = Blocks.to_anchored_markdown(hist_blocks)
      Ok(
        Json.Object({
          "page_id": Json.String(id),
          "stop_before_seq": Json.int(stop_before_seq),
          "existed_at_point": Json.Boolean(hist_page_opt != None),
          "historical_page": hist_page_opt.to_json,
          "historical_blocks": hist_blocks.to_json,
          "historical_markdown": Json.String(hist_md),
          "ops_to_live_count": Json.int(diff_ops.size),
          "summary": prop.summary.to_json,
          "outcomes": prop.outcomes.to_json
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/admin/replay/:id/accept` — Applies a simulated `Modb.Replay` selective rollback proposal atomically.
fn accept_replay(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may accept replay proposals"))
  end
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "replay.accept",
    reason: "accept selective rollback proposal '#{id}'",
    at: now
  )
  accepted = try Replay.accept_proposal_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    id,
    meta
  ).map_error(Db.map_replay_error)
  Ok(
    json_ok(
      200,
      Json.Object({
        "proposal_id": Json.String(accepted.id),
        "status": accepted.status.to_json,
        "summary": accepted.summary.to_json
      })
    )
  )
end

## `POST /api/admin/replay/:id/discard` — Discards a pending `Modb.Replay` proposal without mutating live tables.
fn discard_replay(req: Api.Request, id: Text, auth: AuthContext, files: Files, clock: Clock) : Result(
  Api.Response,
  AppError
)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may discard replay proposals"))
  end
  now = clock.now
  discarded = try Ledger.locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    now,
    Db.map_ledger_error,
    fn(db)
      (_next, prop) = try Replay.discard_proposal(db, id, auth.principal.id, now).map_error(
        Db.map_replay_error
      )
      Ok(prop)
    end
  )
  Ok(
    json_ok(
      200,
      Json.Object({"proposal_id": Json.String(discarded.id), "status": discarded.status.to_json})
    )
  )
end

## `POST /api/grants/delegate` — Attenuates caller's `Modb.Grants.Grant` monotonically into a child Agent token.
## Any attempt to widen actions, collections, call budget, or expiry fails closed with `422`.
fn delegate_grant(
  req: Api.Request,
  auth: AuthContext,
  input: DelegateGrantInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  del_act = if Policy.action_permitted?(auth, "delegate")
    "delegate"
  else
    "manage_grants"
  end
  if not Policy.action_permitted?(auth, del_act)
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit delegation"))
  end
  norm_handle = if input.handle.trim.starts_with?("@")
    input.handle.trim
  else
    "@#{input.handle.trim}"
  end
  if norm_handle.byte_count < 2 or input.label.trim.empty?
    return Error(BadInput(reason: "handle and label must not be empty"))
  end
  if input.allowed_actions.empty? or
    input.max_calls <= 0 or
    input.ttl_days < 1 or
    input.ttl_days > 365
    return Error(BadInput(reason: "invalid actions, max_calls, or ttl_days"))
  end

  now = clock.now
  child_agent_id = "agt_#{Id.ulid(rng, clock)}"
  child_grant_id = "gr_#{Id.ulid(rng, clock)}"
  token_id = "tok_#{Id.ulid(rng, clock)}"
  (raw_token, token_prefix, token_hash) = Policy.mint_agent_token_raw(rng)
  expires_at = now + input.ttl_days.days

  scopes_opt = input.allowed_collections.map(fn(cols)
    cols.map(fn(c)
      if c.starts_with?("collection:") or c == "workspace:*": c else: "collection:#{c}"
    end)
  end)

  spec = Grants.GrantSpec(
    id: child_grant_id,
    principal: child_agent_id,
    allowed_actions: input.allowed_actions,
    max_calls: input.max_calls,
    expires_at: expires_at
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "grant.delegate",
    reason: "delegate attenuated grant '#{child_grant_id}' from '#{auth.grant_id}'",
    at: now
  )
  audit_payload = Json.Object({
    "parent_grant_id": Json.String(auth.grant_id),
    "child_grant_id": Json.String(child_grant_id),
    "child_agent_id": Json.String(child_agent_id)
  })

  (child_principal, child_grant, tok) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "delegated grant #{child_grant_id} from #{auth.grant_id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, del_act, now)
      (t2, g) = try Grants.tx_delegate_scoped(t1, auth.grant_id, spec, scopes_opt, None, {}, now)
        .map_error(Db.map_grants_error)
      p = Principal(
        id: child_agent_id,
        kind: Agent,
        handle: norm_handle,
        display_name: input.display_name.trim,
        email: None,
        avatar_url: None,
        role: Bot,
        model_id: input.model_id,
        root_grant_id: child_grant_id,
        suspended: false,
        created_at: now,
        last_seen_at: None
      )
      t3 = try Table.put(t2, Db.principals_table(), p.id, p).map_error(Db.map_table_error)
      t_rec = AgentToken(
        id: token_id,
        principal_id: child_agent_id,
        grant_id: child_grant_id,
        label: input.label.trim,
        prefix: token_prefix,
        token_hash: token_hash,
        created_by: auth.principal.id,
        expires_at: Some(expires_at),
        revoked_at: None,
        last_used_at: None
      )
      t4 = try Table.put(t3, Db.agent_tokens_table(), t_rec.id, t_rec).map_error(Db.map_table_error)
      Ok((t4, (p, g, t_rec)))
    end
  )

  del_ev = Json.Object({
    "grant_id": Json.String(child_grant.id),
    "parent_grant_id": Json.String(auth.grant_id),
    "principal_handle": Json.String(child_principal.handle),
    "max_calls": Json.int(child_grant.max_calls),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      201,
      Json.Object({
        "raw_token": Json.String(raw_token),
        "principal": child_principal.to_json,
        "grant": child_grant.to_json,
        "token_id": Json.String(tok.id),
        "token_prefix": Json.String(tok.prefix)
      })
    ).with_sse_publish_json("grants", "grant.delegated", del_ev)
  )
end

## `GET /api/webhooks` — Lists webhook subscriptions (secrets redacted, Owner/Admin only, `ReadFiles`-only).
fn list_webhooks(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may inspect webhooks"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Ok(json_ok(200, Json.Object({"webhooks": Json.Array([])})))
  end
  items = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rows = try Table.scan(Ledger.store(db), Db.webhooks_table(), None, None, 200).map_error(
        Db.map_table_error
      )
      Ok(
        rows.map(fn(pair)
          w = pair.1
          Json.Object({
            "id": Json.String(w.id),
            "workspace_id": Json.String(w.workspace_id),
            "collection_id": w.collection_id.to_json,
            "url": Json.String(w.url),
            "events": w.events.to_json,
            "enabled": Json.Boolean(w.enabled),
            "created_at": w.created_at.to_json
          })
        end)
      )
    end
  )
  Ok(json_ok(200, Json.Object({"webhooks": Json.Array(items)})))
end

## `POST /api/webhooks` — Registers an outbound signed webhook subscription (`Arvo.Webhooks`).
fn create_webhook(
  req: Api.Request,
  auth: AuthContext,
  input: CreateWebhookInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may register webhooks"))
  end
  _url_ok = try Webhooks.validate_target_url(input.url).map_error(fn(e)
    BadInput(reason: e.to_text)
  end)
  if input.events.empty?
    return Error(BadInput(reason: "events must not be empty"))
  end

  now = clock.now
  case caller_taint_sid(req, auth)
    Some(sid):
      if files.read_only.exists?(Db.ledger_db_path)
        sess_opt = try Ledger.read_locked(
          files.read_only,
          Db.ledger_db_path,
          Db.vellum_schema(),
          Db.map_ledger_error,
          fn(db) TaintBridge.get_taint_session(Ledger.store(db), sid) end
        )
        case sess_opt
          Some(_):
            _auth_sess = try TaintBridge.authorize_write_locked(
              files,
              Db.ledger_db_path,
              Db.vellum_schema(),
              sid,
              "vlm_webhooks",
              "webhook.create",
              now
            )
          None: Unit
        end
      end
    None: Unit
  end
  wh_id = "wh_#{Id.ulid(rng, clock)}"
  secret = "whsec_#{rng.bytes(24).to_hex}"
  sub = WebhookSub(
    id: wh_id,
    workspace_id: Db.default_workspace_id,
    collection_id: input.collection_id,
    url: input.url.trim,
    secret: secret,
    events: input.events,
    enabled: true,
    created_by: auth.principal.id,
    created_at: now
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "webhook.create",
    reason: "register webhook '#{wh_id}' for #{sub.url}",
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "registered webhook #{wh_id}",
    Json.Object({"webhook_id": Json.String(wh_id), "url": Json.String(sub.url)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, Db.webhooks_table(), sub.id, sub).map_error(Db.map_table_error)
      Ok((t1, sub))
    end
  )
  Ok(
    json_ok(
      201,
      Json.Object({
        "id": Json.String(saved.id),
        "url": Json.String(saved.url),
        "events": saved.events.to_json,
        "collection_id": saved.collection_id.to_json,
        "secret": Json.String(saved.secret)
      })
    )
  )
end

## `GET /api/events` — Emits live grant-scoped `text/event-stream` SSE stream with `Last-Event-ID` catchup (`ReadFiles`-only).
fn events_stream(req: Api.Request, auth: AuthContext, rf: ReadFiles, clock: Clock) : Result(
  Api.Response,
  AppError
)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  last_id = Sse.last_event_id(req)
  grants_scope = req.query_param("scope") == Some("grants")
  if grants_scope
    role_ok = auth.principal.role == Owner or auth.principal.role == Admin
    if not role_ok
      return Error(Forbidden(reason: "only Owner/Admin may subscribe to live grants SSE stream"))
    end
  end
  page_scope = req.query_param("page_id").map(fn(s) s.trim end)
  db_scope = req.query_param("database_id").map(fn(s) s.trim end)
  col_scope = req.query_param("collection_id").map(fn(s) s.trim end)

  if not rf.exists?(Db.ledger_db_path)
    case page_scope
      Some(pid) if not pid.empty?: return Error(Missing(entity: "page", id: pid))
      Some(_) | None: Unit
    end
    case db_scope
      Some(did) if not did.empty?: return Error(Missing(entity: "database", id: did))
      Some(_) | None: Unit
    end
    case col_scope
      Some(cid) if not cid.empty?: return Error(Missing(entity: "collection", id: cid))
      Some(_) | None: Unit
    end
    empty_topics = if grants_scope: ["claims", "grants"] else: ["claims"]
    connected_ev = Sse.SseEvent(
      id: None,
      event: Some("connected"),
      data: Json.Object({
        "topics": empty_topics.to_json,
        "actor": Json.String(auth.principal.handle)
      }).to_text,
      retry_ms: Some(3000)
    )
    snap_ev = Sse.json_event(None, "claims.snapshot", Json.Object({"claims": Json.Array([])}))
    var empty_evs = [connected_ev, snap_ev]
    if grants_scope
      empty_evs = empty_evs.append(
        Sse.json_event(
          None,
          "grants.snapshot",
          Json.Object({
            "total_grants": Json.int(0),
            "active_grants": Json.int(0),
            "delegated_grants": Json.int(0),
            "revoked_grants": Json.int(0)
          })
        )
      )
    end
    return Ok(Sse.response(empty_evs).with_sse_subscribe(empty_topics, last_id))
  end

  cursor = case last_id
    Some(s): s.trim.to_int or 0
    None: 0
  end
  now = clock.now
  (topics, entries, active_claims, grants_snap_opt) = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var scoped_topics = ["claims"]
      var g_snap_opt = None
      if grants_scope
        scoped_topics = ["claims", "grants"]
        all_gs = try Grants.list_all(store).map_error(Db.map_grants_error)
        var g_act = 0
        var g_del = 0
        var g_rev = 0
        for gg in all_gs
          if gg.parent_id != None
            g_del += 1
          end
          if gg.revoked
            g_rev += 1
          else if now <= gg.expires_at
            g_act += 1
          end
        end
        g_snap_opt = Some(
          Json.Object({
            "total_grants": Json.int(all_gs.size),
            "active_grants": Json.int(g_act),
            "delegated_grants": Json.int(g_del),
            "revoked_grants": Json.int(g_rev)
          })
        )
      else
        case page_scope
          Some(pid) if not pid.empty?:
            pg = case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
              Some(p) if p.archived_at == None: p
              Some(_) | None: return Error(Missing(entity: "page", id: pid))
            end
            try Policy.require_collection_access(auth, "read", pg.collection_id)
            scoped_topics = scoped_topics.append("page:#{pg.id}")
          Some(_) | None:
            case db_scope
              Some(did) if not did.empty?:
                d = case try Table.get(store, Db.databases_table(), did).map_error(
                  Db.map_table_error
                )
                  Some(def): def
                  None: return Error(Missing(entity: "database", id: did))
                end
                try Policy.require_collection_access(auth, "read", d.collection_id)
                scoped_topics = scoped_topics.append("database:#{d.id}")
              Some(_) | None:
                case col_scope
                  Some(cid) if not cid.empty?:
                    try Policy.require_collection_access(auth, "read", cid)
                    scoped_topics = scoped_topics.append("collection:#{cid}")
                  Some(_) | None:
                    cols = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
                      Db.map_table_error
                    )
                    var added = 0
                    for (_k, c) in cols
                      if c.archived_at == None and Policy.collection_permitted?(auth, c.id) and added <
                        30
                        scoped_topics = scoped_topics.append("collection:#{c.id}")
                        added += 1
                      end
                    end
                end
            end
        end
      end
      audits = try Ledger.audit_tail_store(store, 50).map_error(Db.map_ledger_error)
      claims = try Claims.list_active(store, now).map_error(Db.map_claims_error)
      Ok((scoped_topics, audits, claims, g_snap_opt))
    end
  )

  var sse_events = [
    Sse.SseEvent(
      id: None,
      event: Some("connected"),
      data: Json.Object({"topics": topics.to_json, "actor": Json.String(auth.principal.handle)})
        .to_text,
      retry_ms: Some(3000)
    ),
    Sse.json_event(None, "claims.snapshot", Json.Object({"claims": active_claims.to_json}))
  ]
  case grants_snap_opt
    Some(gj): sse_events = sse_events.append(Sse.json_event(None, "grants.snapshot", gj))
    None: Unit
  end
  for e in entries
    if e.seq > cursor
      sse_events = sse_events.append(
        Sse.json_event(
          None,
          "audit.#{e.action}",
          Json.Object({
            "seq": Json.int(e.seq),
            "actor": Json.String(e.principal),
            "action": Json.String(e.action),
            "summary": Json.String(e.summary)
          })
        )
      )
    end
  end
  Ok(Sse.response(sse_events).with_sse_subscribe(topics, last_id))
end

## `GET /api/proposals/:id/comments` — Lists anchored review/steer comments for a proposal (`ReadFiles`-only).
fn list_proposal_comments(id: Text, auth: AuthContext, rf: ReadFiles) : Result(
  Api.Response,
  AppError
)
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end
  comments = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pm = case try Table.get(store, Db.proposals_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, "read", pm.collection_id)
      pairs = try Table.lookup(
        store,
        Db.proposal_comments_table(),
        Db.proposal_comments_by_proposal(),
        id
      ).map_error(Db.map_table_error)
      Ok(pairs.map(fn(p) p.1 end).sort_by(fn(c) c.id end))
    end
  )
  Ok(json_ok(200, Json.Object({"proposal_id": Json.String(id), "comments": comments.to_json})))
end

## `POST /api/proposals/:id/comments` — Creates an anchored Patchwork review or steer comment on a proposal.
fn create_proposal_comment(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: CreateProposalCommentInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  clean_body = input.body_markdown.trim
  if clean_body.empty?
    return Error(BadInput(reason: "comment body_markdown must not be empty"))
  end
  tk = (input.target_kind or "proposal").trim
  if tk != "proposal" and tk != "block" and tk != "db_row" and tk != "db_schema"
    return Error(BadInput(reason: "target_kind must be proposal, block, db_row, or db_schema"))
  end
  tref = case input.target_ref
    Some(r) if not r.trim.empty?: Some(r.trim)
    Some(_) | None: None
  end
  if (tk == "block" or tk == "db_row" or tk == "db_schema") and tref == None
    return Error(BadInput(reason: "target_ref is required when target_kind is '#{tk}'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end

  act = if Policy.action_permitted?(auth, "comment")
    "comment"
  else
    "propose"
  end
  now = clock.now
  cid = "pcmt_#{Id.ulid(rng, clock)}"
  akind = case auth.principal.kind
    Human: HumanAuthor
    Agent: AgentAuthor(model: auth.principal.model_id)
  end
  parent_opt = case input.parent_comment_id
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
  cmt = ProposalComment(
    id: cid,
    proposal_id: id,
    target_kind: tk,
    target_ref: tref,
    parent_comment_id: parent_opt,
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    author_kind: akind,
    body_markdown: clean_body,
    steer_requested: input.steer_requested or false,
    resolved_at: None,
    created_at: now
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "proposal.comment.create",
    reason: "comment on proposal '#{id}'",
    at: now
  )
  audit_payload = Json.Object({
    "comment_id": Json.String(cmt.id),
    "proposal_id": Json.String(id),
    "target_kind": Json.String(tk)
  })
  (saved_pm, saved_cmt) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "commented on proposal #{id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      pm = case try Table.tx_get(t1, Db.proposals_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, act, pm.collection_id)
      t2 = try Table.put(t1, Db.proposal_comments_table(), cmt.id, cmt).map_error(Db.map_table_error)
      Ok((t2, (pm, cmt)))
    end
  )
  ev = Json.Object({
    "proposal_id": Json.String(saved_pm.id),
    "comment_id": Json.String(saved_cmt.id),
    "page_id": Json.String(saved_pm.target_page_id),
    "actor": Json.String(auth.principal.handle)
  })
  var resp = json_ok(201, Json.Object({"comment": saved_cmt.to_json})).with_sse_publish_json(
    "collection:#{saved_pm.collection_id}",
    "proposal.commented",
    ev
  )
  if not saved_pm.target_page_id.trim.empty?
    resp = resp.with_sse_publish_json("page:#{saved_pm.target_page_id}", "proposal.commented", ev)
  end
  case saved_pm.target_database_id
    Some(did) if not did.trim.empty?:
      resp = resp.with_sse_publish_json("database:#{did}", "proposal.commented", ev)
    Some(_) | None: Unit
  end
  Ok(resp)
end

## `POST /api/proposals/:id/comments/:comment_id/resolve` — Marks a proposal comment thread resolved or reopened.
fn resolve_proposal_comment(
  req: Api.Request,
  id: Text,
  comment_id: Text,
  auth: AuthContext,
  input: ResolveProposalCommentInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end
  act = if Policy.action_permitted?(auth, "propose")
    "propose"
  else
    "comment"
  end
  now = clock.now
  resolve? = input.resolved or true
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "proposal.comment.resolve",
    reason: if resolve?: "resolve comment '#{comment_id}'" else: "reopen comment '#{comment_id}'",
    at: now
  )
  audit_payload = Json.Object({
    "comment_id": Json.String(comment_id),
    "proposal_id": Json.String(id),
    "resolved": Json.Boolean(resolve?)
  })
  (saved_pm, saved_cmt) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "updated comment resolution on #{comment_id}",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, act, now)
      pm = case try Table.tx_get(t1, Db.proposals_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      try Policy.require_collection_access(auth, act, pm.collection_id)
      old_c = case try Table.tx_get(t1, Db.proposal_comments_table(), comment_id).map_error(
        Db.map_table_error
      )
        Some(c) if c.proposal_id == id: c
        Some(_) | None: return Error(Missing(entity: "proposal_comment", id: comment_id))
      end
      next_c = ProposalComment(
        id: old_c.id,
        proposal_id: old_c.proposal_id,
        target_kind: old_c.target_kind,
        target_ref: old_c.target_ref,
        parent_comment_id: old_c.parent_comment_id,
        author_id: old_c.author_id,
        author_handle: old_c.author_handle,
        author_kind: old_c.author_kind,
        body_markdown: old_c.body_markdown,
        steer_requested: old_c.steer_requested,
        resolved_at: if resolve?: Some(now) else: None,
        created_at: old_c.created_at
      )
      t2 = try Table.put(t1, Db.proposal_comments_table(), next_c.id, next_c).map_error(
        Db.map_table_error
      )
      Ok((t2, (pm, next_c)))
    end
  )
  ev = Json.Object({
    "proposal_id": Json.String(saved_pm.id),
    "comment_id": Json.String(saved_cmt.id),
    "page_id": Json.String(saved_pm.target_page_id),
    "actor": Json.String(auth.principal.handle)
  })
  var resp = json_ok(200, Json.Object({"comment": saved_cmt.to_json})).with_sse_publish_json(
    "collection:#{saved_pm.collection_id}",
    "proposal.commented",
    ev
  )
  if not saved_pm.target_page_id.trim.empty?
    resp = resp.with_sse_publish_json("page:#{saved_pm.target_page_id}", "proposal.commented", ev)
  end
  case saved_pm.target_database_id
    Some(did) if not did.trim.empty?:
      resp = resp.with_sse_publish_json("database:#{did}", "proposal.commented", ev)
    Some(_) | None: Unit
  end
  Ok(resp)
end

## `POST /api/proposals/:id/hunks/reject` — Reverts a single block or DB row hunk inside an open `Modb.World` branch without closing the proposal.
fn reject_proposal_hunk(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  input: RejectProposalHunkInput,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  tk = input.target_kind.trim
  tid = input.target_id.trim
  if tid.empty?
    return Error(BadInput(reason: "target_id must not be empty"))
  end
  if tk != "block" and tk != "db_row"
    return Error(BadInput(reason: "target_kind must be 'block' or 'db_row'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end

  now = clock.now
  clean_reason = case input.reason
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: "Rejected hunk #{tk}:#{tid} in Patchwork Review"
  end
  prov = make_provenance(auth, Some(clean_reason), now)

  (pm, comp_mut, sse_page_opt, sse_db_opt) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      found = case try Table.get(store, Db.proposals_table(), id).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      if found.status != "open"
        return Error(Conflict(reason: "proposal '#{id}' is '#{found.status}', not 'open'"))
      end
      try Policy.require_collection_access(auth, "propose", found.collection_id)
      world = case try World.get_world(store, found.world_id).map_error(Db.map_world_error)
        Some(w): w
        None: return Error(Missing(entity: "world", id: found.world_id))
      end
      (base_tx, spec_tx) = try Db.materialize_world_tx(store, world)

      if tk == "block"
        pid = case input.page_id
          Some(p) if not p.trim.empty?: p.trim
          Some(_) | None: found.target_page_id
        end
        base_blk = try Table.tx_get(base_tx, Db.blocks_table(), tid).map_error(Db.map_table_error)
        spec_blk = try Table.tx_get(spec_tx, Db.blocks_table(), tid).map_error(Db.map_table_error)
        (ops, new_ids) = case (base_blk, spec_blk)
          (Some(bb), Some(sb)): (
            [
              ReplaceBlock(
                block_id: sb.id,
                expected_version: sb.version,
                kind: Some(bb.kind),
                markdown: bb.markdown
              )
            ],
            []
          )
          (None, Some(sb)): ([DeleteBlock(block_id: sb.id, expected_version: sb.version)], [])
          (Some(bb), None):
            b_rows = try Table.tx_lookup(base_tx, Db.blocks_table(), Db.blocks_by_page(), pid)
              .map_error(Db.map_table_error)
            s_rows = try Table.tx_lookup(spec_tx, Db.blocks_table(), Db.blocks_by_page(), pid)
              .map_error(Db.map_table_error)
            var spec_ids = {}
            for sx in s_rows
              spec_ids = spec_ids.set(sx.1.id, true)
            end
            var prev_surviving_id = ""
            for bx in Blocks.sort_blocks(b_rows.map(fn(p) p.1 end))
              break if bx.id == bb.id
              if spec_ids.get(bx.id) == Some(true)
                prev_surviving_id = bx.id
              end
            end
            prev_surviving = if prev_surviving_id.empty?
              None
            else
              Some(prev_surviving_id)
            end
            (
              [
                InsertBlockAfter(
                  after_block_id: prev_surviving,
                  parent_block_id: bb.parent_block_id,
                  kind: bb.kind,
                  markdown: bb.markdown
                )
              ],
              [bb.id]
            )
          (None, None): return Error(Missing(entity: "block", id: tid))
        end
        cmut = PatchPageBlocks(
          page_id: pid,
          ops: ops,
          new_ids: new_ids,
          provenance: prov,
          expected_versions: {}
        )
        Ok((found, cmut, Some(pid), found.target_database_id))
      else
        did = case input.database_id
          Some(d) if not d.trim.empty?: d.trim
          Some(_) | None:
            case found.target_database_id
              Some(d) if not d.trim.empty?: d.trim
              Some(_) | None: return Error(BadInput(reason: "database_id required for db_row hunk"))
            end
        end
        base_row = try Table.tx_get(base_tx, Db.db_rows_table(), tid).map_error(Db.map_table_error)
        spec_row = try Table.tx_get(spec_tx, Db.db_rows_table(), tid).map_error(Db.map_table_error)
        cmut = case (base_row, spec_row)
          (Some(br), Some(sr)):
            var reset_cells = br.cells
            for (k, _v) in sr.cells.entries
              if br.cells.get(k) == None
                reset_cells = reset_cells.set(k, Empty)
              end
            end
            UpdateDbRow(
              database_id: did,
              row_id: sr.id,
              cells: reset_cells,
              expected_version: Some(sr.version),
              provenance: prov
            )
          (None, Some(sr)): DeleteDbRow(database_id: did, row_id: sr.id)
          (Some(_), None) | (None, None): return Error(
            BadInput(reason: "cannot reject deleted database row hunk individually")
          )
        end
        Ok((found, cmut, None, Some(did)))
      end
    end
  )

  bargs = WorldBranchArgs(mutation: comp_mut, updated_at: now)
  step_reply = try World.world_call_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    pm.world_id,
    "propose",
    bargs.to_json,
    clean_reason,
    now
  ).map_error(Db.map_world_error)

  upd_ev = Json.Object({
    "proposal_id": Json.String(pm.id),
    "kind": Json.String("reject_hunk"),
    "target_kind": Json.String(tk),
    "target_id": Json.String(tid),
    "actor": Json.String(auth.principal.handle)
  })
  var resp = json_ok(200, Json.Object({"proposal": pm.to_json, "step_reply": step_reply}))
    .with_sse_publish_json("collection:#{pm.collection_id}", "proposal.updated", upd_ev)
  case sse_page_opt
    Some(pid) if not pid.trim.empty?:
      resp = resp.with_sse_publish_json("page:#{pid}", "proposal.updated", upd_ev)
    Some(_) | None: Unit
  end
  case sse_db_opt
    Some(did) if not did.trim.empty?:
      resp = resp.with_sse_publish_json("database:#{did}", "proposal.updated", upd_ev)
    Some(_) | None: Unit
  end
  Ok(resp)
end

fn ensure_github_bridge_auth_locked(
  files: Files,
  allowed_cols_opt: Option(List(Text)),
  now: Time
) : Result(AuthContext, AppError)
  pid = "agt_github_bridge"
  gid = "gr_github_bridge"
  handle = "@github-pr-bridge"
  scopes_opt = allowed_cols_opt.map(fn(cols)
    cols.map(fn(c) if c.starts_with?("collection:"): c else: "collection:#{c}" end)
  end)

  if files.read_only.exists?(Db.ledger_db_path)
    existing_opt = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        p_opt = try Table.get(store, Db.principals_table(), pid).map_error(Db.map_table_error)
        g_opt = try Grants.get(store, gid).map_error(Db.map_grants_error)
        Ok((p_opt, g_opt))
      end
    )
    case existing_opt
      (Some(prn), Some(gr)):
        if gr.revoked or now > gr.expires_at
          return Error(Forbidden(reason: "GitHub PR bridge grant '#{gid}' is revoked or expired"))
        end
        return Ok(
          AuthContext(
            principal: prn,
            grant_id: gr.id,
            session: None,
            allowed_collections: scopes_opt,
            allowed_actions: ["read", "propose"]
          )
        )
      (_, _): Unit
    end
  end

  meta = Ledger.WriteMeta(
    principal: handle,
    action: "github_bridge.init",
    reason: "initialize proposals-only @github-pr-bridge principal",
    at: now
  )
  (prn, gr) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "initialized proposals-only @github-pr-bridge",
    Json.Object({"principal": Json.String(pid), "grant_id": Json.String(gid)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = case try Grants.tx_get(tx, gid).map_error(Db.map_grants_error)
        Some(_): tx
        None:
          spec = Grants.GrantSpec(
            id: gid,
            principal: pid,
            allowed_actions: ["read", "propose"],
            max_calls: 100000,
            expires_at: now + 3650.days
          )
          (tg, _g) = try Grants.tx_issue_root_scoped(
            tx,
            "system:github-bridge",
            spec,
            scopes_opt,
            None,
            now
          ).map_error(Db.map_grants_error)
          tg
      end
      principal = case try Table.tx_get(t1, Db.principals_table(), pid).map_error(
        Db.map_table_error
      )
        Some(existing_p): existing_p
        None: Principal(
          id: pid,
          kind: Agent,
          handle: handle,
          display_name: "GitHub PR Bridge",
          email: None,
          avatar_url: None,
          role: Bot,
          model_id: None,
          root_grant_id: gid,
          suspended: false,
          created_at: now,
          last_seen_at: None
        )
      end
      t2 = try Table.put(t1, Db.principals_table(), principal.id, principal).map_error(
        Db.map_table_error
      )
      grant = try (try Grants.tx_get(t2, gid).map_error(Db.map_grants_error)).or_fail(
        ServerFailed(reason: "failed loading github bridge grant")
      )
      Ok((t2, (principal, grant)))
    end
  )
  Ok(
    AuthContext(
      principal: prn,
      grant_id: gr.id,
      session: None,
      allowed_collections: scopes_opt,
      allowed_actions: ["read", "propose"]
    )
  )
end

fn draft_github_pr_callout(
  ev: Garden.GithubPrEvent,
  pg_title: Text,
  pg_excerpt: Text,
  env: Env,
  net: Network
) : Text
  files_line = if ev.changed_files.empty?
    ""
  else
    "\nChanged files: `#{ev.changed_files.take(6).join("`, `")}`"
  end
  fallback = "PR ##{ev.pr_number} (#{ev.repo_full_name}): #{ev.title}\nCommit: `#{ev.head_sha}`#{files_line}"
  case Ai.ai_config(env)
    Error(_): fallback
    Ok(cfg):
      sys = "You are Vellum GitHub PR Bridge. Draft a 1-2 sentence runbook update callout from this GitHub PR for a Modb.World Change Proposal. Return Markdown plain text only."
      usr = "Repo: #{ev.repo_full_name}\nPR ##{ev.pr_number}: #{ev.title}\nBody: #{ev.body}\nFiles: #{ev
        .changed_files
        .join(", ")}\nTarget Page: #{pg_title}\nExcerpt:\n#{pg_excerpt}"
      case Http.send(Ai.build_llm_request(cfg, sys, usr), net)
        Error(_): fallback
        Ok(res) if res.status >= 200 and res.status < 300:
          case Ai.extract_llm_text(cfg, res.body)
            Ok(txt) if not txt.trim.empty?: txt.trim
            Ok(_) | Error(_): fallback
          end
        Ok(_): fallback
      end
  end
end

fn stage_pr_proposal_for_page_locked(
  bridge_auth: AuthContext,
  ev: Garden.GithubPrEvent,
  pg: Page,
  blks: List(Block),
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(ProposalMeta, AppError)
  now = clock.now
  note_md = draft_github_pr_callout(ev, pg.title, Blocks.blocks_plain_text(blks.take(4)), env, net)
  prop_id = "prop_#{Id.ulid(rng, clock)}"
  world_id = "w_#{Id.ulid(rng, clock)}"
  _wrec = try World.open_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    world_id,
    bridge_auth.grant_id,
    now,
    now + 7.days
  ).map_error(Db.map_world_error)

  pr_cit = Citation(
    source_kind: "github_pr",
    source_ref: ev.html_url,
    label: "#{ev.repo_full_name}##{ev.pr_number}",
    excerpt: Some(ev.title)
  )
  prop_reason = "GitHub PR ##{ev.pr_number} (#{ev.repo_full_name}): #{ev.title}"
  prov = Provenance(
    author_id: bridge_auth.principal.id,
    author_kind: AgentAuthor(model: Some("github-pr-bridge")),
    grant_id: Some(bridge_auth.grant_id),
    proposal_id: Some(prop_id),
    reason: Some(prop_reason),
    citations: [pr_cit],
    updated_at: now
  )
  new_bid = "blk_#{Id.ulid(rng, clock)}"
  callout_kind = Callout(tone: "NOTE", icon: Some("git-pull-request"))
  wargs = WorldPatchArgs(
    page_id: pg.id,
    ops: [
      InsertBlockAfter(
        after_block_id: blks.last.map(fn(b) b.id end),
        parent_block_id: None,
        kind: callout_kind,
        markdown: note_md
      )
    ],
    new_ids: [new_bid],
    provenance: prov,
    expected_versions: {},
    updated_at: now
  )
  _step = try World.world_call_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    world_id,
    "propose",
    wargs.to_json,
    prop_reason,
    now
  ).map_error(Db.map_world_error)

  pm = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: pg.collection_id,
    target_page_id: pg.id,
    target_database_id: None,
    branch_kind: "proposal",
    title: "PR ##{ev.pr_number}: Sync #{pg.title}",
    reason: prop_reason,
    author_id: bridge_auth.principal.id,
    author_handle: bridge_auth.principal.handle,
    grant_id: bridge_auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  wmeta = Ledger.WriteMeta(
    principal: bridge_auth.principal.handle,
    action: "webhook.github_pr_proposal",
    reason: prop_reason,
    at: now
  )
  Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "opened PR ##{ev.pr_number} proposal #{pm.id}",
    Json.Object({
      "proposal_id": Json.String(pm.id),
      "page_id": Json.String(pg.id),
      "pr_number": Json.int(ev.pr_number)
    }),
    Db.map_ledger_error,
    fn(tx)
      (t1, _g) = try Grants.tx_authorize(tx, bridge_auth.grant_id, "propose", now).map_error(
        Db.map_grants_error
      )
      t2 = try Table.put(t1, Db.proposals_table(), pm.id, pm).map_error(Db.map_table_error)
      t3 = try TaintBridge.tx_mark_provenance(
        t2,
        "vlm_proposals",
        pm.id,
        "webhook:github:#{ev.repo_full_name}##{ev.pr_number}",
        "untrusted",
        now
      )
      Ok((t3, pm))
    end
  )
end

## `POST /api/webhooks/github` — Signed inbound GitHub `pull_request` webhook bridge that matches
## affected docs via `Db.search_pages_hybrid` and opens `Modb.World` Change Proposals (never writes live).
fn github_pr_webhook(
  req: Api.Request,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  secret = case env.get("VELLUM_GITHUB_WEBHOOK_SECRET")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Error(
      Forbidden(reason: "GitHub webhook bridge disabled: missing VELLUM_GITHUB_WEBHOOK_SECRET")
    )
  end
  if not Garden.verify_github_signature(secret, req.body, req.header("X-Hub-Signature-256"))
    return Error(Forbidden(reason: "invalid GitHub webhook X-Hub-Signature-256"))
  end

  gh_event = (req.header("X-GitHub-Event") or "pull_request").trim.ascii_lowercase
  if gh_event == "ping"
    return Ok(json_ok(200, Json.Object({"ok": Json.Boolean(true), "event": Json.String("ping")})))
  end
  if gh_event != "pull_request"
    return Ok(
      json_ok(200, Json.Object({"ignored": Json.Boolean(true), "event": Json.String(gh_event)}))
    )
  end

  ev = try Garden.parse_github_pr_webhook(req.body).map_error(fn(e) BadInput(reason: e) end)
  relevant? = ev.action == "opened" or ev.action == "synchronize" or ev.action == "reopened" or
    (ev.action == "closed" and ev.merged)
  if not relevant?
    return Ok(
      json_ok(200, Json.Object({"ignored": Json.Boolean(true), "action": Json.String(ev.action)}))
    )
  end

  now = clock.now
  allowed_cols_opt = case env.get("VELLUM_GITHUB_WEBHOOK_COLLECTIONS")
    Some(raw) if not raw.trim.empty?:
      Some(raw.split(",").map(fn(s) s.trim end).filter(fn(s) not s.empty? end))
    Some(_) | None: None
  end
  bridge_auth = try ensure_github_bridge_auth_locked(files, allowed_cols_opt, now)
  search_q = Garden.build_pr_search_query(ev)

  matches = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      qvec = Some(Vec.text_sketch_embedding(search_q, Db.sketch_vec_dims))
      hits = try Db.search_pages_hybrid(
        store,
        bridge_auth,
        search_q,
        qvec,
        Db.sketch_vec_index(),
        "hybrid",
        3,
        true,
        None,
        Some(Db.sketch_min_vec_score)
      )
      var out = []
      for h in hits
        case try Table.get(store, Db.pages_table(), h.page_id).map_error(Db.map_table_error)
          Some(pg) if pg.archived_at == None and pg.kind == Document:
            blks = try Db.load_page_blocks(store, pg.id)
            out = out.append((pg, blks))
          Some(_) | None: Unit
        end
      end
      Ok(out)
    end
  )

  var staged_props = []
  var sse_cols = []
  for (pg, blks) in matches
    saved_pm = try stage_pr_proposal_for_page_locked(
      bridge_auth,
      ev,
      pg,
      blks,
      files,
      rng,
      clock,
      env,
      net
    )
    staged_props = staged_props.append(saved_pm)
    sse_cols = sse_cols.append((saved_pm.collection_id, saved_pm.target_page_id, saved_pm))
  end

  status = if staged_props.empty?: 200 else: 201
  var resp = json_ok(
    status,
    Json.Object({
      "event": Json.String("pull_request"),
      "action": Json.String(ev.action),
      "pr_number": Json.int(ev.pr_number),
      "repo": Json.String(ev.repo_full_name),
      "matched_pages": Json.int(matches.size),
      "proposals": staged_props.to_json
    })
  )
  for (cid, pid, spm) in sse_cols
    pev = Json.Object({
      "proposal_id": Json.String(spm.id),
      "page_id": Json.String(pid),
      "collection_id": Json.String(cid),
      "title": Json.String(spm.title),
      "actor": Json.String(bridge_auth.principal.handle)
    })
    resp = resp.with_sse_publish_json("page:#{pid}", "proposal.opened", pev)
      .with_sse_publish_json("collection:#{cid}", "proposal.opened", pev)
  end
  Ok(resp)
end

## `GET /api/admin/taint/status` — Lists active/cleared `Modb.Taint` sessions, Lethal Trifecta policy,
## and untrusted provenance markers across pages, blocks, and proposals.
fn taint_status(auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok
    return Error(Forbidden(reason: "only Owner/Admin may inspect Modb.Taint status"))
  end
  policy_json = TaintBridge.policy_summary_json()
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "policy": policy_json,
          "sessions": Json.Array([]),
          "untrusted": Json.Object({
            "pages": Json.Array([]),
            "blocks": Json.Array([]),
            "proposals": Json.Array([])
          })
        })
      )
    )
  end
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      sessions = try TaintBridge.list_sessions_json(store)
      pages = try TaintBridge.list_untrusted_provenance_json(store, "vlm_pages")
      blocks = try TaintBridge.list_untrusted_provenance_json(store, "vlm_blocks")
      proposals = try TaintBridge.list_untrusted_provenance_json(store, "vlm_proposals")
      Ok(
        Json.Object({
          "policy": policy_json,
          "sessions": Json.Array(sessions),
          "untrusted": Json.Object({
            "pages": Json.Array(pages),
            "blocks": Json.Array(blocks),
            "proposals": Json.Array(proposals)
          })
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/admin/taint/sessions/:id/clear` — Admin review action clearing dynamic taint on a session.
fn clear_taint_session(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  role_ok = auth.principal.role == Owner or auth.principal.role == Admin
  if not role_ok or not Policy.action_permitted?(auth, "manage_grants")
    return Error(Forbidden(reason: "only Owner/Admin may clear session taint"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "taint_session", id: id))
  end
  reason = if req.body.empty?
    "admin verified and cleared session taint"
  else
    case Json.parse(req.text or "")
      Ok(j): (j.text_at("reason") or "").trim
      Error(_): ""
    end
  end
  clean_reason = if reason.empty?
    "admin verified and cleared session taint"
  else
    reason
  end
  cleared = try TaintBridge.clear_session_taint_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    id,
    auth.principal.handle,
    true,
    clean_reason,
    clock.now
  )
  Ok(json_ok(200, Json.Object({"session": TaintBridge.taint_session_to_json(cleared)})))
end
