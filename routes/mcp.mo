## Streamable HTTP `/mcp` server handler powered by `Arvo.Mcp`, `Modb.Claims`,
## `Modb.World`, `Modb.Fts`, `Domain.Blocks`, and `Domain.DatabaseModel`.
module Routes.Mcp
expose handle_mcp
use Api
use Arvo.Id
use Arvo.Mcp
use Arvo.Modb.Jobs
use Db
use Domain.Blocks
use Domain.Collab{ProposalMeta, WorldBranchArgs, WorldMutation, WorldPatchArgs}
use Domain.DatabaseModel{
  DbRow,
  ViewQueryResult
}
use Domain.Policy
use Domain.TaintBridge
use Domain.Types{
  AppError,
  AuthContext,
  AuthorKind,
  BlockOp,
  Page,
  PageKind,
  PrincipalKind,
  Provenance,
  WorkspaceRole
}
use Json
use Modb{WriteTx}
use Modb.Claims
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Modb.Vec
use Modb.World
use Routes.Ai
use Routes.Packs

fn vellum_server_info() : Mcp.ServerInfo
  Mcp.ServerInfo(
    name: "vellum-mcp",
    version: "1.0.0",
    protocol_version: Mcp.default_protocol_version,
    instructions: Some(
      "Vellum AI-native workspace MCP server. Provide 'reason' on all writes. Use proposals in gated collections."
    )
  )
end

fn str_prop(desc: Text) : Json
  Json.Object({"type": Json.String("string"), "description": Json.String(desc)})
end

fn vellum_tools() : List(Mcp.ToolDef)
  [
    Mcp.ToolDef(
      name: "vellum.onboard",
      description: "Inspect caller identity, active grant bounds, accessible collections, claims, and open proposals.",
      input_schema: Mcp.object_schema({}, []),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.list_collections",
      description: "List workspace collections accessible under the caller's grant.",
      input_schema: Mcp.object_schema({}, []),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.search",
      description: "Hybrid BM25 + semantic Modb.Vec search across accessible pages and database rows under Modb.Taint supervision.",
      input_schema: Mcp.object_schema(
        {
          "q": str_prop("Search query"),
          "collection_id": str_prop("Optional collection filter"),
          "mode": str_prop("Optional mode: 'hybrid' (default), 'bm25', or 'semantic'"),
          "session_id": str_prop("Optional Modb.Taint session ID"),
          "parent_session_id": str_prop("Optional parent Modb.Taint session ID to fork monotonic taint from")
        },
        ["q"]
      ),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.read_page",
      description: "Read page metadata, provenance trust tier, and lossless anchored Markdown (with stable blk IDs).",
      input_schema: Mcp.object_schema(
        {
          "page_id": str_prop("Target page ID"),
          "session_id": str_prop("Optional Modb.Taint session ID"),
          "parent_session_id": str_prop("Optional parent Modb.Taint session ID to fork monotonic taint from")
        },
        ["page_id"]
      ),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.patch_blocks",
      description: "Directly apply surgical BlockOps on DirectWithAudit collections with mandatory reason.",
      input_schema: Mcp.object_schema(
        {
          "page_id": str_prop("Target page ID"),
          "ops": Json.Object({"type": Json.String("array")}),
          "expected_versions": Json.Object({"type": Json.String("object")}),
          "reason": str_prop("Audit reason for this mutation"),
          "session_id": str_prop("Optional Modb.Taint session ID"),
          "parent_session_id": str_prop("Optional parent Modb.Taint session ID")
        },
        ["page_id", "ops", "reason"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.claim_acquire",
      description: "Acquire an advisory Modb.Claims lease on a page, block, or database row.",
      input_schema: Mcp.object_schema(
        {
          "resource": str_prop("e.g. page:pg_123 or page:pg_123:block:blk_456"),
          "ttl_seconds": Json.Object({"type": Json.String("integer")}),
          "reason": str_prop("Why this claim is held")
        },
        ["resource", "reason"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.claim_release",
      description: "Release an active Modb.Claims lease held by caller.",
      input_schema: Mcp.object_schema({"resource": str_prop("Resource key")}, ["resource"]),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.proposal_open",
      description: "Open an isolated speculative Modb.World Change Proposal on a page.",
      input_schema: Mcp.object_schema(
        {
          "page_id": str_prop("Target page ID"),
          "title": str_prop("Proposal title"),
          "reason": str_prop("Why this change is proposed")
        },
        ["page_id", "title", "reason"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.proposal_stage_ops",
      description: "Stage surgical BlockOps inside an open Modb.World Change Proposal.",
      input_schema: Mcp.object_schema(
        {
          "proposal_id": str_prop("Proposal ID"),
          "ops": Json.Object({"type": Json.String("array")}),
          "expected_versions": Json.Object({"type": Json.String("object")}),
          "reason": str_prop("Reason for staged change")
        },
        ["proposal_id", "ops", "reason"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.proposal_diff",
      description: "Inspect structural CoW bucket diffs of a speculative Change Proposal.",
      input_schema: Mcp.object_schema({"proposal_id": str_prop("Proposal ID")}, ["proposal_id"]),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.db_query",
      description: "Query a Vellum relational database with filters, sorts, and exact Decimal rollups.",
      input_schema: Mcp.object_schema(
        {
          "database_id": str_prop("Target database ID"),
          "filters": Json.Object({"type": Json.String("array")}),
          "sorts": Json.Object({"type": Json.String("array")})
        },
        ["database_id"]
      ),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.db_schema",
      description: "Inspect relational database schema properties, saved views, and row count.",
      input_schema: Mcp.object_schema({"database_id": str_prop("Target database ID")}, ["database_id"]),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.db_create_row",
      description: "Directly create a typed row on a DirectWithAudit database with mandatory reason.",
      input_schema: Mcp.object_schema(
        {
          "database_id": str_prop("Target database ID"),
          "cells": Json.Object({"type": Json.String("object")}),
          "markdown": str_prop("Optional backing page Markdown"),
          "reason": str_prop("Audit reason for row creation"),
          "session_id": str_prop("Optional Modb.Taint session ID"),
          "parent_session_id": str_prop("Optional parent Modb.Taint session ID")
        },
        ["database_id", "cells", "reason"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.db_update_row",
      description: "Directly update typed cells on a DirectWithAudit database row with optimistic concurrency check.",
      input_schema: Mcp.object_schema(
        {
          "database_id": str_prop("Target database ID"),
          "row_id": str_prop("Target row ID"),
          "cells": Json.Object({"type": Json.String("object")}),
          "expected_version": Json.Object({"type": Json.String("integer")}),
          "reason": str_prop("Audit reason for row update"),
          "session_id": str_prop("Optional Modb.Taint session ID"),
          "parent_session_id": str_prop("Optional parent Modb.Taint session ID")
        },
        ["database_id", "row_id", "cells", "expected_version", "reason"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.db_propose_changes",
      description: "Open or extend an isolated Modb.World Change Proposal with typed DB row/schema mutations or block patches.",
      input_schema: Mcp.object_schema(
        {
          "database_id": str_prop("Target database ID"),
          "proposal_id": str_prop("Optional existing open proposal ID to append mutations to"),
          "title": str_prop("Proposal title (required when opening a new branch)"),
          "branch_kind": str_prop("'proposal' (default) or 'scenario'"),
          "reason": str_prop("Audit reason"),
          "mutations": Json.Object({"type": Json.String("array")})
        },
        ["database_id", "reason", "mutations"]
      ),
      read_only?: false
    ),
    Mcp.ToolDef(
      name: "vellum.proposal_comments",
      description: "Read anchored Patchwork review & steer comments attached to a Change Proposal.",
      input_schema: Mcp.object_schema({"proposal_id": str_prop("Proposal ID")}, ["proposal_id"]),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.list_summaries",
      description: "List compact grant-filtered Living Summaries (~50 tokens each) for accessible pages and databases.",
      input_schema: Mcp.object_schema(
        {
          "collection_id": str_prop("Optional collection filter"),
          "kind": str_prop("Optional entity kind: 'page' or 'database'")
        },
        []
      ),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.list_packs",
      description: "List reusable Context Packs available to this grant (progressive-disclosure bundles).",
      input_schema: Mcp.object_schema({}, []),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.read_pack",
      description: "Compile a Context Pack under its token budget and return Markdown + token utilization telemetry.",
      input_schema: Mcp.object_schema(
        {
          "slug": str_prop("Pack slug or ID"),
          "q": str_prop("Optional query hint to prioritize relevant pages")
        },
        ["slug"]
      ),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.rlm_query",
      description: "RLM Deep Research (Tier 1 Modb.Views ReadProgram or Tier 2 capability-confined Mo Micro-REPL VM) with recursive child taint forks and inspectable trace.",
      input_schema: Mcp.object_schema(
        {
          "question": str_prop("Research question to answer across accessible collections"),
          "collection_id": str_prop("Optional collection filter (grant-verified by Modb.Views)"),
          "block_kinds": Json.Object({
            "type": Json.String("array"),
            "items": Json.Object({"type": Json.String("string")})
          }),
          "heading_contains": str_prop("Optional heading substring to isolate matching page sections"),
          "include_databases": Json.Object({"type": Json.String("boolean")}),
          "max_pages": Json.Object({"type": Json.String("integer")}),
          "max_blocks_per_page": Json.Object({"type": Json.String("integer")}),
          "max_subcalls": Json.Object({"type": Json.String("integer")}),
          "max_rows_scanned": Json.Object({"type": Json.String("integer")}),
          "session_id": str_prop("Optional Modb.Taint session suffix"),
          "tier": str_prop("Execution tier: 'tier1' (default) or 'tier2' (Mo Micro-REPL)"),
          "script": str_prop("Optional explicit Mo Micro-REPL script (triggers Tier 2)"),
          "max_depth": Json.Object({"type": Json.String("integer")})
        },
        ["question"]
      ),
      read_only?: true
    )
  ]
end

fn vellum_resources_for(auth: AuthContext, rf: ReadFiles) : List(Mcp.ResourceDef)
  base = [
    Mcp.ResourceDef(
      uri: "vellum://index",
      name: "Workspace Index (/llms.txt)",
      description: "Compact grant-filtered progressive-disclosure index of Context Packs, collections, and Living Summaries",
      mime_type: "text/markdown"
    ),
    Mcp.ResourceDef(
      uri: "vellum://workspace/overview",
      name: "Workspace Overview",
      description: "Permitted collections and relational databases for caller",
      mime_type: "application/json"
    )
  ]
  if not rf.exists?(Db.ledger_db_path) or auth.principal.suspended or
    not Policy.action_permitted?(auth, "read")
    return base
  end
  pack_res = Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      pks = try Packs.list_permitted_packs(Ledger.store(db), auth)
      Ok(
        Json.Array(
          pks.map(fn(pk)
            Json.Object({
              "slug": Json.String(pk.slug),
              "name": Json.String(pk.name),
              "token_budget": Json.int(pk.token_budget),
              "description": Json.String(pk.description)
            })
          end)
        )
      )
    end
  )
  case pack_res
    Error(_): base
    Ok(Json.Array(pks)):
      var out = base
      for pk in pks
        slug = pk.text_at("slug") or ""
        name = pk.text_at("name") or ""
        budget = pk.int_at("token_budget") or 0
        desc = pk.text_at("description") or ""
        out = out.append(
          Mcp.ResourceDef(
            uri: "vellum://packs/#{slug}",
            name: name,
            description: "Context Pack (#{budget} tok): #{desc}",
            mime_type: "text/markdown"
          )
        )
      end
      out
    Ok(Json.Null) | Ok(Json.Boolean(_)) | Ok(Json.Number(_)) | Ok(Json.String(_)) | Ok(Json.Object(_)):
      base
  end
end

fn make_provenance(auth: AuthContext, reason: Text, now: Time) : Provenance
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
    reason: Some(reason),
    citations: [],
    updated_at: now
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

fn generate_insert_ids(ops: List(BlockOp), rng: SecureRandom, clock: Clock) : List(Text)
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

fn mcp_session_id(args: Json, auth: AuthContext) : Text
  case args.text_at("session_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: "agent:#{auth.grant_id}"
  end
end

fn ensure_mcp_session_locked(
  args: Json,
  auth: AuthContext,
  files: Files,
  now: Time
) : Result((Text, Bool), AppError)
  sid = mcp_session_id(args, auth)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok((sid, false))
  end
  existing = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) TaintBridge.get_taint_session(Ledger.store(db), sid) end
  )
  grant_opt = if auth.principal.kind == Agent: Some(auth.grant_id) else: None
  case existing
    Some(s): Ok((sid, s.untrusted_tainted))
    None:
      parent_opt = case args.text_at("parent_session_id")
        Some(p) if not p.trim.empty?: Some(p.trim)
        Some(_) | None: None
      end
      sess = case parent_opt
        Some(pid):
          try TaintBridge.fork_taint_session_locked(
            files,
            Db.ledger_db_path,
            Db.vellum_schema(),
            pid,
            sid,
            auth.principal.handle,
            grant_opt,
            now
          )
        None:
          try TaintBridge.ensure_taint_session_locked(
            files,
            Db.ledger_db_path,
            Db.vellum_schema(),
            sid,
            auth.principal.handle,
            grant_opt,
            now
          )
      end
      Ok((sid, sess.untrusted_tainted))
  end
end

fn authorize_mcp_write_locked(
  args: Json,
  auth: AuthContext,
  files: Files,
  action_name: Text,
  now: Time
) : Result(Unit, AppError)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(Unit)
  end
  sid = mcp_session_id(args, auth)
  parent_opt = case args.text_at("parent_session_id")
    Some(p) if not p.trim.empty?: Some(p.trim)
    Some(_) | None: None
  end
  existing = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) TaintBridge.get_taint_session(Ledger.store(db), sid) end
  )
  case existing
    Some(_): Unit
    None:
      case parent_opt
        Some(_):
          _forked = try ensure_mcp_session_locked(args, auth, files, now)
        None: return Ok(Unit)
      end
  end
  _ok_sess = try TaintBridge.authorize_action_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    sid,
    action_name,
    now
  )
  Ok(Unit)
end

fn mcp_search_vec_setup(
  rf: ReadFiles,
  q: Text,
  env: Env,
  net: Network
) : Result((Option(List(Float)), Vec.VecIndex, Text, Option(Float)), AppError)
  case Ai.embed_config(env)
    None:
      Ok(
        (
          Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
          Db.sketch_vec_index(),
          "sketch",
          Some(Db.sketch_min_vec_score)
        )
      )
    Some(ecfg):
      has_neural = try Ledger.read_locked(
        rf,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db) Db.neural_vec_populated(Ledger.store(db), ecfg.dimensions) end
      )
      if has_neural
        case Ai.fetch_embedding(ecfg, q, net)
          Ok(qv): Ok((Some(qv), Db.neural_vec_index(ecfg.dimensions), "neural", Some(ecfg.min_score)))
          Error(_):
            Ok(
              (
                Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
                Db.sketch_vec_index(),
                "sketch",
                Some(Db.sketch_min_vec_score)
              )
            )
        end
      else
        Ok(
          (
            Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
            Db.sketch_vec_index(),
            "sketch",
            Some(Db.sketch_min_vec_score)
          )
        )
      end
  end
end

fn decode_ops_and_versions(args: Json) : Result((List(BlockOp), Map(Text, Int)), Text)
  ops_json = try args.get("ops").or_fail("missing 'ops' array")
  ops = try Blocks.decode_block_ops_json(ops_json.to_text.bytes)
  exp_vers = case args.get("expected_versions")
    None | Some(Json.Null): {}
    Some(ev): try Blocks.decode_version_map_json(ev.to_text.bytes)
  end
  Ok((ops, exp_vers))
end

fn handle_mcp_db_schema(
  id: Mcp.RpcId,
  args: Json,
  auth: AuthContext,
  files: Files
) : Result(Api.Response, AppError)
  db_id = case args.text_at("database_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'database_id'"))
  end
  read_act = if Policy.action_permitted?(auth, "query_db"): "query_db" else: "read"
  sres = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      def = case try Table.get(store, Db.databases_table(), db_id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: db_id))
      end
      try Policy.require_collection_access(auth, read_act, def.collection_id)
      vpairs = try Table.lookup(store, Db.db_views_table(), Db.db_views_by_database(), def.id)
        .map_error(Db.map_table_error)
      views = vpairs.map(fn(p) p.1 end).sort_by(fn(v) v.sort_order end)
      rpairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def.id)
        .map_error(Db.map_table_error)
      row_count = rpairs.filter(fn(p) p.1.archived_at == None end).size
      Ok(
        Json.Object({
          "database": def.to_json,
          "properties": def.properties.to_json,
          "views": views.to_json,
          "row_count": Json.int(row_count)
        })
      )
    end
  )
  case sres
    Ok(payload): Ok(Mcp.tool_ok(id, "Loaded schema for database #{db_id}.", Some(payload)))
    Error(e): Ok(Mcp.tool_error(id, e.to_text))
  end
end

fn handle_mcp_db_create_row(
  id: Mcp.RpcId,
  args: Json,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  now: Time
) : Result(Api.Response, AppError)
  db_id = case args.text_at("database_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'database_id'"))
  end
  reason = case args.text_at("reason")
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "non-empty 'reason' is required"))
  end
  cells_json = case args.get("cells")
    Some(cj): cj
    None: return Ok(Mcp.tool_error(id, "missing 'cells' object"))
  end
  cells = case DatabaseModel.decode_cell_map_json(cells_json.to_text.bytes)
    Ok(m): m
    Error(e): return Ok(Mcp.tool_error(id, "invalid cells: #{e}"))
  end
  case authorize_mcp_write_locked(args, auth, files, "mcp.db_create_row", now)
    Ok(_): Unit
    Error(e): return Ok(Mcp.tool_error(id, e.to_text))
  end
  md_opt = args.text_at("markdown")
  row_id = "row_#{Id.ulid(rng, clock)}"
  page_id = "pg_#{Id.ulid(rng, clock)}"
  block_prefix = "blk_#{Id.ulid(rng, clock)}"
  prov = make_provenance(auth, reason, now)
  blocks = case md_opt
    Some(md) if not md.trim.empty?: Blocks.parse_markdown_blocks(page_id, md, prov, block_prefix)
    Some(_) | None: []
  end
  idx_job = Jobs.prepare(
    rng,
    clock,
    "vellum.page.indexed",
    Json.Object({"page_id": Json.String(page_id)})
  )
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "mcp.db_create_row",
    reason: reason,
    at: now
  )
  res = Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "mcp created row #{row_id} in #{db_id}",
    Json.Object({"database_id": Json.String(db_id), "row_id": Json.String(row_id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_db", now)
      def = case try Table.tx_get(t1, Db.databases_table(), db_id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: db_id))
      end
      try Policy.require_collection_access(auth, "write_db", def.collection_id)
      col = case try Table.tx_get(t1, Db.collections_table(), def.collection_id).map_error(
        Db.map_table_error
      )
        Some(c): c
        None: return Error(Missing(entity: "collection", id: def.collection_id))
      end
      if not Policy.can_write_db_direct?(auth, col)
        return Error(
          Forbidden(
            reason: "collection '#{col.slug}' requires Change Proposals; use vellum.db_propose_changes"
          )
        )
      end
      (t_seq, assigned_cells) = try Db.tx_assign_unique_ids(t1, def, cells)
      row = DbRow(
        id: row_id,
        database_id: def.id,
        page_id: page_id,
        cells: assigned_cells,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      case DatabaseModel.validate_row_cells(def, row)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end
      row_title = DatabaseModel.extract_row_title(def, assigned_cells)
      page = Page(
        id: page_id,
        collection_id: def.collection_id,
        parent_page_id: Some(def.page_id),
        title: row_title,
        icon: None,
        cover_attachment_id: None,
        kind: DatabaseRow(database_id: def.id, row_id: row_id),
        sort_order: row_id,
        database_id: Some(def.id),
        freshness_ttl_days: None,
        verified_at: None,
        verified_by: None,
        created_by: auth.principal.id,
        created_at: now,
        updated_at: now,
        archived_at: None,
        version: 1
      )
      t2 = try Db.tx_put_db_row(t_seq, def, row, page, blocks)
      t2b = try Db.tx_put_db_row_editor(t2, row.id, auth.principal.id)
      (t3, _jid) = try Jobs.tx_put(t2b, idx_job).map_error(Db.map_table_error)
      Ok((
        t3,
        Json.Object({
          "row": row.to_json,
          "page": page.to_json,
          "database_id": Json.String(row.database_id),
          "row_id": Json.String(row.id),
          "page_id": Json.String(page.id),
          "collection_id": Json.String(page.collection_id)
        })
      ))
    end
  )
  case res
    Ok(saved_j):
      row_j = saved_j.get("row") or Json.Null
      page_j = saved_j.get("page") or Json.Null
      s_db_id = saved_j.text_at("database_id") or db_id
      s_row_id = saved_j.text_at("row_id") or row_id
      s_page_id = saved_j.text_at("page_id") or page_id
      s_col_id = saved_j.text_at("collection_id") or ""
      row_ev = Json.Object({
        "database_id": Json.String(s_db_id),
        "row_id": Json.String(s_row_id),
        "page_id": Json.String(s_page_id),
        "collection_id": Json.String(s_col_id),
        "actor": Json.String(auth.principal.handle)
      })
      payload = Json.Object({"row": row_j, "page": page_j})
      Ok(
        Mcp.tool_ok(id, "Created row #{s_row_id} in database #{db_id}.", Some(payload))
          .with_sse_publish_json("database:#{s_db_id}", "db.row_created", row_ev)
          .with_sse_publish_json("collection:#{s_col_id}", "db.row_created", row_ev)
      )
    Error(e): Ok(Mcp.tool_error(id, e.to_text))
  end
end

fn handle_mcp_db_update_row(
  id: Mcp.RpcId,
  args: Json,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  now: Time
) : Result(Api.Response, AppError)
  db_id = case args.text_at("database_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'database_id'"))
  end
  row_id = case args.text_at("row_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'row_id'"))
  end
  reason = case args.text_at("reason")
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "non-empty 'reason' is required"))
  end
  exp_ver = case args.int_at("expected_version")
    Some(v): v
    None: return Ok(Mcp.tool_error(id, "missing integer 'expected_version'"))
  end
  cells_json = case args.get("cells")
    Some(cj): cj
    None: return Ok(Mcp.tool_error(id, "missing 'cells' object"))
  end
  cell_updates = case DatabaseModel.decode_cell_map_json(cells_json.to_text.bytes)
    Ok(m): m
    Error(e): return Ok(Mcp.tool_error(id, "invalid cells: #{e}"))
  end
  case authorize_mcp_write_locked(args, auth, files, "mcp.db_update_row", now)
    Ok(_): Unit
    Error(e): return Ok(Mcp.tool_error(id, e.to_text))
  end
  idx_job = Jobs.prepare(rng, clock, "vellum.page.indexed", Json.Null)
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "mcp.db_update_row",
    reason: reason,
    at: now
  )
  res = Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "mcp updated row #{row_id} in #{db_id}",
    Json.Object({"database_id": Json.String(db_id), "row_id": Json.String(row_id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try tx_authorize_if_agent(tx, auth, "write_db", now)
      def = case try Table.tx_get(t1, Db.databases_table(), db_id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: db_id))
      end
      try Policy.require_collection_access(auth, "write_db", def.collection_id)
      col = case try Table.tx_get(t1, Db.collections_table(), def.collection_id).map_error(
        Db.map_table_error
      )
        Some(c): c
        None: return Error(Missing(entity: "collection", id: def.collection_id))
      end
      if not Policy.can_write_db_direct?(auth, col)
        return Error(
          Forbidden(
            reason: "collection '#{col.slug}' requires Change Proposals; use vellum.db_propose_changes"
          )
        )
      end
      old_row = case try Table.tx_get(t1, Db.db_rows_table(), row_id).map_error(Db.map_table_error)
        Some(r) if r.database_id == def.id and r.archived_at == None: r
        Some(_) | None: return Error(Missing(entity: "db_row", id: row_id))
      end
      if old_row.version != exp_ver
        return Error(
          Conflict(
            reason: "db_row '#{row_id}' version mismatch: expected #{exp_ver}, found #{old_row
              .version}"
          )
        )
      end
      try DatabaseModel.check_unique_id_immutable(def, old_row.cells, cell_updates).map_error(fn(msg)
        BadInput(reason: msg)
      end)
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
        updated_at: now,
        archived_at: old_row.archived_at,
        version: old_row.version + 1
      )
      case DatabaseModel.validate_row_cells(def, bumped_row)
        Some(msg): return Error(BadInput(reason: msg))
        None: Unit
      end
      old_page = case try Table.tx_get(t1, Db.pages_table(), old_row.page_id).map_error(
        Db.map_table_error
      )
        Some(p): p
        None: return Error(Missing(entity: "page", id: old_row.page_id))
      end
      block_rows = try Table.tx_lookup(t1, Db.blocks_table(), Db.blocks_by_page(), old_page.id)
        .map_error(Db.map_table_error)
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
        updated_at: now,
        archived_at: old_page.archived_at,
        version: old_page.version + 1
      )
      t2 = try Db.tx_put_db_row(t1, def, bumped_row, bumped_page, existing_blocks)
      t2b = try Db.tx_put_db_row_editor(t2, bumped_row.id, auth.principal.id)
      final_idx_job = Jobs.JobRecord(
        id: idx_job.id,
        queue: idx_job.queue,
        job_name: idx_job.job_name,
        payload_json: Json.Object({"page_id": Json.String(bumped_page.id)}).to_text,
        state: idx_job.state,
        attempts: idx_job.attempts,
        max_attempts: idx_job.max_attempts,
        run_at: idx_job.run_at,
        locked_at: idx_job.locked_at,
        last_error: idx_job.last_error,
        created_at: idx_job.created_at,
        updated_at: idx_job.updated_at
      )
      (t3, _jid) = try Jobs.tx_put(t2b, final_idx_job).map_error(Db.map_table_error)
      Ok((
        t3,
        Json.Object({
          "row": bumped_row.to_json,
          "page": bumped_page.to_json,
          "database_id": Json.String(bumped_row.database_id),
          "row_id": Json.String(bumped_row.id),
          "page_id": Json.String(bumped_page.id),
          "collection_id": Json.String(bumped_page.collection_id),
          "version": Json.int(bumped_row.version)
        })
      ))
    end
  )
  case res
    Ok(next_j):
      row_j = next_j.get("row") or Json.Null
      page_j = next_j.get("page") or Json.Null
      n_db_id = next_j.text_at("database_id") or db_id
      n_row_id = next_j.text_at("row_id") or row_id
      n_page_id = next_j.text_at("page_id") or ""
      n_col_id = next_j.text_at("collection_id") or ""
      n_ver = next_j.int_at("version") or 1
      row_ev = Json.Object({
        "database_id": Json.String(n_db_id),
        "row_id": Json.String(n_row_id),
        "page_id": Json.String(n_page_id),
        "collection_id": Json.String(n_col_id),
        "version": Json.int(n_ver),
        "actor": Json.String(auth.principal.handle)
      })
      payload = Json.Object({"row": row_j, "page": page_j})
      Ok(
        Mcp.tool_ok(id, "Updated row #{n_row_id} (v#{n_ver}).", Some(payload))
          .with_sse_publish_json("database:#{n_db_id}", "db.row_updated", row_ev)
          .with_sse_publish_json("collection:#{n_col_id}", "db.row_updated", row_ev)
      )
    Error(e): Ok(Mcp.tool_error(id, e.to_text))
  end
end

fn decode_mcp_world_mutation(
  item: Json,
  def_id: Text,
  def_page_id: Text,
  prov: Provenance,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(WorldMutation, Text)
  mkind = (item.text_at("kind") or "").trim
  if mkind == "page_patch"
    pid = case item.text_at("page_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: def_page_id
    end
    ops_j = case item.get("ops")
      Some(j): j
      None: return Error("ops required for page_patch")
    end
    ops = case Blocks.decode_block_ops_json(ops_j.to_text.bytes)
      Ok(o) if not o.empty?: o
      Ok(_): return Error("ops must not be empty")
      Error(e): return Error("invalid ops: #{e}")
    end
    exp_vers = case item.get("expected_versions")
      None | Some(Json.Null): {}
      Some(evj):
        case Blocks.decode_version_map_json(evj.to_text.bytes)
          Ok(m): m
          Error(e): return Error("invalid expected_versions: #{e}")
        end
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
    ).map_error(fn(e) e.to_text end)
    return Ok(
      PatchPageBlocks(
        page_id: pg.id,
        ops: ops,
        new_ids: generate_insert_ids(ops, rng, clock),
        provenance: prov,
        expected_versions: exp_vers
      )
    )
  end

  mut_db_id = case item.text_at("database_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: def_id
  end
  if mut_db_id != def_id
    _d = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        fd = case try Table.get(Ledger.store(db), Db.databases_table(), mut_db_id).map_error(
          Db.map_table_error
        )
          Some(d): d
          None: return Error(Missing(entity: "database", id: mut_db_id))
        end
        try Policy.require_collection_access(auth, "propose", fd.collection_id)
        Ok(fd)
      end
    ).map_error(fn(e) e.to_text end)
  end

  if mkind == "db_row_create"
    cj = case item.get("cells")
      Some(j): j
      None: return Error("cells required for db_row_create")
    end
    cs = case DatabaseModel.decode_cell_map_json(cj.to_text.bytes)
      Ok(m): m
      Error(e): return Error("invalid cells: #{e}")
    end
    Ok(
      CreateDbRow(
        database_id: mut_db_id,
        row_id: "row_#{Id.ulid(rng, clock)}",
        page_id: "pg_#{Id.ulid(rng, clock)}",
        cells: cs,
        markdown: item.text_at("markdown"),
        block_prefix: "blk_#{Id.ulid(rng, clock)}",
        provenance: prov
      )
    )
  else if mkind == "db_row_update"
    rid = (item.text_at("row_id") or "").trim
    if rid.empty?
      return Error("row_id required for db_row_update")
    end
    cj = case item.get("cells")
      Some(j): j
      None: return Error("cells required for db_row_update")
    end
    cs = case DatabaseModel.decode_cell_map_json(cj.to_text.bytes)
      Ok(m): m
      Error(e): return Error("invalid cells: #{e}")
    end
    Ok(
      UpdateDbRow(
        database_id: mut_db_id,
        row_id: rid,
        cells: cs,
        expected_version: item.int_at("expected_version"),
        provenance: prov
      )
    )
  else if mkind == "db_row_delete"
    rid = (item.text_at("row_id") or "").trim
    if rid.empty?
      return Error("row_id required for db_row_delete")
    end
    Ok(DeleteDbRow(database_id: mut_db_id, row_id: rid))
  else if mkind == "db_schema_update"
    t_opt = case item.get("title")
      None | Some(Json.Null): None
      Some(Json.String(s)): Some(s)
      Some(_): return Error("invalid schema title")
    end
    d_opt = case item.get("description")
      None | Some(Json.Null): None
      Some(Json.String(s)): Some(s)
      Some(_): return Error("invalid schema description")
    end
    p_opt = case item.get("properties")
      None | Some(Json.Null): None
      Some(pj):
        case DatabaseModel.decode_property_defs_json(pj.to_text.bytes)
          Ok(ps): Some(ps)
          Error(e): return Error("invalid schema properties: #{e}")
        end
    end
    Ok(
      UpdateDbSchema(
        database_id: mut_db_id,
        title: t_opt,
        description: d_opt,
        properties: p_opt,
        expected_version: item.int_at("expected_version")
      )
    )
  else
    Error("unsupported mutation kind '#{mkind}'")
  end
end

fn handle_mcp_db_propose_changes(
  id: Mcp.RpcId,
  args: Json,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  now: Time
) : Result(Api.Response, AppError)
  db_id = case args.text_at("database_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'database_id'"))
  end
  reason = case args.text_at("reason")
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "non-empty 'reason' is required"))
  end
  muts_raw = case args.list_at("mutations")
    Some(xs) if not xs.empty?: xs
    Some(_) | None: return Ok(Mcp.tool_error(id, "non-empty 'mutations' array is required"))
  end
  existing_pid_opt = case args.text_at("proposal_id")
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
  bkind = case args.text_at("branch_kind")
    Some(k) if not k.trim.empty?:
      tk = k.trim
      if tk != "proposal" and tk != "scenario"
        return Ok(Mcp.tool_error(id, "branch_kind must be 'proposal' or 'scenario'"))
      end
      tk
    Some(_) | None: "proposal"
  end

  target_def_res = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      found_def = case try Table.get(store, Db.databases_table(), db_id).map_error(
        Db.map_table_error
      )
        Some(d): d
        None: return Error(Missing(entity: "database", id: db_id))
      end
      try Policy.require_collection_access(auth, "propose", found_def.collection_id)
      Ok(found_def)
    end
  )
  def = case target_def_res
    Ok(d): d
    Error(e): return Ok(Mcp.tool_error(id, e.to_text))
  end

  prov = make_provenance(auth, reason, now)
  var decoded_muts = []
  for item in muts_raw
    case decode_mcp_world_mutation(item, def.id, def.page_id, prov, auth, files, rng, clock)
      Ok(mut): decoded_muts = decoded_muts.append(mut)
      Error(msg): return Ok(Mcp.tool_error(id, msg))
    end
  end

  (pm, opened_new?) = case existing_pid_opt
    Some(pid):
      pm_res = Ledger.read_locked(
        files.read_only,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          found = case try Table.get(Ledger.store(db), Db.proposals_table(), pid).map_error(
            Db.map_table_error
          )
            Some(p): p
            None: return Error(Missing(entity: "proposal", id: pid))
          end
          try Policy.require_collection_access(auth, "propose", found.collection_id)
          Ok(found)
        end
      )
      found = case pm_res
        Ok(p): p
        Error(e): return Ok(Mcp.tool_error(id, e.to_text))
      end
      is_admin? = auth.principal.role == Owner or auth.principal.role == Admin
      if found.status != "open" or (found.author_id != auth.principal.id and not is_admin?)
        return Ok(
          Mcp.tool_error(id, "proposal '#{pid}' must be open and authored by caller or admin")
        )
      end
      (found, false)
    None:
      title = case args.text_at("title")
        Some(s) if not s.trim.empty?: s.trim
        Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'title' when opening proposal"))
      end
      prop_id = "prop_#{Id.ulid(rng, clock)}"
      world_id = "w_#{Id.ulid(rng, clock)}"
      case World.open_world_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        world_id,
        auth.grant_id,
        now,
        now + 7.days
      ).map_error(Db.map_world_error)
        Error(e): return Ok(Mcp.tool_error(id, e.to_text))
        Ok(_): Unit
      end
      pm_new = ProposalMeta(
        id: prop_id,
        world_id: world_id,
        collection_id: def.collection_id,
        target_page_id: def.page_id,
        target_database_id: Some(def.id),
        branch_kind: bkind,
        title: title,
        reason: reason,
        author_id: auth.principal.id,
        author_handle: auth.principal.handle,
        grant_id: auth.grant_id,
        status: "open",
        created_at: now,
        updated_at: now,
        decided_by: None,
        decided_at: None
      )
      meta = Ledger.WriteMeta(
        principal: auth.principal.handle,
        action: "mcp.db_propose_changes",
        reason: reason,
        at: now
      )
      saved_pm = try Ledger.transact_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        meta,
        "mcp opened db proposal #{prop_id} on #{def.id}",
        Json.Object({"proposal_id": Json.String(prop_id), "database_id": Json.String(def.id)}),
        Db.map_ledger_error,
        fn(tx)
          t1 = try tx_authorize_if_agent(tx, auth, "propose", now)
          t2 = try Db.tx_put_proposal(t1, pm_new)
          Ok((t2, pm_new))
        end
      )
      (saved_pm, true)
  end

  var step_replies = []
  for mut in decoded_muts
    bargs = WorldBranchArgs(mutation: mut, updated_at: now)
    case World.world_call_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.world_catalog(),
      pm.world_id,
      "propose",
      bargs.to_json,
      reason,
      now
    ).map_error(Db.map_world_error)
      Ok(rep): step_replies = step_replies.append(rep)
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  ev_name = if opened_new?: "proposal.opened" else: "proposal.updated"
  ev_payload = Json.Object({
    "proposal_id": Json.String(pm.id),
    "database_id": Json.String(def.id),
    "page_id": Json.String(pm.target_page_id),
    "collection_id": Json.String(pm.collection_id),
    "title": Json.String(pm.title),
    "actor": Json.String(auth.principal.handle)
  })
  out_json = Json.Object({
    "proposal": pm.to_json,
    "staged_count": Json.int(step_replies.size),
    "step_replies": Json.Array(step_replies)
  })
  Ok(
    Mcp.tool_ok(
      id,
      "Staged #{step_replies.size} database mutation(s) in proposal #{pm.id}.",
      Some(out_json)
    ).with_sse_publish_json("collection:#{pm.collection_id}", ev_name, ev_payload)
      .with_sse_publish_json("database:#{def.id}", ev_name, ev_payload)
  )
end

fn handle_mcp_proposal_comments(
  id: Mcp.RpcId,
  args: Json,
  auth: AuthContext,
  files: Files
) : Result(Api.Response, AppError)
  pid = case args.text_at("proposal_id")
    Some(s) if not s.trim.empty?: s.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'proposal_id'"))
  end
  cres = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pm = case try Table.get(store, Db.proposals_table(), pid).map_error(Db.map_table_error)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: pid))
      end
      try Policy.require_collection_access(auth, "read", pm.collection_id)
      pairs = try Table.lookup(
        store,
        Db.proposal_comments_table(),
        Db.proposal_comments_by_proposal(),
        pid
      ).map_error(Db.map_table_error)
      cmts = pairs.map(fn(p) p.1 end).sort_by(fn(c) c.id end)
      Ok(Json.Object({"comments": cmts.to_json, "count": Json.int(cmts.size)}))
    end
  )
  case cres
    Ok(cj):
      cnt = cj.int_at("count") or 0
      cmts_j = cj.get("comments") or Json.Array([])
      Ok(
        Mcp.tool_ok(
          id,
          "Returned #{cnt} comments for proposal #{pid}.",
          Some(Json.Object({"proposal_id": Json.String(pid), "comments": cmts_j}))
        )
      )
    Error(e): Ok(Mcp.tool_error(id, e.to_text))
  end
end

fn handle_mcp_rlm_query(
  id: Mcp.RpcId,
  args: Json,
  auth: AuthContext,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  question = case args.text_at("question")
    Some(q) if not q.trim.empty?: q.trim
    Some(_) | None: return Ok(Mcp.tool_error(id, "non-empty 'question' is required"))
  end
  col_opt = case args.text_at("collection_id")
    Some(c) if not c.trim.empty?: Some(c.trim)
    Some(_) | None: None
  end
  heading_opt = case args.text_at("heading_contains")
    Some(h) if not h.trim.empty?: Some(h.trim)
    Some(_) | None: None
  end
  kinds_opt = case args.get("block_kinds")
    None | Some(Json.Null): None
    Some(Json.Array(items)):
      var ks = []
      for item in items
        case item
          Json.String(s): ks = ks.append(s)
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): return Ok(
            Mcp.tool_error(id, "invalid block_kinds: expected array of strings")
          )
        end
      end
      Some(ks)
    Some(_): return Ok(Mcp.tool_error(id, "invalid block_kinds: expected array of strings"))
  end
  inc_dbs_opt = args.bool_at("include_databases")
  max_pages_opt = args.int_at("max_pages")
  max_b_opt = args.int_at("max_blocks_per_page")
  max_sub_opt = args.int_at("max_subcalls")
  max_rows_opt = args.int_at("max_rows_scanned")
  sess_opt = case args.text_at("session_id")
    Some(s) if not s.trim.empty?: Some(s.trim)
    Some(_) | None: None
  end
  tier_opt = case args.text_at("tier")
    Some(t) if not t.trim.empty?: Some(t.trim)
    Some(_) | None: None
  end
  script_opt = case args.text_at("script")
    Some(sc) if not sc.trim.empty?: Some(sc.trim)
    Some(_) | None: None
  end
  max_depth_opt = args.int_at("max_depth")

  inp = Ai.DeepResearchInput(
    question: question,
    collection_id: col_opt,
    block_kinds: kinds_opt,
    heading_contains: heading_opt,
    include_databases: inc_dbs_opt,
    max_pages: max_pages_opt,
    max_blocks_per_page: max_b_opt,
    max_subcalls: max_sub_opt,
    max_rows_scanned: max_rows_opt,
    session_id: sess_opt,
    tier: tier_opt,
    script: script_opt,
    max_depth: max_depth_opt
  )
  case Ai.execute_deep_research(auth, inp, files, clock, env, net)
    Ok(out): Ok(Mcp.tool_ok(id, out.answer, Some(Ai.deep_research_outcome_to_json(out))))
    Error(e): Ok(Mcp.tool_error(id, e.to_text))
  end
end

fn handle_tool_call(
  id: Mcp.RpcId,
  name: Text,
  args: Json,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  now = clock.now

  if name == "vellum.onboard"
    if not Policy.action_permitted?(auth, "read")
      return Ok(Mcp.tool_error(id, "grant '#{auth.grant_id}' does not permit 'read'"))
    end
    data = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        cols = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        vis_cols = cols.filter(fn(p)
          p.1.archived_at == None and Policy.collection_permitted?(auth, p.1.id)
        end).map(fn(p) p.1 end)
        claims = try Claims.list_active(store, now).map_error(Db.map_claims_error)
        props = try Table.lookup(store, Db.proposals_table(), Db.proposals_by_status(), "open")
          .map_error(Db.map_table_error)
        vis_props = props.filter(fn(p) Policy.collection_permitted?(auth, p.1.collection_id) end)
          .map(fn(p) p.1 end)
        Ok(
          Json.Object({
            "principal_id": Json.String(auth.principal.id),
            "handle": Json.String(auth.principal.handle),
            "kind": auth.principal.kind.to_json,
            "grant_id": Json.String(auth.grant_id),
            "allowed_actions": auth.allowed_actions.to_json,
            "allowed_collections": auth.allowed_collections.to_json,
            "accessible_collections": vis_cols.to_json,
            "active_claims": claims.to_json,
            "open_proposals": vis_props.to_json
          })
        )
      end
    )
    return Ok(Mcp.tool_ok(id, "Workspace onboarding state ready.", Some(data)))
  end

  if name == "vellum.list_collections"
    if not Policy.action_permitted?(auth, "read")
      return Ok(Mcp.tool_error(id, "grant '#{auth.grant_id}' does not permit 'read'"))
    end
    cols_res = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        rows = try Table.scan(Ledger.store(db), Db.collections_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        cols = rows.filter(fn(p)
          p.1.archived_at == None and Policy.collection_permitted?(auth, p.1.id)
        end).map(fn(p) p.1 end)
        Ok(Json.Object({"collections": cols.to_json, "count": Json.int(cols.size)}))
      end
    )
    cols_cnt = cols_res.int_at("count") or 0
    cols_j = cols_res.get("collections") or Json.Array([])
    return Ok(
      Mcp.tool_ok(
        id,
        "Found #{cols_cnt} collections.",
        Some(Json.Object({"collections": cols_j}))
      )
    )
  end

  if name == "vellum.search"
    if not Policy.action_permitted?(auth, "read")
      return Ok(Mcp.tool_error(id, "grant '#{auth.grant_id}' does not permit 'read'"))
    end
    q = (args.text_at("q") or "").trim
    if q.empty?
      return Ok(Mcp.tool_error(id, "'q' must not be empty"))
    end
    col_filter = case args.text_at("collection_id")
      Some(s) if not s.trim.empty?: Some(s.trim)
      Some(_) | None: None
    end
    raw_mode = (args.text_at("mode") or "hybrid").trim.ascii_lowercase
    if raw_mode != "hybrid" and raw_mode != "bm25" and raw_mode != "semantic"
      return Ok(Mcp.tool_error(id, "invalid search mode '#{raw_mode}'; expected hybrid, bm25, or semantic"))
    end
    if not files.read_only.exists?(Db.ledger_db_path)
      return Ok(
        Mcp.tool_ok(
          id,
          "Found 0 #{raw_mode} search hits.",
          Some(
            Json.Object({
              "results": Json.Array([]),
              "mode": Json.String(raw_mode),
              "vector_backend": Json.String("none")
            })
          )
        )
      )
    end
    (sess_id, _init_tainted) = case ensure_mcp_session_locked(args, auth, files, now)
      Ok(pair): pair
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    cids_res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        case col_filter
          Some(cid):
            try Policy.require_collection_access(auth, "read", cid)
            Ok(Json.Array([Json.String(cid)]))
          None:
            rows = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
              Db.map_table_error
            )
            var out = []
            for (_id, c) in rows
              if c.archived_at == None and Policy.collection_permitted?(auth, c.id)
                out = out.append(Json.String(c.id))
              end
            end
            Ok(Json.Array(out))
        end
      end
    )
    target_cids = case cids_res
      Ok(Json.Array(xs)):
        var s_out = []
        for item in xs
          case item
            Json.String(s): s_out = s_out.append(s)
            Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Object(_) | Json.Array(_): Unit
          end
        end
        s_out
      Ok(Json.Null) | Ok(Json.Boolean(_)) | Ok(Json.Number(_)) | Ok(Json.String(_)) | Ok(Json.Object(_)):
        []
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    (raw_qv_opt, vec_idx, vec_backend, min_vec) = try mcp_search_vec_setup(
      files.read_only,
      q,
      env,
      net
    )
    (qv_opt, fts_w, vec_w, eff_backend) = if raw_mode == "bm25"
      (None, 1.0.to_float, 0.0.to_float, "none")
    else if raw_mode == "semantic"
      (raw_qv_opt, 0.0.to_float, 1.0.to_float, vec_backend)
    else
      (raw_qv_opt, 1.0.to_float, 1.0.to_float, vec_backend)
    end
    is_admin = auth.principal.role == Owner or auth.principal.role == Admin
    var raw_hits = []
    for cid in target_cids
      opts = Vec.HybridOptions(
        limit: 20,
        prefix_last_term?: true,
        required_scope: Some(cid),
        rrf_k: 60,
        fts_weight: fts_w,
        vec_weight: vec_w,
        candidate_limit: 40,
        min_vec_score: min_vec
      )
      (hhits, _upd_sess) = case TaintBridge.run_tainted_hybrid_search_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        sess_id,
        Db.fts_index(),
        vec_idx,
        q,
        qv_opt,
        opts,
        is_admin,
        now
      )
        Ok(pair): pair
        Error(e): return Ok(Mcp.tool_error(id, e.to_text))
      end
      for hh in hhits
        if hh.scope == cid and Policy.collection_permitted?(auth, hh.scope)
          raw_hits = raw_hits.append(hh)
        end
      end
    end
    sorted_hits = raw_hits.sort_by(fn(h) -h.score end).take(20)
    search_res_json = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        ptbl = Db.pages_table()
        var items = []
        var srcs = []
        var seen = []
        for hh in sorted_hits
          if not seen.contains?(hh.doc_id)
            case try Table.get(store, ptbl, hh.doc_id).map_error(Db.map_table_error)
              Some(p) if p.archived_at == None and Policy.collection_permitted?(auth, p.collection_id):
                seen = seen.append(p.id)
                pg_prov = try TaintBridge.get_provenance_info(store, "vlm_pages", p.id)
                var untrusted_w = case pg_prov
                  Some((tr, w, _at)) if tr == "untrusted": Some(w)
                  Some(_) | None: None
                end
                if untrusted_w == None
                  pblks = try Db.load_page_blocks(store, p.id)
                  for blk in pblks
                    if untrusted_w == None
                      case try TaintBridge.get_provenance_info(store, "vlm_blocks", blk.id)
                        Some((btr, bw, _bat)) if btr == "untrusted": untrusted_w = Some(bw)
                        Some(_) | None: Unit
                      end
                    end
                  end
                end
                trust_tier = case untrusted_w
                  Some(w):
                    srcs = srcs.append("page:#{p.id}(#{w})")
                    "untrusted"
                  None: "trusted"
                end
                fields = if hh.matched_fields.empty? and hh.vec_rank != None
                  ["semantic"]
                else
                  hh.matched_fields
                end
                items = items.append(
                  Json.Object({
                    "page_id": Json.String(p.id),
                    "collection_id": Json.String(p.collection_id),
                    "title": Json.String(p.title),
                    "score": hh.score.to_json,
                    "matched_terms": hh.matched_terms.to_json,
                    "matched_fields": fields.to_json,
                    "fts_rank": hh.fts_rank.to_json,
                    "vec_rank": hh.vec_rank.to_json,
                    "vec_score": hh.vec_score.to_json,
                    "trust_tier": Json.String(trust_tier)
                  })
                )
              Some(_) | None: Unit
            end
          end
        end
        Ok(Json.Object({"items": Json.Array(items), "untrusted_srcs": srcs.to_json}))
      end
    )
    items_json = search_res_json.list_at("items") or []
    var untrusted_srcs = []
    for sitem in search_res_json.list_at("untrusted_srcs") or []
      case sitem
        Json.String(s): untrusted_srcs = untrusted_srcs.append(s)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): Unit
      end
    end
    for usrc in untrusted_srcs
      _ts = try TaintBridge.record_untrusted_read_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        sess_id,
        usrc,
        now
      )
    end
    final_sess_json = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        sopt = try TaintBridge.get_taint_session(Ledger.store(db), sess_id)
        Ok(sopt.map(fn(s) TaintBridge.taint_session_to_json(s) end).to_json)
      end
    )
    return Ok(
      Mcp.tool_ok(
        id,
        "Found #{items_json.size} #{raw_mode} (#{eff_backend}) search hits.",
        Some(
          Json.Object({
            "results": Json.Array(items_json),
            "mode": Json.String(raw_mode),
            "vector_backend": Json.String(eff_backend),
            "taint_session": final_sess_json
          })
        )
      )
    )
  end

  if name == "vellum.read_page"
    pid = case args.text_at("page_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'page_id'"))
    end
    if not files.read_only.exists?(Db.ledger_db_path)
      return Ok(Mcp.tool_error(id, "page '#{pid}' not found"))
    end
    (sess_id, _init_tainted) = case ensure_mcp_session_locked(args, auth, files, now)
      Ok(pair): pair
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        pg = case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: pid))
        end
        try Policy.require_collection_access(auth, "read", pg.collection_id)
        blks = try Db.load_page_blocks(store, pg.id)
        pg_prov = try TaintBridge.get_provenance_info(store, "vlm_pages", pg.id)
        var untrusted_w = case pg_prov
          Some((tr, w, _at)) if tr == "untrusted": Some(w)
          Some(_) | None: None
        end
        if untrusted_w == None
          for blk in blks
            if untrusted_w == None
              case try TaintBridge.get_provenance_info(store, "vlm_blocks", blk.id)
                Some((btr, bw, _bat)) if btr == "untrusted": untrusted_w = Some(bw)
                Some(_) | None: Unit
              end
            end
          end
        end
        trust_tier = case untrusted_w
          Some(_): "untrusted"
          None: "trusted"
        end
        untrusted_src_opt = untrusted_w.map(fn(w) "page:#{pg.id}(#{w})" end)
        Ok(
          Json.Object({
            "page": pg.to_json,
            "blocks": blks.to_json,
            "anchored": Json.String(Blocks.to_anchored_markdown(blks)),
            "trust_tier": Json.String(trust_tier),
            "untrusted_src": untrusted_src_opt.to_json
          })
        )
      end
    )
    return case res
      Ok(res_j):
        untrusted_src_opt = res_j.text_at("untrusted_src")
        case untrusted_src_opt
          Some(src):
            _ts = try TaintBridge.record_untrusted_read_locked(
              files,
              Db.ledger_db_path,
              Db.vellum_schema(),
              sess_id,
              src,
              now
            )
          None: Unit
        end
        sess_json = try Ledger.read_locked(
          files.read_only,
          Db.ledger_db_path,
          Db.vellum_schema(),
          Db.map_ledger_error,
          fn(db)
            sopt = try TaintBridge.get_taint_session(Ledger.store(db), sess_id)
            Ok(sopt.map(fn(s) TaintBridge.taint_session_to_json(s) end).to_json)
          end
        )
        anchored = res_j.text_at("anchored") or ""
        trust_tier = res_j.text_at("trust_tier") or "trusted"
        payload = Json.Object({
          "page": res_j.get("page") or Json.Null,
          "blocks": res_j.get("blocks") or Json.Array([]),
          "anchored_markdown": Json.String(anchored),
          "trust_tier": Json.String(trust_tier),
          "taint_session": sess_json
        })
        Ok(Mcp.tool_ok(id, anchored, Some(payload)))
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.patch_blocks"
    pid = case args.text_at("page_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'page_id'"))
    end
    reason = case args.text_at("reason")
      Some(r) if not r.trim.empty?: r.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "non-empty 'reason' is required"))
    end
    (ops, exp_vers) = case decode_ops_and_versions(args)
      Ok(p): p
      Error(msg): return Ok(Mcp.tool_error(id, msg))
    end
    case authorize_mcp_write_locked(args, auth, files, "mcp.patch_blocks", now)
      Ok(_): Unit
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    new_ids = generate_insert_ids(ops, rng, clock)
    prov = make_provenance(auth, reason, now)
    meta = Ledger.WriteMeta(
      principal: auth.principal.handle,
      action: "mcp.patch_blocks",
      reason: reason,
      at: now
    )
    res = Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      meta,
      "mcp patched #{pid}",
      Json.Object({"page_id": Json.String(pid)}),
      Db.map_ledger_error,
      fn(tx)
        t1 = try tx_authorize_if_agent(tx, auth, "write_direct", now)
        old_pg = case try Table.tx_get(t1, Db.pages_table(), pid).map_error(Db.map_table_error)
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: pid))
        end
        try Policy.require_collection_access(auth, "write_direct", old_pg.collection_id)
        col = case try Table.tx_get(t1, Db.collections_table(), old_pg.collection_id).map_error(
          Db.map_table_error
        )
          Some(c): c
          None: return Error(Missing(entity: "collection", id: old_pg.collection_id))
        end
        if not Policy.can_write_page_direct?(auth, col)
          return Error(
            Forbidden(
              reason: "collection '#{col.slug}' requires Change Proposals; use vellum.proposal_open + vellum.proposal_stage_ops"
            )
          )
        end
        patch_args = WorldPatchArgs(
          page_id: pid,
          ops: ops,
          new_ids: new_ids,
          provenance: prov,
          expected_versions: exp_vers,
          updated_at: now
        )
        (t2, rep) = try Db.tx_apply_world_patch(t1, patch_args.to_json).map_error(fn(m)
          BadInput(reason: m)
        end)
        Ok((t2, Json.Object({"rep": rep, "collection_id": Json.String(old_pg.collection_id)})))
      end
    )
    return case res
      Ok(rj):
        rep = rj.get("rep") or Json.Null
        col_id = rj.text_at("collection_id") or ""
        blocks_ev = Json.Object({
          "page_id": Json.String(pid),
          "collection_id": Json.String(col_id),
          "actor": Json.String(auth.principal.handle),
          "reason": Json.String(reason)
        })
        Ok(
          Mcp.tool_ok(id, "Patched page #{pid}.", Some(rep))
            .with_sse_publish_json("page:#{pid}", "page.blocks_updated", blocks_ev)
            .with_sse_publish_json("collection:#{col_id}", "page.blocks_updated", blocks_ev)
        )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.claim_acquire"
    resource = case args.text_at("resource")
      Some(r) if not r.trim.empty?: r.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'resource'"))
    end
    reason = case args.text_at("reason")
      Some(r) if not r.trim.empty?: r.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'reason'"))
    end
    ttl = args.int_at("ttl_seconds") or 120
    if ttl < 10 or ttl > 3600
      return Ok(Mcp.tool_error(id, "ttl_seconds must be in 10..3600"))
    end
    if not Policy.action_permitted?(auth, "claim")
      return Ok(Mcp.tool_error(id, "grant '#{auth.grant_id}' does not permit 'claim'"))
    end
    meta = Ledger.WriteMeta(
      principal: auth.principal.handle,
      action: "mcp.claim_acquire",
      reason: reason,
      at: now
    )
    res = Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      meta,
      "mcp claim acquire #{resource}",
      Json.Object({"resource": Json.String(resource)}),
      Db.map_ledger_error,
      fn(tx)
        t1 = try tx_authorize_if_agent(tx, auth, "claim", now)
        (t2, cl) = try Claims.tx_acquire(
          t1,
          resource,
          auth.principal.id,
          auth.grant_id,
          None,
          reason,
          now,
          now + ttl.seconds
        ).map_error(Db.map_claims_error)
        Ok((t2, cl.to_json))
      end
    )
    return case res
      Ok(cl_json): Ok(
        Mcp.tool_ok(id, "Acquired claim on #{resource}.", Some(cl_json)).with_sse_publish_json(
          "claims",
          "claim.acquired",
          Json.Object({"claim": cl_json, "actor": Json.String(auth.principal.handle)})
        )
      )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.claim_release"
    resource = case args.text_at("resource")
      Some(r) if not r.trim.empty?: r.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'resource'"))
    end
    if not Policy.action_permitted?(auth, "claim")
      return Ok(Mcp.tool_error(id, "grant '#{auth.grant_id}' does not permit 'claim'"))
    end
    meta = Ledger.WriteMeta(
      principal: auth.principal.handle,
      action: "mcp.claim_release",
      reason: "release #{resource}",
      at: now
    )
    res = Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      meta,
      "mcp claim release #{resource}",
      Json.Object({"resource": Json.String(resource)}),
      Db.map_ledger_error,
      fn(tx)
        t1 = try tx_authorize_if_agent(tx, auth, "claim", now)
        t2 = try Claims.tx_release(t1, resource, auth.principal.id).map_error(Db.map_claims_error)
        Ok((t2, Unit))
      end
    )
    return case res
      Ok(_): Ok(
        Mcp.tool_ok(id, "Released claim on #{resource}.", None).with_sse_publish_json(
          "claims",
          "claim.released",
          Json.Object({
            "resource": Json.String(resource),
            "actor": Json.String(auth.principal.handle)
          })
        )
      )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.proposal_open"
    pid = case args.text_at("page_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'page_id'"))
    end
    title = case args.text_at("title")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'title'"))
    end
    reason = case args.text_at("reason")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'reason'"))
    end
    pg_res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        pg = case try Table.get(Ledger.store(db), Db.pages_table(), pid).map_error(
          Db.map_table_error
        )
          Some(p) if p.archived_at == None: p
          Some(_) | None: return Error(Missing(entity: "page", id: pid))
        end
        try Policy.require_collection_access(auth, "propose", pg.collection_id)
        Ok(pg)
      end
    )
    pg = case pg_res
      Ok(p): p
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    prop_id = "prop_#{Id.ulid(rng, clock)}"
    world_id = "w_#{Id.ulid(rng, clock)}"
    case World.open_world_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      world_id,
      auth.grant_id,
      now,
      now + 7.days
    ).map_error(Db.map_world_error)
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
      Ok(_): Unit
    end
    pm = ProposalMeta(
      id: prop_id,
      world_id: world_id,
      collection_id: pg.collection_id,
      target_page_id: pg.id,
      target_database_id: None,
      branch_kind: "proposal",
      title: title,
      reason: reason,
      author_id: auth.principal.id,
      author_handle: auth.principal.handle,
      grant_id: auth.grant_id,
      status: "open",
      created_at: now,
      updated_at: now,
      decided_by: None,
      decided_at: None
    )
    meta = Ledger.WriteMeta(
      principal: auth.principal.handle,
      action: "mcp.proposal_open",
      reason: reason,
      at: now
    )
    saved = try Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      meta,
      "mcp opened proposal #{prop_id}",
      Json.Object({"proposal_id": Json.String(prop_id)}),
      Db.map_ledger_error,
      fn(tx)
        t1 = try tx_authorize_if_agent(tx, auth, "propose", now)
        t2 = try Db.tx_put_proposal(t1, pm)
        Ok((t2, pm))
      end
    )
    prop_ev = Json.Object({
      "proposal_id": Json.String(saved.id),
      "page_id": Json.String(saved.target_page_id),
      "collection_id": Json.String(saved.collection_id),
      "title": Json.String(saved.title),
      "actor": Json.String(auth.principal.handle)
    })
    return Ok(
      Mcp.tool_ok(id, "Opened proposal #{saved.id}.", Some(saved.to_json))
        .with_sse_publish_json("collection:#{saved.collection_id}", "proposal.opened", prop_ev)
        .with_sse_publish_json("page:#{saved.target_page_id}", "proposal.opened", prop_ev)
    )
  end

  if name == "vellum.proposal_stage_ops"
    prop_id = case args.text_at("proposal_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'proposal_id'"))
    end
    reason = case args.text_at("reason")
      Some(r) if not r.trim.empty?: r.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'reason'"))
    end
    (ops, exp_vers) = case decode_ops_and_versions(args)
      Ok(p): p
      Error(msg): return Ok(Mcp.tool_error(id, msg))
    end
    pm_res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        found = case try Table.get(Ledger.store(db), Db.proposals_table(), prop_id).map_error(
          Db.map_table_error
        )
          Some(p): p
          None: return Error(Missing(entity: "proposal", id: prop_id))
        end
        try Policy.require_collection_access(auth, "propose", found.collection_id)
        Ok(found)
      end
    )
    pm = case pm_res
      Ok(p): p
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    if pm.status != "open" or pm.author_id != auth.principal.id
      return Ok(Mcp.tool_error(id, "proposal '#{prop_id}' must be open and authored by caller"))
    end
    new_ids = generate_insert_ids(ops, rng, clock)
    prov = make_provenance(auth, reason, now)
    wargs = WorldPatchArgs(
      page_id: pm.target_page_id,
      ops: ops,
      new_ids: new_ids,
      provenance: prov,
      expected_versions: exp_vers,
      updated_at: now
    )
    return case World.world_call_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.world_catalog(),
      pm.world_id,
      "propose",
      wargs.to_json,
      reason,
      now
    ).map_error(Db.map_world_error)
      Ok(rep): Ok(Mcp.tool_ok(id, "Staged #{ops.size} ops on #{pm.id}.", Some(rep)))
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.proposal_diff"
    prop_id = case args.text_at("proposal_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'proposal_id'"))
    end
    pm_res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        found = case try Table.get(Ledger.store(db), Db.proposals_table(), prop_id).map_error(
          Db.map_table_error
        )
          Some(p): p
          None: return Error(Missing(entity: "proposal", id: prop_id))
        end
        try Policy.require_collection_access(auth, "read", found.collection_id)
        Ok(found)
      end
    )
    pm = case pm_res
      Ok(p): p
      Error(e): return Ok(Mcp.tool_error(id, e.to_text))
    end
    return case World.world_diff_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.world_catalog(),
      pm.world_id
    ).map_error(Db.map_world_error)
      Ok(diffs): Ok(Mcp.tool_ok(id, "Computed diff for #{pm.id}.", Some(diffs.to_json)))
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.db_query"
    db_id = case args.text_at("database_id")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'database_id'"))
    end
    filters = case args.get("filters")
      None | Some(Json.Null): []
      Some(fj):
        case DatabaseModel.decode_filter_rules_json(fj.to_text.bytes)
          Ok(fs): fs
          Error(e): return Ok(Mcp.tool_error(id, "invalid filters: #{e}"))
        end
    end
    sorts = case args.get("sorts")
      None | Some(Json.Null): []
      Some(sj):
        case DatabaseModel.decode_sort_rules_json(sj.to_text.bytes)
          Ok(ss): ss
          Error(e): return Ok(Mcp.tool_error(id, "invalid sorts: #{e}"))
        end
    end
    read_act = if Policy.action_permitted?(auth, "query_db"): "query_db" else: "read"
    qres = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        def = case try Table.get(store, Db.databases_table(), db_id).map_error(Db.map_table_error)
          Some(d): d
          None: return Error(Missing(entity: "database", id: db_id))
        end
        try Policy.require_collection_access(auth, read_act, def.collection_id)
        pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def.id)
          .map_error(Db.map_table_error)
        active = pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end)
        enriched = try Db.enrich_rows_with_rollups(store, def, active)
        filtered = enriched.filter(fn(er)
          DatabaseModel.matches_filters?(er, filters, true)
        end)
        sorted = DatabaseModel.sort_enriched_rows(filtered, sorts)
        Ok(
          Json.Object({
            "vq": ViewQueryResult(view: None, rows: sorted, board_groups: None, total_count: sorted.size).to_json,
            "total_count": Json.int(sorted.size)
          })
        )
      end
    )
    return case qres
      Ok(qj):
        cnt = qj.int_at("total_count") or 0
        vq_j = qj.get("vq") or Json.Null
        Ok(Mcp.tool_ok(id, "Returned #{cnt} rows.", Some(vq_j)))
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.db_schema"
    return handle_mcp_db_schema(id, args, auth, files)
  end

  if name == "vellum.db_create_row"
    return handle_mcp_db_create_row(id, args, auth, files, rng, clock, now)
  end

  if name == "vellum.db_update_row"
    return handle_mcp_db_update_row(id, args, auth, files, rng, clock, now)
  end

  if name == "vellum.db_propose_changes"
    return handle_mcp_db_propose_changes(id, args, auth, files, rng, clock, now)
  end

  if name == "vellum.proposal_comments"
    return handle_mcp_proposal_comments(id, args, auth, files)
  end

  if name == "vellum.list_summaries"
    col_f = case args.text_at("collection_id")
      Some(s) if not s.trim.empty?: Some(s.trim)
      Some(_) | None: None
    end
    kind_f = case args.text_at("kind")
      Some(s) if not s.trim.empty?: Some(s.trim)
      Some(_) | None: None
    end
    res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        sums = try Packs.list_permitted_summaries(Ledger.store(db), auth, col_f, kind_f)
        Ok(Json.Object({"summaries": sums.to_json, "count": Json.int(sums.size)}))
      end
    )
    return case res
      Ok(sj):
        cnt = sj.int_at("count") or 0
        sums_j = sj.get("summaries") or Json.Array([])
        Ok(
          Mcp.tool_ok(id, "Returned #{cnt} living summaries.", Some(Json.Object({"summaries": sums_j})))
        )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.list_packs"
    res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        pks = try Packs.list_permitted_packs(Ledger.store(db), auth)
        Ok(Json.Object({"packs": pks.to_json, "count": Json.int(pks.size)}))
      end
    )
    return case res
      Ok(pj):
        cnt = pj.int_at("count") or 0
        pks_j = pj.get("packs") or Json.Array([])
        Ok(
          Mcp.tool_ok(id, "Returned #{cnt} context packs.", Some(Json.Object({"packs": pks_j})))
        )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.read_pack"
    slug = case args.text_at("slug")
      Some(s) if not s.trim.empty?: s.trim
      Some(_) | None: return Ok(Mcp.tool_error(id, "missing 'slug'"))
    end
    q_hint = case args.text_at("q")
      Some(s) if not s.trim.empty?: Some(s.trim)
      Some(_) | None: None
    end
    res = Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        compiled = try Packs.compile_pack_from_store(Ledger.store(db), auth, slug, q_hint, now)
        Ok(
          Json.Object({
            "slug": Json.String(compiled.pack.slug),
            "tokens_used": Json.int(compiled.tokens_used),
            "token_budget": Json.int(compiled.token_budget),
            "markdown": Json.String(compiled.markdown),
            "json": compiled.to_json
          })
        )
      end
    )
    return case res
      Ok(cj):
        c_slug = cj.text_at("slug") or slug
        tok_used = cj.int_at("tokens_used") or 0
        tok_budget = cj.int_at("token_budget") or 0
        c_md = cj.text_at("markdown") or ""
        Ok(
          Mcp.tool_ok(
            id,
            "Compiled pack '#{c_slug}' (#{tok_used}/#{tok_budget} tok).\n\n#{c_md}",
            Some(cj.get("json") or Json.Null)
          )
        )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
  end

  if name == "vellum.rlm_query"
    return handle_mcp_rlm_query(id, args, auth, files, clock, env, net)
  end

  Ok(Mcp.tool_error(id, "unhandled tool '#{name}'"))
end

fn handle_resource_read(
  id: Mcp.RpcId,
  uri: Text,
  auth: AuthContext,
  rf: ReadFiles,
  clock: Clock
) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Ok(
      Mcp.json_rpc_error(id, Mcp.RpcError(code: -32003, message: "read not permitted", data: None))
    )
  end

  if uri == "vellum://index"
    idx_res = Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db) Packs.render_llms_txt_from_store(Ledger.store(db), auth) end
    )
    return case idx_res
      Ok(md): Ok(
        Mcp.resource_response(
          id,
          [Mcp.ResourceContent(uri: uri, mime_type: "text/markdown", text: md)]
        )
      )
      Error(e): Ok(Mcp.json_rpc_error(id, Mcp.RpcError(code: -32004, message: e.to_text, data: None)))
    end
  end

  case uri.drop_prefix("vellum://packs/")
    Some(slug) if not slug.trim.empty?:
      now = clock.now
      pk_res = Ledger.read_locked(
        rf,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          compiled = try Packs.compile_pack_from_store(Ledger.store(db), auth, slug.trim, None, now)
          Ok(Json.Object({"markdown": Json.String(compiled.markdown)}))
        end
      )
      return case pk_res
        Ok(pj): Ok(
          Mcp.resource_response(
            id,
            [Mcp.ResourceContent(uri: uri, mime_type: "text/markdown", text: pj.text_at("markdown") or "")]
          )
        )
        Error(e): Ok(
          Mcp.json_rpc_error(id, Mcp.RpcError(code: -32004, message: e.to_text, data: None))
        )
      end
    Some(_) | None: Unit
  end

  if uri == "vellum://workspace/overview"
    overview = try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        cols = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        vis_cols = cols.filter(fn(p)
          p.1.archived_at == None and Policy.collection_permitted?(auth, p.1.id)
        end).map(fn(p) p.1 end)
        dbs = try Table.scan(store, Db.databases_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        vis_dbs = dbs.filter(fn(p) Policy.collection_permitted?(auth, p.1.collection_id) end).map(
          fn(p) p.1 end
        )
        Ok(Json.Object({"collections": vis_cols.to_json, "databases": vis_dbs.to_json}).to_text)
      end
    )
    return Ok(
      Mcp.resource_response(
        id,
        [Mcp.ResourceContent(uri: uri, mime_type: "application/json", text: overview)]
      )
    )
  end

  case uri.drop_prefix("vellum://pages/")
    Some(pid) if not pid.trim.empty?:
      page_res = Ledger.read_locked(
        rf,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          store = Ledger.store(db)
          pg = case try Table.get(store, Db.pages_table(), pid.trim).map_error(Db.map_table_error)
            Some(p) if p.archived_at == None: p
            Some(_) | None: return Error(Missing(entity: "page", id: pid.trim))
          end
          try Policy.require_collection_access(auth, "read", pg.collection_id)
          blks = try Db.load_page_blocks(store, pg.id)
          Ok(Blocks.to_anchored_markdown(blks))
        end
      )
      return case page_res
        Ok(md): Ok(
          Mcp.resource_response(
            id,
            [Mcp.ResourceContent(uri: uri, mime_type: "text/markdown", text: md)]
          )
        )
        Error(e): Ok(
          Mcp.json_rpc_error(id, Mcp.RpcError(code: -32004, message: e.to_text, data: None))
        )
      end
    Some(_) | None: Ok(
      Mcp.json_rpc_error(
        id,
        Mcp.RpcError(
          code: Mcp.err_invalid_params,
          message: "unknown resource URI '#{uri}'",
          data: None
        )
      )
    )
  end
end

## `POST /mcp` — Authenticated Streamable HTTP MCP endpoint for external AI agents.
fn handle_mcp(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  resources = vellum_resources_for(auth, files.read_only)
  case Mcp.dispatch(req, vellum_server_info(), vellum_tools(), resources)
    Mcp.Respond(res): Ok(res)
    Mcp.CallTool(id: rpc_id, name: tool_name, arguments: args): handle_tool_call(
      rpc_id,
      tool_name,
      args,
      auth,
      files,
      rng,
      clock,
      env,
      net
    )
    Mcp.ReadResource(id: rpc_id, uri: uri): handle_resource_read(
      rpc_id,
      uri,
      auth,
      files.read_only,
      clock
    )
  end
end
