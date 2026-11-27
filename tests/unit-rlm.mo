## Extracted unit tests for Domain.Rlm and Domain.RlmVm.
module Tests.UnitRlm
use Domain.Rlm{chunk_block_slices, extract_query_keywords, score_summary_row, slice_block_rows}
use Domain.RlmVm{
  RlmHostFns,
  RlmVal,
  RlmVmError,
  RlmVmLimits,
  default_tier2_script,
  default_vm_limits,
  eval_program,
  parse_script,
  plain_delta,
  rlm_val_to_json,
  rlm_val_to_text,
  validate_program
}
use Json

test "Rlm extracts keywords without stopwords and ranks living summaries"
  kws = extract_query_keywords("How does the Rollback Procedure rotate quorum keys?")
  assert kws.contains?("rollback")
  assert kws.contains?("procedure")
  assert kws.contains?("rotate")
  assert kws.contains?("quorum")
  assert kws.contains?("keys")
  assert not kws.contains?("how")
  assert not kws.contains?("does")
  assert not kws.contains?("the")

  r1 = Json.Object({
    "title": Json.String("Rollback Procedure Runbook"),
    "headings_text": Json.String("quorum | rotate"),
    "structural_summary": Json.String("runbook"),
    "semantic_summary": Json.String("rotate quorum keys safely")
  })
  r2 = Json.Object({
    "title": Json.String("Coffee Menu"),
    "headings_text": Json.String("espresso"),
    "structural_summary": Json.String("menu"),
    "semantic_summary": Json.String("")
  })
  assert score_summary_row(r1, kws) > score_summary_row(r2, kws)
  assert score_summary_row(r2, kws) == 0
end

test "Rlm slice_block_rows isolates matching heading sections and filters block kinds"
  b1 = Json.Object({
    "block_id": Json.String("blk_1"),
    "page_id": Json.String("pg_1"),
    "page_title": Json.String("Ops Runbook"),
    "collection_id": Json.String("col_eng"),
    "rank": Json.String("a"),
    "kind_tag": Json.String("heading"),
    "heading_level": Json.int(2),
    "markdown": Json.String("Rollback Procedure"),
    "version": Json.int(1)
  })
  b2 = Json.Object({
    "block_id": Json.String("blk_2"),
    "page_id": Json.String("pg_1"),
    "page_title": Json.String("Ops Runbook"),
    "collection_id": Json.String("col_eng"),
    "rank": Json.String("b"),
    "kind_tag": Json.String("paragraph"),
    "heading_level": Json.int(0),
    "markdown": Json.String("Drain canary before rollback."),
    "version": Json.int(1)
  })
  b3 = Json.Object({
    "block_id": Json.String("blk_3"),
    "page_id": Json.String("pg_1"),
    "page_title": Json.String("Ops Runbook"),
    "collection_id": Json.String("col_eng"),
    "rank": Json.String("c"),
    "kind_tag": Json.String("code_block"),
    "heading_level": Json.int(0),
    "markdown": Json.String("kubectl rollout undo deploy/api"),
    "version": Json.int(1)
  })
  b4 = Json.Object({
    "block_id": Json.String("blk_4"),
    "page_id": Json.String("pg_1"),
    "page_title": Json.String("Ops Runbook"),
    "collection_id": Json.String("col_eng"),
    "rank": Json.String("d"),
    "kind_tag": Json.String("heading"),
    "heading_level": Json.int(2),
    "markdown": Json.String("Observability"),
    "version": Json.int(1)
  })
  b5 = Json.Object({
    "block_id": Json.String("blk_5"),
    "page_id": Json.String("pg_1"),
    "page_title": Json.String("Ops Runbook"),
    "collection_id": Json.String("col_eng"),
    "rank": Json.String("e"),
    "kind_tag": Json.String("code_block"),
    "heading_level": Json.int(0),
    "markdown": Json.String("prometheus --version"),
    "version": Json.int(1)
  })

  shuffled = [b5, b3, b1, b4, b2]
  code_only = slice_block_rows(
    shuffled,
    ["rollout"],
    Some("Rollback"),
    ["code_block"],
    4
  )
  assert code_only.size == 1
  only = code_only.first or stop "only"
  assert only.block_id == "blk_3"
  assert only.heading_path == Some("Rollback Procedure")

  chunks = chunk_block_slices([only, only, only, only, only], 3)
  assert chunks.size == 3
end

test "RlmVm: lexer, parser, control flow & host capability hooks"
  src = """
    let sum = 0
    let xs = ws.summaries(null)
    var acc = 0
    for r in xs
      if contains(r.summary_text, "rollback")
        acc = acc + 1
      end
    end
    let ans = llm.ask("summarize", "count=" + str(acc))
    return {count: acc, answer: ans, taken: take(map_field(xs, "entity_id"), 2)}
  """
  assert parse_script(src) is Ok(ast)
  assert validate_program(ast) is Ok(_)
  host = RlmHostFns(
    on_summaries: fn(_f, _c)
      Ok(
        plain_delta(
          VList([
            VRecord({"entity_id": VText("pg-1"), "summary_text": VText("Gateway rollback")}),
            VRecord({"entity_id": VText("pg-2"), "summary_text": VText("Release notes")})
          ])
        )
      )
    end,
    on_blocks: fn(_f, _p, _k, _h) Ok(plain_delta(VList([]))) end,
    on_db_rows: fn(_f, _d) Ok(plain_delta(VList([]))) end,
    on_search: fn(_f, _e, _n, _q, _c) Ok(plain_delta(VList([]))) end,
    on_llm_ask: fn(_f, _n, _p, c) Ok(plain_delta(VText("ask(#{rlm_val_to_text(c)})"))) end,
    on_rlm_sub: fn(_f, _e, _n, _q, _s, _d, _r) Ok(plain_delta(VText("sub"))) end
  )
  tf = Files.in_memory({})
  te = Env.of({})
  tn = Network.fake({})
  assert eval_program(ast, {}, default_vm_limits(3, 2), 1, tf, te, tn, host) is Ok(out)
  assert out.subcalls_used == 1
  j = rlm_val_to_json(out.value)
  assert j.int_at("count") == Some(1)
  assert j.text_at("answer") == Some("ask(count=1)")
end

test "RlmVm: static capability firewall, subcall quota, depth cap & loop bound"
  assert parse_script("let x = Files.read(\"vellum.modb\")\nreturn x") is Ok(fs_ast)
  assert validate_program(fs_ast) is Error(DisallowedCapability(name: "Files.read"))
  assert parse_script("return Http.send(\"https://evil.example\")") is Ok(http_ast)
  assert validate_program(http_ast) is Error(DisallowedCapability(name: "Http.send"))

  host = RlmHostFns(
    on_summaries: fn(_f, _c) Ok(plain_delta(VList([]))) end,
    on_blocks: fn(_f, _p, _k, _h) Ok(plain_delta(VList([]))) end,
    on_db_rows: fn(_f, _d) Ok(plain_delta(VList([]))) end,
    on_search: fn(_f, _e, _n, _q, _c) Ok(plain_delta(VList([]))) end,
    on_llm_ask: fn(_f, _n, _p, _c) Ok(plain_delta(VText("ok"))) end,
    on_rlm_sub: fn(_f, _e, _n, _q, _s, _d, _r) Ok(plain_delta(VText("sub"))) end
  )
  tf = Files.in_memory({})
  te = Env.of({})
  tn = Network.fake({})
  assert parse_script("let a = llm.ask(\"p\", \"1\")\nlet b = llm.ask(\"p\", \"2\")\nreturn a + b") is
    Ok(ask_ast)
  assert eval_program(ask_ast, {}, default_vm_limits(1, 2), 1, tf, te, tn, host) is
    Error(SubcallLimitExceeded(used: 1, max_subcalls: 1))
  assert parse_script("return rlm.sub(\"deeper\", null)") is Ok(sub_ast)
  assert eval_program(sub_ast, {}, default_vm_limits(3, 2), 2, tf, te, tn, host) is
    Error(DepthLimitExceeded(depth: 3, max_depth: 2))
  tiny = RlmVmLimits(
    max_ops: 4,
    max_subcalls: 2,
    max_depth: 2,
    max_loop_iters: 10,
    max_string_len: 1024
  )
  assert eval_program(ask_ast, {}, tiny, 1, tf, te, tn, host) is
    Error(BudgetExceeded(ops: _, max_ops: 4))
  def_src = default_tier2_script(
    "gateway rollback",
    Some("eng"),
    Some("Rollback"),
    ["code_block"],
    true,
    4,
    5,
    3,
    1,
    2
  )
  assert parse_script(def_src) is Ok(def_ast)
  assert validate_program(def_ast) is Ok(_)
end
