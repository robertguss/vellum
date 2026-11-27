## Isolated bridge wrapping `Modb.Policy`, `Modb.Taint`, and `Modb.Views` so callers importing
## `Domain.Policy` never collide with `Modb.Policy` (`E0038` leaf name clash).
module Domain.TaintBridge
expose default_sensitivity_policy,
default_taint_policy,
sensitivity_label,
map_views_error,
map_taint_error,
ensure_taint_session_locked,
run_tainted_read_program_locked,
fork_taint_session_locked,
run_tainted_hybrid_search_locked,
record_untrusted_read_locked,
mark_block_untrusted_locked,
get_taint_session,
tx_mark_provenance,
get_provenance_info,
list_untrusted_provenance_json,
taint_session_to_json,
list_sessions_json,
policy_summary_json,
authorize_action_locked,
authorize_write_locked,
clear_session_taint_locked
use Domain.Types{AppError}
use Json
use Modb{Store, WriteTx}
use Modb.Fts
use Modb.Ledger{Schema}
use Modb.Policy
use Modb.Table
use Modb.Taint
use Modb.Vec
use Modb.Views

fn fork_taint_session_locked(
  files: Files,
  path: Text,
  sc: Schema,
  parent_session_id: Text,
  child_session_id: Text,
  child_principal: Text,
  child_grant_opt: Option(Text),
  now: Time
) : Result(Taint.TaintSession, AppError)
  Taint.fork_session_locked(
    files,
    path,
    sc,
    parent_session_id,
    child_session_id,
    child_principal,
    child_grant_opt,
    now
  ).map_error(map_taint_error)
end

fn run_tainted_hybrid_search_locked(
  files: Files,
  path: Text,
  sc: Schema,
  session_id: Text,
  fts_idx: Fts.FtsIndex,
  vec_idx: Vec.VecIndex,
  query_text: Text,
  query_vec: Option(List(Float)),
  opts: Vec.HybridOptions,
  is_admin: Bool,
  now: Time
) : Result((List(Vec.HybridHit), Taint.TaintSession), AppError)
  Taint.hybrid_search_tainted_locked(
    files,
    path,
    sc,
    default_sensitivity_policy(),
    default_taint_policy(),
    session_id,
    fts_idx,
    vec_idx,
    query_text,
    query_vec,
    opts,
    is_admin,
    now
  ).map_error(map_taint_error)
end

fn record_untrusted_read_locked(
  files: Files,
  path: Text,
  sc: Schema,
  session_id: Text,
  source_label: Text,
  now: Time
) : Result(Taint.TaintSession, AppError)
  Taint.record_untrusted_read_locked(files, path, sc, session_id, source_label, now).map_error(
    map_taint_error
  )
end

fn get_taint_session(store: Store, session_id: Text) : Result(Option(Taint.TaintSession), AppError)
  Taint.get_session(store, session_id).map_error(map_taint_error)
end

fn mark_block_untrusted_locked(
  files: Files,
  path: Text,
  sc: Schema,
  block_id: Text,
  writer: Text,
  now: Time
) : Result(Unit, AppError)
  Ledger.locked(
    files,
    path,
    sc,
    now,
    fn(e) map_taint_error(Taint.LedgerFailure(e)) end,
    fn(db)
      meta = Ledger.WriteMeta(
        principal: writer,
        action: "taint.mark_untrusted",
        reason: "mark block #{block_id} untrusted provenance",
        at: now
      )
      _next = try Ledger.write(
        db,
        meta,
        "mark untrusted provenance on #{block_id}",
        Json.Null,
        fn(tx)
          Taint.tx_mark_provenance(
            tx,
            "vlm_blocks",
            block_id.bytes,
            writer,
            Taint.Untrusted,
            now
          ).map_error(fn(e) Table.DecodeKey(reason: Taint.to_text(e)) end)
        end
      ).map_error(fn(e) map_taint_error(Taint.LedgerFailure(e)) end)
      Ok(Unit)
    end
  )
end

## Default `Modb.Policy.SensitivityPolicy` (`Public` clearance baseline for Tier 1 RLM reads;
## Phase 4.1 layers workspace/collection sensitivity rules onto this policy).
fn default_sensitivity_policy() : Policy.SensitivityPolicy
  Policy.policy()
end

## Default `Modb.Taint.TaintPolicy` (monotonic untrusted read tracking + `block_write_down?: true`
## + Lethal Trifecta external actions and webhook exfiltration sink).
fn default_taint_policy() : Taint.TaintPolicy
  Taint.taint_policy()
    .with_external_action("webhook.create")
    .with_external_action("webhook.deliver")
    .with_external_action("mcp.patch_blocks")
    .with_external_action("mcp.db_create_row")
    .with_external_action("mcp.db_update_row")
    .with_external_action("page.write_direct")
    .with_exfil_sink("vlm_webhooks")
    .with_block_write_down(true)
end

fn trust_from_tag(tag: Text) : Taint.TrustTier
  clean = tag.trim.ascii_lowercase
  if clean == "untrusted"
    Taint.Untrusted
  else if clean == "internal_agent" or clean == "agent"
    Taint.InternalAgent
  else
    Taint.Owner
  end
end

fn tx_mark_provenance(
  tx: WriteTx,
  bucket: Text,
  key_id: Text,
  writer: Text,
  trust_tag: Text,
  now: Time
) : Result(WriteTx, AppError)
  Taint.tx_mark_provenance(tx, bucket, key_id.bytes, writer, trust_from_tag(trust_tag), now)
    .map_error(map_taint_error)
end

fn get_provenance_info(store: Store, bucket: Text, key_id: Text) : Result(
  Option((Text, Text, Time)),
  AppError
)
  rec_opt = try Taint.get_provenance(store, bucket, key_id.bytes).map_error(map_taint_error)
  Ok(rec_opt.map(fn(r) (Taint.trust_to_text(r.trust), r.writer, r.updated_at) end))
end

fn list_untrusted_provenance_json(store: Store, bucket: Text) : Result(List(Json), AppError)
  recs = try Taint.list_provenance_for_bucket(store, bucket).map_error(map_taint_error)
  Ok(
    recs.filter(fn(r) r.trust is Taint.Untrusted end).map(fn(r)
      Json.Object({
        "bucket": Json.String(r.bucket),
        "key_hex": Json.String(r.key_hex),
        "writer": Json.String(r.writer),
        "trust": Json.String(Taint.trust_to_text(r.trust)),
        "recorded_txid": Json.int(r.recorded_txid),
        "updated_at": r.updated_at.to_json
      })
    end)
  )
end

fn taint_session_to_json(s: Taint.TaintSession) : Json
  Json.Object({
    "id": Json.String(s.id),
    "principal": Json.String(s.principal),
    "grant_id": s.grant_id.to_json,
    "parent_session_id": s.parent_session_id.to_json,
    "untrusted_tainted": Json.Boolean(s.untrusted_tainted),
    "untrusted_sources": s.untrusted_sources.to_json,
    "max_sensitivity_read": Json.String(sensitivity_label(s.max_sensitivity_read)),
    "sensitive_sources": s.sensitive_sources.to_json,
    "blocked_attempts": Json.int(s.blocked_attempts),
    "opened_at": s.opened_at.to_json,
    "updated_at": s.updated_at.to_json,
    "cleared_at": s.cleared_at.to_json,
    "cleared_by": s.cleared_by.to_json,
    "closed": Json.Boolean(s.closed)
  })
end

fn list_sessions_json(store: Store) : Result(List(Json), AppError)
  rows = try Taint.list_sessions(store).map_error(map_taint_error)
  sorted = rows.sort_by(fn(s) s.id end)
  Ok(sorted.map(fn(s) taint_session_to_json(s) end))
end

fn policy_summary_json() : Json
  p = default_taint_policy()
  Json.Object({
    "peer_agents_taint": Json.Boolean(p.peer_agents_taint?),
    "max_sensitivity_when_tainted": Json.String(sensitivity_label(p.max_sensitivity_when_tainted)),
    "exfil_sinks": p.exfil_sinks.to_list.to_json,
    "external_actions": p.external_actions.to_list.to_json,
    "block_write_down": Json.Boolean(p.block_write_down?),
    "strict_no_write_down": Json.Boolean(p.strict_no_write_down?)
  })
end

fn authorize_action_locked(
  files: Files,
  path: Text,
  sc: Schema,
  session_id: Text,
  action_name: Text,
  now: Time
) : Result(Taint.TaintSession, AppError)
  Taint.authorize_action_locked(
    files,
    path,
    sc,
    default_sensitivity_policy(),
    default_taint_policy(),
    session_id,
    action_name,
    now
  ).map_error(map_taint_error)
end

fn authorize_write_locked(
  files: Files,
  path: Text,
  sc: Schema,
  session_id: Text,
  target_bucket: Text,
  action_name: Text,
  now: Time
) : Result(Taint.TaintSession, AppError)
  Taint.authorize_write_locked(
    files,
    path,
    sc,
    default_sensitivity_policy(),
    default_taint_policy(),
    session_id,
    target_bucket,
    action_name,
    now
  ).map_error(map_taint_error)
end

fn clear_session_taint_locked(
  files: Files,
  path: Text,
  sc: Schema,
  session_id: Text,
  reviewer: Text,
  is_admin: Bool,
  reason: Text,
  now: Time
) : Result(Taint.TaintSession, AppError)
  Taint.clear_session_taint_locked(
    files,
    path,
    sc,
    session_id,
    reviewer,
    is_admin,
    reason,
    now
  ).map_error(map_taint_error)
end

## Formats a `Modb.Policy.Sensitivity` value as canonical lowercase text.
fn sensitivity_label(s: Policy.Sensitivity) : Text
  Policy.sensitivity_to_text(s)
end

## Maps a `Modb.Views.ViewsError` to Vellum's typed `AppError` (fail-closed HTTP status codes).
fn map_views_error(err: Views.ViewsError) : AppError
  case err
    Views.GrantFailure(g): Forbidden(reason: g.to_text)
    Views.UnknownView(name: _) | Views.UnknownRelease(name: _): Missing(
      entity: "view",
      id: Views.to_text(err)
    )
    Views.FieldNotInView(view: _, field: _, allowed: _) | Views.InvalidProgram(reason: _) | Views
      .WorkBudgetExceeded(metric: _, limit: _): BadInput(reason: Views.to_text(err))
    Views.ReleaseThresholdBlocked(release: _, min_group_size: _, actual_count: _): Forbidden(
      reason: Views.to_text(err)
    )
    Views.LedgerFailure(_) | Views.ViewLoadFailed(view: _, detail: _) | Views.ReleaseFailed(
      release: _,
      detail: _
    ): ServerFailed(reason: Views.to_text(err))
  end
end

## Maps a `Modb.Taint.TaintError` (and inner `PolicyError`/`ViewsError`/`GrantError`) to `AppError`.
fn map_taint_error(err: Taint.TaintError) : AppError
  case err
    Taint.ViewsFailure(ve): map_views_error(ve)
    Taint.GrantFailure(ge): Forbidden(reason: ge.to_text)
    Taint.PolicyFailure(pe):
      case pe
        Policy.ViewsFailure(ve): map_views_error(ve)
        Policy.GrantFailure(ge): Forbidden(reason: ge.to_text)
        Policy.ClearanceDenied(subject: _, required: _, actual: _) | Policy.ClearanceWideningDenied(
          grant_id: _,
          parent_id: _,
          requested: _,
          parent_clearance: _
        ) | Policy.DeclassificationDenied(
          release: _,
          input_sensitivity: _,
          output_sensitivity: _,
          min_group_size: _
        ): Forbidden(reason: Policy.to_text(pe))
        Policy.InvalidPolicy(reason: _): BadInput(reason: Policy.to_text(pe))
        Policy.ExportBlocked(bucket: _, required: _, actual: _): Forbidden(
          reason: Policy.to_text(pe)
        )
        Policy.LedgerFailure(_) | Policy.ExportFailure(_) | Policy.FtsFailure(_) | Policy.VecFailure(
          _
        ): ServerFailed(reason: Policy.to_text(pe))
      end
    Taint.TaintedReadEscalationBlocked(
      session_id: _,
      subject: _,
      required: _,
      capped_clearance: _,
      untrusted_sources: _
    ) | Taint.LethalTrifectaBlocked(
      session_id: _,
      target: _,
      max_sensitivity_read: _,
      untrusted_sources: _,
      reason: _
    ) | Taint.ClearDenied(reason: _): Forbidden(reason: Taint.to_text(err))
    Taint.InvalidSession(reason: _) | Taint.SessionClosed(id: _) | Taint.SessionAlreadyExists(id: _): BadInput(
      reason: Taint.to_text(err)
    )
    Taint.SessionNotFound(id: sid): Missing(entity: "taint_session", id: sid)
    Taint.LedgerFailure(_) | Taint.FtsFailure(_) | Taint.VecFailure(_): ServerFailed(
      reason: Taint.to_text(err)
    )
  end
end

## Opens or reuses a `Modb.Taint.TaintSession` inside a write lock for sandboxed RLM inspection.
fn ensure_taint_session_locked(
  files: Files,
  path: Text,
  sc: Schema,
  session_id: Text,
  principal: Text,
  grant_id_opt: Option(Text),
  now: Time
) : Result(Taint.TaintSession, AppError)
  Taint.ensure_session_locked(files, path, sc, session_id, principal, grant_id_opt, now).map_error(
    map_taint_error
  )
end

## Executes a `Modb.Views.ReadProgram` under `Modb.Taint` supervision (enforcing View narrowing,
## `ReadLimits` work budgets, `_modb_read_log` provenance, and monotonic taint tracking).
fn run_tainted_read_program_locked(
  files: Files,
  path: Text,
  sc: Schema,
  cat: Views.ViewCatalog,
  session_id: Text,
  prog: Views.ReadProgram,
  is_admin: Bool,
  limits: Views.ReadLimits,
  now: Time
) : Result(Taint.TaintedReadResult, AppError)
  Taint.execute_read_program_tainted_locked(
    files,
    path,
    sc,
    cat,
    default_sensitivity_policy(),
    default_taint_policy(),
    session_id,
    prog,
    is_admin,
    limits,
    now
  ).map_error(map_taint_error)
end
