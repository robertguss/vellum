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
SteerProposalInput(..),
DeepResearchInput(..),
DeepResearchOutcome(..),
GardenStalePage(..),
GardenBrokenLink(..),
GardenReport(..),
GardenProposeInput(..),
ai_config,
embed_config,
build_llm_request,
extract_llm_text,
build_llm_request_with_stream,
build_embedding_request,
fetch_embedding,
generate_semantic_summary,
execute_workspace_search,
ask_workspace,
draft_blocks,
refresh_ai_brief,
steer_proposal,
build_ai_column_prompts,
build_steer_prompts,
build_rlm_subcall_prompts,
build_rlm_synthesis_prompts,
build_rlm_tier2_planner_prompts,
deep_research_outcome_to_json,
execute_rlm_tier1,
execute_rlm_tier2,
execute_deep_research,
deep_research,
run_ai_column,
ai_columns_status,
sync_ai_column_feed,
run_garden,
propose_garden_fix,
garden_job
use Api
use Arvo.Id
use Db
use Domain.Blocks
use Domain.Collab{ProposalComment, ProposalMeta, WorldBranchArgs, WorldMutation, WorldPatchArgs}
use Domain.Garden{GardenCitationDrift, GardenDuplicatePair}
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
use Domain.Rlm{RlmBlockSlice, RlmDbSlice, RlmTraceStep}
use Domain.RlmVm
use Domain.TaintBridge
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
  PageKind,
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
use Modb.Views
use Modb.World
use Routes.Auth
use Routes.Packs
use VaultOps

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
  duplicate_pairs: List(GardenDuplicatePair)
  citation_drifts: List(GardenCitationDrift)
  scanned_at: Time
end

## JSON payload for `POST /api/admin/garden/propose` (strictly Proposals-Only Gardener).
struct GardenProposeInput
  kind: Text
  target_page_id: Text
  target_block_id: Option(Text)
  related_page_id: Option(Text)
  related_block_id: Option(Text)
  reason: Option(Text)
  deterministic_fallback: Option(Bool)
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
  raw_txt = try http_res.body.decode_utf8.or_fail(
    ServerFailed(reason: "Embedding JSON response is not valid UTF-8")
  )
  parsed = try Json.parse(raw_txt).map_error(fn(e)
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
  raw_txt = try body.decode_utf8.or_fail(
    ServerFailed(reason: "LLM JSON response is not valid UTF-8")
  )
  parsed = try Json.parse(raw_txt).map_error(fn(e)
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

fn decode_search_result_items_json(arr_j: Json) : List(SearchResultItem)
  var items = []
  case arr_j
    Json.Array(raw_items):
      for item in raw_items
        score = case item.get("score")
          Some(Json.Number(num)): num.to_float or 0.0
          Some(_) | None: 0.0
        end
        vec_score = case item.get("vec_score")
          Some(Json.Number(num)): num.to_float
          Some(_) | None: None
        end
        items = items.append(
          SearchResultItem(
            page_id: item.text_at("page_id") or "",
            collection_id: item.text_at("collection_id") or "",
            title: item.text_at("title") or "",
            score: score,
            matched_terms: VaultOps.json_text_list_opt(item, "matched_terms") or [],
            matched_fields: VaultOps.json_text_list_opt(item, "matched_fields") or [],
            fts_rank: item.int_at("fts_rank"),
            vec_rank: item.int_at("vec_rank"),
            vec_score: vec_score
          )
        )
      end
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): Unit
  end
  items
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
    hits_j = try Ledger.read_locked(
      rf,
      Db.ledger_db_path,
      Db.vellum_schema(),
      Db.map_ledger_error,
      fn(db)
        Db.search_pages(Ledger.store(db), auth, q, limit, prefix_last?, collection_filter).map(
          fn(xs) Json.Array(xs.map(fn(x) x.to_json end)) end
        )
      end
    )
    hits = decode_search_result_items_json(hits_j)
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
      has_neural_j = try Ledger.read_locked(
        rf,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          Ok(Json.Boolean(try Db.neural_vec_populated(Ledger.store(db), ecfg.dimensions)))
        end
      )
      if has_neural_j == Json.Boolean(true)
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

  hits_j = try Ledger.read_locked(
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
      ).map(fn(xs) Json.Array(xs.map(fn(x) x.to_json end)) end)
    end
  )
  hits = decode_search_result_items_json(hits_j)
  Ok(WorkspaceSearchOutcome(results: hits, mode: mode, vector_backend: backend_label))
end

## `POST /api/ai/ask` — Grant-filtered Hybrid (BM25 + `Modb.Vec`) context retrieval + LLM synthesis (JSON or SSE stream, `ReadFiles`-only).
fn ask_workspace(
  req: Api.Request,
  auth: AuthContext,
  rf: ReadFiles,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = AskWorkspaceInput(
    question: try VaultOps.req_text(rj, "question"),
    collection_id: rj.text_at("collection_id"),
    max_sources: rj.int_at("max_sources"),
    stream: rj.bool_at("stream")
  )
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = input.question.trim
  if q.empty?
    return Error(BadInput(reason: "question must not be empty"))
  end
  cfg = try ai_config(env)
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  case input.collection_id
    Some(cid) if not cid.trim.empty? and rf.exists?(Db.ledger_db_path):
      _ok = try Ledger.read_locked(
        rf,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          VaultOps.require_ai_allowed_for_collection(
            Ledger.store(db),
            cid.trim,
            cfg.base_url,
            local_only_ai?
          )
        end
      )
    Some(_) | None: Unit
  end
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
  ask_ctx = if search_out.results.empty? or not rf.exists?(Db.ledger_db_path)
    Json.Object({"citations": Json.Array([]), "ctx": Json.Array([])})
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
          if not try VaultOps.ai_allowed_for_collection(
            store,
            hit.collection_id,
            cfg.base_url,
            local_only_ai?
          )
            continue
          end
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
        Ok(Json.Object({"citations": Json.Array(cites), "ctx": ctx.to_json}))
      end
    )
  end
  citations = ask_ctx.list_at("citations") or []
  context_lines = VaultOps.json_text_list_raw(ask_ctx, "ctx")

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
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = DraftBlockInput(
    page_id: try VaultOps.req_text(rj, "page_id"),
    instruction: try VaultOps.req_text(rj, "instruction"),
    as_proposal: rj.bool_at("as_proposal")
  )
  inst = input.instruction.trim
  if inst.empty?
    return Error(BadInput(reason: "instruction must not be empty"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: input.page_id))
  end

  cfg_url_opt = case ai_config(env)
    Ok(c): Some(c.base_url)
    Error(_): None
  end
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  draft_ctx = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Db.get_page(store, input.page_id)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: input.page_id))
      end
      try Policy.require_collection_access(auth, "read", pg.collection_id)
      case cfg_url_opt
        Some(url):
          try VaultOps.require_ai_allowed_for_collection(
            store,
            pg.collection_id,
            url,
            local_only_ai?
          )
        None: Unit
      end
      blks = try Db.load_page_blocks(store, pg.id)
      Ok(
        Json.Object({
          "page_id": Json.String(pg.id),
          "collection_id": Json.String(pg.collection_id),
          "title": Json.String(pg.title),
          "anchored": Json.String(Blocks.to_anchored_markdown(blks)),
          "last_block_id": blks.last.map(fn(b) b.id end).to_json
        })
      )
    end
  )
  page_id = draft_ctx.text_at("page_id") or input.page_id
  page_collection_id = draft_ctx.text_at("collection_id") or ""
  page_title = draft_ctx.text_at("title") or ""
  anchored_md = draft_ctx.text_at("anchored") or ""
  var prev_anchor = draft_ctx.text_at("last_block_id")

  cfg = try ai_config(env)
  sys_prompt = "You draft concise Markdown sections for Vellum documents. Output Markdown blocks only."
  usr_prompt = "Page: #{page_title}\nExisting content:\n#{anchored_md}\n\nInstruction: #{inst}"
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
  parsed_blocks = Blocks.parse_markdown_blocks(page_id, draft_md, prov, draft_prefix)

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

  try Policy.require_collection_access(auth, "propose", page_collection_id)
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
    collection_id: page_collection_id,
    target_page_id: page_id,
    target_database_id: None,
    branch_kind: "proposal",
    title: "AI Draft: #{page_title}",
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
    page_id: page_id,
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
    reason: "open AI draft proposal on #{page_id}",
    at: now
  )
  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created AI draft proposal #{prop_id}",
    Json.Object({"proposal_id": Json.String(prop_id), "page_id": Json.String(page_id)}),
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
      t2 = try Db.tx_put_proposal(t1, pm)
      Ok((t2, Unit))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "draft_markdown": Json.String(draft_md),
        "proposal": pm.to_json,
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

  col_rows = try Db.scan_collections(store, 200)
  var col_ttl = {}
  for (cid, col) in col_rows
    case col.freshness_ttl_days
      Some(d): col_ttl = col_ttl.set(cid, d)
      None: Unit
    end
  end

  page_rows = try Db.scan_pages(store, 500)
  var active_pages = {}
  for (pid, p) in page_rows
    if p.archived_at == None
      active_pages = active_pages.set(pid, p)
    end
  end

  var checked = 0
  var stale = []
  var broken = []
  var all_drifts = []
  var permitted_docs = []
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
          ) | Quote | Callout(tone: _, icon: _) | CodeBlock(language: _) | Divider | TableBlock(
            has_header: _
          ) | Toggle(summary: _, open: _) | TableOfContents | Image(
            attachment_id: _,
            caption: _
          ) | FileEmbed(attachment_id: _, filename: _) | DatabaseViewEmbed(
            database_id: _,
            view_id: _
          ) | AiBrief(prompt: _, source_scope: _, refreshed_at: _): Unit
        end
      end

      page_drifts = try Db.detect_page_citation_drifts(store, auth_opt, p, blks)
      for d in page_drifts
        all_drifts = all_drifts.append(d)
      end
      if p.kind == Document
        permitted_docs = permitted_docs.append((p, blks))
      end
    end
  end

  sorted_docs = permitted_docs.sort_by(fn(pair) pair.0.id end)
  dup_pairs = try Db.detect_duplicate_contradictions(store, auth_opt, sorted_docs)

  Ok(
    GardenReport(
      checked_pages: checked,
      stale_pages: stale,
      broken_links: broken,
      duplicate_pairs: dup_pairs,
      citation_drifts: all_drifts,
      scanned_at: now
    )
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
        GardenReport(
          checked_pages: 0,
          stale_pages: [],
          broken_links: [],
          duplicate_pairs: [],
          citation_drifts: [],
          scanned_at: now
        ).to_json
      )
    )
  end
  rep_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      rep = try scan_garden_report(Ledger.store(db), Some(auth), now)
      Ok(rep.to_json)
    end
  )
  Ok(json_ok(200, rep_json))
end

## Scheduled Knowledge Gardening scan (`job "vellum.garden" ... every 1.hour`), read-only over `vellum.modb`.
fn garden_job(_payload: Json, files: Files, clock: Clock) : Result(Unit, AppError)
  if not files.read_only.exists?(Db.ledger_db_path)
    return Ok(Unit)
  end
  now = clock.now
  Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      _rep = try scan_garden_report(Ledger.store(db), None, now)
      Ok(Unit)
    end
  )
end

fn citations_from_json_list(items: List(Json)) : List(Citation)
  var out = []
  for item in items
    out = out.append(
      Citation(
        source_kind: item.text_at("source_kind") or "page",
        source_ref: item.text_at("source_ref") or "",
        label: item.text_at("label") or "",
        excerpt: item.text_at("excerpt")
      )
    )
  end
  out
end

fn garden_draft_note(
  kind: Text,
  info: Json,
  custom_reason: Text,
  use_det?: Bool,
  env: Env,
  net: Network
) : Result((Text, Text), AppError)
  t_title = info.text_at("target_title") or ""
  target_ctx = info.text_at("target_excerpt") or ""
  rel_pg_title_opt = info.text_at("rel_page_title")
  rel_pg_id_opt = info.text_at("rel_page_id")
  rel_blk_id_opt = info.text_at("rel_block_id")
  rel_blk_ver = info.int_at("rel_block_version") or 1
  rel_blk_md = info.text_at("rel_block_markdown") or ""

  det_note = case (kind, rel_pg_title_opt, rel_pg_id_opt, rel_blk_id_opt)
    ("citation_drift", Some(rp_t), _, Some(rb_id)):
      "Gardener sync review: cited source [#{rp_t} §#{rb_id}] (v#{rel_blk_ver}) changed:\n#{rel_blk_md}"
    ("duplicate_contradiction", Some(rp_t), Some(rp_id), _):
      "Gardener contradiction check: reconcile overlap/conflict with '#{rp_t}' (#{rp_id}). #{custom_reason}"
    (_, Some(rp_t), _, _):
      "Gardener review suggested against '#{rp_t}': #{custom_reason}"
    (_, _, _, _):
      "Gardener verification reminder for '#{t_title}': #{custom_reason}"
  end
  if use_det?
    return Ok((det_note, "deterministic-gardener"))
  end
  case ai_config(env)
    Error(_): Ok((det_note, "deterministic-gardener"))
    Ok(cfg):
      sys = "You are Vellum Knowledge Gardener. Draft a crisp, actionable 1-2 sentence Markdown reconciliation callout for a Modb.World Change Proposal. Return plain Markdown text only."
      rel_ctx = case (rel_pg_title_opt, rel_pg_id_opt, rel_blk_id_opt)
        (Some(rp_t), _, Some(rb_id)):
          "\nCited Block [#{rp_t} §#{rb_id} v#{rel_blk_ver}]:\n#{rel_blk_md}"
        (Some(rp_t), Some(rp_id), None): "\nRelated Page [#{rp_t} (#{rp_id})]"
        (_, _, _): ""
      end
      usr = "Kind: #{kind}\nTarget Page: #{t_title}\nReason: #{custom_reason}\nTarget Excerpt:\n#{target_ctx}#{rel_ctx}"
      http_res = try Http.send(build_llm_request(cfg, sys, usr), net).map_error(fn(e)
        ServerFailed(reason: "Gardener LLM request failed: #{e.to_text}")
      end)
      if http_res.status < 200 or http_res.status >= 300
        return Ok((det_note, "deterministic-gardener"))
      end
      txt = (try extract_llm_text(cfg, http_res.body)).trim
      if txt.empty?
        Ok((det_note, "deterministic-gardener"))
      else
        Ok((txt, cfg.model))
      end
  end
end

## `POST /api/admin/garden/propose` — Proposals-Only Gardener: stages stale-refresh, duplicate/contradiction,
## or cited-dependency drift fixes strictly into a `Modb.World` Change Proposal (never writes live).
fn propose_garden_fix(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = GardenProposeInput(
    kind: try VaultOps.req_text(rj, "kind"),
    target_page_id: try VaultOps.req_text(rj, "target_page_id"),
    target_block_id: rj.text_at("target_block_id"),
    related_page_id: rj.text_at("related_page_id"),
    related_block_id: rj.text_at("related_block_id"),
    reason: rj.text_at("reason"),
    deterministic_fallback: rj.bool_at("deterministic_fallback")
  )
  kind = input.kind.trim.ascii_lowercase
  if kind != "citation_drift" and kind != "duplicate_contradiction" and kind != "stale_refresh"
    return Error(
      BadInput(
        reason: "kind must be 'citation_drift', 'duplicate_contradiction', or 'stale_refresh'"
      )
    )
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: input.target_page_id))
  end

  cfg_url_opt = case ai_config(env)
    Ok(c): Some(c.base_url)
    Error(_): None
  end
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  g_ctx = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      tpg = case try Db.get_page(store, input.target_page_id)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: input.target_page_id))
      end
      try Policy.require_collection_access(auth, "propose", tpg.collection_id)
      case cfg_url_opt
        Some(url):
          try VaultOps.require_ai_allowed_for_collection(
            store,
            tpg.collection_id,
            url,
            local_only_ai?
          )
        None: Unit
      end
      tblks = try Db.load_page_blocks(store, tpg.id)

      rpg_opt = case input.related_page_id
        Some(rpid) if not rpid.trim.empty?:
          rp = case try Db.get_page(store, rpid.trim)
            Some(p) if p.archived_at == None: p
            Some(_) | None: return Error(Missing(entity: "page", id: rpid.trim))
          end
          try Policy.require_collection_access(auth, "read", rp.collection_id)
          Some(rp)
        Some(_) | None: None
      end
      rblk_opt = case input.related_block_id
        Some(rbid) if not rbid.trim.empty?:
          case try Table.get(store, Db.blocks_table(), rbid.trim).map_error(Db.map_table_error)
            Some(rb):
              rpg2 = case try Db.get_page(store, rb.page_id)
                Some(p) if p.archived_at == None: p
                Some(_) | None: return Error(Missing(entity: "page", id: rb.page_id))
              end
              try Policy.require_collection_access(auth, "read", rpg2.collection_id)
              Some(rb)
            None: return Error(Missing(entity: "block", id: rbid.trim))
          end
        Some(_) | None: None
      end
      var tb_ver_opt = None
      var tb_md_opt = None
      case input.target_block_id
        Some(tbid) if not tbid.trim.empty?:
          case tblks.find(fn(b) b.id == tbid.trim end)
            Some(tb):
              tb_ver_opt = Some(tb.version)
              tb_md_opt = Some(tb.markdown)
            None: Unit
          end
        Some(_) | None: Unit
      end
      last_bid_opt = tblks.last.map(fn(b) b.id end)
      Ok(
        Json.Object({
          "target_id": Json.String(tpg.id),
          "target_title": Json.String(tpg.title),
          "target_col_id": Json.String(tpg.collection_id),
          "target_excerpt": Json.String(Blocks.blocks_plain_text(tblks.take(6))),
          "last_block_id": last_bid_opt.to_json,
          "target_block_ver": tb_ver_opt.to_json,
          "target_block_md": tb_md_opt.to_json,
          "rel_page_id": rpg_opt.map(fn(p) p.id end).to_json,
          "rel_page_title": rpg_opt.map(fn(p) p.title end).to_json,
          "rel_block_id": rblk_opt.map(fn(b) b.id end).to_json,
          "rel_block_page_id": rblk_opt.map(fn(b) b.page_id end).to_json,
          "rel_block_version": rblk_opt.map(fn(b) b.version end).to_json,
          "rel_block_markdown": rblk_opt.map(fn(b) b.markdown end).to_json
        })
      )
    end
  )
  target_pg_id = g_ctx.text_at("target_id") or input.target_page_id
  target_pg_title = g_ctx.text_at("target_title") or ""
  target_col_id = g_ctx.text_at("target_col_id") or ""

  reason_str = case input.reason
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: "Knowledge Gardener #{kind} proposal"
  end
  (note_md, model_label) = try garden_draft_note(
    kind,
    g_ctx,
    reason_str,
    input.deterministic_fallback or false,
    env,
    net
  )

  var cits = []
  case g_ctx.text_at("rel_block_id")
    Some(rb_id):
      src_title = g_ctx.text_at("rel_page_title") or (g_ctx.text_at("rel_block_page_id") or "")
      cits = cits.append(
        Citation(
          source_kind: "block",
          source_ref: rb_id,
          label: "#{src_title} §#{rb_id}",
          excerpt: g_ctx.text_at("rel_block_markdown")
        )
      )
    None:
      case (g_ctx.text_at("rel_page_id"), g_ctx.text_at("rel_page_title"))
        (Some(rp_id), Some(rp_t)): cits = cits.append(
          Citation(
            source_kind: "page",
            source_ref: "/p/#{rp_id}",
            label: rp_t,
            excerpt: None
          )
        )
        (_, _): Unit
      end
  end

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

  prop_prov = Provenance(
    author_id: auth.principal.id,
    author_kind: AgentAuthor(model: Some(model_label)),
    grant_id: if auth.principal.kind == Agent: Some(auth.grant_id) else: None,
    proposal_id: Some(prop_id),
    reason: Some(reason_str),
    citations: cits,
    updated_at: now
  )
  (ops, new_ids) = case (input.target_block_id, g_ctx.int_at("target_block_ver"), g_ctx.text_at("target_block_md"))
    (Some(tbid), Some(tbv), Some(tbm)) if kind == "citation_drift" and not tbid.trim.empty?:
      (
        [
          ReplaceBlock(
            block_id: tbid.trim,
            expected_version: tbv,
            kind: None,
            markdown: "#{tbm}\n\n#{note_md}"
          )
        ],
        []
      )
    (_, _, _):
      new_bid = "blk_#{Id.ulid(rng, clock)}"
      tone = if kind == "duplicate_contradiction": "WARNING" else: "NOTE"
      (
        [
          InsertBlockAfter(
            after_block_id: g_ctx.text_at("last_block_id"),
            parent_block_id: None,
            kind: Callout(tone: tone, icon: Some("leaf")),
            markdown: note_md
          )
        ],
        [new_bid]
      )
  end

  wargs = WorldPatchArgs(
    page_id: target_pg_id,
    ops: ops,
    new_ids: new_ids,
    provenance: prop_prov,
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
    reason_str,
    now
  ).map_error(Db.map_world_error)

  prop_title = if kind == "citation_drift"
    "Gardener Drift: #{target_pg_title}"
  else if kind == "duplicate_contradiction"
    "Gardener Reconcile: #{target_pg_title}"
  else
    "Gardener Refresh: #{target_pg_title}"
  end
  pm = ProposalMeta(
    id: prop_id,
    world_id: world_id,
    collection_id: target_col_id,
    target_page_id: target_pg_id,
    target_database_id: None,
    branch_kind: "proposal",
    title: prop_title,
    reason: reason_str,
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
    action: "garden.propose",
    reason: reason_str,
    at: now
  )
  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "staged gardener proposal #{pm.id}",
    Json.Object({
      "proposal_id": Json.String(pm.id),
      "page_id": Json.String(target_pg_id),
      "kind": Json.String(kind)
    }),
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
      t2 = try Db.tx_put_proposal(t1, pm)
      Ok((t2, Unit))
    end
  )

  prop_ev = Json.Object({
    "proposal_id": Json.String(pm.id),
    "page_id": Json.String(target_pg_id),
    "collection_id": Json.String(target_col_id),
    "title": Json.String(pm.title),
    "actor": Json.String(auth.principal.handle)
  })
  Ok(
    json_ok(
      201,
      Json.Object({
        "proposal": pm.to_json,
        "kind": Json.String(kind),
        "target_page_id": Json.String(target_pg_id),
        "citations": cits.to_json,
        "model": Json.String(model_label)
      })
    ).with_sse_publish_json("page:#{target_pg_id}", "proposal.opened", prop_ev)
      .with_sse_publish_json("collection:#{target_col_id}", "proposal.opened", prop_ev)
  )
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
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = RefreshAiBriefInput(
    page_id: try VaultOps.req_text(rj, "page_id"),
    block_id: try VaultOps.req_text(rj, "block_id"),
    deterministic_fallback: rj.bool_at("deterministic_fallback")
  )
  if auth.principal.suspended
    return Error(Forbidden(reason: "principal '#{auth.principal.handle}' is suspended"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "page", id: input.page_id))
  end

  cfg_url_opt = case ai_config(env)
    Ok(c): Some(c.base_url)
    Error(_): None
  end
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  brief_ctx = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pg = case try Db.get_page(store, input.page_id.trim)
        Some(p) if p.archived_at == None: p
        Some(_) | None: return Error(Missing(entity: "page", id: input.page_id))
      end
      try Policy.require_collection_access(auth, "read", pg.collection_id)
      try Policy.require_collection_access(auth, "propose", pg.collection_id)
      if input.deterministic_fallback != Some(true)
        case cfg_url_opt
          Some(url):
            try VaultOps.require_ai_allowed_for_collection(
              store,
              pg.collection_id,
              url,
              local_only_ai?
            )
          None: Unit
        end
      end

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
        ) | Quote | Callout(tone: _, icon: _) | CodeBlock(language: _) | Divider | TableBlock(
          has_header: _
        ) | Toggle(summary: _, open: _) | TableOfContents | Image(
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
        if input.deterministic_fallback != Some(true)
          case cfg_url_opt
            Some(url):
              if not try VaultOps.ai_allowed_for_collection(
                store,
                s.collection_id,
                url,
                local_only_ai?
              )
                continue
              end
            None: Unit
          end
        end
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
      Ok(
        Json.Object({
          "page_id": Json.String(pg.id),
          "page_title": Json.String(pg.title),
          "collection_id": Json.String(pg.collection_id),
          "block_id": Json.String(tblk.id),
          "block_version": Json.int(tblk.version),
          "brief_prompt": Json.String(pr_txt),
          "scope": sc_opt.to_json,
          "sum_lines": lines.to_json,
          "citations": citations.to_json
        })
      )
    end
  )
  pg_id = brief_ctx.text_at("page_id") or input.page_id.trim
  pg_title = brief_ctx.text_at("page_title") or ""
  pg_collection_id = brief_ctx.text_at("collection_id") or ""
  target_blk_id = brief_ctx.text_at("block_id") or input.block_id.trim
  target_blk_ver = brief_ctx.int_at("block_version") or 1
  brief_prompt = brief_ctx.text_at("brief_prompt") or ""
  scope_opt = brief_ctx.text_at("scope")
  sum_lines = VaultOps.json_text_list_raw(brief_ctx, "sum_lines")
  cits = citations_from_json_list(brief_ctx.list_at("citations") or [])

  digest = if sum_lines.empty?
    "- No accessible workspace summaries in scope yet."
  else
    sum_lines.join("\n")
  end

  (brief_md, model_name) = case ai_config(env)
    Ok(cfg):
      sys_prompt = "You maintain a concise Living Brief card inside a Vellum knowledge document. Synthesize strictly from the provided workspace summaries using crisp Markdown bullet points."
      usr_prompt = "Document: #{pg_title}\nBrief Goal: #{brief_prompt}\n\nAccessible Living Summaries:\n#{digest}"
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
      block_id: target_blk_id,
      expected_version: target_blk_ver,
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
    page_id: pg_id,
    ops: ops,
    new_ids: [],
    provenance: prov,
    expected_versions: {target_blk_id: target_blk_ver},
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
    collection_id: pg_collection_id,
    target_page_id: pg_id,
    target_database_id: None,
    branch_kind: "proposal",
    title: "Refresh Living Brief: #{brief_prompt}",
    reason: "Proposals-only Living AI Brief refresh on '#{target_blk_id}'",
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
    reason: "stage refreshed ai-brief proposal on #{pg_id}",
    at: now
  )
  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created AI brief proposal #{prop_id} for #{pg_id}",
    Json.Object({"proposal_id": Json.String(prop_id), "page_id": Json.String(pg_id)}),
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
      t2 = try Db.tx_put_proposal(t1, pm)
      Ok((t2, Unit))
    end
  )

  Ok(
    json_ok(
      201,
      Json.Object({
        "proposal": pm.to_json,
        "draft_markdown": Json.String(brief_md),
        "block_id": Json.String(target_blk_id),
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
        Select(options: opts) | Status(options: opts, done_option_ids: _) | AiDerived(
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
        Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
          prefix: _
        ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
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
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | FilesVal(attachment_ids: xs) | RelationVal(
      row_ids: xs
    ): xs.join(", ")
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
        ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
          prefix: _
        ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
          target_db_id: _,
          inverse_prop_id: _
        ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): true
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
      def = case try Db.get_database(store, id)
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
          ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
            prefix: _
          ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
            target_db_id: _,
            inverse_prop_id: _
          ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): Unit
        end
      end

      r_pairs = try Db.lookup_db_rows_by_database(store, def.id)
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
                ) | MultiSelect(options: _) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
                  prefix: _
                ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
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
  _u = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      d = case try Db.get_database(Ledger.store(db), id)
        Some(x): x
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "read", d.collection_id)
      Ok(Unit)
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
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = RunAiColumnInput(
    row_ids: VaultOps.json_text_list_opt(rj, "row_ids"),
    only_stale: rj.bool_at("only_stale"),
    mode_override: rj.text_at("mode_override"),
    deterministic_fallback: rj.bool_at("deterministic_fallback")
  )
  if auth.principal.suspended or not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "database", id: id))
  end

  now = clock.now
  day_iso = now.to_text.bytes.slice(0, 10).decode_utf8 or "1970-01-01"

  def_check_j = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      d = case try Db.get_database(store, id)
        Some(x): x
        None: return Error(Missing(entity: "database", id: id))
      end
      try Policy.require_collection_access(auth, "read", d.collection_id)
      Ok(d.to_json)
    end
  )
  def_props_j = try def_check_j.get("properties").or_fail(
    ServerFailed(reason: "missing database properties")
  )
  def_props = try DatabaseModel.decode_property_defs_json(def_props_j.to_text.bytes).map_error(fn(e)
    ServerFailed(reason: e)
  end)
  def_check = DatabaseDef(
    id: def_check_j.text_at("id") or id,
    collection_id: def_check_j.text_at("collection_id") or "",
    page_id: def_check_j.text_at("page_id") or "",
    title: def_check_j.text_at("title") or "",
    description: def_check_j.text_at("description") or "",
    properties: def_props,
    version: def_check_j.int_at("version") or 1
  )
  prop = try def_check.properties.find(fn(p) p.id == prop_id end).or_fail(
    Missing(entity: "property", id: prop_id)
  )
  (prompt_str, src_ids, include_body?, out_kind, col_mode, daily_cap) = case prop.kind
    AiDerived(
      prompt: pr_t,
      source_prop_ids: sids,
      include_row_body: inc_b,
      output_kind: ok_k,
      mode: cm,
      daily_call_cap: cap
    ): (pr_t, sids, inc_b, ok_k, cm, cap)
    Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
      options: _
    ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
      prefix: _
    ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
      target_db_id: _,
      inverse_prop_id: _
    ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): return Error(
      BadInput(reason: "property '#{prop_id}' is not an AI-compiled column")
    )
  end

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
  # Sync Modb.Feeds O(diff) staleness cursor before evaluating target rows
  _feed_sync = try Db.sync_ai_col_feed_locked(files, def_check.id, now)

  usage_key = DatabaseModel.ai_col_usage_key(def_check.id, prop.id, day_iso)
  pr_hash = DatabaseModel.compute_ai_prompt_hash(prompt_str, out_kind)
  only_stale? = case input.only_stale
    Some(b): b
    None: true
  end

  cfg_url_opt = case ai_config(env)
    Ok(c): Some(c.base_url)
    Error(_): None
  end
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  col_pre = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      col_check = case try Db.get_collection(store, def_check.collection_id)
        Some(x): x
        None: return Error(Missing(entity: "collection", id: def_check.collection_id))
      end
      eff_m = if col_check.write_policy == ProposalsRequiredForAll or
        (col_check.write_policy == ProposalsRequiredForAgents and auth.principal.kind == Agent)
        StageProposal
      else
        base_mode
      end
      write_act = if eff_m == AutoApply
        if Policy.action_permitted?(auth, "write_db"): "write_db" else: "write_direct"
      else
        "propose"
      end
      try Policy.require_collection_access(auth, write_act, col_check.id)
      case cfg_url_opt
        Some(url):
          try VaultOps.require_ai_allowed_for_collection(
            store,
            col_check.id,
            url,
            local_only_ai?
          )
        None: Unit
      end
      used = case try Table.get(store, Db.ai_col_usage_table(), usage_key).map_error(
        Db.map_table_error
      )
        Some(u): u.calls_used
        None: 0
      end
      r_pairs = try Db.lookup_db_rows_by_database(store, def_check.id)
      active_rows = r_pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end).sort_by(
        fn(r) r.id end
      )

      row_filter = case input.row_ids
        Some(xs) if not xs.empty?: Some(xs)
        Some(_) | None: None
      end

      var out_cands = []
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
          (rt, st, rcits) = build_row_ai_context(def_check, r, src_ids, include_body?, blks)
          out_cands = out_cands.append(
            Json.Object({
              "row_id": Json.String(r.id),
              "row_version": Json.int(r.version),
              "in_h": Json.String(in_h),
              "row_title": Json.String(rt),
              "src_txt": Json.String(st),
              "citations": rcits.to_json
            })
          )
        end
      end
      Ok(
        Json.Object({
          "used_before": Json.int(used),
          "auto_apply": Json.Boolean(eff_m == AutoApply),
          "write_act": Json.String(write_act),
          "candidates": Json.Array(out_cands)
        })
      )
    end
  )
  eff_mode = if col_pre.bool_at("auto_apply") == Some(true): AutoApply else: StageProposal
  write_act = col_pre.text_at("write_act") or "propose"
  used_before = col_pre.int_at("used_before") or 0
  candidates = col_pre.list_at("candidates") or []

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

  for cand in to_eval
    cand_row_id = cand.text_at("row_id") or ""
    cand_row_ver = cand.int_at("row_version") or 1
    in_h = cand.text_at("in_h") or ""
    row_title = cand.text_at("row_title") or ""
    src_txt = cand.text_at("src_txt") or ""
    cits = citations_from_json_list(cand.list_at("citations") or [])
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
            "row_id": Json.String(cand_row_id),
            "status": Json.String("validation_error"),
            "error": Json.String(parse_msg)
          })
        )
      Ok((cell_val, rat_opt, mname)):
        case DatabaseModel.validate_cell(prop, cell_val)
          Some(val_msg):
            result_items = result_items.append(
              Json.Object({
                "row_id": Json.String(cand_row_id),
                "status": Json.String("validation_error"),
                "error": Json.String(val_msg)
              })
            )
          None:
            valid_updates = valid_updates.append((
              cand_row_id,
              cand_row_ver,
              cell_val,
              rat_opt,
              cits,
              in_h,
              mname
            ))
            result_items = result_items.append(
              Json.Object({
                "row_id": Json.String(cand_row_id),
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
    auto_res_json = try Ledger.transact_locked(
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
        t = try Db.tx_put_ai_col_usage(t, new_u)

        var applied = 0
        for (orig_row_id, _orig_ver, cell_val, rat_opt, cits, in_h, mname) in valid_updates
          cur_def = case try Db.tx_get_database(t, def_check.id)
            Some(d): d
            None: def_check
          end
          cur_row = case try Db.tx_get_db_row(t, orig_row_id)
            Some(r) if r.archived_at == None: r
            Some(_) | None: continue
          end
          old_pg = case try Db.tx_get_page(t, cur_row.page_id)
            Some(p): p
            None: continue
          end
          blks = try Db.tx_lookup_blocks_by_page(t, old_pg.id)
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
          t = try Db.tx_put_ai_cell_meta(t, cmeta)
          applied += 1
        end
        Ok((
          t,
          Json.Object({
            "calls_used": Json.int(new_u.calls_used),
            "updated_cnt": Json.int(applied)
          })
        ))
      end
    )
    auto_used = auto_res_json.int_at("calls_used") or 0
    updated_cnt = auto_res_json.int_at("updated_cnt") or 0
    rem_after = if daily_cap > auto_used
      daily_cap - auto_used
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
            "calls_used": Json.int(auto_used),
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
  usage_res_json = try Ledger.transact_locked(
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
      t1 = try Db.tx_put_ai_col_usage(t, new_u)
      Ok((t1, Json.Object({"calls_used": Json.int(new_u.calls_used)})))
    end
  )
  st_used = usage_res_json.int_at("calls_used") or 0
  rem_after = if daily_cap > st_used
    daily_cap - st_used
  else
    0
  end
  usage_json = Json.Object({
    "calls_used": Json.int(st_used),
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
  for (cand_row_id, cand_row_ver, cell_val, rat_opt, cits, in_h, mname) in valid_updates
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
      row_id: cand_row_id,
      cells: {prop.id: cell_val},
      expected_version: Some(cand_row_ver),
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
      "stage AI cell #{prop.id} on #{cand_row_id}",
      now
    ).map_error(Db.map_world_error)

    cmeta = AiCellMeta(
      id: DatabaseModel.ai_cell_meta_key(def_check.id, cand_row_id, prop.id),
      database_id: def_check.id,
      row_id: cand_row_id,
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
      "stage AI cell metadata #{prop.id} on #{cand_row_id}",
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
  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    pmeta,
    "created AI column proposal #{prop_id_new}",
    Json.Object({"proposal_id": Json.String(prop_id_new), "database_id": Json.String(def_check.id)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try Db.tx_put_proposal(tx, pm)
      Ok((t1, Unit))
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
        "proposal": pm.to_json
      })
    )
  )
end

## JSON payload for `POST /api/proposals/:id/steer`.
struct SteerProposalInput
  target_block_id: Option(Text)
  target_page_id: Option(Text)
  instruction: Text
  deterministic_fallback: Option(Bool)
end

## Builds exact `(system_prompt, user_prompt)` strings for Patchwork Steer-in-Place revision.
fn build_steer_prompts(
  page_title: Text,
  block_id: Text,
  live_md: Text,
  proposed_md: Text,
  instruction: Text
) : (Text, Text)
  sys_prompt = "You are revising a speculative Vellum proposal block in-place inside a Modb.World branch. Return ONLY the revised Markdown for this single block without code fences or commentary."
  usr_prompt = "Page: #{page_title}\nBlock: #{block_id}\nCurrent Live Text:\n#{live_md}\n\nCurrent Proposed Text:\n#{proposed_md}\n\nReviewer Steer Instruction:\n#{instruction}"
  (sys_prompt, usr_prompt)
end

## `POST /api/proposals/:id/steer` — Revises a single block inside an existing `Modb.World` branch according to reviewer instruction and records anchored comments.
fn steer_proposal(
  req: Api.Request,
  id: Text,
  auth: AuthContext,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  rj = try VaultOps.parse_req_json_obj(req.text)
  input = SteerProposalInput(
    target_block_id: rj.text_at("target_block_id"),
    target_page_id: rj.text_at("target_page_id"),
    instruction: try VaultOps.req_text(rj, "instruction"),
    deterministic_fallback: rj.bool_at("deterministic_fallback")
  )
  clean_instr = input.instruction.trim
  if clean_instr.empty?
    return Error(BadInput(reason: "steer instruction must not be empty"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "proposal", id: id))
  end

  cfg_url_opt = case ai_config(env)
    Ok(c): Some(c.base_url)
    Error(_): None
  end
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  st_ctx = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      found = case try Db.get_proposal(store, id)
        Some(p): p
        None: return Error(Missing(entity: "proposal", id: id))
      end
      if found.status != "open"
        return Error(Conflict(reason: "proposal '#{id}' is '#{found.status}', not 'open'"))
      end
      try Policy.require_collection_access(auth, "propose", found.collection_id)
      if input.deterministic_fallback != Some(true)
        case cfg_url_opt
          Some(url):
            try VaultOps.require_ai_allowed_for_collection(
              store,
              found.collection_id,
              url,
              local_only_ai?
            )
          None: Unit
        end
      end
      world = case try World.get_world(store, found.world_id).map_error(Db.map_world_error)
        Some(w): w
        None: return Error(Missing(entity: "world", id: found.world_id))
      end
      (base_tx, spec_tx) = try Db.materialize_world_tx(store, world)
      pid = case input.target_page_id
        Some(p) if not p.trim.empty?: p.trim
        Some(_) | None: found.target_page_id
      end
      pg_spec = try Db.tx_get_page(spec_tx, pid)
      pg_base = try Db.tx_get_page(base_tx, pid)
      ptitle = case pg_spec
        Some(p): p.title
        None:
          case pg_base
            Some(p): p.title
            None: pid
          end
      end

      brows = try Db.tx_lookup_blocks_by_page(base_tx, pid)
      srows = try Db.tx_lookup_blocks_by_page(spec_tx, pid)
      base_blocks = Blocks.sort_blocks(brows.map(fn(x) x.1 end))
      spec_blocks = Blocks.sort_blocks(srows.map(fn(x) x.1 end))
      var base_by_id = {}
      for bb in base_blocks
        base_by_id = base_by_id.set(bb.id, bb)
      end

      chosen = case input.target_block_id
        Some(bid) if not bid.trim.empty?:
          tbid = bid.trim
          case spec_blocks.find(fn(b) b.id == tbid end)
            Some(sb): sb
            None: return Error(Missing(entity: "block", id: tbid))
          end
        Some(_) | None:
          changed_opt = spec_blocks.find(fn(sb)
            case base_by_id.get(sb.id)
              None: true
              Some(bb): bb.markdown != sb.markdown or bb.kind != sb.kind
            end
          end)
          case changed_opt
            Some(sb): sb
            None:
              case spec_blocks.first
                Some(sb): sb
                None: return Error(
                  BadInput(reason: "no block available on page '#{pid}' to steer")
                )
              end
          end
      end

      cur_live = case base_by_id.get(chosen.id)
        Some(bb): bb.markdown
        None: ""
      end
      Ok(
        Json.Object({
          "proposal": found.to_json,
          "proposal_id": Json.String(found.id),
          "collection_id": Json.String(found.collection_id),
          "world_id": Json.String(found.world_id),
          "target_pid": Json.String(pid),
          "page_title": Json.String(ptitle),
          "block_id": Json.String(chosen.id),
          "block_version": Json.int(chosen.version),
          "block_markdown": Json.String(chosen.markdown),
          "live_md": Json.String(cur_live)
        })
      )
    end
  )
  pm_json = st_ctx.get("proposal") or Json.Null
  pm_id = st_ctx.text_at("proposal_id") or id
  pm_collection_id = st_ctx.text_at("collection_id") or ""
  pm_world_id = st_ctx.text_at("world_id") or ""
  target_pid = st_ctx.text_at("target_pid") or ""
  page_title = st_ctx.text_at("page_title") or ""
  spec_blk_id = st_ctx.text_at("block_id") or ""
  spec_blk_ver = st_ctx.int_at("block_version") or 1
  spec_blk_md = st_ctx.text_at("block_markdown") or ""
  live_md = st_ctx.text_at("live_md") or ""

  # Execute LLM call strictly outside any MoDB lock
  (sys_prompt, usr_prompt) = build_steer_prompts(
    page_title,
    spec_blk_id,
    live_md,
    spec_blk_md,
    clean_instr
  )
  use_det? = input.deterministic_fallback or false
  (revised_md, model_name) = if not use_det?
    case ai_config(env)
      Ok(cfg):
        http_res = try Http.send(build_llm_request(cfg, sys_prompt, usr_prompt), net).map_error(
          fn(e) ServerFailed(reason: "Steer LLM HTTP request failed: #{e.to_text}") end
        )
        if http_res.status < 200 or http_res.status >= 300
          return Error(
            ServerFailed(reason: "Steer LLM provider returned HTTP #{http_res.status}")
          )
        end
        txt = (try extract_llm_text(cfg, http_res.body)).trim
        if txt.empty?
          return Error(ServerFailed(reason: "Steer LLM returned empty response"))
        end
        (txt, cfg.model)
      Error(e):
        return Error(BadInput(reason: "AI provider not configured for Steer-in-Place: #{e.to_text}"))
    end
  else
    ("#{spec_blk_md.trim} [Steered: #{clean_instr}]", "deterministic-steer")
  end

  now = clock.now
  agent_prov = Provenance(
    author_id: auth.principal.id,
    author_kind: AgentAuthor(model: Some(model_name)),
    grant_id: if auth.principal.kind == Agent: Some(auth.grant_id) else: None,
    proposal_id: Some(pm_id),
    reason: Some("Steered in-place: #{clean_instr}"),
    citations: [],
    updated_at: now
  )
  patch_mut = PatchPageBlocks(
    page_id: target_pid,
    ops: [
      ReplaceBlock(
        block_id: spec_blk_id,
        expected_version: spec_blk_ver,
        kind: None,
        markdown: revised_md
      )
    ],
    new_ids: [],
    provenance: agent_prov,
    expected_versions: {}
  )
  _step = try World.world_call_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.world_catalog(),
    pm_world_id,
    "propose",
    WorldBranchArgs(mutation: patch_mut, updated_at: now).to_json,
    "steer block #{spec_blk_id} in #{pm_id}",
    now
  ).map_error(Db.map_world_error)

  h_kind = case auth.principal.kind
    Human: HumanAuthor
    Agent: AgentAuthor(model: auth.principal.model_id)
  end
  human_cmt = ProposalComment(
    id: "pcmt_#{Id.ulid(rng, clock)}",
    proposal_id: pm_id,
    target_kind: "block",
    target_ref: Some(spec_blk_id),
    parent_comment_id: None,
    author_id: auth.principal.id,
    author_handle: auth.principal.handle,
    author_kind: h_kind,
    body_markdown: clean_instr,
    steer_requested: true,
    resolved_at: None,
    created_at: now
  )
  agent_cmt = ProposalComment(
    id: "pcmt_#{Id.ulid(rng, clock)}",
    proposal_id: pm_id,
    target_kind: "block",
    target_ref: Some(spec_blk_id),
    parent_comment_id: Some(human_cmt.id),
    author_id: auth.principal.id,
    author_handle: "@vellum-steer",
    author_kind: AgentAuthor(model: Some(model_name)),
    body_markdown: "Revised block `#{spec_blk_id}` in-place inside branch `#{pm_world_id}`.",
    steer_requested: false,
    resolved_at: None,
    created_at: now
  )
  cmeta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "proposal.steer",
    reason: "steer block '#{spec_blk_id}' inside proposal '#{pm_id}'",
    at: now
  )
  audit_payload = Json.Object({
    "proposal_id": Json.String(pm_id),
    "block_id": Json.String(spec_blk_id),
    "model": Json.String(model_name)
  })
  try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    cmeta,
    "steered block #{spec_blk_id} in proposal #{pm_id}",
    audit_payload,
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
      t2 = try Db.tx_put_proposal_comment(t1, human_cmt)
      t3 = try Db.tx_put_proposal_comment(t2, agent_cmt)
      Ok((t3, Unit))
    end
  )

  steer_ev = Json.Object({
    "proposal_id": Json.String(pm_id),
    "page_id": Json.String(target_pid),
    "block_id": Json.String(spec_blk_id),
    "actor": Json.String(auth.principal.handle)
  })
  var resp = json_ok(
    200,
    Json.Object({
      "proposal": pm_json,
      "human_comment": human_cmt.to_json,
      "agent_comment": agent_cmt.to_json,
      "revised_block_id": Json.String(spec_blk_id),
      "revised_markdown": Json.String(revised_md),
      "model": Json.String(model_name)
    })
  ).with_sse_publish_json("collection:#{pm_collection_id}", "proposal.updated", steer_ev)
    .with_sse_publish_json("collection:#{pm_collection_id}", "proposal.commented", steer_ev)
  if not target_pid.trim.empty?
    resp = resp.with_sse_publish_json("page:#{target_pid}", "proposal.updated", steer_ev)
      .with_sse_publish_json("page:#{target_pid}", "proposal.commented", steer_ev)
  end
  Ok(resp)
end

## JSON payload for `POST /api/ai/deep-research` and MCP `vellum.rlm_query` (RLM Tier 1 & Tier 2).
struct DeepResearchInput
  question: Text
  collection_id: Option(Text)
  block_kinds: Option(List(Text))
  heading_contains: Option(Text)
  include_databases: Option(Bool)
  max_pages: Option(Int)
  max_blocks_per_page: Option(Int)
  max_subcalls: Option(Int)
  max_rows_scanned: Option(Int)
  session_id: Option(Text)
  tier: Option(Text)
  script: Option(Text)
  max_depth: Option(Int)
end

## Structured Tier 1 / Tier 2 RLM Deep Research result with inspectable `Modb.Views` / VM trace & `Modb.Taint` state.
struct DeepResearchOutcome
  tier: Text
  answer: Text
  model: Text
  session_id: Text
  untrusted_tainted: Bool
  max_sensitivity_read: Text
  untrusted_sources: List(Text)
  rows_scanned: Int
  ops_used: Int
  subcalls_used: Int
  max_subcalls: Int
  citations: List(Json)
  db_slices: List(RlmDbSlice)
  trace: List(RlmTraceStep)
  executed_script: Option(Text)
  depth_used: Int
  max_depth: Int
  child_sessions: List(Text)
  grant_calls_debited: Int
end

fn rlm_clamp(opt: Option(Int), def_v: Int, lo: Int, hi: Int) : Int
  case opt
    Some(v):
      if v < lo: lo else if v > hi: hi else: v
    None: def_v
  end
end

fn rlm_auth_mode(auth: AuthContext) : (Option(Text), Bool)
  case auth.allowed_collections
    Some(_): (Some(auth.grant_id), false)
    None: (None, true)
  end
end

fn rlm_target_collections(
  rf: ReadFiles,
  auth: AuthContext,
  col_filter: Option(Text),
  ai_url_opt: Option(Text),
  local_only_ai?: Bool
) : Result((List(Text), List(Text)), AppError)
  filter_opt = case col_filter
    Some(raw) if not raw.trim.empty?: Some(raw.trim)
    Some(_) | None: None
  end
  if not rf.exists?(Db.ledger_db_path)
    return case filter_opt
      Some(cid): Error(Missing(entity: "collection", id: cid))
      None: Ok(([], []))
    end
  end
  cols_json = try Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      pairs = try Db.scan_collections(store, 200)
      active = pairs.filter(fn(p) p.1.archived_at == None end).map(fn(p) p.1 end).sort_by(
        fn(c) c.id end
      )
      ok_cols = case (filter_opt, ai_url_opt)
        (Some(cid), Some(url)):
          if active.any?(fn(c) c.id == cid end)
            try Policy.require_collection_access(auth, "read", cid)
            try VaultOps.require_ai_allowed_for_collection(store, cid, url, local_only_ai?)
          end
          active
        (Some(cid), None):
          if active.any?(fn(c) c.id == cid end)
            try Policy.require_collection_access(auth, "read", cid)
          end
          active
        (None, Some(url)):
          var xs = []
          for c in active
            if Policy.collection_permitted?(auth, c.id) and try VaultOps.ai_allowed_for_collection(
              store,
              c.id,
              url,
              local_only_ai?
            )
              xs = xs.append(c)
            end
          end
          xs
        (None, None): active
      end
      Ok(
        Json.Object({
          "all_ids": ok_cols.map(fn(c) c.id end).to_json,
          "permitted_ids": ok_cols
            .filter(fn(c) Policy.collection_permitted?(auth, c.id) end)
            .map(fn(c) c.id end)
            .to_json
        })
      )
    end
  )
  all_col_ids = VaultOps.json_text_list_raw(cols_json, "all_ids")
  perm_col_ids = VaultOps.json_text_list_raw(cols_json, "permitted_ids")
  case filter_opt
    Some(cid):
      if not all_col_ids.contains?(cid)
        return Error(Missing(entity: "collection", id: cid))
      end
      try Policy.require_collection_access(auth, "read", cid)
      Ok(([cid], [cid]))
    None: Ok((perm_col_ids, perm_col_ids))
  end
end

## Formats the sub-agent map step prompts for a bounded chunk of RLM block slices.
fn build_rlm_subcall_prompts(
  question: Text,
  chunk_idx: Int,
  total_chunks: Int,
  slices: List(RlmBlockSlice)
) : (Text, Text)
  sys = "You are Vellum RLM Deep Research sub-agent #{chunk_idx}/#{total_chunks}. Extract exact facts strictly from the provided sliced workspace blocks and preserve every [PageTitle §block_id] citation."
  var parts = ["Question: #{question}", "", "Sliced Workspace Blocks (Chunk #{chunk_idx}/#{total_chunks}):"]
  for s in slices
    hp = case s.heading_path
      Some(h): ", section=#{h}"
      None: ""
    end
    parts = parts.append("[#{s.page_title} §#{s.block_id}] (#{s.kind_tag}#{hp})\n#{s.markdown}")
  end
  (sys, parts.join("\n"))
end

## Formats the final Tier 1 RLM synthesizer prompts over sub-agent notes, block slices, and DB slices.
fn build_rlm_synthesis_prompts(
  question: Text,
  subcall_notes: List(Text),
  slices: List(RlmBlockSlice),
  db_slices: List(RlmDbSlice)
) : (Text, Text)
  sys = "You are Vellum RLM Deep Research synthesizer. Synthesize a concise, verified answer strictly from the inspected block slices, database slices, and sub-agent findings. Cite [Title §block_id] and [DB: DatabaseTitle #row_id]."
  var parts = ["Question: #{question}"]
  if not subcall_notes.empty?
    parts = parts.append("")
    parts = parts.append("Sub-Agent Map Findings:")
    for note in subcall_notes
      parts = parts.append(note)
    end
  end
  if not slices.empty?
    parts = parts.append("")
    parts = parts.append("Inspected Block Slices (#{slices.size}):")
    for s in slices
      hp = case s.heading_path
        Some(h): ", section=#{h}"
        None: ""
      end
      parts = parts.append("[#{s.page_title} §#{s.block_id}] (#{s.kind_tag}#{hp})\n#{s.markdown}")
    end
  end
  if not db_slices.empty?
    parts = parts.append("")
    parts = parts.append("Inspected Database Slices (#{db_slices.size}):")
    for d in db_slices
      parts = parts.append(
        "[DB: #{d.database_title} ##{d.row_id}] #{d.title} — #{d.cells_summary}"
      )
    end
  end
  if slices.empty? and db_slices.empty?
    parts = parts.append("")
    parts = parts.append("(No matching permitted block or database slices found.)")
  end
  (sys, parts.join("\n"))
end

struct RlmDbState
  rows_scanned: Int
  ops_used: Int
  trace: List(RlmTraceStep)
  untrusted_tainted: Bool
  max_sens: Text
  untrusted_sources: List(Text)
end

fn rlm_append_db_slices(
  files: Files,
  cat: Views.ViewCatalog,
  sess_id: Text,
  is_admin: Bool,
  limits: Views.ReadLimits,
  db_cands: List((Int, Text, Text)),
  now: Time,
  st0: RlmDbState
) : Result((RlmDbState, List(RlmDbSlice)), AppError)
  ranked_dbs = db_cands.sort_by(fn(p) -p.0 end)
  pos_dbs = ranked_dbs.filter(fn(p) p.0 > 0 end).take(4)
  chosen_dbs = if not pos_dbs.empty?: pos_dbs else: ranked_dbs.take(2)
  if chosen_dbs.empty?
    return Ok((st0, []))
  end

  var col_order = []
  var by_col = {}
  for (_sc, cid, did) in chosen_dbs
    case by_col.get(cid)
      Some(xs): by_col = by_col.set(cid, xs.append(did))
      None:
        col_order = col_order.append(cid)
        by_col = by_col.set(cid, [did])
    end
  end

  var st = st0
  var out_dbs = []
  for cid in col_order
    dids = by_col.get(cid) or []
    if not dids.empty?
      prog = Views.ReadProgram(
        view: "rlm_db_rows:#{cid}",
        where_clause: Some(
          Views.InList(field: "database_id", values: dids.map(fn(x) Json.String(x) end))
        ),
        select: None,
        group_by: None,
        aggregates: None,
        order_by: None,
        limit: Some(40)
      )
      tr = try TaintBridge.run_tainted_read_program_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        cat,
        sess_id,
        prog,
        is_admin,
        limits,
        now
      )
      res = tr.governed.result
      st.rows_scanned += res.rows_scanned
      st.ops_used += res.ops_used
      st.untrusted_tainted = tr.session.untrusted_tainted
      st.max_sens = TaintBridge.sensitivity_label(tr.session.max_sensitivity_read)
      st.untrusted_sources = tr.session.untrusted_sources
      st.trace = st.trace.append(
        RlmTraceStep(
          step: st.trace.size + 1,
          op: "read_program",
          target: prog.view,
          detail: "Sliced #{res.result_count} database rows from #{dids.size} databases",
          rows_scanned: res.rows_scanned,
          ops_used: res.ops_used,
          result_count: res.result_count,
          answer_hash: Some(res.answer_hash)
        )
      )
      for r in res.rows
        out_dbs = out_dbs.append(
          RlmDbSlice(
            database_id: r.text_at("database_id") or "",
            database_title: r.text_at("database_title") or "",
            collection_id: r.text_at("collection_id") or cid,
            row_id: r.text_at("row_id") or "",
            page_id: r.text_at("page_id") or "",
            title: r.text_at("title") or "",
            cells_summary: r.text_at("cells_summary") or ""
          )
        )
      end
    end
  end
  Ok((st, out_dbs))
end

fn rlm_inspect_storage(
  files: Files,
  cat: Views.ViewCatalog,
  query_cids: List(Text),
  sess_id: Text,
  is_admin: Bool,
  limits: Views.ReadLimits,
  keywords: List(Text),
  heading_contains: Option(Text),
  allowed_kinds: List(Text),
  include_dbs?: Bool,
  max_pages: Int,
  max_blocks_per_page: Int,
  now: Time
) : Result((RlmDbState, List(RlmBlockSlice), List(RlmDbSlice)), AppError)
  var st = RlmDbState(
    rows_scanned: 0,
    ops_used: 0,
    trace: [],
    untrusted_tainted: false,
    max_sens: "public",
    untrusted_sources: []
  )
  var page_cands = []
  var db_cands = []

  for cid in query_cids
    prog = Views.ReadProgram(
      view: "rlm_summaries:#{cid}",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(200)
    )
    tr = try TaintBridge.run_tainted_read_program_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      cat,
      sess_id,
      prog,
      is_admin,
      limits,
      now
    )
    res = tr.governed.result
    st.rows_scanned += res.rows_scanned
    st.ops_used += res.ops_used
    st.untrusted_tainted = tr.session.untrusted_tainted
    st.max_sens = TaintBridge.sensitivity_label(tr.session.max_sensitivity_read)
    st.untrusted_sources = tr.session.untrusted_sources
    st.trace = st.trace.append(
      RlmTraceStep(
        step: st.trace.size + 1,
        op: "read_program",
        target: prog.view,
        detail: "Scanned #{res.result_count} Living Summaries in #{cid}",
        rows_scanned: res.rows_scanned,
        ops_used: res.ops_used,
        result_count: res.result_count,
        answer_hash: Some(res.answer_hash)
      )
    )
    for row in res.rows
      ek = row.text_at("entity_kind") or ""
      eid = row.text_at("entity_id") or ""
      sc = Rlm.score_summary_row(row, keywords)
      if ek == "page" and not eid.empty?
        page_cands = page_cands.append((sc, cid, eid))
      else if ek == "database" and not eid.empty?
        db_cands = db_cands.append((sc, cid, eid))
      end
    end
  end

  ranked_pages = page_cands.sort_by(fn(p) -p.0 end)
  pos_pages = ranked_pages.filter(fn(p) p.0 > 0 end).take(max_pages)
  chosen_pages = if not pos_pages.empty?: pos_pages else: ranked_pages.take(max_pages)

  var col_order = []
  var pids_by_col = {}
  for (_sc, cid, pid) in chosen_pages
    case pids_by_col.get(cid)
      Some(xs): pids_by_col = pids_by_col.set(cid, xs.append(pid))
      None:
        col_order = col_order.append(cid)
        pids_by_col = pids_by_col.set(cid, [pid])
    end
  end

  has_heading_f? = case heading_contains
    Some(h) if not h.trim.empty?: true
    Some(_) | None: false
  end
  var raw_block_rows = []
  for cid in col_order
    pids = pids_by_col.get(cid) or []
    if not pids.empty?
      pid_pred = Views.InList(field: "page_id", values: pids.map(fn(x) Json.String(x) end))
      where_pred = if (not has_heading_f?) and (not allowed_kinds.empty?)
        Views.And(
          preds: [
            pid_pred,
            Views.InList(field: "kind_tag", values: allowed_kinds.map(fn(k) Json.String(k) end))
          ]
        )
      else
        pid_pred
      end
      bprog = Views.ReadProgram(
        view: "rlm_blocks:#{cid}",
        where_clause: Some(where_pred),
        select: None,
        group_by: None,
        aggregates: None,
        order_by: None,
        limit: Some(200)
      )
      btr = try TaintBridge.run_tainted_read_program_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        cat,
        sess_id,
        bprog,
        is_admin,
        limits,
        now
      )
      bres = btr.governed.result
      st.rows_scanned += bres.rows_scanned
      st.ops_used += bres.ops_used
      st.untrusted_tainted = btr.session.untrusted_tainted
      st.max_sens = TaintBridge.sensitivity_label(btr.session.max_sensitivity_read)
      st.untrusted_sources = btr.session.untrusted_sources
      st.trace = st.trace.append(
        RlmTraceStep(
          step: st.trace.size + 1,
          op: "read_program",
          target: bprog.view,
          detail: "Sliced #{bres.result_count} candidate blocks across #{pids.size} pages",
          rows_scanned: bres.rows_scanned,
          ops_used: bres.ops_used,
          result_count: bres.result_count,
          answer_hash: Some(bres.answer_hash)
        )
      )
      for brow in bres.rows
        raw_block_rows = raw_block_rows.append(brow)
      end
    end
  end

  slices = Rlm.slice_block_rows(
    raw_block_rows,
    keywords,
    heading_contains,
    allowed_kinds,
    max_blocks_per_page
  )

  (final_st, db_slices) = if include_dbs?
    try rlm_append_db_slices(files, cat, sess_id, is_admin, limits, db_cands, now, st)
  else
    (st, [])
  end
  Ok((final_st, slices, db_slices))
end

fn rlm_build_citations(slices: List(RlmBlockSlice)) : List(Json)
  var seen = Set.empty
  var out = []
  for s in slices
    k = "#{s.page_id}:#{s.block_id}"
    if not seen.has?(k)
      seen = seen.add(k)
      hp_json = case s.heading_path
        Some(h): Json.String(h)
        None: Json.Null
      end
      out = out.append(
        Json.Object({
          "page_id": Json.String(s.page_id),
          "collection_id": Json.String(s.collection_id),
          "block_id": Json.String(s.block_id),
          "title": Json.String(s.page_title),
          "excerpt": Json.String(Rlm.format_slice_excerpt(s)),
          "kind_tag": Json.String(s.kind_tag),
          "heading_path": hp_json
        })
      )
    end
  end
  out
end

## Executes Tier 1 RLM Deep Research (`Modb.Views` `ReadProgram` + block-slice DSL + bounded LLM map/reduce)
## strictly under `Modb.Grants`, `Modb.Views.ReadLimits`, and `Modb.Taint.TaintSession`, calling LLM HTTP APIs
## strictly outside all storage locks.
fn execute_rlm_tier1(
  auth: AuthContext,
  input: DeepResearchInput,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Result(DeepResearchOutcome, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = input.question.trim
  if q.empty?
    return Error(BadInput(reason: "question must not be empty"))
  end
  cfg = try ai_config(env)

  max_pages = rlm_clamp(input.max_pages, 6, 1, 12)
  max_b_per_p = rlm_clamp(input.max_blocks_per_page, 6, 1, 15)
  max_subcalls = rlm_clamp(input.max_subcalls, 3, 0, 6)
  max_rows = rlm_clamp(input.max_rows_scanned, 500, 1, 2000)
  raw_ops = max_rows * 40
  max_ops = if raw_ops < 100: 100 else if raw_ops > 20000: 20000 else: raw_ops
  limits = Views.ReadLimits(max_rows_scanned: max_rows, max_ops: max_ops, max_result_rows: 200)
  allowed_kinds = Rlm.normalize_block_kinds(input.block_kinds)
  include_dbs? = input.include_databases != Some(false)
  keywords = Rlm.extract_query_keywords(q)
  now = clock.now

  (grant_opt, is_admin) = rlm_auth_mode(auth)
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  (catalog_cids, query_cids) = try rlm_target_collections(
    files.read_only,
    auth,
    input.collection_id,
    Some(cfg.base_url),
    local_only_ai?
  )

  sess_id = case input.session_id
    Some(raw) if not raw.trim.empty?: "rlm:#{auth.grant_id}:#{raw.trim}"
    Some(_) | None: "rlm:#{auth.grant_id}"
  end
  sess = if files.read_only.exists?(Db.ledger_db_path)
    try TaintBridge.ensure_taint_session_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      sess_id,
      auth.principal.id,
      grant_opt,
      now
    )
  else
    return Error(Missing(entity: "collection", id: "none"))
  end

  cat = Db.rlm_view_catalog(catalog_cids)
  (st0, slices, db_slices) = try rlm_inspect_storage(
    files,
    cat,
    query_cids,
    sess.id,
    is_admin,
    limits,
    keywords,
    input.heading_contains,
    allowed_kinds,
    include_dbs?,
    max_pages,
    max_b_per_p,
    now
  )

  # Run bounded map-reduce LLM calls strictly outside MoDB locks.
  var trace = st0.trace
  var subcall_notes = []
  var subcalls_used = 0
  if slices.size > 1 and max_subcalls > 0
    chunks = Rlm.chunk_block_slices(slices, max_subcalls)
    if chunks.size >= 2 or slices.size > 4
      total_ch = chunks.size
      for (i, ch) in chunks.enumerate
        cidx = i + 1
        (sub_sys, sub_usr) = build_rlm_subcall_prompts(q, cidx, total_ch, ch)
        sub_res = try Http.send(build_llm_request(cfg, sub_sys, sub_usr), net).map_error(fn(e)
          ServerFailed(reason: "RLM sub-agent LLM request failed: #{e.to_text}")
        end)
        if sub_res.status < 200 or sub_res.status >= 300
          return Error(
            ServerFailed(reason: "RLM sub-agent LLM returned HTTP #{sub_res.status}")
          )
        end
        note = try extract_llm_text(cfg, sub_res.body)
        subcalls_used += 1
        subcall_notes = subcall_notes.append("Chunk #{cidx}/#{total_ch}:\n#{note}")
        trace = trace.append(
          RlmTraceStep(
            step: trace.size + 1,
            op: "sub_llm",
            target: "subcall_#{cidx}",
            detail: "Analyzed #{ch.size} sliced blocks in map chunk #{cidx}/#{total_ch}",
            rows_scanned: 0,
            ops_used: 0,
            result_count: ch.size,
            answer_hash: None
          )
        )
      end
    end
  end

  (syn_sys, syn_usr) = build_rlm_synthesis_prompts(q, subcall_notes, slices, db_slices)
  syn_res = try Http.send(build_llm_request(cfg, syn_sys, syn_usr), net).map_error(fn(e)
    ServerFailed(reason: "RLM synthesizer LLM request failed: #{e.to_text}")
  end)
  if syn_res.status < 200 or syn_res.status >= 300
    return Error(ServerFailed(reason: "RLM synthesizer LLM returned HTTP #{syn_res.status}"))
  end
  answer = try extract_llm_text(cfg, syn_res.body)
  trace = trace.append(
    RlmTraceStep(
      step: trace.size + 1,
      op: "synthesize",
      target: cfg.model,
      detail: "Synthesized answer from #{slices.size} block slices and #{db_slices.size} DB slices",
      rows_scanned: 0,
      ops_used: 0,
      result_count: slices.size + db_slices.size,
      answer_hash: None
    )
  )

  Ok(
    DeepResearchOutcome(
      tier: "tier1_read_program",
      answer: answer,
      model: cfg.model,
      session_id: sess.id,
      untrusted_tainted: st0.untrusted_tainted,
      max_sensitivity_read: st0.max_sens,
      untrusted_sources: st0.untrusted_sources,
      rows_scanned: st0.rows_scanned,
      ops_used: st0.ops_used,
      subcalls_used: subcalls_used,
      max_subcalls: max_subcalls,
      citations: rlm_build_citations(slices),
      db_slices: db_slices,
      trace: trace,
      executed_script: None,
      depth_used: 1,
      max_depth: 1,
      child_sessions: [],
      grant_calls_debited: 0
    )
  )
end

## Debits 1 call from an `Agent` grant (`Modb.Grants.tx_authorize`) strictly inside a transaction
## before invoking an external LLM call; humans pass with 0 debited.
fn debit_agent_rlm_call(
  files: Files,
  auth: AuthContext,
  reason: Text,
  now: Time
) : Result(Int, AppError)
  if auth.principal.kind != Agent
    return Ok(0)
  end
  meta = Ledger.WriteMeta(
    principal: auth.principal.handle,
    action: "rlm.tier2.llm_call",
    reason: reason,
    at: now
  )
  _u = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    reason,
    Json.Object({"grant_id": Json.String(auth.grant_id)}),
    Db.map_ledger_error,
    fn(tx)
      (tg, _g) = try Grants.tx_authorize(tx, auth.grant_id, "read", now).map_error(
        Db.map_grants_error
      )
      Ok((tg, Unit))
    end
  )
  Ok(1)
end

## Formats the Planner LLM prompt that emits a capability-confined Mo Micro-REPL script.
fn build_rlm_tier2_planner_prompts(
  question: Text,
  col_opt: Option(Text),
  heading_opt: Option(Text),
  allowed_kinds: List(Text),
  include_dbs?: Bool,
  max_pages: Int,
  max_blocks_per_page: Int,
  max_subcalls: Int,
  max_depth: Int
) : (Text, Text)
  sys = "You are Vellum Tier 2 RLM Planner. Write ONLY a safe Mo Micro-REPL script wrapped in ```mo ... ``` using ONLY: ws.summaries(col_or_null), ws.search(query, col_or_null), ws.blocks(page_ids, block_kinds, heading_or_null), ws.db_rows(db_ids), llm.ask(prompt, context), rlm.sub(sub_q, sub_script_or_null), and pure helpers len/take/join/map_field/filter_contains/dedup_text/contains/append/concat/str. Variables: let/var, for x in xs ... end, if ... else ... end, return expr. Do NOT use Files, Http, Env, Net, or Os."
  col_s = col_opt or "null"
  hd_s = heading_opt or "null"
  kinds_s = if allowed_kinds.empty?: "[]" else: allowed_kinds.join(", ")
  usr = "Question: #{question}\nScope collection: #{col_s}\nHeading filter: #{hd_s}\nBlock kinds: #{kinds_s}\nInclude databases: #{if include_dbs?: "true" else: "false"}\nBudgets: max_pages=#{max_pages}, max_blocks_per_page=#{max_blocks_per_page}, max_subcalls=#{max_subcalls}, max_depth=#{max_depth}\nReturn the Mo Micro-REPL script ending with `return answer`."
  (sys, usr)
end

fn extract_planned_script(raw: Text) : Text
  trimmed = raw.trim
  case Json.parse(trimmed)
    Ok(j):
      case j.text_at("script")
        Some(sc) if not sc.trim.empty?: return sc.trim
        Some(_) | None: Unit
      end
    Error(_): Unit
  end
  parts = trimmed.split("```")
  if parts.size >= 3
    body = (parts.get(1) or "").trim
    body_lines = body.split("\n")
    first = (body_lines.first or "").trim.ascii_lowercase
    if first == "mo" or first == "rlm" or first == "script" or first == "vellum"
      return body_lines.drop(1).join("\n").trim
    end
    return body
  end
  trimmed
end

fn rlm_vm_opt_text(v: RlmVm.RlmVal) : Option(Text)
  case v
    RlmVm.VNull: None
    RlmVm.VText(s):
      c = s.trim
      if c.empty?: None else: Some(c)
    RlmVm.VBool(_) | RlmVm.VInt(_) | RlmVm.VList(_) | RlmVm.VRecord(_): None
  end
end

fn rlm_vm_text_list(v: RlmVm.RlmVal) : List(Text)
  case v
    RlmVm.VList(xs):
      var out = []
      for x in xs
        s = RlmVm.rlm_val_to_text(x).trim
        if not s.empty?
          out = out.append(s)
        end
      end
      out
    RlmVm.VText(s):
      if s.trim.empty?: [] else: [s.trim]
    RlmVm.VNull | RlmVm.VBool(_) | RlmVm.VInt(_) | RlmVm.VRecord(_): []
  end
end

fn rlm_merge_cids(
  auth: AuthContext,
  col_opt: Option(Text),
  rf: ReadFiles,
  ai_url_opt: Option(Text),
  local_only_ai?: Bool
) : Result((List(Text), List(Text)), AppError)
  rlm_target_collections(rf, auth, col_opt, ai_url_opt, local_only_ai?)
end

struct TaintMerge
  tainted?: Bool
  max_sens: Text
  untrusted_srcs: List(Text)
end

fn taint_merge_init() : TaintMerge
  TaintMerge(tainted?: false, max_sens: "public", untrusted_srcs: [])
end

fn merge_taint_fields(
  tm: TaintMerge,
  u_tainted: Bool,
  sens_label: Text,
  srcs: List(Text)
) : TaintMerge
  var merged = tm.untrusted_srcs
  for src in srcs
    if not merged.contains?(src)
      merged = merged.append(src)
    end
  end
  TaintMerge(
    tainted?: tm.tainted? or u_tainted,
    max_sens: RlmVm.max_sensitivity_label(tm.max_sens, sens_label),
    untrusted_srcs: merged
  )
end

fn make_read_delta(
  val: RlmVm.RlmVal,
  rows_scanned: Int,
  views_ops: Int,
  block_slices: List(RlmBlockSlice),
  db_slices: List(RlmDbSlice),
  traces: List(RlmTraceStep),
  tm: TaintMerge
) : RlmVm.RlmHostDelta
  RlmVm.RlmHostDelta(
    value: val,
    rows_scanned: rows_scanned,
    views_ops: views_ops,
    subcalls_delta: 0,
    depth_reached: 0,
    grant_calls_debited: 0,
    block_slices: block_slices,
    db_slices: db_slices,
    trace: traces,
    child_sessions: [],
    untrusted_tainted: tm.tainted?,
    max_sensitivity_read: tm.max_sens,
    untrusted_sources: tm.untrusted_srcs
  )
end

fn rlm_vm_run_summaries(
  files: Files,
  auth: AuthContext,
  sess_id: Text,
  is_admin: Bool,
  limits: Views.ReadLimits,
  default_col_opt: Option(Text),
  arg_col: RlmVm.RlmVal,
  ai_url_opt: Option(Text),
  local_only_ai?: Bool,
  now: Time
) : Result(RlmVm.RlmHostDelta, RlmVm.RlmVmError)
  eff_col = case rlm_vm_opt_text(arg_col)
    Some(c): Some(c)
    None: default_col_opt
  end
  (catalog_cids, target_cids) = try rlm_merge_cids(
    auth,
    eff_col,
    files.read_only,
    ai_url_opt,
    local_only_ai?
  ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  cat = Db.rlm_view_catalog(catalog_cids)
  var out_vals = []
  var total_rows = 0
  var total_ops = 0
  var traces = []
  var tm = taint_merge_init()

  for cid in target_cids
    prog = Views.ReadProgram(
      view: "rlm_summaries:#{cid}",
      where_clause: None,
      select: None,
      group_by: None,
      aggregates: None,
      order_by: None,
      limit: Some(200)
    )
    tr = try TaintBridge.run_tainted_read_program_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      cat,
      sess_id,
      prog,
      is_admin,
      limits,
      now
    ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
    res = tr.governed.result
    total_rows += res.rows_scanned
    total_ops += res.ops_used
    tm = merge_taint_fields(
      tm,
      tr.session.untrusted_tainted,
      TaintBridge.sensitivity_label(tr.session.max_sensitivity_read),
      tr.session.untrusted_sources
    )
    traces = traces.append(
      RlmTraceStep(
        step: 1,
        op: "read_program",
        target: prog.view,
        detail: "VM ws.summaries scanned #{res.result_count} rows in #{cid}",
        rows_scanned: res.rows_scanned,
        ops_used: res.ops_used,
        result_count: res.result_count,
        answer_hash: Some(res.answer_hash)
      )
    )
    for r in res.rows
      out_vals = out_vals.append(
        RlmVm.VRecord({
          "entity_kind": RlmVm.VText(r.text_at("entity_kind") or ""),
          "entity_id": RlmVm.VText(r.text_at("entity_id") or ""),
          "collection_id": RlmVm.VText(cid),
          "title": RlmVm.VText(r.text_at("title") or ""),
          "summary_text": RlmVm.VText(r.text_at("summary_text") or "")
        })
      )
    end
  end

  Ok(make_read_delta(RlmVm.VList(out_vals), total_rows, total_ops, [], [], traces, tm))
end

fn rlm_vm_search_vec_setup(
  rf: ReadFiles,
  q: Text,
  env: Env,
  net: Network
) : Result((Option(List(Float)), Vec.VecIndex, Option(Float)), AppError)
  case embed_config(env)
    None: Ok(
      (
        Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
        Db.sketch_vec_index(),
        Some(Db.sketch_min_vec_score)
      )
    )
    Some(ecfg):
      has_neural_j = try Ledger.read_locked(
        rf,
        Db.ledger_db_path,
        Db.vellum_schema(),
        Db.map_ledger_error,
        fn(db)
          Ok(Json.Boolean(try Db.neural_vec_populated(Ledger.store(db), ecfg.dimensions)))
        end
      )
      if has_neural_j == Json.Boolean(true)
        case fetch_embedding(ecfg, q, net)
          Ok(qv): Ok((Some(qv), Db.neural_vec_index(ecfg.dimensions), Some(ecfg.min_score)))
          Error(_): Ok(
            (
              Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
              Db.sketch_vec_index(),
              Some(Db.sketch_min_vec_score)
            )
          )
        end
      else
        Ok(
          (
            Some(Vec.text_sketch_embedding(q, Db.sketch_vec_dims)),
            Db.sketch_vec_index(),
            Some(Db.sketch_min_vec_score)
          )
        )
      end
  end
end

fn rlm_vm_run_search(
  files: Files,
  auth: AuthContext,
  sess_id: Text,
  is_admin: Bool,
  default_col_opt: Option(Text),
  q_val: RlmVm.RlmVal,
  col_val: RlmVm.RlmVal,
  env: Env,
  net: Network,
  now: Time
) : Result(RlmVm.RlmHostDelta, RlmVm.RlmVmError)
  q = RlmVm.rlm_val_to_text(q_val).trim
  if q.empty?
    return Ok(RlmVm.plain_delta(RlmVm.VList([])))
  end
  eff_col = case rlm_vm_opt_text(col_val)
    Some(c): Some(c)
    None: default_col_opt
  end
  ai_url_opt = case ai_config(env)
    Ok(c): Some(c.base_url)
    Error(_): None
  end
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  (_cat_cids, target_cids) = try rlm_merge_cids(
    auth,
    eff_col,
    files.read_only,
    ai_url_opt,
    local_only_ai?
  ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  if target_cids.empty? or not files.read_only.exists?(Db.ledger_db_path)
    return Ok(RlmVm.plain_delta(RlmVm.VList([])))
  end

  (qv_opt, vec_idx, min_vec) = try rlm_vm_search_vec_setup(files.read_only, q, env, net).map_error(
    fn(e) RlmVm.HostAppError(err: e) end
  )

  var raw_hits = []
  var tm = taint_merge_init()
  for cid in target_cids
    opts = Vec.HybridOptions(
      limit: 6,
      prefix_last_term?: true,
      required_scope: Some(cid),
      rrf_k: 60,
      fts_weight: 1.0.to_float,
      vec_weight: 1.0.to_float,
      candidate_limit: 18,
      min_vec_score: min_vec
    )
    (hhits, upd_sess) = try TaintBridge.run_tainted_hybrid_search_locked(
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
    ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
    tm = merge_taint_fields(
      tm,
      upd_sess.untrusted_tainted,
      TaintBridge.sensitivity_label(upd_sess.max_sensitivity_read),
      upd_sess.untrusted_sources
    )
    for hh in hhits
      if hh.scope == cid and Policy.collection_permitted?(auth, hh.scope)
        raw_hits = raw_hits.append(hh)
      end
    end
  end

  sorted_hits = raw_hits.sort_by(fn(h) -h.score end).take(12)
  out_vals_j = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      ptbl = Db.pages_table()
      var list_out = []
      for (i, hh) in sorted_hits.enumerate
        case try Table.get(store, ptbl, hh.doc_id).map_error(Db.map_table_error)
          Some(p) if p.archived_at == None and Policy.collection_permitted?(auth, p.collection_id):
            list_out = list_out.append(
              Json.Object({
                "page_id": Json.String(p.id),
                "collection_id": Json.String(p.collection_id),
                "title": Json.String(p.title),
                "rank": Json.int(i + 1)
              })
            )
          Some(_) | None: Unit
        end
      end
      Ok(Json.Array(list_out))
    end
  ).map_error(fn(e) RlmVm.HostAppError(err: e) end)

  var out_vals = []
  case out_vals_j
    Json.Array(items):
      for item in items
        out_vals = out_vals.append(
          RlmVm.VRecord({
            "page_id": RlmVm.VText(item.text_at("page_id") or ""),
            "collection_id": RlmVm.VText(item.text_at("collection_id") or ""),
            "title": RlmVm.VText(item.text_at("title") or ""),
            "rank": RlmVm.VInt(item.int_at("rank") or 1)
          })
        )
      end
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): Unit
  end

  tr_step = RlmTraceStep(
    step: 1,
    op: "hybrid_search",
    target: q,
    detail: "VM ws.search found #{out_vals.size} permitted hits across #{target_cids.size} collections",
    rows_scanned: out_vals.size,
    ops_used: target_cids.size,
    result_count: out_vals.size,
    answer_hash: None
  )
  Ok(make_read_delta(RlmVm.VList(out_vals), out_vals.size, target_cids.size, [], [], [tr_step], tm))
end

fn rlm_vm_run_blocks(
  files: Files,
  auth: AuthContext,
  sess_id: Text,
  is_admin: Bool,
  limits: Views.ReadLimits,
  catalog_cids: List(Text),
  keywords: List(Text),
  page_ids_val: RlmVm.RlmVal,
  kinds_val: RlmVm.RlmVal,
  heading_val: RlmVm.RlmVal,
  default_kinds: List(Text),
  default_heading: Option(Text),
  max_blocks_per_page: Int,
  now: Time
) : Result(RlmVm.RlmHostDelta, RlmVm.RlmVmError)
  req_pids = rlm_vm_text_list(page_ids_val)
  if req_pids.empty? or not files.read_only.exists?(Db.ledger_db_path)
    return Ok(RlmVm.plain_delta(RlmVm.VList([])))
  end
  raw_kinds = rlm_vm_text_list(kinds_val)
  eff_kinds = if not raw_kinds.empty?
    Rlm.normalize_block_kinds(Some(raw_kinds))
  else
    default_kinds
  end
  eff_heading = case rlm_vm_opt_text(heading_val)
    Some(h): Some(h)
    None: default_heading
  end
  has_heading? = eff_heading != None

  col_pids_json = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      ptbl = Db.pages_table()
      var by_col = {}
      var col_order = []
      for pid in req_pids
        case try Table.get(store, ptbl, pid).map_error(Db.map_table_error)
          Some(p) if p.archived_at == None:
            if not Policy.collection_permitted?(auth, p.collection_id)
              return Error(
                Forbidden(reason: "collection '#{p.collection_id}' is not permitted by grant")
              )
            end
            case by_col.get(p.collection_id)
              Some(xs): by_col = by_col.set(p.collection_id, xs.append(pid))
              None:
                col_order = col_order.append(p.collection_id)
                by_col = by_col.set(p.collection_id, [pid])
            end
          Some(_) | None: Unit
        end
      end
      Ok(
        Json.Array(
          col_order.map(fn(cid)
            Json.Object({
              "cid": Json.String(cid),
              "ids": Json.Array((by_col.get(cid) or []).map(fn(x) Json.String(x) end))
            })
          end)
        )
      )
    end
  ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  col_pids = case col_pids_json
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): []
  end

  cat = Db.rlm_view_catalog(catalog_cids)
  var raw_rows = []
  var total_rows = 0
  var total_ops = 0
  var traces = []
  var tm = taint_merge_init()

  for col_entry in col_pids
    cid = col_entry.text_at("cid") or ""
    pids = case col_entry.get("ids")
      Some(Json.Array(items)):
        var s_ids = []
        for it in items
          case it
            Json.String(s): s_ids = s_ids.append(s)
            Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Object(_) | Json.Array(_): Unit
          end
        end
        s_ids
      Some(_) | None: []
    end
    if not pids.empty?
      pid_pred = Views.InList(field: "page_id", values: pids.map(fn(x) Json.String(x) end))
      where_pred = if (not has_heading?) and (not eff_kinds.empty?)
        Views.And(
          preds: [
            pid_pred,
            Views.InList(field: "kind_tag", values: eff_kinds.map(fn(k) Json.String(k) end))
          ]
        )
      else
        pid_pred
      end
      bprog = Views.ReadProgram(
        view: "rlm_blocks:#{cid}",
        where_clause: Some(where_pred),
        select: None,
        group_by: None,
        aggregates: None,
        order_by: None,
        limit: Some(200)
      )
      btr = try TaintBridge.run_tainted_read_program_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        cat,
        sess_id,
        bprog,
        is_admin,
        limits,
        now
      ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
      bres = btr.governed.result
      total_rows += bres.rows_scanned
      total_ops += bres.ops_used
      tm = merge_taint_fields(
        tm,
        btr.session.untrusted_tainted,
        TaintBridge.sensitivity_label(btr.session.max_sensitivity_read),
        btr.session.untrusted_sources
      )
      traces = traces.append(
        RlmTraceStep(
          step: 1,
          op: "read_program",
          target: bprog.view,
          detail: "VM ws.blocks sliced #{bres.result_count} candidate blocks across #{pids.size} pages",
          rows_scanned: bres.rows_scanned,
          ops_used: bres.ops_used,
          result_count: bres.result_count,
          answer_hash: Some(bres.answer_hash)
        )
      )
      for brow in bres.rows
        raw_rows = raw_rows.append(brow)
      end
    end
  end

  slices = Rlm.slice_block_rows(raw_rows, keywords, eff_heading, eff_kinds, max_blocks_per_page)
  vals = slices.map(fn(s)
    hp_s = s.heading_path or ""
    ex = "[#{s.page_title} §#{s.block_id}] (#{s.kind_tag}) #{Rlm.format_slice_excerpt(s)}"
    RlmVm.VRecord({
      "page_id": RlmVm.VText(s.page_id),
      "page_title": RlmVm.VText(s.page_title),
      "collection_id": RlmVm.VText(s.collection_id),
      "block_id": RlmVm.VText(s.block_id),
      "kind_tag": RlmVm.VText(s.kind_tag),
      "heading_path": RlmVm.VText(hp_s),
      "markdown": RlmVm.VText(s.markdown),
      "excerpt": RlmVm.VText(ex)
    })
  end)

  Ok(make_read_delta(RlmVm.VList(vals), total_rows, total_ops, slices, [], traces, tm))
end

fn rlm_vm_run_db_rows(
  files: Files,
  auth: AuthContext,
  sess_id: Text,
  is_admin: Bool,
  limits: Views.ReadLimits,
  catalog_cids: List(Text),
  db_ids_val: RlmVm.RlmVal,
  now: Time
) : Result(RlmVm.RlmHostDelta, RlmVm.RlmVmError)
  req_dids = rlm_vm_text_list(db_ids_val)
  if req_dids.empty? or not files.read_only.exists?(Db.ledger_db_path)
    return Ok(RlmVm.plain_delta(RlmVm.VList([])))
  end

  col_dids_json = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      dtbl = Db.databases_table()
      var by_col = {}
      var col_order = []
      for did in req_dids
        case try Table.get(store, dtbl, did).map_error(Db.map_table_error)
          Some(d):
            if not Policy.collection_permitted?(auth, d.collection_id)
              return Error(
                Forbidden(reason: "database collection '#{d.collection_id}' is not permitted by grant")
              )
            end
            case by_col.get(d.collection_id)
              Some(xs): by_col = by_col.set(d.collection_id, xs.append(did))
              None:
                col_order = col_order.append(d.collection_id)
                by_col = by_col.set(d.collection_id, [did])
            end
          Some(_) | None: Unit
        end
      end
      Ok(
        Json.Array(
          col_order.map(fn(cid)
            Json.Object({
              "cid": Json.String(cid),
              "ids": Json.Array((by_col.get(cid) or []).map(fn(x) Json.String(x) end))
            })
          end)
        )
      )
    end
  ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  col_dids = case col_dids_json
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): []
  end

  cat = Db.rlm_view_catalog(catalog_cids)
  var db_slices = []
  var total_rows = 0
  var total_ops = 0
  var traces = []
  var tm = taint_merge_init()

  for col_entry in col_dids
    cid = col_entry.text_at("cid") or ""
    dids = case col_entry.get("ids")
      Some(Json.Array(items)):
        var s_ids = []
        for it in items
          case it
            Json.String(s): s_ids = s_ids.append(s)
            Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Object(_) | Json.Array(_): Unit
          end
        end
        s_ids
      Some(_) | None: []
    end
    if not dids.empty?
      prog = Views.ReadProgram(
        view: "rlm_db_rows:#{cid}",
        where_clause: Some(
          Views.InList(field: "database_id", values: dids.map(fn(x) Json.String(x) end))
        ),
        select: None,
        group_by: None,
        aggregates: None,
        order_by: None,
        limit: Some(40)
      )
      tr = try TaintBridge.run_tainted_read_program_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        cat,
        sess_id,
        prog,
        is_admin,
        limits,
        now
      ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
      res = tr.governed.result
      total_rows += res.rows_scanned
      total_ops += res.ops_used
      tm = merge_taint_fields(
        tm,
        tr.session.untrusted_tainted,
        TaintBridge.sensitivity_label(tr.session.max_sensitivity_read),
        tr.session.untrusted_sources
      )
      traces = traces.append(
        RlmTraceStep(
          step: 1,
          op: "read_program",
          target: prog.view,
          detail: "VM ws.db_rows sliced #{res.result_count} rows from #{dids.size} databases",
          rows_scanned: res.rows_scanned,
          ops_used: res.ops_used,
          result_count: res.result_count,
          answer_hash: Some(res.answer_hash)
        )
      )
      for r in res.rows
        db_slices = db_slices.append(
          RlmDbSlice(
            database_id: r.text_at("database_id") or "",
            database_title: r.text_at("database_title") or "",
            collection_id: r.text_at("collection_id") or cid,
            row_id: r.text_at("row_id") or "",
            page_id: r.text_at("page_id") or "",
            title: r.text_at("title") or "",
            cells_summary: r.text_at("cells_summary") or ""
          )
        )
      end
    end
  end

  vals = db_slices.map(fn(d)
    ex = "[DB: #{d.database_title} ##{d.row_id}] #{d.title} — #{d.cells_summary}"
    RlmVm.VRecord({
      "database_id": RlmVm.VText(d.database_id),
      "database_title": RlmVm.VText(d.database_title),
      "collection_id": RlmVm.VText(d.collection_id),
      "row_id": RlmVm.VText(d.row_id),
      "page_id": RlmVm.VText(d.page_id),
      "title": RlmVm.VText(d.title),
      "cells_summary": RlmVm.VText(d.cells_summary),
      "excerpt": RlmVm.VText(ex)
    })
  end)

  Ok(make_read_delta(RlmVm.VList(vals), total_rows, total_ops, [], db_slices, traces, tm))
end

fn rlm_vm_run_llm_ask(
  cfg: AiConfig,
  files: Files,
  auth: AuthContext,
  depth: Int,
  prompt_val: RlmVm.RlmVal,
  ctx_val: RlmVm.RlmVal,
  net: Network,
  now: Time
) : Result(RlmVm.RlmHostDelta, RlmVm.RlmVmError)
  prompt_txt = RlmVm.rlm_val_to_text(prompt_val).trim
  ctx_txt = RlmVm.rlm_val_to_text(ctx_val)
  sys = "You are Vellum RLM Tier 2 sub-agent at recursion depth #{depth}. Answer strictly using the inspected MoDB context provided and preserve every [Title §block_id] and [DB: Title #row_id] citation."
  usr = if ctx_txt.trim.empty?: prompt_txt else: "#{prompt_txt}\n\nContext:\n#{ctx_txt}"

  debited = try debit_agent_rlm_call(files, auth, "RLM Tier 2 llm.ask at depth #{depth}", now)
    .map_error(fn(e) RlmVm.HostAppError(err: e) end)
  http_res = try Http.send(build_llm_request(cfg, sys, usr), net).map_error(fn(e)
    RlmVm.HostAppError(err: ServerFailed(reason: "RLM Tier 2 llm.ask failed: #{e.to_text}"))
  end)
  if http_res.status < 200 or http_res.status >= 300
    return Error(
      RlmVm.HostAppError(
        err: ServerFailed(reason: "RLM Tier 2 llm.ask returned HTTP #{http_res.status}")
      )
    )
  end
  answer = try extract_llm_text(cfg, http_res.body).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  tr_step = RlmTraceStep(
    step: 1,
    op: "vm_llm_ask",
    target: cfg.model,
    detail: "VM llm.ask at depth #{depth} (#{usr.byte_count} bytes context)",
    rows_scanned: 0,
    ops_used: 0,
    result_count: 1,
    answer_hash: None
  )
  Ok(
    RlmVm.RlmHostDelta(
      value: RlmVm.VText(answer),
      rows_scanned: 0,
      views_ops: 0,
      subcalls_delta: 1,
      depth_reached: depth,
      grant_calls_debited: debited,
      block_slices: [],
      db_slices: [],
      trace: [tr_step],
      child_sessions: [],
      untrusted_tainted: false,
      max_sensitivity_read: "public",
      untrusted_sources: []
    )
  )
end

struct RlmFrameConfig
  cfg: AiConfig
  local_only_ai?: Bool
  auth: AuthContext
  default_col_opt: Option(Text)
  catalog_cids: List(Text)
  default_kinds: List(Text)
  default_heading: Option(Text)
  include_dbs?: Bool
  max_pages: Int
  max_blocks_per_page: Int
  limits: Views.ReadLimits
  grant_opt: Option(Text)
  is_admin?: Bool
  max_depth: Int
end

fn rlm_vm_sync_parent_taint(
  files: Files,
  parent_sess_id: Text,
  child_sess_id: Text,
  child_tainted?: Bool,
  now: Time
) : Result(Unit, RlmVm.RlmVmError)
  if not child_tainted?
    return Ok(Unit)
  end
  already_tainted_j = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      case try TaintBridge.get_taint_session(Ledger.store(db), parent_sess_id)
        Some(ps): Ok(Json.Boolean(ps.untrusted_tainted))
        None: Ok(Json.Boolean(false))
      end
    end
  ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  if already_tainted_j != Json.Boolean(true)
    _upd = try TaintBridge.record_untrusted_read_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      parent_sess_id,
      "rlm_sub:#{child_sess_id}",
      now
    ).map_error(fn(e) RlmVm.HostAppError(err: e) end)
  end
  Ok(Unit)
end

fn next_child_session_id(files: Files, base: Text) : Result(Text, RlmVm.RlmVmError)
  case try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var seq = 1
      while seq < 64
        cand = "#{base}:#{seq}"
        if (try TaintBridge.get_taint_session(store, cand)) is None
          return Ok(Json.String(cand))
        end
        seq += 1
      end
      Ok(Json.String("#{base}:64"))
    end
  ).map_error(fn(err) RlmVm.HostAppError(err: err) end)
    Json.String(s): Ok(s)
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): Ok("#{base}:64")
  end
end

fn run_rlm_tier2_frame(
  fcfg: RlmFrameConfig,
  sess_id: Text,
  question: Text,
  script_src: Text,
  depth: Int,
  max_subcalls: Int,
  files: Files,
  env: Env,
  net: Network,
  now: Time
) : Result(RlmVm.RlmEvalOutcome, AppError)
  stmts = try RlmVm.parse_script(script_src).map_error(RlmVm.vm_error_to_app_error)
  try RlmVm.validate_program(stmts).map_error(RlmVm.vm_error_to_app_error)
  keywords = Rlm.extract_query_keywords(question)
  vm_limits = RlmVm.default_vm_limits(max_subcalls, fcfg.max_depth)

  host = RlmVm.RlmHostFns(
    on_summaries: fn(f, col_v)
      rlm_vm_run_summaries(
        f,
        fcfg.auth,
        sess_id,
        fcfg.is_admin?,
        fcfg.limits,
        fcfg.default_col_opt,
        col_v,
        Some(fcfg.cfg.base_url),
        fcfg.local_only_ai?,
        now
      )
    end,
    on_blocks: fn(f, pids_v, kinds_v, hd_v)
      rlm_vm_run_blocks(
        f,
        fcfg.auth,
        sess_id,
        fcfg.is_admin?,
        fcfg.limits,
        fcfg.catalog_cids,
        keywords,
        pids_v,
        kinds_v,
        hd_v,
        fcfg.default_kinds,
        fcfg.default_heading,
        fcfg.max_blocks_per_page,
        now
      )
    end,
    on_db_rows: fn(f, db_ids_v)
      rlm_vm_run_db_rows(
        f,
        fcfg.auth,
        sess_id,
        fcfg.is_admin?,
        fcfg.limits,
        fcfg.catalog_cids,
        db_ids_v,
        now
      )
    end,
    on_search: fn(f, e, nt, qv, cv)
      rlm_vm_run_search(
        f,
        fcfg.auth,
        sess_id,
        fcfg.is_admin?,
        fcfg.default_col_opt,
        qv,
        cv,
        e,
        nt,
        now
      )
    end,
    on_llm_ask: fn(f, nt, pv, cv)
      rlm_vm_run_llm_ask(fcfg.cfg, f, fcfg.auth, depth, pv, cv, nt, now)
    end,
    on_rlm_sub: fn(f, e, nt, sub_q_v, sub_script_v, next_depth, rem_subcalls)
      sub_q = RlmVm.rlm_val_to_text(sub_q_v).trim
      if sub_q.empty?
        return Error(RlmVm.TypeMismatch(reason: "rlm.sub requires a non-empty sub-question"))
      end
      child_sess_id = try next_child_session_id(f, "#{sess_id}:d#{next_depth}:s#{rem_subcalls}")
      _forked = try TaintBridge.fork_taint_session_locked(
        f,
        Db.ledger_db_path,
        Db.vellum_schema(),
        sess_id,
        child_sess_id,
        fcfg.auth.principal.id,
        fcfg.grant_opt,
        now
      ).map_error(fn(err) RlmVm.HostAppError(err: err) end)

      child_script = case rlm_vm_opt_text(sub_script_v)
        Some(sc): sc
        None: RlmVm.default_tier2_script(
          sub_q,
          fcfg.default_col_opt,
          fcfg.default_heading,
          fcfg.default_kinds,
          fcfg.include_dbs?,
          fcfg.max_pages,
          fcfg.max_blocks_per_page,
          rem_subcalls,
          next_depth,
          fcfg.max_depth
        )
      end

      child_out = try run_rlm_tier2_frame(
        fcfg,
        child_sess_id,
        sub_q,
        child_script,
        next_depth,
        rem_subcalls,
        f,
        e,
        nt,
        now
      ).map_error(fn(err) RlmVm.HostAppError(err: err) end)

      try rlm_vm_sync_parent_taint(f, sess_id, child_sess_id, child_out.untrusted_tainted, now)
      sub_sc = if child_out.subcalls_used > 0: child_out.subcalls_used else: 1
      sub_trace = [
        RlmTraceStep(
          step: 1,
          op: "rlm_sub",
          target: child_sess_id,
          detail: "Forked child depth=#{next_depth} for '#{sub_q}' (#{child_out.block_slices.size} blocks, taint=#{if child_out.untrusted_tainted: "true" else: "false"})",
          rows_scanned: child_out.rows_scanned,
          ops_used: child_out.views_ops,
          result_count: child_out.block_slices.size + child_out.db_slices.size,
          answer_hash: None
        )
      ].concat(child_out.trace)

      Ok(
        RlmVm.RlmHostDelta(
          value: child_out.value,
          rows_scanned: child_out.rows_scanned,
          views_ops: child_out.views_ops,
          subcalls_delta: sub_sc,
          depth_reached: child_out.max_depth_reached,
          grant_calls_debited: child_out.grant_calls_debited,
          block_slices: child_out.block_slices,
          db_slices: child_out.db_slices,
          trace: sub_trace,
          child_sessions: [child_sess_id].concat(child_out.child_sessions),
          untrusted_tainted: child_out.untrusted_tainted,
          max_sensitivity_read: child_out.max_sensitivity_read,
          untrusted_sources: child_out.untrusted_sources
        )
      )
    end
  )

  col_init = case fcfg.default_col_opt
    Some(c): RlmVm.VText(c)
    None: RlmVm.VNull
  end
  init_vars = {
    "question": RlmVm.VText(question),
    "collection_id": col_init,
    "depth": RlmVm.VInt(depth),
    "max_depth": RlmVm.VInt(fcfg.max_depth),
    "max_subcalls": RlmVm.VInt(max_subcalls),
    "max_pages": RlmVm.VInt(fcfg.max_pages)
  }
  RlmVm.eval_program(stmts, init_vars, vm_limits, depth, files, env, net, host).map_error(
    RlmVm.vm_error_to_app_error
  )
end

fn resolve_tier2_root_script(
  cfg: AiConfig,
  files: Files,
  auth: AuthContext,
  question: Text,
  script_opt: Option(Text),
  col_opt: Option(Text),
  heading_opt: Option(Text),
  allowed_kinds: List(Text),
  include_dbs?: Bool,
  max_pages: Int,
  max_blocks_per_page: Int,
  max_subcalls: Int,
  max_depth: Int,
  net: Network,
  now: Time
) : Result((Text, Int, List(RlmTraceStep)), AppError)
  case script_opt
    Some(raw) if not raw.trim.empty?:
      clean = raw.trim
      stmts = try RlmVm.parse_script(clean).map_error(RlmVm.vm_error_to_app_error)
      try RlmVm.validate_program(stmts).map_error(RlmVm.vm_error_to_app_error)
      step = RlmTraceStep(
        step: 1,
        op: "custom_script",
        target: "mo_micro_repl",
        detail: "Validated explicit Tier 2 Mo Micro-REPL script (#{clean.byte_count} bytes)",
        rows_scanned: 0,
        ops_used: 0,
        result_count: stmts.size,
        answer_hash: None
      )
      Ok((clean, 0, [step]))
    Some(_) | None:
      plan_deb = try debit_agent_rlm_call(
        files,
        auth,
        "RLM Tier 2 Planner script generation",
        now
      )
      (p_sys, p_usr) = build_rlm_tier2_planner_prompts(
        question,
        col_opt,
        heading_opt,
        allowed_kinds,
        include_dbs?,
        max_pages,
        max_blocks_per_page,
        max_subcalls,
        max_depth
      )
      p_res = try Http.send(build_llm_request(cfg, p_sys, p_usr), net).map_error(fn(e)
        ServerFailed(reason: "RLM Tier 2 planner request failed: #{e.to_text}")
      end)
      if p_res.status < 200 or p_res.status >= 300
        return Error(ServerFailed(reason: "RLM Tier 2 planner returned HTTP #{p_res.status}"))
      end
      raw_plan = try extract_llm_text(cfg, p_res.body)
      cand = extract_planned_script(raw_plan)
      parsed_ok? = case RlmVm.parse_script(cand)
        Ok(ast):
          case RlmVm.validate_program(ast)
            Ok(_): true
            Error(_): false
          end
        Error(_): false
      end
      if parsed_ok?
        step = RlmTraceStep(
          step: 1,
          op: "plan_script",
          target: cfg.model,
          detail: "Planner emitted valid Mo Micro-REPL script (#{cand.byte_count} bytes)",
          rows_scanned: 0,
          ops_used: 0,
          result_count: 1,
          answer_hash: None
        )
        Ok((cand, plan_deb, [step]))
      else
        fallback = RlmVm.default_tier2_script(
          question,
          col_opt,
          heading_opt,
          allowed_kinds,
          include_dbs?,
          max_pages,
          max_blocks_per_page,
          max_subcalls,
          1,
          max_depth
        )
        step = RlmTraceStep(
          step: 1,
          op: "plan_fallback",
          target: "default_tier2_script",
          detail: "Planner output did not parse/validate cleanly; executing canonical Mo Micro-REPL script",
          rows_scanned: 0,
          ops_used: 0,
          result_count: 1,
          answer_hash: None
        )
        Ok((fallback, plan_deb, [step]))
      end
  end
end

## Executes Tier 2 RLM Deep Research via the capability-confined Mo Micro-REPL VM (`Domain.RlmVm`),
## monotonic `Modb.Taint` child forks (`rlm.sub`), grant call debits, and tainted hybrid search.
fn execute_rlm_tier2(
  auth: AuthContext,
  input: DeepResearchInput,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Result(DeepResearchOutcome, AppError)
  if not Policy.action_permitted?(auth, "read")
    return Error(Forbidden(reason: "grant '#{auth.grant_id}' does not permit 'read'"))
  end
  q = input.question.trim
  if q.empty?
    return Error(BadInput(reason: "question must not be empty"))
  end
  cfg = try ai_config(env)

  max_pages = rlm_clamp(input.max_pages, 6, 1, 12)
  max_b_per_p = rlm_clamp(input.max_blocks_per_page, 6, 1, 15)
  max_subcalls = rlm_clamp(input.max_subcalls, 3, 0, 12)
  max_depth = rlm_clamp(input.max_depth, 2, 1, 4)
  max_rows = rlm_clamp(input.max_rows_scanned, 500, 1, 2000)
  raw_ops = max_rows * 40
  max_ops = if raw_ops < 100: 100 else if raw_ops > 20000: 20000 else: raw_ops
  limits = Views.ReadLimits(max_rows_scanned: max_rows, max_ops: max_ops, max_result_rows: 200)
  allowed_kinds = Rlm.normalize_block_kinds(input.block_kinds)
  include_dbs? = input.include_databases != Some(false)
  now = clock.now

  col_opt = case input.collection_id
    Some(c) if not c.trim.empty?: Some(c.trim)
    Some(_) | None: None
  end
  heading_opt = case input.heading_contains
    Some(h) if not h.trim.empty?: Some(h.trim)
    Some(_) | None: None
  end
  (grant_opt, is_admin) = rlm_auth_mode(auth)
  local_only_ai? = VaultOps.env_ai_local_only?(env)
  (catalog_cids, _query_cids) = try rlm_target_collections(
    files.read_only,
    auth,
    col_opt,
    Some(cfg.base_url),
    local_only_ai?
  )

  sess_id = case input.session_id
    Some(raw) if not raw.trim.empty?: "rlm2:#{auth.grant_id}:#{raw.trim}"
    Some(_) | None: "rlm2:#{auth.grant_id}"
  end
  sess = if files.read_only.exists?(Db.ledger_db_path)
    try TaintBridge.ensure_taint_session_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      sess_id,
      auth.principal.id,
      grant_opt,
      now
    )
  else
    return Error(Missing(entity: "collection", id: "none"))
  end

  (exec_script, plan_deb, pre_trace) = try resolve_tier2_root_script(
    cfg,
    files,
    auth,
    q,
    input.script,
    col_opt,
    heading_opt,
    allowed_kinds,
    include_dbs?,
    max_pages,
    max_b_per_p,
    max_subcalls,
    max_depth,
    net,
    now
  )

  fcfg = RlmFrameConfig(
    cfg: cfg,
    local_only_ai?: local_only_ai?,
    auth: auth,
    default_col_opt: col_opt,
    catalog_cids: catalog_cids,
    default_kinds: allowed_kinds,
    default_heading: heading_opt,
    include_dbs?: include_dbs?,
    max_pages: max_pages,
    max_blocks_per_page: max_b_per_p,
    limits: limits,
    grant_opt: grant_opt,
    is_admin?: is_admin,
    max_depth: max_depth
  )

  vm_out = try run_rlm_tier2_frame(
    fcfg,
    sess.id,
    q,
    exec_script,
    1,
    max_subcalls,
    files,
    env,
    net,
    now
  )

  persisted_j = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      case try TaintBridge.get_taint_session(Ledger.store(db), sess.id)
        Some(ps): Ok(
          Json.Object({
            "untrusted_tainted": Json.Boolean(ps.untrusted_tainted),
            "max_sensitivity": Json.String(TaintBridge.sensitivity_label(ps.max_sensitivity_read)),
            "untrusted_sources": ps.untrusted_sources.to_json
          })
        )
        None: Ok(Json.Null)
      end
    end
  )
  (db_tainted, db_sens, db_srcs) = if persisted_j == Json.Null
    (sess.untrusted_tainted, TaintBridge.sensitivity_label(sess.max_sensitivity_read), [])
  else
    (
      persisted_j.bool_at("untrusted_tainted") or false,
      persisted_j.text_at("max_sensitivity") or "public",
      VaultOps.json_text_list_raw(persisted_j, "untrusted_sources")
    )
  end
  final_tainted = db_tainted or vm_out.untrusted_tainted
  final_sens = RlmVm.max_sensitivity_label(db_sens, vm_out.max_sensitivity_read)
  var final_srcs = db_srcs
  for s in vm_out.untrusted_sources
    if not final_srcs.contains?(s)
      final_srcs = final_srcs.append(s)
    end
  end

  var full_trace = pre_trace
  for st in vm_out.trace
    full_trace = full_trace.append(
      RlmTraceStep(
        step: full_trace.size + 1,
        op: st.op,
        target: st.target,
        detail: st.detail,
        rows_scanned: st.rows_scanned,
        ops_used: st.ops_used,
        result_count: st.result_count,
        answer_hash: st.answer_hash
      )
    )
  end

  Ok(
    DeepResearchOutcome(
      tier: "tier2_micro_repl",
      answer: RlmVm.rlm_val_to_text(vm_out.value),
      model: cfg.model,
      session_id: sess.id,
      untrusted_tainted: final_tainted,
      max_sensitivity_read: final_sens,
      untrusted_sources: final_srcs,
      rows_scanned: vm_out.rows_scanned,
      ops_used: vm_out.views_ops + vm_out.vm_ops,
      subcalls_used: vm_out.subcalls_used,
      max_subcalls: max_subcalls,
      citations: rlm_build_citations(vm_out.block_slices),
      db_slices: vm_out.db_slices,
      trace: full_trace,
      executed_script: Some(exec_script),
      depth_used: vm_out.max_depth_reached,
      max_depth: max_depth,
      child_sessions: vm_out.child_sessions,
      grant_calls_debited: plan_deb + vm_out.grant_calls_debited
    )
  )
end

## Unified dispatcher between Tier 1 (`Modb.Views.ReadProgram`) and Tier 2 (`Domain.RlmVm`).
fn execute_deep_research(
  auth: AuthContext,
  input: DeepResearchInput,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Result(DeepResearchOutcome, AppError)
  tier_norm = case input.tier
    Some(t): t.trim.ascii_lowercase
    None:
      case input.script
        Some(sc) if not sc.trim.empty?: "tier2"
        Some(_) | None: "tier1"
      end
  end
  if tier_norm.empty? or tier_norm == "tier1" or tier_norm == "tier1_read_program"
    execute_rlm_tier1(auth, input, files, clock, env, net)
  else if tier_norm == "tier2" or tier_norm == "tier2_micro_repl"
    execute_rlm_tier2(auth, input, files, clock, env, net)
  else
    Error(BadInput(reason: "tier must be 'tier1' or 'tier2'"))
  end
end

## Serializes `DeepResearchOutcome` into the canonical JSON API & MCP structuredContent shape.
fn deep_research_outcome_to_json(out: DeepResearchOutcome) : Json
  exec_sc_json = case out.executed_script
    Some(s): Json.String(s)
    None: Json.Null
  end
  Json.Object({
    "tier": Json.String(out.tier),
    "answer": Json.String(out.answer),
    "model": Json.String(out.model),
    "session_id": Json.String(out.session_id),
    "rows_scanned": Json.int(out.rows_scanned),
    "ops_used": Json.int(out.ops_used),
    "subcalls_used": Json.int(out.subcalls_used),
    "max_subcalls": Json.int(out.max_subcalls),
    "citations": Json.Array(out.citations),
    "db_slices": out.db_slices.to_json,
    "trace": out.trace.to_json,
    "executed_script": exec_sc_json,
    "depth_used": Json.int(out.depth_used),
    "max_depth": Json.int(out.max_depth),
    "child_sessions": out.child_sessions.to_json,
    "grant_calls_debited": Json.int(out.grant_calls_debited),
    "taint": Json.Object({
      "session_id": Json.String(out.session_id),
      "untrusted_tainted": Json.Boolean(out.untrusted_tainted),
      "max_sensitivity_read": Json.String(out.max_sensitivity_read),
      "untrusted_sources": out.untrusted_sources.to_json
    })
  })
end

## `POST /api/ai/deep-research` — Executes Tier 1 (`Modb.Views.ReadProgram`) or Tier 2 (`Domain.RlmVm`)
## RLM Deep Research and returns synthesized findings, citations, trace, and `Modb.Taint` state.
fn deep_research(
  req: Api.Request,
  auth: AuthContext,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  try Auth.require_session_csrf(req, auth)
  body = try VaultOps.parse_req_json_obj(req.text)
  input = DeepResearchInput(
    question: try VaultOps.req_text(body, "question"),
    collection_id: body.text_at("collection_id"),
    block_kinds: VaultOps.json_text_list_opt(body, "block_kinds"),
    heading_contains: body.text_at("heading_contains"),
    include_databases: body.bool_at("include_databases"),
    max_pages: body.int_at("max_pages"),
    max_blocks_per_page: body.int_at("max_blocks_per_page"),
    max_subcalls: body.int_at("max_subcalls"),
    max_rows_scanned: body.int_at("max_rows_scanned"),
    session_id: body.text_at("session_id"),
    tier: body.text_at("tier"),
    script: body.text_at("script"),
    max_depth: body.int_at("max_depth")
  )
  out = try execute_deep_research(auth, input, files, clock, env, net)
  Ok(json_ok(200, deep_research_outcome_to_json(out)))
end
