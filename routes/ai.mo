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
GardenStalePage(..),
GardenBrokenLink(..),
GardenReport(..),
ai_config,
embed_config,
build_llm_request,
build_llm_request_with_stream,
build_embedding_request,
fetch_embedding,
execute_workspace_search,
ask_workspace,
draft_blocks,
run_garden,
garden_job
use Api
use Arvo.Id
use Db
use Domain.Blocks
use Domain.Collab{ProposalMeta, WorldPatchArgs}
use Domain.Policy
use Domain.Types{
  AppError,
  AuthContext,
  AuthorKind,
  BlockKind,
  BlockOp,
  PrincipalKind,
  Provenance,
  SearchResultItem
}
use Http
use Json
use Modb{Store}
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Modb.Vec
use Modb.World
use Routes.Auth

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
          ) | FileEmbed(attachment_id: _, filename: _): Unit
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
