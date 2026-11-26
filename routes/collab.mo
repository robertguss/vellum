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
SimulateReplayInput(..),
DelegateGrantInput(..),
CreateWebhookInput(..),
list_claims,
acquire_claim,
heartbeat_claim,
release_claim,
list_proposals,
open_proposal,
stage_proposal_ops,
diff_proposal,
accept_proposal,
reject_proposal,
pin_replay_baseline,
simulate_replay,
accept_replay,
discard_replay,
delegate_grant,
list_webhooks,
create_webhook,
events_stream
use Api
use Arvo.Id
use Arvo.Modb.Jobs
use Arvo.Sse
use Arvo.Webhooks
use Db
use Domain.Collab{ProposalMeta, WebhookJobPayload, WebhookSub, WorldPatchArgs}
use Domain.Policy
use Domain.Types{
  AgentToken,
  AppError,
  AuthContext,
  AuthorKind,
  BlockOp,
  CollectionWritePolicy,
  Principal,
  PrincipalKind,
  Provenance,
  WorkspaceRole
}
use Json
use Modb{Store, WriteTx}
use Modb.Claims
use Modb.Grants
use Modb.Ledger
use Modb.Replay
use Modb.Table
use Modb.World
use Routes.Auth

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

fn prepare_webhook_jobs(
  subs: List(WebhookSub),
  event: Text,
  body_json: Json,
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
      body_json: body_json
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

## `GET /api/proposals/:id/diff` — Inspects structural CoW diffs inside a proposal's `Modb.World` (`ReadFiles`-only).
fn diff_proposal(id: Text, auth: AuthContext, rf: ReadFiles) : Result(Api.Response, AppError)
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end
  pm = try Ledger.read_locked(
    rf,
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
      try Policy.require_collection_access(auth, "read", found.collection_id)
      Ok(found)
    end
  )
  diffs = try World.world_diff_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    pm.world_id
  ).map_error(Db.map_world_error)
  Ok(json_ok(200, Json.Object({"proposal": pm.to_json, "bucket_diffs": diffs.to_json})))
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

  (pm, col, matching_subs) = try Ledger.read_locked(
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
      subs = try matching_webhooks_in_store(store, "proposal.accepted", Some(found.collection_id))
      Ok((found, c, subs))
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
  ).map_error(Db.map_world_error)

  accepted = ProposalMeta(
    id: pm.id,
    world_id: pm.world_id,
    collection_id: pm.collection_id,
    target_page_id: pm.target_page_id,
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
  hook_jobs = prepare_webhook_jobs(
    matching_subs,
    "proposal.accepted",
    Json.Object({
      "event": Json.String("proposal.accepted"),
      "proposal": accepted.to_json,
      "commit_txid": Json.int(land_res.commit_txid)
    }),
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
  Ok(
    json_ok(200, Json.Object({"proposal": saved.to_json, "land_result": land_res.to_json}))
      .with_sse_publish_json("collection:#{saved.collection_id}", "proposal.accepted", prop_payload)
      .with_sse_publish_json("page:#{saved.target_page_id}", "proposal.accepted", prop_payload)
  )
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
  _dropped = try World.drop_world_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    pm.world_id,
    now
  ).map_error(Db.map_world_error)

  rejected = ProposalMeta(
    id: pm.id,
    world_id: pm.world_id,
    collection_id: pm.collection_id,
    target_page_id: pm.target_page_id,
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
  Ok(
    json_ok(200, saved.to_json).with_sse_publish_json(
      "collection:#{saved.collection_id}",
      "proposal.rejected",
      prop_payload
    ).with_sse_publish_json("page:#{saved.target_page_id}", "proposal.rejected", prop_payload)
  )
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
        "summary": prop.summary.to_json,
        "bucket_diffs": prop.bucket_diffs.to_json,
        "status": prop.status.to_json
      })
    )
  )
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
    )
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
    empty_topics = ["claims"]
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
    return Ok(Sse.response([connected_ev, snap_ev]).with_sse_subscribe(empty_topics, last_id))
  end

  cursor = case last_id
    Some(s): s.trim.to_int or 0
    None: 0
  end
  now = clock.now
  (topics, entries, active_claims) = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var scoped_topics = ["claims"]
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
                    if c.archived_at == None and Policy.collection_permitted?(auth, c.id) and added < 30
                      scoped_topics = scoped_topics.append("collection:#{c.id}")
                      added += 1
                    end
                  end
              end
          end
      end
      audits = try Ledger.audit_tail_store(store, 50).map_error(Db.map_ledger_error)
      claims = try Claims.list_active(store, now).map_error(Db.map_claims_error)
      Ok((scoped_topics, audits, claims))
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
