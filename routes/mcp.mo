## Streamable HTTP `/mcp` server handler powered by `Arvo.Mcp`, `Modb.Claims`,
## `Modb.World`, `Modb.Fts`, `Domain.Blocks`, and `Domain.DatabaseModel`.
module Routes.Mcp
expose handle_mcp
use Api
use Arvo.Id
use Arvo.Mcp
use Db
use Domain.Blocks
use Domain.Collab{ProposalMeta, WorldPatchArgs}
use Domain.DatabaseModel{DbFilterRule, DbSortRule, ViewQueryResult}
use Domain.Policy
use Domain.Types{AppError, AuthContext, AuthorKind, BlockOp, PrincipalKind, Provenance}
use Json
use Modb{WriteTx}
use Modb.Claims
use Modb.Grants
use Modb.Ledger
use Modb.Table
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
      description: "Hybrid BM25 + semantic Modb.Vec search across accessible pages and database rows.",
      input_schema: Mcp.object_schema(
        {
          "q": str_prop("Search query"),
          "collection_id": str_prop("Optional collection filter"),
          "mode": str_prop("Optional mode: 'hybrid' (default), 'bm25', or 'semantic'")
        },
        ["q"]
      ),
      read_only?: true
    ),
    Mcp.ToolDef(
      name: "vellum.read_page",
      description: "Read page metadata and lossless anchored Markdown (with stable blk IDs).",
      input_schema: Mcp.object_schema({"page_id": str_prop("Target page ID")}, ["page_id"]),
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
          "reason": str_prop("Audit reason for this mutation")
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
    fn(db) Packs.list_permitted_packs(Ledger.store(db), auth) end
  )
  case pack_res
    Error(_): base
    Ok(pks):
      var out = base
      for pk in pks
        out = out.append(
          Mcp.ResourceDef(
            uri: "vellum://packs/#{pk.slug}",
            name: pk.name,
            description: "Context Pack (#{pk.token_budget} tok): #{pk.description}",
            mime_type: "text/markdown"
          )
        )
      end
      out
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

fn decode_ops_and_versions(args: Json) : Result((List(BlockOp), Map(Text, Int)), Text)
  ops_json = try args.get("ops").or_fail("missing 'ops' array")
  ops = try Json.decode_strict[List(BlockOp)](ops_json.to_text.bytes).map_error(fn(e) e.to_text end)
  exp_vers = case args.get("expected_versions")
    None | Some(Json.Null): {}
    Some(ev): try Json.decode_strict[Map(Text, Int)](ev.to_text.bytes).map_error(
      fn(e) e.to_text end
    )
  end
  Ok((ops, exp_vers))
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
    cols = try Ledger.read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        rows = try Table.scan(Ledger.store(db), Db.collections_table(), None, None, 200).map_error(
          Db.map_table_error
        )
        Ok(
          rows.filter(fn(p)
            p.1.archived_at == None and Policy.collection_permitted?(auth, p.1.id)
          end).map(fn(p) p.1 end)
        )
      end
    )
    return Ok(
      Mcp.tool_ok(
        id,
        "Found #{cols.size} collections.",
        Some(Json.Object({"collections": cols.to_json}))
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
    col_filter = args.text_at("collection_id")
    mode_arg = args.text_at("mode")
    out = case Ai.execute_workspace_search(
      files.read_only,
      auth,
      q,
      20,
      true,
      col_filter,
      mode_arg,
      env,
      net
    )
      Ok(o): o
      Error(BadInput(reason: msg)): return Ok(Mcp.tool_error(id, msg))
      Error(e): return Error(e)
    end
    return Ok(
      Mcp.tool_ok(
        id,
        "Found #{out.results.size} #{out.mode} (#{out.vector_backend}) search hits.",
        Some(
          Json.Object({
            "results": out.results.to_json,
            "mode": Json.String(out.mode),
            "vector_backend": Json.String(out.vector_backend)
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
        Ok(
          Json.Object({
            "page": pg.to_json,
            "blocks": blks.to_json,
            "anchored_markdown": Json.String(Blocks.to_anchored_markdown(blks))
          })
        )
      end
    )
    return case res
      Ok(payload): Ok(Mcp.tool_ok(id, payload.text_at("anchored_markdown") or "", Some(payload)))
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
        Ok((t2, (rep, old_pg.collection_id)))
      end
    )
    return case res
      Ok((rep, col_id)):
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
        Ok((t2, cl))
      end
    )
    return case res
      Ok(cl): Ok(
        Mcp.tool_ok(id, "Acquired claim on #{resource}.", Some(cl.to_json)).with_sse_publish_json(
          "claims",
          "claim.acquired",
          Json.Object({"claim": cl.to_json, "actor": Json.String(auth.principal.handle)})
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
        t2 = try Table.put(t1, Db.proposals_table(), pm.id, pm).map_error(Db.map_table_error)
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
        case Json.decode_strict[List(DbFilterRule)](fj.to_text.bytes)
          Ok(fs): fs
          Error(e): return Ok(Mcp.tool_error(id, "invalid filters: #{e.to_text}"))
        end
    end
    sorts = case args.get("sorts")
      None | Some(Json.Null): []
      Some(sj):
        case Json.decode_strict[List(DbSortRule)](sj.to_text.bytes)
          Ok(ss): ss
          Error(e): return Ok(Mcp.tool_error(id, "invalid sorts: #{e.to_text}"))
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
        Ok(ViewQueryResult(view: None, rows: sorted, board_groups: None, total_count: sorted.size))
      end
    )
    return case qres
      Ok(vq): Ok(Mcp.tool_ok(id, "Returned #{vq.total_count} rows.", Some(vq.to_json)))
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
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
      fn(db) Packs.list_permitted_summaries(Ledger.store(db), auth, col_f, kind_f) end
    )
    return case res
      Ok(sums): Ok(
        Mcp.tool_ok(id, "Returned #{sums.size} living summaries.", Some(Json.Object({"summaries": sums.to_json})))
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
      fn(db) Packs.list_permitted_packs(Ledger.store(db), auth) end
    )
    return case res
      Ok(pks): Ok(
        Mcp.tool_ok(id, "Returned #{pks.size} context packs.", Some(Json.Object({"packs": pks.to_json})))
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
      fn(db) Packs.compile_pack_from_store(Ledger.store(db), auth, slug, q_hint, now) end
    )
    return case res
      Ok(compiled): Ok(
        Mcp.tool_ok(
          id,
          "Compiled pack '#{compiled.pack.slug}' (#{compiled.tokens_used}/#{compiled.token_budget} tok).\n\n#{compiled.markdown}",
          Some(compiled.to_json)
        )
      )
      Error(e): Ok(Mcp.tool_error(id, e.to_text))
    end
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
        fn(db) Packs.compile_pack_from_store(Ledger.store(db), auth, slug.trim, None, now) end
      )
      return case pk_res
        Ok(compiled): Ok(
          Mcp.resource_response(
            id,
            [Mcp.ResourceContent(uri: uri, mime_type: "text/markdown", text: compiled.markdown)]
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
