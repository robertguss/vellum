## Built-in configurable AI workflows (OpenAI, Anthropic, or local OpenAI-compatible gateway):
## grant-filtered Hybrid (BM25 + Modb.Vec) Ask Workspace with block citations + SSE streaming,
## OpenAI-compatible `/v1/embeddings` client + workspace hybrid search orchestrator,
## Draft-into-Proposal, and Knowledge Gardening.
module Routes.Ai
expose AiConfig(..),
EmbedConfig(..),
WorkspaceSearchOutcome(..),
AskWorkspaceInput(..),
DraftBlockInput(..),
RefreshAiBriefInput(..),
RunAiColumnInput(..),
GardenStalePage(..),
GardenBrokenLink(..),
GardenReport(..),
ai_config,
embed_config,
build_llm_request,
build_llm_request_with_stream,
build_embedding_request,
fetch_embedding,
generate_semantic_summary,
execute_workspace_search,
ask_workspace,
draft_blocks,
refresh_ai_brief,
build_ai_column_prompts,
run_ai_column,
ai_columns_status,
sync_ai_column_feed,
run_garden,
garden_job
use Api
use Arvo.Id
use Db
use Domain.Blocks
use Domain.Collab{ProposalMeta, WorldBranchArgs, WorldMutation, WorldPatchArgs}
use Domain.DatabaseModel{
  AiCellMeta,
  AiColumnMode,
  AiColumnUsage,
  AiOutputKind,
  CellValue,
  DatabaseDef,
  DbRow,
  PropertyDef,
  PropertyKind
}
use Domain.Policy
use Domain.Types{
  AppError,
  AuthContext,
  AuthorKind,
  Block,
  BlockKind,
  BlockOp,
  Citation,
  CollectionWritePolicy,
  Page,
  PrincipalKind,
  Provenance,
  SearchResultItem
}
use Http
use Json
use Modb{Store}
use Modb.Feeds
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Modb.Vec
use Modb.World
use Routes.Auth
use Routes.Packs

## Runtime configuration for Vellum's built-in LLM client.
struct AiConfig
  provider: Text
  api_key: Text
  base_url: Text
  model: Text
end

## Optional runtime configuration for OpenAI-compatible neural `/v1/embeddings`.
struct EmbedConfig
  api_key: Text
  base_url: Text
  model: Text
  dimensions: Int
  min_score: Float
end

## Unified hybrid/BM25/semantic search response metadata returned by `execute_workspace_search`.
struct WorkspaceSearchOutcome
  results: List(SearchResultItem)
  mode: Text
  vector_backend: Text
end

## JSON payload for `POST /api/ai/ask`.
struct AskWorkspaceInput
  question: Text
  collection_id: Option(Text)
  max_sources: Option(Int)
  stream: Option(Bool)
end

## JSON payload for `POST /api/ai/draft`.
struct DraftBlockInput
  page_id: Text
  instruction: Text
  as_proposal: Option(Bool)
end

## Page past its `freshness_ttl_days` verification window.
struct GardenStalePage
  page_id: Text
  collection_id: Text
  title: Text
  days_since_verified: Int
  ttl_days: Int
end

## Broken internal `[[target_page_id|label]]` reference detected during Knowledge Gardening.
struct GardenBrokenLink
  source_page_id: Text
  source_title: Text
  block_id: Text
  target_page_id: Text
  label: Text
end

## Workspace health summary produced by `GET /api/admin/garden` and `vellum.garden`.
struct GardenReport
  checked_pages: Int
  stale_pages: List(GardenStalePage)
  broken_links: List(GardenBrokenLink)
  scanned_at: Time
end

fn json_ok(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

## Loads LLM provider config from environment variables (fail-closed if `VELLUM_AI_API_KEY` missing).
fn ai_config(env: Env) : Result(AiConfig, AppError)
  api_key = try env.get("VELLUM_AI_API_KEY").or_fail(
    ServerFailed(reason: "missing VELLUM_AI_API_KEY env var")
  )
  if api_key.trim.empty?
    return Error(ServerFailed(reason: "VELLUM_AI_API_KEY must not be empty"))
  end
  provider = case env.get("VELLUM_AI_PROVIDER")
    Some(p) if not p.trim.empty?: p.trim.ascii_lowercase
    Some(_) | None: "openai"
  end
  if provider != "openai" and provider != "anthropic"
    return Error(ServerFailed(reason: "VELLUM_AI_PROVIDER must be 'openai' or 'anthropic'"))
  end
  base_url = case env.get("VELLUM_AI_BASE_URL")
    Some(u) if not u.trim.empty?: u.trim
    Some(_) | None:
      if provider == "anthropic"
        "https://api.anthropic.com/v1/messages"
      else
        "https://api.openai.com/v1/chat/completions"
      end
  end
  model = case env.get("VELLUM_AI_MODEL")
    Some(m) if not m.trim.empty?: m.trim
    Some(_) | None: if provider == "anthropic": "claude-sonnet-4-6" else: "gpt-4o-mini"
  end
  Ok(AiConfig(provider: provider, api_key: api_key.trim, base_url: base_url, model: model))
end

fn non_empty_env(env: Env, key: Text) : Option(Text)
  case env.get(key)
    Some(v) if not v.trim.empty?: Some(v.trim)
    Some(_) | None: None
  end
end

## Loads neural embedding configuration when explicitly opted in via `VELLUM_EMBED_BASE_URL`,
## `VELLUM_EMBED_MODEL`, or `VELLUM_EMBED_API_KEY`.
fn embed_config(env: Env) : Option(EmbedConfig)
  base_opt = non_empty_env(env, "VELLUM_EMBED_BASE_URL")
  model_opt = non_empty_env(env, "VELLUM_EMBED_MODEL")
  embed_key_opt = non_empty_env(env, "VELLUM_EMBED_API_KEY")
  if base_opt is None and model_opt is None and embed_key_opt is None
    return None
  end
  api_key = case embed_key_opt
    Some(k): k
    None:
      case non_empty_env(env, "VELLUM_AI_API_KEY")
        Some(k): k
        None: return None
      end
  end
  base_url = base_opt or "https://api.openai.com/v1/embeddings"
  model = model_opt or "text-embedding-3-small"
  dims = case env.get("VELLUM_EMBED_DIMENSIONS")
    Some(raw):
      case raw.trim.to_int
        Some(n) if n >= 1 and n <= 4096: n
        Some(_) | None: 256
      end
    None: 256
  end
  Some(
    EmbedConfig(
      api_key: api_key,
      base_url: base_url,
      model: model,
      dimensions: dims,
      min_score: 0.25.to_float
    )
  )
end

## Builds the signed HTTP request for OpenAI-compatible `POST /v1/embeddings`.
fn build_embedding_request(cfg: EmbedConfig, input_text: Text) : Http.Request
  Http.post(cfg.base_url).json(
    Json.Object({
      "model": Json.String(cfg.model),
      "input": Json.String(input_text),
      "dimensions": Json.int(cfg.dimensions)
    })
  ).header("Authorization", "Bearer #{cfg.api_key}")
end

## Requests a neural embedding vector from the configured `/v1/embeddings` endpoint and validates dimensions.
fn fetch_embedding(cfg: EmbedConfig, input_text: Text, net: Network) : Result(
  List(Float),
  AppError
)
  clean = input_text.trim
  if clean.empty?
    return Error(BadInput(reason: "embedding input text must not be empty"))
  end
  http_res = try Http.send(build_embedding_request(cfg, clean), net).map_error(fn(e)
    ServerFailed(reason: "Embedding HTTP request failed: #{e.to_text}")
  end)
  if http_res.status < 200 or http_res.status >= 300
    return Error(ServerFailed(reason: "Embedding provider returned HTTP #{http_res.status}"))
  end
  parsed = try Json.decode_strict[Json](http_res.body).map_error(fn(e)
    ServerFailed(reason: "invalid embedding JSON response: #{e.to_text}")
  end)
  raw_list = case parsed.list_at("data.0.embedding")
    Some(xs): xs
    None: return Error(ServerFailed(reason: "embedding response missing data.0.embedding array"))
  end
  var vec = []
  for item in raw_list
    case item
      Json.Number(num):
        case num.to_float
          Some(f) if not f.nan? and not f.infinite?: vec = vec.append(f)
          Some(_) | None: return Error(
            ServerFailed(reason: "embedding vector contains non-finite float value")
          )
        end
      Json.Null | Json.Boolean(_) | Json.String(_) | Json.Array(_) | Json.Object(_): return Error(
        ServerFailed(reason: "embedding vector element is not a number")
      )
    end
  end
  if vec.size != cfg.dimensions
    return Error(
      ServerFailed(
        reason: "embedding dimension mismatch: expected #{cfg.dimensions}, got #{vec.size}"
      )
    )
  end
  Ok(vec)
end

## Builds the signed HTTP request for either OpenAI-compatible chat completions or Anthropic
## messages, optionally setting `"stream": true` for SSE delta streaming.
fn build_llm_request_with_stream(
  cfg: AiConfig,
  system_prompt: Text,
  user_prompt: Text,
  stream?: Bool
) : Http.Request
  if cfg.provider == "anthropic"
    var fields = {
      "model": Json.String(cfg.model),
      "max_tokens": Json.int(1024),
      "system": Json.String(system_prompt),
      "messages": Json.Array([
        Json.Object({"role": Json.String("user"), "content": Json.String(user_prompt)})
      ])
    }
    if stream?
      fields = fields.set("stream", Json.Boolean(true))
    end
    Http.post(cfg.base_url).json(Json.Object(fields)).header("x-api-key", cfg.api_key).header(
      "anthropic-version",
      "2023-06-01"
    )
  else
    var fields = {
      "model": Json.String(cfg.model),
      "messages": Json.Array([
        Json.Object({"role": Json.String("system"), "content": Json.String(system_prompt)}),
        Json.Object({"role": Json.String("user"), "content": Json.String(user_prompt)})
      ])
    }
    if stream?
      fields = fields.set("stream", Json.Boolean(true))
    end
    Http.post(cfg.base_url).json(Json.Object(fields)).header("Authorization", "Bearer #{cfg.api_key}")
  end
end

## Builds the non-streaming signed HTTP request for OpenAI-compatible or Anthropic completions.
fn build_llm_request(cfg: AiConfig, system_prompt: Text, user_prompt: Text) : Http.Request
  build_llm_request_with_stream(cfg, system_prompt, user_prompt, false)
end

fn extract_llm_text(cfg: AiConfig, body: Bytes) : Result(Text, AppError)
  parsed = try Json.decode_strict[Json](body).map_error(fn(e)
    ServerFailed(reason: "invalid LLM JSON response: #{e.to_text}")
  end)
  txt_opt = if cfg.provider == "anthropic"
    parsed.text_at("content.0.text")
  else
    parsed.text_at("choices.0.message.content")
  end
  case txt_opt
    Some(t): Ok(t)
    None: Error(ServerFailed(reason: "LLM response missing assistant text content"))
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

fn normalize_search_mode(raw: Option(Text)) : Result(Text, AppError)
  case raw
    None: Ok("hybrid")
    Some(s):
      m = s.trim.ascii_lowercase
      if m.empty? or m == "hybrid"
        Ok("hybrid")
      else if m == "bm25" or m == "semantic"
        Ok(m)
      else
        Error(BadInput(reason: "search mode must be 'hybrid', 'bm25', or 'semantic'"))
      end
  end
end

## Executes fail-closed grant-filtered hybrid (`Modb.Fts` + `Modb.Vec` RRF), `bm25`, or `semantic` search
## strictly using `ReadFiles`, selecting the neural vector index when populated and gracefully falling
## back to the local 256-dim `Modb.Vec` sketch index otherwise (never calling external HTTP inside a lock).
fn execute_workspace_search(
  rf: ReadFiles,
  auth: AuthContext,
  query: Text,
  limit: Int,
  prefix_last?: Bool,
  collection_filter: Option(Text),
  raw_mode: Option(Text),
  env: Env,
  net: Network
) : Result(WorkspaceSearchOutcome, AppError)
  mode = try normalize_search_mode(raw_mode)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = query.trim
  if q.empty? or not rf.exists?(Db.ledger_db_path)
    empty_backend = if mode == "bm25": "none" else: "sketch"
    return Ok(WorkspaceSearchOutcome(results: [], mode: mode, vector_backend: empty_backend))
  end

  if mode == "bm25"
    hits = try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db) Db.search_pages(Ledger.store(db), auth, q, limit, prefix_last?, collection_filter) end
    )
    return Ok(WorkspaceSearchOutcome(results: hits, mode: "bm25", vector_backend: "none"))
  end

  (qv_opt, vec_idx, backend_label, min_vec_score) = case embed_config(env)
    None: (
      Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
      Db.sketch_vec_index(),
      "sketch",
      Some(Db.sketch_min_vec_score)
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
        case fetch_embedding(ecfg, q, net)
          Ok(qv): (Some(qv), Db.neural_vec_index(ecfg.dimensions), "neural", Some(ecfg.min_score))
          Error(_): (
            Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
            Db.sketch_vec_index(),
            "sketch",
            Some(Db.sketch_min_vec_score)
          )
        end
      else
        (
          Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
          Db.sketch_vec_index(),
          "sketch",
          Some(Db.sketch_min_vec_score)
        )
      end
  end

  hits = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      Db.search_pages_hybrid(
        Ledger.store(db),
        auth,
        q,
        qv_opt,
        vec_idx,
        mode,
        limit,
        prefix_last?,
        collection_filter,
        min_vec_score
      )
    end
  )
  Ok(WorkspaceSearchOutcome(results: hits, mode: mode, vector_backend: backend_label))
end

## `POST /api/ai/ask` — Grant-filtered Hybrid (BM25 + `Modb.Vec`) context retrieval + LLM synthesis (JSON or SSE stream, `ReadFiles`-only).
fn ask_workspace(
  req: Api.Request,
  auth: AuthContext,
  input: AskWorkspaceInput,
  rf: ReadFiles,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = input.question.trim
  if q.empty?
    return Error(BadInput(reason: "question must not be empty"))
  end
  cfg = try ai_config(env)
  max_src = case input.max_sources
    Some(n) if n >= 1 and n <= 10: n
    Some(_) | None: 5
  end

  search_out = try execute_workspace_search(
    rf,
    auth,
    q,
    max_src,
    true,
    input.collection_id,
    Some("hybrid"),
    env,
    net
  )
  (citations, context_lines) = if search_out.results.empty? or not rf.exists?(Db.ledger_db_path)
    ([], [])
  else
    try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        var cites = []
        var ctx = []
        for hit in search_out.results
          blks = try Db.load_page_blocks(store, hit.page_id)
          first_blk = blks.first
          excerpt = case first_blk
            Some(b): b.markdown
            None: hit.title
          end
          blk_id = case first_blk
            Some(b): b.id
            None: "page"
          end
          cites = cites.append(
            Json.Object({
              "page_id": Json.String(hit.page_id),
              "collection_id": Json.String(hit.collection_id),
              "block_id": Json.String(blk_id),
              "title": Json.String(hit.title),
              "excerpt": Json.String(excerpt)
            })
          )
          ctx = ctx.append("[#{hit.title} §#{blk_id}]\n#{Blocks.blocks_plain_text(blks)}")
        end
        Ok((cites, ctx))
      end
    )
  end

  sys_prompt = "You are Vellum Workspace Assistant. Answer strictly from the provided workspace excerpts and cite [Title §block_id]."
  ctx_body = if context_lines.empty?
    "(No permitted workspace excerpts matched this query.)"
  else
    context_lines.join("\n\n---\n\n")
  end
  usr_prompt = "Question: #{q}\n\nWorkspace Sources:\n#{ctx_body}"

  accept = (req.header("Accept") or "").ascii_lowercase
  wants_sse? = input.stream == Some(true) or accept.contains?("text/event-stream")
  if wants_sse?
    stream_req = build_llm_request_with_stream(cfg, sys_prompt, usr_prompt, true)
    relay_mode = if cfg.provider == "anthropic": "anthropic_sse" else: "openai_sse"
    body_text = stream_req.body.decode_utf8 or ""
    var citation_events = []
    for c in citations
      citation_events = citation_events.append((Some("ai.citation"), c.to_text))
    end
    relay = Api.SseRelay(
      method: stream_req.method,
      url: stream_req.url,
      headers: stream_req.headers,
      body: body_text,
      mode: relay_mode,
      idle_timeout_ms: 60000,
      token_event: Some("ai.token"),
      done_event: Some("ai.done"),
      done_data: Some(Json.Object({"model": Json.String(cfg.model)}).to_text),
      error_event: Some("ai.error")
    )
    return Ok(Api.sse_relay_stream(citation_events, relay))
  end

  http_req = build_llm_request(cfg, sys_prompt, usr_prompt)
  http_res = try Http.send(http_req, net).map_error(fn(e)
    ServerFailed(reason: "LLM HTTP request failed: #{e.to_text}")
  end)
  if http_res.status < 200 or http_res.status >= 300
    return Error(ServerFailed(reason: "LLM provider returned HTTP #{http_res.status}"))
  end
  answer = try extract_llm_text(cfg, http_res.body)

  Ok(
    json_ok(
      200,
      Json.Object({
        "answer": Json.String(answer),
        "model": Json.String(cfg.model),
        "citations": Json.Array(citations)
      })
    )
  )
end

## `POST /api/ai/draft` — Drafts blocks via the configured LLM, optionally isolating them inside a `Modb.World` proposal.
fn draft_blocks(
  req: Api.Request,
  auth: AuthContext,
  input: DraftBlockInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  inst = input.instruction.trim
  if inst.empty?
    return Error(BadInput(reason: "instruction must not be empty"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: input.page_id))
  end

  (page, existing_blocks) = try Ledger.read_locked(
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
      try Policy.require_collection_access(auth, "read", pg.collection_id)
      blks = try Db.load_page_blocks(store, pg.id)
      Ok((pg, blks))
    end
  )

  cfg = try ai_config(env)
  sys_prompt = "You draft concise Markdown sections for Vellum documents. Output Markdown blocks only."
  usr_prompt = "Page: #{page.title}\nExisting content:\n#{Blocks.to_anchored_markdown(
    existing_blocks
  )}\n\nInstruction: #{inst}"
  http_res = try Http.send(build_llm_request(cfg, sys_prompt, usr_prompt), net).map_error(fn(e)
    ServerFailed(reason: "LLM HTTP request failed: #{e.to_text}")
  end)
  if http_res.status < 200 or http_res.status >= 300
    return Error(ServerFailed(reason: "LLM provider returned HTTP #{http_res.status}"))
  end
  draft_md = try extract_llm_text(cfg, http_res.body)

  now = clock.now
  draft_prefix = "blk_#{Id.ulid(rng, clock)}"
  prov = make_provenance(auth, "AI draft: #{inst}", now)
  parsed_blocks = Blocks.parse_markdown_blocks(page.id, draft_md, prov, draft_prefix)

  if input.as_proposal != Some(true)
    return Ok(
      json_ok(
        200,
        Json.Object({
          "draft_markdown": Json.String(draft_md),
          "blocks": parsed_blocks.to_json,
          "model": Json.String(cfg.model)
        })
      )
    )
  end

  try Policy.require_collection_access(auth, "propose", page.collection_id)
  if parsed_blocks.empty?
    return Error(BadInput(reason: "LLM returned empty draft"))
  end

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

  var new_ids = []
  var ops = []
  var prev_anchor = existing_blocks.last.map(fn(b) b.id end)
  for db_item in parsed_blocks
    nid = "blk_#{Id.ulid(rng, clock)}"
    new_ids = new_ids.append(nid)
    ops = ops.append(
      InsertBlockAfter(
        after_block_id: prev_anchor,
        parent_block_id: None,
        kind: db_item.kind,
        markdown: db_item.markdown
      )
    )
    prev_anchor = Some(nid)
  end

  pm = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: page.collection_id,
    target_page_id: page.id,
    target_database_id: None,
    branch_kind: "proposal",
    title: "AI Draft: #{page.title}",
    reason: "AI inline draft: #{inst}",
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    grant_id: auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  wargs = WorldPatchArgs(
    page_id: page.id,
    ops: ops,
    new_ids: new_ids,
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
    "stage AI draft blocks",
    now
  ).map_error(Db.map_world_error)

  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "ai.draft_proposal",
    reason: "open AI draft proposal on #{page.id}",
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created AI draft proposal #{prop_id}",
    Json.Object({"proposal_id": Json.String(prop_id), "page_id": Json.String(page.id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = if auth.principal.kind == Agent
        (tg, _g) = try Grants.tx_authorize(tx, auth.grant_id, "propose", now).map_error(
          Db.map_grants_error
        )
        tg
      else
        tx
      end
      t2 = try Table.put(t1, Db.proposals_table(), pm.id, pm).map_error(Db.map_table_error)
      Ok((t2, pm))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "draft_markdown": Json.String(draft_md),
        "proposal": saved.to_json,
        "model": Json.String(cfg.model)
      })
    )
  )
end

fn scan_garden_report(store: Store, auth_opt: Option(AuthContext), now: Time) : Result(
  GardenReport,
  AppError
)
  ws_opt = try Table.get(store, Db.workspaces_table(), Db.default_workspace_id).map_error(
    Db.map_table_error
  )
  ws_default_ttl = case ws_opt
    Some(ws) if ws.default_freshness_ttl_days > 0: Some(ws.default_freshness_ttl_days)
    Some(_) | None: None
  end

  col_rows = try Table.scan(store, Db.collections_table(), None, None, 200).map_error(
    Db.map_table_error
  )
  var col_ttl = {}
  for (cid, col) in col_rows
    case col.freshness_ttl_days
      Some(d): col_ttl = col_ttl.set(cid, d)
      None: Unit
    end
  end

  page_rows = try Table.scan(store, Db.pages_table(), None, None, 500).map_error(Db.map_table_error)
  var active_pages = {}
  for (pid, p) in page_rows
    if p.archived_at == None
      active_pages = active_pages.set(pid, p)
    end
  end

  var checked = 0
  var stale = []
  var broken = []
  for (_pid, p) in page_rows
    permitted = case auth_opt
      Some(a): Policy.collection_permitted?(a, p.collection_id)
      None: true
    end
    if p.archived_at == None and permitted
      checked += 1
      ttl_opt = case p.freshness_ttl_days
        Some(d): Some(d)
        None:
          case col_ttl.get(p.collection_id)
            Some(d): Some(d)
            None: ws_default_ttl
          end
      end
      case ttl_opt
        Some(ttl) if ttl > 0:
          ref_time = p.verified_at or p.updated_at
          if now > ref_time + ttl.days
            age_days = (now - ref_time).in_milliseconds.floor_div(86400000)
            stale = stale.append(
              GardenStalePage(
                page_id: p.id,
                collection_id: p.collection_id,
                title: p.title,
                days_since_verified: age_days,
                ttl_days: ttl
              )
            )
          end
        Some(_) | None: Unit
      end

      blks = try Db.load_page_blocks(store, p.id)
      for blk in blks
        case blk.kind
          PageLink(target_page_id: tid):
            if active_pages.get(tid) == None
              broken = broken.append(
                GardenBrokenLink(
                  source_page_id: p.id,
                  source_title: p.title,
                  block_id: blk.id,
                  target_page_id: tid,
                  label: blk.markdown
                )
              )
            end
          Paragraph | Heading(level: _) | BulletListItem | OrderedListItem(start: _) | TaskItem(
            checked: _
          ) | Quote | Callout(tone: _, icon: _) | CodeBlock(language: _) | Divider | Image(
            attachment_id: _,
            caption: _
          ) | FileEmbed(attachment_id: _, filename: _) | DatabaseViewEmbed(
            database_id: _,
            view_id: _
          ) | AiBrief(prompt: _, source_scope: _, refreshed_at: _): Unit
        end
      end
    end
  end

  Ok(
    GardenReport(checked_pages: checked, stale_pages: stale, broken_links: broken, scanned_at: now)
  )
end

## `GET /api/admin/garden` — Scans accessible pages for stale freshness TTLs and broken `PageLink` targets (`ReadFiles`-only).
fn run_garden(auth: AuthContext, rf: ReadFiles, clock: Clock) : Result(Api.Response, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  now = clock.now
  if not rf.exists?(Db.ledger_db_path)
    return Ok(
      json_ok(
        200,
        GardenReport(checked_pages: 0, stale_pages: [], broken_links: [], scanned_at: now).to_json
      )
    )
  end
  rep = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) scan_garden_report(Ledger.store(db), Some(auth), now) end
  )
  Ok(json_ok(200, rep.to_json))
end

## Scheduled Knowledge Gardening scan (`job "vellum.garden" ... every 1.hour`), read-only over `vellum.modb`.
fn garden_job(_payload: Json, files: Files, clock: Clock) : Result(Unit, AppError)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(Unit)
  end
  now = clock.now
  _rep = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db) scan_garden_report(Ledger.store(db), None, now) end
  )
  Ok(Unit)
end

## JSON payload for `POST /api/ai/brief/refresh`.
struct RefreshAiBriefInput
  page_id: Text
  block_id: Text
  deterministic_fallback: Option(Bool)
end

## Generates a crisp 1-sentence semantic summary for `title` + `body` via the configured LLM outside MoDB locks.
fn generate_semantic_summary(cfg: AiConfig, title: Text, body: Text, net: Network) : Result(
  Text,
  AppError
)
  trimmed = body.trim
  return Ok(title.trim) if trimmed.empty?
  excerpt = if trimmed.byte_count > 2000
    trimmed.bytes.slice(0, 2000).decode_utf8 or trimmed
  else
    trimmed
  end
  sys_prompt = "Summarize this Vellum workspace document in one concise factual sentence under 35 words. Return plain text only with no preamble."
  usr_prompt = "Title: #{title}\n\nContent:\n#{excerpt}"
  http_res = try Http.send(build_llm_request(cfg, sys_prompt, usr_prompt), net).map_error(fn(e)
    ServerFailed(reason: "Semantic summary HTTP request failed: #{e.to_text}")
  end)
  if http_res.status < 200 or http_res.status >= 300
    return Error(ServerFailed(reason: "LLM provider returned HTTP #{http_res.status}"))
  end
  raw = try extract_llm_text(cfg, http_res.body)
  Ok(raw.replace("\n", " ").trim)
end

## `POST /api/ai/brief/refresh` — Refreshes an `AiBrief` card into a speculative `Modb.World` Change Proposal (never writes live).
fn refresh_ai_brief(
  req: Api.Request,
  auth: AuthContext,
  input: RefreshAiBriefInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: input.page_id))
  end

  (pg, target_blk, brief_prompt, scope_opt, sum_lines, cits) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Table.get(store, Db.pages_table(), input.page_id.trim).map_error(
        Db.map_table_error
      )
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: input.page_id))
      end
      try Policy.require_collection_access(auth, "read", pg.collection_id)
      try Policy.require_collection_access(auth, "propose", pg.collection_id)

      blks = try Db.load_page_blocks(store, pg.id)
      var found_blk = None
      for b in blks
        if b.id == input.block_id.trim
          found_blk = Some(b)
          break
        end
      end
      tblk = try found_blk.or_fail(Missing(entity: "block", id: input.block_id))
      (pr_txt, sc_opt) = case tblk.kind
        AiBrief(prompt: pr, source_scope: sc, refreshed_at: _): (pr, sc)
        Paragraph | Heading(level: _) | BulletListItem | OrderedListItem(start: _) | TaskItem(
          checked: _
        ) | Quote | Callout(tone: _, icon: _) | CodeBlock(language: _) | Divider | Image(
          attachment_id: _,
          caption: _
        ) | FileEmbed(attachment_id: _, filename: _) | PageLink(target_page_id: _) | DatabaseViewEmbed(
          database_id: _,
          view_id: _
        ): return Error(BadInput(reason: "block '#{tblk.id}' is not an ai-brief card"))
      end

      eff_scope = case sc_opt
        Some(s) if not s.trim.empty?: Some(s.trim)
        Some(_) | None: Some(pg.collection_id)
      end
      sums = try Packs.list_permitted_summaries(store, auth, eff_scope, None)
      var lines = []
      var citations = []
      for s in sums.take(15)
        blurb = s.semantic_summary or s.structural_summary
        lines = lines.append("- [#{s.entity_kind} #{s.entity_id}] #{s.title}: #{blurb}")
        if s.entity_kind == "page" and citations.size < 5
          citations = citations.append(
            Citation(
              source_kind: "living_summary",
              source_ref: s.entity_id,
              label: s.title,
              excerpt: Some(blurb)
            )
          )
        end
      end
      Ok((pg, tblk, pr_txt, sc_opt, lines, citations))
    end
  )

  digest = if sum_lines.empty?
    "- No accessible workspace summaries in scope yet."
  else
    sum_lines.join("\n")
  end

  (brief_md, model_name) = case ai_config(env)
    Ok(cfg):
      sys_prompt = "You maintain a concise Living Brief card inside a Vellum knowledge document. Synthesize strictly from the provided workspace summaries using crisp Markdown bullet points."
      usr_prompt = "Document: #{pg.title}\nBrief Goal: #{brief_prompt}\n\nAccessible Living Summaries:\n#{digest}"
      http_res = try Http.send(build_llm_request(cfg, sys_prompt, usr_prompt), net).map_error(fn(e)
        ServerFailed(reason: "AI brief LLM request failed: #{e.to_text}")
      end)
      if http_res.status < 200 or http_res.status >= 300
        return Error(ServerFailed(reason: "LLM provider returned HTTP #{http_res.status}"))
      end
      raw = try extract_llm_text(cfg, http_res.body)
      (raw.trim, cfg.model)
    Error(cfg_err):
      if input.deterministic_fallback == Some(true)
        ("**#{brief_prompt}**\n#{digest}", "deterministic-summary")
      else
        return Error(cfg_err)
      end
  end

  now = clock.now
  prov = Provenance(
    author_id: auth.principal.id,
    author_kind: case auth.principal.kind
      Human: HumanAuthor
      Agent: AgentAuthor(model: auth.principal.model_id)
    end,
    grant_id: if auth.principal.kind == Agent: Some(auth.grant_id) else: None,
    proposal_id: None,
    reason: Some("AI brief refresh: #{brief_prompt}"),
    citations: cits,
    updated_at: now
  )
  next_kind = AiBrief(prompt: brief_prompt, source_scope: scope_opt, refreshed_at: Some(now.to_text))
  ops = [
    ReplaceBlock(
      block_id: target_blk.id,
      expected_version: target_blk.version,
      kind: Some(next_kind),
      markdown: brief_md
    )
  ]

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

  wargs = WorldPatchArgs(
    page_id: pg.id,
    ops: ops,
    new_ids: [],
    provenance: prov,
    expected_versions: {target_blk.id: target_blk.version},
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
    "stage refreshed ai-brief block",
    now
  ).map_error(Db.map_world_error)

  pm = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: pg.collection_id,
    target_page_id: pg.id,
    target_database_id: None,
    branch_kind: "proposal",
    title: "Refresh Living Brief: #{brief_prompt}",
    reason: "Proposals-only Living AI Brief refresh on '#{target_blk.id}'",
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
    action: "ai.refresh_brief_proposal",
    reason: "stage refreshed ai-brief proposal on #{pg.id}",
    at: now
  )
  saved = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created AI brief proposal #{prop_id} for #{pg.id}",
    Json.Object({"proposal_id": Json.String(prop_id), "page_id": Json.String(pg.id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = if auth.principal.kind == Agent
        (tg, _g) = try Grants.tx_authorize(tx, auth.grant_id, "propose", now).map_error(
          Db.map_grants_error
        )
        tg
      else
        tx
      end
      t2 = try Table.put(t1, Db.proposals_table(), pm.id, pm).map_error(Db.map_table_error)
      Ok((t2, pm))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "proposal": saved.to_json,
        "draft_markdown": Json.String(brief_md),
        "block_id": Json.String(target_blk.id),
        "model": Json.String(model_name)
      })
    )
  )
end

## JSON payload for `POST /api/databases/:id/ai-columns/:prop_id/run`.
struct RunAiColumnInput
  row_ids: Option(List(Text))
  only_stale: Option(Bool)
  mode_override: Option(Text)
  deterministic_fallback: Option(Bool)
end

fn ai_output_schema_description(out_k: AiOutputKind) : Text
  case out_k
    AiText: "short plain text string"
    AiNumber(format: fmt): "exact decimal number (format=#{fmt}), e.g. \"42.50\" or 42.50"
    AiDate: "ISO date string YYYY-MM-DD"
    AiBool: "JSON boolean true or false"
    AiSelect(options: opts):
      labels = opts.map(fn(o) "#{o.id} (#{o.label})" end).join(", ")
      "one allowed select option id/label from: [#{labels}]"
  end
end

## Builds exact `(system_prompt, user_prompt)` strings used to evaluate an `AiDerived` cell.
fn build_ai_column_prompts(
  db_title: Text,
  prop_name: Text,
  prompt_str: Text,
  out_k: AiOutputKind,
  row_title: Text,
  src_txt: Text
) : (Text, Text)
  schema_desc = ai_output_schema_description(out_k)
  sys_prompt = "You evaluate an AI-compiled database column '#{prop_name}' (schema: #{schema_desc}). Respond ONLY with a valid JSON object {\"value\": <value>, \"rationale\": \"<short citation-grounded explanation>\"}."
  usr_prompt = "Database: #{db_title}\nColumn Prompt: #{prompt_str}\nOutput Type: #{schema_desc}\nRow Title: #{row_title}\n\nGrounded Row Inputs:\n#{src_txt}"
  (sys_prompt, usr_prompt)
end

fn ai_cell_value_to_plain_text(prop: PropertyDef, c: CellValue) : Text
  case c
    Empty: ""
    TextVal(s) | UrlVal(s): s.trim
    NumberVal(d): d.to_text
    DateVal(start: st, end_date: ed_opt):
      case ed_opt
        Some(ed): "#{st.to_iso}..#{ed.to_iso}"
        None: st.to_iso
      end
    BoolVal(b): if b: "true" else: "false"
    SelectVal(option_id: oid):
      case prop.kind
        Select(options: opts) | AiDerived(
          prompt: _,
          source_prop_ids: _,
          include_row_body: _,
          output_kind: AiSelect(options: opts),
          mode: _,
          daily_call_cap: _
        ):
          for o in opts
            if o.id == oid
              return "#{o.label} (#{o.id})"
            end
          end
          oid
        Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
          target_db_id: _,
          inverse_prop_id: _
        ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
          prompt: _,
          source_prop_ids: _,
          include_row_body: _,
          output_kind: _,
          mode: _,
          daily_call_cap: _
        ): oid
      end
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | RelationVal(row_ids: xs): xs.join(", ")
  end
end

fn build_row_ai_context(
  def: DatabaseDef,
  row: DbRow,
  source_prop_ids: List(Text),
  include_row_body?: Bool,
  body_blocks: List(Block)
) : (Text, Text, List(Citation))
  row_title = DatabaseModel.extract_row_title(def, row.cells)
  var prop_by_id = {}
  for p in def.properties
    prop_by_id = prop_by_id.set(p.id, p)
  end
  target_ids = if source_prop_ids.empty?
    def.properties.filter(fn(p)
      case p.kind
        AiDerived(
          prompt: _,
          source_prop_ids: _,
          include_row_body: _,
          output_kind: _,
          mode: _,
          daily_call_cap: _
        ): false
        Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
          options: _
        ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | Rollup(
          relation_prop_id: _,
          target_prop_id: _,
          agg: _
        ): true
      end
    end).map(fn(p) p.id end)
  else
    source_prop_ids
  end

  var lines = []
  var cits = []
  for sid in target_ids
    case prop_by_id.get(sid)
      Some(sp):
        val = row.cells.get(sid) or Empty
        txt = ai_cell_value_to_plain_text(sp, val)
        if not txt.empty?
          lines = lines.append("- #{sp.name} (#{sp.id}): #{txt}")
          if cits.size < 4
            cits = cits.append(
              Citation(
                source_kind: "db_row",
                source_ref: row.id,
                label: "#{row_title} · #{sp.name}",
                excerpt: Some(txt)
              )
            )
          end
        end
      None: Unit
    end
  end

  body_plain = if include_row_body? and not body_blocks.empty?
    plain = Blocks.blocks_plain_text(body_blocks)
    if not plain.trim.empty?
      case body_blocks.first
        Some(fb):
          if cits.size < 6
            cits = cits.append(
              Citation(
                source_kind: "block",
                source_ref: fb.id,
                label: "#{row_title} notes",
                excerpt: Some(fb.markdown)
              )
            )
          end
        None: Unit
      end
    end
    plain
  else
    ""
  end

  src_txt = if body_plain.trim.empty?
    lines.join("\n")
  else if lines.empty?
    "Row Document Notes:\n#{body_plain}"
  else
    "#{lines.join("\n")}\n\nRow Document Notes:\n#{body_plain}"
  end
  (row_title, src_txt, cits)
end

## `GET /api/databases/:id/ai-columns/status` — Returns daily AI column budget usage, `Modb.Feeds` cursor, and per-cell metadata (`ReadFiles`-only).
fn ai_columns_status(
  id: Text,
  auth: AuthContext,
  rf: ReadFiles,
  clock: Clock
) : Result(Api.Response, AppError)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not rf.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end

  now = clock.now
  today_iso = now.to_text.bytes.slice(0, 10).decode_utf8 or "1970-01-01"
  payload = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      def = case try Table.get(store, Db.databases_table(), id).map_error(Db.map_table_error)
        Some(d): d
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "read", def.collection_id)

      var prop_by_id = {}
      var usage_map = {}
      for p in def.properties
        prop_by_id = prop_by_id.set(p.id, p)
        case p.kind
          AiDerived(
            prompt: _,
            source_prop_ids: _,
            include_row_body: _,
            output_kind: _,
            mode: _,
            daily_call_cap: cap
          ):
            uk = DatabaseModel.ai_col_usage_key(def.id, p.id, today_iso)
            used = case try Table.get(store, Db.ai_col_usage_table(), uk).map_error(
              Db.map_table_error
            )
              Some(u): u.calls_used
              None: 0
            end
            rem = if cap > used: cap - used else: 0
            usage_map = usage_map.set(
              p.id,
              Json.Object({
                "calls_used": Json.int(used),
                "daily_call_cap": Json.int(cap),
                "remaining_calls": Json.int(rem),
                "day_iso": Json.String(today_iso)
              })
            )
          Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
            options: _
          ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | Rollup(
            relation_prop_id: _,
            target_prop_id: _,
            agg: _
          ): Unit
        end
      end

      r_pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def.id)
        .map_error(Db.map_table_error)
      var row_by_id = {}
      for (_rid, r) in r_pairs
        if r.archived_at == None
          row_by_id = row_by_id.set(r.id, r)
        end
      end

      meta_pairs = try Table.lookup(
        store,
        Db.ai_cell_meta_table(),
        Db.ai_cell_meta_by_database(),
        def.id
      ).map_error(Db.map_table_error)
      var cell_map = {}
      for (_mk, m) in meta_pairs
        live_stale = if m.stale
          true
        else
          case (prop_by_id.get(m.prop_id), row_by_id.get(m.row_id))
            (Some(prop), Some(row)):
              case prop.kind
                AiDerived(
                  prompt: pr,
                  source_prop_ids: _,
                  include_row_body: body?,
                  output_kind: out_k,
                  mode: _,
                  daily_call_cap: _
                ):
                  pr_h = DatabaseModel.compute_ai_prompt_hash(pr, out_k)
                  b_plain = if body?
                    Blocks.blocks_plain_text(try Db.load_page_blocks(store, row.page_id))
                  else
                    ""
                  end
                  in_h = DatabaseModel.compute_ai_input_hash(def, prop, row, b_plain)
                  pr_h != m.prompt_hash or in_h != m.input_hash
                Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(
                  options: _
                ) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
                  target_db_id: _,
                  inverse_prop_id: _
                ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): false
              end
            (_, _): true
          end
        end
        eff_m = AiCellMeta(
          id: m.id,
          database_id: m.database_id,
          row_id: m.row_id,
          prop_id: m.prop_id,
          model: m.model,
          prompt_hash: m.prompt_hash,
          input_hash: m.input_hash,
          stale: live_stale,
          rationale: m.rationale,
          citations: m.citations,
          proposal_id: m.proposal_id,
          computed_at: m.computed_at
        )
        cell_map = cell_map.set("#{m.row_id}:#{m.prop_id}", eff_m.to_json)
      end

      feed_json = case try Feeds.get_feed(store, Db.ai_col_feed_id(def.id)).map_error(
        Db.map_feeds_error
      )
        Some(sub):
          Json.Object({
            "feed_id": Json.String(sub.id),
            "cursor_txid": Json.int(sub.cursor_txid),
            "events_delivered": Json.int(sub.events_delivered),
            "bootstrapped": Json.Boolean(sub.bootstrapped)
          })
        None: Json.Null
      end

      Ok(
        Json.Object({
          "database_id": Json.String(def.id),
          "day_iso": Json.String(today_iso),
          "feed": feed_json,
          "usage": Json.Object(usage_map),
          "cells": Json.Object(cell_map)
        })
      )
    end
  )
  Ok(json_ok(200, payload))
end

## `POST /api/databases/:id/ai-columns/sync-feed` — Consumes `Modb.Feeds` changes and marks stale AI cells.
fn sync_ai_column_feed(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  clock: Clock
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end
  _def = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      d = case try Table.get(Ledger.store(db), Db.databases_table(), id).map_error(
        Db.map_table_error
      )
        Some(x): x
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "read", d.collection_id)
      Ok(d)
    end
  )
  res = try Db.sync_ai_col_feed_locked(files, id, clock.now)
  Ok(json_ok(200, res.to_json))
end

## `POST /api/databases/:id/ai-columns/:prop_id/run` — Evaluates one `AiDerived` column over target/stale rows
## strictly outside MoDB write locks, validates outputs via `DatabaseModel.validate_cell`, enforces daily caps,
## and routes writes to AutoApply or a `Modb.World` Change Proposal according to column & collection policy.
fn run_ai_column(
  req: Api.Request,
  id: Text,
  prop_id: Text,
  auth: AuthContext,
  input: RunAiColumnInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end

  now = clock.now
  day_iso = now.to_text.bytes.slice(0, 10).decode_utf8 or "1970-01-01"

  (def_check, col_check, prop, prompt_str, src_ids, include_body?, out_kind, col_mode, daily_cap) = try Ledger
    .read_locked(
      files.read_only,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        store = Ledger.store(db)
        d = case try Table.get(store, Db.databases_table(), id).map_error(Db.map_table_error)
          Some(x): x
          None: return Error(Missing(entity: "database", id: id))
        end
        try Policy.require_collection_access(auth, "read", d.collection_id)
        c = case try Table.get(store, Db.collections_table(), d.collection_id).map_error(
          Db.map_table_error
        )
          Some(x): x
          None: return Error(Missing(entity: "collection", id: d.collection_id))
        end
        var found_p = None
        for p in d.properties
          if p.id == prop_id
            found_p = Some(p)
            break
          end
        end
        prp = try found_p.or_fail(Missing(entity: "property", id: prop_id))
        case prp.kind
          AiDerived(
            prompt: pr_t,
            source_prop_ids: sids,
            include_row_body: inc_b,
            output_kind: ok_k,
            mode: cm,
            daily_call_cap: cap
          ): Ok((d, c, prp, pr_t, sids, inc_b, ok_k, cm, cap))
          Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
            options: _
          ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | Rollup(
            relation_prop_id: _,
            target_prop_id: _,
            agg: _
          ): Error(BadInput(reason: "property '#{prop_id}' is not an AI-compiled column"))
        end
      end
    )

  base_mode = case input.mode_override
    None: col_mode
    Some(m):
      norm = m.trim.ascii_lowercase
      if norm.empty?
        col_mode
      else if norm == "proposal" or norm == "stage_proposal"
        StageProposal
      else if norm == "auto" or norm == "auto_apply"
        AutoApply
      else
        return Error(BadInput(reason: "mode_override must be 'auto' or 'proposal'"))
      end
  end
  eff_mode = if col_check.write_policy == ProposalsRequiredForAll or
    (col_check.write_policy == ProposalsRequiredForAgents and auth.principal.kind == Agent)
    StageProposal
  else
    base_mode
  end

  write_act = if eff_mode == AutoApply
    if Policy.action_permitted?(auth, "write_db")
      "write_db"
    else
      "write_direct"
    end
  else
    "propose"
  end
  try Policy.require_collection_access(auth, write_act, col_check.id)

  # Sync Modb.Feeds O(diff) staleness cursor before evaluating target rows
  _feed_sync = try Db.sync_ai_col_feed_locked(files, def_check.id, now)

  usage_key = DatabaseModel.ai_col_usage_key(def_check.id, prop.id, day_iso)
  pr_hash = DatabaseModel.compute_ai_prompt_hash(prompt_str, out_kind)
  only_stale? = case input.only_stale
    Some(b): b
    None: true
  end

  (used_before, candidates, row_blocks_map) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      used = case try Table.get(store, Db.ai_col_usage_table(), usage_key).map_error(
        Db.map_table_error
      )
        Some(u): u.calls_used
        None: 0
      end
      r_pairs = try Table.lookup(store, Db.db_rows_table(), Db.db_rows_by_database(), def_check.id)
        .map_error(Db.map_table_error)
      active_rows = r_pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end).sort_by(
        fn(r) r.id end
      )

      row_filter = case input.row_ids
        Some(xs) if not xs.empty?: Some(xs)
        Some(_) | None: None
      end

      var out_cands = []
      var blk_map = {}
      for r in active_rows
        in_row_filter = case row_filter
          Some(xs): xs.contains?(r.id)
          None: true
        end
        continue if not in_row_filter

        blks = if include_body?
          try Db.load_page_blocks(store, r.page_id)
        else
          []
        end
        b_plain = if include_body?: Blocks.blocks_plain_text(blks) else: ""
        in_h = DatabaseModel.compute_ai_input_hash(def_check, prop, r, b_plain)
        mk = DatabaseModel.ai_cell_meta_key(def_check.id, r.id, prop.id)
        m_opt = try Table.get(store, Db.ai_cell_meta_table(), mk).map_error(Db.map_table_error)
        cur_val = r.cells.get(prop.id) or Empty
        stale? = case m_opt
          Some(m): m.stale or m.prompt_hash != pr_hash or m.input_hash != in_h
          None: true
        end
        need_eval = if only_stale?
          cur_val == Empty or stale?
        else
          true
        end
        if need_eval
          out_cands = out_cands.append((r, in_h))
          blk_map = blk_map.set(r.id, blks)
        end
      end
      Ok((used, out_cands, blk_map))
    end
  )

  remaining = if daily_cap > used_before: daily_cap - used_before else: 0
  if remaining <= 0 and not candidates.empty?
    return Error(
      Conflict(
        reason: "daily call cap (#{daily_cap}) reached for AI column '#{prop.id}' on #{day_iso}"
      )
    )
  end

  to_eval = candidates.take(remaining)
  skipped_budget = candidates.size - to_eval.size
  cfg_res = ai_config(env)

  var attempted_calls = 0
  var valid_updates = []
  var result_items = []
  var used_model = "none"

  for (row, in_h) in to_eval
    blks = row_blocks_map.get(row.id) or []
    (row_title, src_txt, cits) = build_row_ai_context(
      def_check,
      row,
      src_ids,
      include_body?,
      blks
    )
    attempted_calls += 1

    eval_out = case cfg_res
      Ok(cfg):
        used_model = cfg.model
        (sys_prompt, usr_prompt) = build_ai_column_prompts(
          def_check.title,
          prop.name,
          prompt_str,
          out_kind,
          row_title,
          src_txt
        )
        http_res = try Http.send(build_llm_request(cfg, sys_prompt, usr_prompt), net).map_error(
          fn(e) ServerFailed(reason: "AI column LLM request failed: #{e.to_text}") end
        )
        if http_res.status < 200 or http_res.status >= 300
          return Error(ServerFailed(reason: "LLM provider returned HTTP #{http_res.status}"))
        end
        raw_reply = try extract_llm_text(cfg, http_res.body)
        case DatabaseModel.parse_ai_cell_output(out_kind, raw_reply)
          Ok((cval, rat_opt)): Ok((cval, rat_opt, cfg.model))
          Error(msg): Error(msg)
        end
      Error(cfg_err):
        if input.deterministic_fallback == Some(true)
          used_model = "deterministic-column"
          (cval, rat) = DatabaseModel.compute_deterministic_ai_cell(
            prop,
            out_kind,
            row_title,
            src_txt
          )
          Ok((cval, Some(rat), "deterministic-column"))
        else
          return Error(cfg_err)
        end
    end

    case eval_out
      Error(parse_msg):
        result_items = result_items.append(
          Json.Object({
            "row_id": Json.String(row.id),
            "status": Json.String("validation_error"),
            "error": Json.String(parse_msg)
          })
        )
      Ok((cell_val, rat_opt, mname)):
        case DatabaseModel.validate_cell(prop, cell_val)
          Some(val_msg):
            result_items = result_items.append(
              Json.Object({
                "row_id": Json.String(row.id),
                "status": Json.String("validation_error"),
                "error": Json.String(val_msg)
              })
            )
          None:
            valid_updates = valid_updates.append((row, cell_val, rat_opt, cits, in_h, mname))
            result_items = result_items.append(
              Json.Object({
                "row_id": Json.String(row.id),
                "status": Json.String(
                  if eff_mode == AutoApply: "applied" else: "staged"
                ),
                "value": cell_val.to_json,
                "rationale": case rat_opt
                  Some(r): Json.String(r)
                  None: Json.Null
                end
              })
            )
        end
    end
  end

  if eff_mode == AutoApply
    wmeta = Ledger.WriteMeta(
      principal: auth.principal.handle,
      action: "ai_column.run_auto",
      reason: "AI-compiled column '#{prop.id}' evaluated #{attempted_calls} rows",
      at: now
    )
    (next_usage, updated_cnt) = try Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      wmeta,
      "ran AI column #{prop.id} (auto_apply)",
      Json.Object({
        "database_id": Json.String(def_check.id),
        "prop_id": Json.String(prop.id),
        "attempted": Json.int(attempted_calls),
        "updated": Json.int(valid_updates.size)
      }),
      Db.map_ledger_error,
      fn(tx)
        var t = if auth.principal.kind == Agent
          (tg, _g) = try Grants.tx_authorize(tx, auth.grant_id, write_act, now).map_error(
            Db.map_grants_error
          )
          tg
        else
          tx
        end
        cur_u = case try Table.tx_get(t, Db.ai_col_usage_table(), usage_key).map_error(
          Db.map_table_error
        )
          Some(u): u.calls_used
          None: 0
        end
        new_u = AiColumnUsage(
          id: usage_key,
          database_id: def_check.id,
          prop_id: prop.id,
          day_iso: day_iso,
          calls_used: cur_u + attempted_calls,
          updated_at: now
        )
        t = try Table.put(t, Db.ai_col_usage_table(), new_u.id, new_u).map_error(
          Db.map_table_error
        )

        var applied = 0
        for (orig_row, cell_val, rat_opt, cits, in_h, mname) in valid_updates
          cur_def = case try Table.tx_get(t, Db.databases_table(), def_check.id).map_error(
            Db.map_table_error
          )
            Some(d): d
            None: def_check
          end
          cur_row = case try Table.tx_get(t, Db.db_rows_table(), orig_row.id).map_error(
            Db.map_table_error
          )
            Some(r) if r.archived_at == None: r
            Some(_) | None: continue
          end
          old_pg = case try Table.tx_get(t, Db.pages_table(), cur_row.page_id).map_error(
            Db.map_table_error
          )
            Some(p): p
            None: continue
          end
          blks = try Table.tx_lookup(t, Db.blocks_table(), Db.blocks_by_page(), old_pg.id)
            .map_error(Db.map_table_error)
            .map(fn(xs) Blocks.sort_blocks(xs.map(fn(x) x.1 end)) end)
          merged_cells = cur_row.cells.set(prop.id, cell_val)
          bumped_row = DbRow(
            id: cur_row.id,
            database_id: cur_row.database_id,
            page_id: cur_row.page_id,
            cells: merged_cells,
            created_by: cur_row.created_by,
            created_at: cur_row.created_at,
            updated_at: now,
            archived_at: cur_row.archived_at,
            version: cur_row.version + 1
          )
          bumped_pg = Page(
            id: old_pg.id,
            collection_id: old_pg.collection_id,
            parent_page_id: old_pg.parent_page_id,
            title: DatabaseModel.extract_row_title(cur_def, merged_cells),
            icon: old_pg.icon,
            cover_attachment_id: old_pg.cover_attachment_id,
            kind: old_pg.kind,
            sort_order: old_pg.sort_order,
            database_id: old_pg.database_id,
            freshness_ttl_days: old_pg.freshness_ttl_days,
            verified_at: old_pg.verified_at,
            verified_by: old_pg.verified_by,
            created_by: old_pg.created_by,
            created_at: old_pg.created_at,
            updated_at: now,
            archived_at: old_pg.archived_at,
            version: old_pg.version + 1
          )
          t = try Db.tx_put_db_row(t, cur_def, bumped_row, bumped_pg, blks)
          cmeta = AiCellMeta(
            id: DatabaseModel.ai_cell_meta_key(cur_def.id, bumped_row.id, prop.id),
            database_id: cur_def.id,
            row_id: bumped_row.id,
            prop_id: prop.id,
            model: mname,
            prompt_hash: pr_hash,
            input_hash: in_h,
            stale: false,
            rationale: rat_opt,
            citations: cits,
            proposal_id: None,
            computed_at: now
          )
          t = try Table.put(t, Db.ai_cell_meta_table(), cmeta.id, cmeta).map_error(
            Db.map_table_error
          )
          applied += 1
        end
        Ok((t, (new_u, applied)))
      end
    )

    rem_after = if daily_cap > next_usage.calls_used
      daily_cap - next_usage.calls_used
    else
      0
    end
    return Ok(
      json_ok(
        200,
        Json.Object({
          "database_id": Json.String(def_check.id),
          "prop_id": Json.String(prop.id),
          "mode": Json.String("auto_apply"),
          "model": Json.String(used_model),
          "attempted_calls": Json.int(attempted_calls),
          "updated_count": Json.int(updated_cnt),
          "skipped_budget_count": Json.int(skipped_budget),
          "usage": Json.Object({
            "calls_used": Json.int(next_usage.calls_used),
            "daily_call_cap": Json.int(daily_cap),
            "remaining_calls": Json.int(rem_after),
            "day_iso": Json.String(day_iso)
          }),
          "results": Json.Array(result_items),
          "proposal": Json.Null
        })
      )
    )
  end

  # StageProposal mode: debit usage and stage all valid cell + AiCellMeta updates inside ONE Modb.World branch
  umeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "ai_column.usage_debit",
    reason: "debit AI column call budget on '#{prop.id}'",
    at: now
  )
  next_usage = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    umeta,
    "debited AI column usage on #{prop.id}",
    Json.Object({
      "database_id": Json.String(def_check.id),
      "prop_id": Json.String(prop.id),
      "attempted": Json.int(attempted_calls)
    }),
    Db.map_ledger_error,
    fn(tx)
      t = if auth.principal.kind == Agent
        (tg, _g) = try Grants.tx_authorize(tx, auth.grant_id, "propose", now).map_error(
          Db.map_grants_error
        )
        tg
      else
        tx
      end
      cur_u = case try Table.tx_get(t, Db.ai_col_usage_table(), usage_key).map_error(
        Db.map_table_error
      )
        Some(u): u.calls_used
        None: 0
      end
      new_u = AiColumnUsage(
        id: usage_key,
        database_id: def_check.id,
        prop_id: prop.id,
        day_iso: day_iso,
        calls_used: cur_u + attempted_calls,
        updated_at: now
      )
      t1 = try Table.put(t, Db.ai_col_usage_table(), new_u.id, new_u).map_error(
        Db.map_table_error
      )
      Ok((t1, new_u))
    end
  )
  rem_after = if daily_cap > next_usage.calls_used
    daily_cap - next_usage.calls_used
  else
    0
  end
  usage_json = Json.Object({
    "calls_used": Json.int(next_usage.calls_used),
    "daily_call_cap": Json.int(daily_cap),
    "remaining_calls": Json.int(rem_after),
    "day_iso": Json.String(day_iso)
  })

  if valid_updates.empty?
    return Ok(
      json_ok(
        200,
        Json.Object({
          "database_id": Json.String(def_check.id),
          "prop_id": Json.String(prop.id),
          "mode": Json.String("stage_proposal"),
          "model": Json.String(used_model),
          "attempted_calls": Json.int(attempted_calls),
          "updated_count": Json.int(0),
          "skipped_budget_count": Json.int(skipped_budget),
          "usage": usage_json,
          "results": Json.Array(result_items),
          "proposal": Json.Null
        })
      )
    )
  end

  prop_id_new = "prop_#{Id.ulid(rng, clock)}"
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

  base_prov = make_provenance(auth, "AI-compiled column '#{prop.name}'", now)
  for (row, cell_val, rat_opt, cits, in_h, mname) in valid_updates
    row_prov = Provenance(
      author_id: base_prov.author_id,
      author_kind: base_prov.author_kind,
      grant_id: base_prov.grant_id,
      proposal_id: Some(prop_id_new),
      reason: Some("AI column '#{prop.name}': #{rat_opt or mname}"),
      citations: cits,
      updated_at: now
    )
    row_mut = UpdateDbRow(
      database_id: def_check.id,
      row_id: row.id,
      cells: {prop.id: cell_val},
      expected_version: Some(row.version),
      provenance: row_prov
    )
    _s1 = try World.world_call_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.world_catalog(),
      world_id,
      "propose",
      WorldBranchArgs(mutation: row_mut, updated_at: now).to_json,
      "stage AI cell #{prop.id} on #{row.id}",
      now
    ).map_error(Db.map_world_error)

    cmeta = AiCellMeta(
      id: DatabaseModel.ai_cell_meta_key(def_check.id, row.id, prop.id),
      database_id: def_check.id,
      row_id: row.id,
      prop_id: prop.id,
      model: mname,
      prompt_hash: pr_hash,
      input_hash: in_h,
      stale: false,
      rationale: rat_opt,
      citations: cits,
      proposal_id: Some(prop_id_new),
      computed_at: now
    )
    _s2 = try World.world_call_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.world_catalog(),
      world_id,
      "propose",
      WorldBranchArgs(mutation: PutAiCellMeta(meta: cmeta), updated_at: now).to_json,
      "stage AI cell metadata #{prop.id} on #{row.id}",
      now
    ).map_error(Db.map_world_error)
  end

  pm = ProposalMeta(
    id: prop_id_new,
    world_id: world_id,
    collection_id: def_check.collection_id,
    target_page_id: def_check.page_id,
    target_database_id: Some(def_check.id),
    branch_kind: "proposal",
    title: "AI Column: #{prop.name} (#{valid_updates.size} rows)",
    reason: "AI-compiled column '#{prop.id}' run via #{used_model}",
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    grant_id: auth.grant_id,
    status: "open",
    created_at: now,
    updated_at: now,
    decided_by: None,
    decided_at: None
  )
  pmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "ai_column.stage_proposal",
    reason: "open AI column proposal #{prop_id_new} on #{def_check.id}",
    at: now
  )
  saved_pm = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    pmeta,
    "created AI column proposal #{prop_id_new}",
    Json.Object({"proposal_id": Json.String(prop_id_new), "database_id": Json.String(def_check.id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try Table.put(tx, Db.proposals_table(), pm.id, pm).map_error(Db.map_table_error)
      Ok((t1, pm))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "database_id": Json.String(def_check.id),
        "prop_id": Json.String(prop.id),
        "mode": Json.String("stage_proposal"),
        "model": Json.String(used_model),
        "attempted_calls": Json.int(attempted_calls),
        "updated_count": Json.int(valid_updates.size),
        "skipped_budget_count": Json.int(skipped_budget),
        "usage": usage_json,
        "results": Json.Array(result_items),
        "proposal": saved_pm.to_json
      })
    )
  )
end
