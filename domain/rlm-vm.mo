## Capability-confined Mo Micro-REPL VM (`Domain.RlmVm`) for Tier 2 RLM Deep Research.
## Intentionally imports zero Http, Db, Modb, Ledger, or Os modules: external effects
## are strictly injected via `RlmHostFns` and statically allowlisted before execution.
module Domain.RlmVm
expose RlmVal(..),
RlmVmLimits(..),
RlmVmError(..),
RlmUnOp(..),
RlmBinOp(..),
RlmExpr(..),
RlmStmt(..),
RlmHostDelta(..),
RlmHostFns(..),
RlmEvalOutcome(..),
plain_delta,
max_sensitivity_label,
default_vm_limits,
rlm_val_to_text,
rlm_val_to_json,
json_to_rlm_val,
vm_error_to_text,
vm_error_to_app_error,
parse_script,
validate_program,
eval_program,
default_tier2_script
use Domain.Rlm{RlmBlockSlice, RlmDbSlice, RlmTraceStep}
use Domain.Types{AppError}
use Json

enum RlmVal
  VNull
  VBool(Bool)
  VInt(Int)
  VText(Text)
  VList(List(RlmVal))
  VRecord(Map(Text, RlmVal))
end

struct RlmVmLimits
  max_ops: Int
  max_subcalls: Int
  max_depth: Int
  max_loop_iters: Int
  max_string_len: Int
end

enum RlmVmError
  SyntaxError(line: Int, reason: Text)
  DisallowedCapability(name: Text)
  UndefinedVar(name: Text)
  TypeMismatch(reason: Text)
  BudgetExceeded(ops: Int, max_ops: Int)
  SubcallLimitExceeded(used: Int, max_subcalls: Int)
  DepthLimitExceeded(depth: Int, max_depth: Int)
  LoopLimitExceeded(iters: Int, max_iters: Int)
  HostAppError(err: AppError)
end

enum RlmUnOp
  UNot
  UNeg
end

enum RlmBinOp
  BAdd
  BSub
  BMul
  BDiv
  BEq
  BNe
  BLt
  BLe
  BGt
  BGe
  BAnd
  BOr
end

enum RlmExpr
  ELit(RlmVal)
  EVar(Text)
  EList(List(RlmExpr))
  ERecord(List((Text, RlmExpr)))
  EField(obj: RlmExpr, field: Text)
  EIndex(obj: RlmExpr, idx: RlmExpr)
  EMethod(obj: RlmExpr, method: Text, args: List(RlmExpr))
  ECall(target: Text, args: List(RlmExpr))
  EUnOp(op: RlmUnOp, expr: RlmExpr)
  EBinOp(op: RlmBinOp, left: RlmExpr, right: RlmExpr)
end

enum RlmStmt
  SAssign(name: Text, expr: RlmExpr)
  SReturn(expr: RlmExpr)
  SExpr(expr: RlmExpr)
  SIf(cond: RlmExpr, then_body: List(RlmStmt), else_body: List(RlmStmt))
  SFor(var_name: Text, iter_expr: RlmExpr, body: List(RlmStmt))
end

struct RlmHostDelta
  value: RlmVal
  rows_scanned: Int
  views_ops: Int
  subcalls_delta: Int
  depth_reached: Int
  grant_calls_debited: Int
  block_slices: List(RlmBlockSlice)
  db_slices: List(RlmDbSlice)
  trace: List(RlmTraceStep)
  child_sessions: List(Text)
  untrusted_tainted: Bool
  max_sensitivity_read: Text
  untrusted_sources: List(Text)
end

fn plain_delta(val: RlmVal) : RlmHostDelta
  RlmHostDelta(
    value: val,
    rows_scanned: 0,
    views_ops: 0,
    subcalls_delta: 0,
    depth_reached: 0,
    grant_calls_debited: 0,
    block_slices: [],
    db_slices: [],
    trace: [],
    child_sessions: [],
    untrusted_tainted: false,
    max_sensitivity_read: "public",
    untrusted_sources: []
  )
end

fn sens_rank(label: Text) : Int
  clean = label.trim.ascii_lowercase
  if clean == "restricted"
    3
  else if clean == "confidential"
    2
  else if clean == "internal"
    1
  else
    0
  end
end

fn max_sensitivity_label(a: Text, b: Text) : Text
  if sens_rank(b) > sens_rank(a): b else: a
end

struct RlmHostFns
  on_summaries: fn(Files, RlmVal) : Result(RlmHostDelta, RlmVmError)
  on_blocks: fn(Files, RlmVal, RlmVal, RlmVal) : Result(RlmHostDelta, RlmVmError)
  on_db_rows: fn(Files, RlmVal) : Result(RlmHostDelta, RlmVmError)
  on_search: fn(Files, Env, Network, RlmVal, RlmVal) : Result(RlmHostDelta, RlmVmError)
  on_llm_ask: fn(Files, Network, RlmVal, RlmVal) : Result(RlmHostDelta, RlmVmError)
  on_rlm_sub: fn(Files, Env, Network, RlmVal, RlmVal, Int, Int) : Result(RlmHostDelta, RlmVmError)
end

struct RlmEvalOutcome
  value: RlmVal
  vm_ops: Int
  views_ops: Int
  rows_scanned: Int
  subcalls_used: Int
  max_depth_reached: Int
  grant_calls_debited: Int
  block_slices: List(RlmBlockSlice)
  db_slices: List(RlmDbSlice)
  trace: List(RlmTraceStep)
  child_sessions: List(Text)
  untrusted_tainted: Bool
  max_sensitivity_read: Text
  untrusted_sources: List(Text)
end

fn default_vm_limits(max_subcalls: Int, max_depth: Int) : RlmVmLimits
  RlmVmLimits(
    max_ops: 5000,
    max_subcalls: if max_subcalls < 0: 0 else if max_subcalls > 12: 12 else: max_subcalls,
    max_depth: if max_depth < 1: 1 else if max_depth > 4: 4 else: max_depth,
    max_loop_iters: 300,
    max_string_len: 48000
  )
end

fn clip_text(s: Text, max_len: Int) : Text
  if max_len <= 0 or s.byte_count <= max_len
    s
  else
    s.bytes.slice(0, max_len).decode_utf8 or s
  end
end

fn truthy?(v: RlmVal) : Bool
  case v
    VNull: false
    VBool(b): b
    VInt(i): i != 0
    VText(t): not t.empty?
    VList(xs): not xs.empty?
    VRecord(m): not m.entries.empty?
  end
end

fn rlm_val_to_text(v: RlmVal) : Text
  case v
    VNull: ""
    VBool(b): if b: "true" else: "false"
    VInt(i): i.to_text
    VText(t): t
    VList(xs): rlm_val_to_json(VList(xs)).to_text
    VRecord(m): rlm_val_to_json(VRecord(m)).to_text
  end
end

fn rlm_val_to_json(v: RlmVal) : Json
  case v
    VNull: Json.Null
    VBool(b): Json.Boolean(b)
    VInt(i): Json.int(i)
    VText(t): Json.String(t)
    VList(xs): Json.Array(xs.map(fn(x) rlm_val_to_json(x) end))
    VRecord(m):
      var obj = {}
      for (k, val) in m.entries
        obj = obj.set(k, rlm_val_to_json(val))
      end
      Json.Object(obj)
  end
end

fn json_to_rlm_val(j: Json) : RlmVal
  case j
    Json.Null: VNull
    Json.Boolean(b): VBool(b)
    Json.Number(n):
      case n.to_int
        Some(i): VInt(i)
        None: VText(n.to_text)
      end
    Json.String(s): VText(s)
    Json.Array(xs): VList(xs.map(fn(x) json_to_rlm_val(x) end))
    Json.Object(m):
      var fields = {}
      for (k, val) in m.entries
        fields = fields.set(k, json_to_rlm_val(val))
      end
      VRecord(fields)
  end
end

fn val_eq?(a: RlmVal, b: RlmVal) : Bool
  case (a, b)
    (VNull, VNull): true
    (VBool(x), VBool(y)): x == y
    (VInt(x), VInt(y)): x == y
    (VText(x), VText(y)): x == y
    (VList(xs), VList(ys)):
      xs.size == ys.size and xs.enumerate.all?(fn(p) val_eq?(p.1, ys.get(p.0) or VNull) end)
    (VNull, _) | (VBool(_), _) | (VInt(_), _) | (VText(_), _) | (VList(_), _) | (VRecord(_), _):
      false
  end
end

fn vm_error_to_text(err: RlmVmError) : Text
  case err
    SyntaxError(line: l, reason: r): "RLM VM syntax error at line #{l}: #{r}"
    DisallowedCapability(name: n): "capability '#{n}' is not permitted in RLM Micro-REPL sandbox"
    UndefinedVar(name: n): "undefined RLM VM variable '#{n}'"
    TypeMismatch(reason: r): "RLM VM type error: #{r}"
    BudgetExceeded(ops: o, max_ops: m): "RLM VM work budget exceeded (#{o} > #{m} ops)"
    SubcallLimitExceeded(used: u, max_subcalls: m):
      "RLM VM sub-call limit exceeded (#{u} >= #{m})"
    DepthLimitExceeded(depth: d, max_depth: m):
      "RLM VM recursion depth limit exceeded (#{d} > #{m})"
    LoopLimitExceeded(iters: it, max_iters: m):
      "RLM VM loop iteration limit exceeded (#{it} > #{m})"
    HostAppError(err: e): e.to_text
  end
end

fn vm_error_to_app_error(err: RlmVmError) : AppError
  case err
    HostAppError(err: e): e
    DisallowedCapability(name: _) | SyntaxError(line: _, reason: _) | UndefinedVar(name: _) |
      TypeMismatch(reason: _) | BudgetExceeded(ops: _, max_ops: _) |
      SubcallLimitExceeded(used: _, max_subcalls: _) | DepthLimitExceeded(depth: _, max_depth: _) |
      LoopLimitExceeded(iters: _, max_iters: _):
      BadInput(reason: vm_error_to_text(err))
  end
end

## Compact lexer with string-tagged tokens (`tag` = "ident", "str", "int", "nl", "eof", or punctuation/operator).
struct Tok
  tag: Text
  sval: Text
  nval: Int
  line: Int
end

fn lex_string(chars: List(Char), i0: Int, quote: Char, line: Int) : Result((Text, Int, Int), RlmVmError)
  var i = i0
  var cur_line = line
  var out = []
  while i < chars.size
    c = chars.get(i) or ' '
    if c == quote
      return Ok((Text.from_chars(out), i + 1, cur_line))
    end
    if c == '\n'
      cur_line += 1
    end
    if c == '\\'
      i += 1
      if i >= chars.size
        return Error(SyntaxError(line: cur_line, reason: "unterminated escape in string literal"))
      end
      esc = chars.get(i) or ' '
      mapped = if esc == 'n'
        '\n'
      else if esc == 't'
        '\t'
      else if esc == 'r'
        '\r'
      else
        esc
      end
      out = out.append(mapped)
    else
      out = out.append(c)
    end
    i += 1
  end
  Error(SyntaxError(line: line, reason: "unterminated string literal"))
end

fn tokenize(src: Text) : Result(List(Tok), RlmVmError)
  chars = src.chars
  var i = 0
  var line = 1
  var toks = []
  while i < chars.size
    c = chars.get(i) or ' '
    nc = chars.get(i + 1) or '\u{0000}'
    if c == ' ' or c == '\t' or c == '\r'
      i += 1
    else if c == '\n'
      toks = toks.append(Tok(tag: "nl", sval: "", nval: 0, line: line))
      line += 1
      i += 1
    else if c == '#' or (c == '/' and nc == '/')
      while i < chars.size and (chars.get(i) or ' ') != '\n'
        i += 1
      end
    else if c == '"' or c == '\''
      (s, ni, nl) = try lex_string(chars, i + 1, c, line)
      toks = toks.append(Tok(tag: "str", sval: s, nval: 0, line: line))
      i = ni
      line = nl
    else if c.ascii_digit?
      var acc = 0
      while i < chars.size and (chars.get(i) or ' ').ascii_digit?
        acc = acc * 10 + ((chars.get(i) or '0').code - 48)
        i += 1
      end
      toks = toks.append(Tok(tag: "int", sval: "", nval: acc, line: line))
    else if c.ascii_letter? or c == '_'
      var buf = []
      while i < chars.size
        ch = chars.get(i) or ' '
        if not (ch.ascii_letter? or ch.ascii_digit? or ch == '_' or ch == '?')
          break
        end
        buf = buf.append(ch)
        i += 1
      end
      toks = toks.append(Tok(tag: "ident", sval: Text.from_chars(buf), nval: 0, line: line))
    else
      two = Text.from_chars([c, nc])
      one = Text.from_chars([c])
      if two == "==" or two == "!=" or two == "<=" or two == ">="
        toks = toks.append(Tok(tag: two, sval: two, nval: 0, line: line))
        i += 2
      else if "()[]{}.,:;=<>+-*/!".contains?(one)
        toks = toks.append(Tok(tag: one, sval: one, nval: 0, line: line))
        i += 1
      else
        return Error(SyntaxError(line: line, reason: "unexpected character '#{c}'"))
      end
    end
  end
  Ok(toks.append(Tok(tag: "eof", sval: "", nval: 0, line: line)))
end

## Compact recursive-descent parser.
struct Parser
  toks: List(Tok)
  pos: Int
end

fn p_tok(p: Parser, offset: Int) : Tok
  p.toks.get(p.pos + offset) or Tok(tag: "eof", sval: "", nval: 0, line: 1)
end

fn p_adv(p: Parser) : Parser
  Parser(toks: p.toks, pos: p.pos + 1)
end

fn p_skip_nl(p: Parser) : Parser
  var cur = p
  while p_tok(cur, 0).tag == "nl"
    cur = p_adv(cur)
  end
  cur
end

fn p_skip_sep(p: Parser) : Parser
  var cur = p
  while true
    tg = p_tok(cur, 0).tag
    if tg == "nl" or tg == ";"
      cur = p_adv(cur)
    else
      return cur
    end
  end
  cur
end

fn kw?(t: Tok, kw: Text) : Bool
  t.tag == "ident" and t.sval == kw
end

fn parse_args(p0: Parser) : Result((Parser, List(RlmExpr)), RlmVmError)
  var p = p_skip_nl(p_adv(p0))
  var args = []
  if p_tok(p, 0).tag == ")"
    return Ok((p_adv(p), args))
  end
  while true
    (p1, e) = try parse_expr(p_skip_nl(p))
    args = args.append(e)
    p = p_skip_nl(p1)
    t = p_tok(p, 0)
    if t.tag == ","
      p = p_adv(p)
    else if t.tag == ")"
      return Ok((p_adv(p), args))
    else
      return Error(SyntaxError(line: t.line, reason: "expected ',' or ')' in arguments"))
    end
  end
  Ok((p, args))
end

fn parse_list(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  var p = p_skip_nl(p_adv(p0))
  var items = []
  while true
    p = p_skip_nl(p)
    t = p_tok(p, 0)
    if t.tag == "]"
      return Ok((p_adv(p), EList(items)))
    end
    (p1, e) = try parse_expr(p)
    items = items.append(e)
    p = p_skip_nl(p1)
    nt = p_tok(p, 0)
    if nt.tag == ","
      p = p_adv(p)
    else if nt.tag == "]"
      return Ok((p_adv(p), EList(items)))
    else
      return Error(SyntaxError(line: nt.line, reason: "expected ',' or ']' in list literal"))
    end
  end
  Ok((p, EList(items)))
end

fn parse_record(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  var p = p_skip_nl(p_adv(p0))
  var entries = []
  while true
    p = p_skip_nl(p)
    kt = p_tok(p, 0)
    if kt.tag == "}"
      return Ok((p_adv(p), ERecord(entries)))
    end
    if kt.tag != "str" and kt.tag != "ident"
      return Error(SyntaxError(line: kt.line, reason: "expected field key inside '{...}'"))
    end
    p = p_adv(p)
    if p_tok(p, 0).tag != ":"
      t = p_tok(p, 0)
      return Error(SyntaxError(line: t.line, reason: "expected ':' after key '#{kt.sval}'"))
    end
    (p1, val_e) = try parse_expr(p_skip_nl(p_adv(p)))
    entries = entries.append((kt.sval, val_e))
    p = p_skip_nl(p1)
    nt = p_tok(p, 0)
    if nt.tag == ","
      p = p_adv(p)
    else if nt.tag == "}"
      return Ok((p_adv(p), ERecord(entries)))
    else
      return Error(SyntaxError(line: nt.line, reason: "expected ',' or '}' in record"))
    end
  end
  Ok((p, ERecord(entries)))
end

fn parse_primary(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  t = p_tok(p0, 0)
  if t.tag == "int"
    Ok((p_adv(p0), ELit(VInt(t.nval))))
  else if t.tag == "str"
    Ok((p_adv(p0), ELit(VText(t.sval))))
  else if t.tag == "["
    parse_list(p0)
  else if t.tag == "{"
    parse_record(p0)
  else if t.tag == "("
    (p1, inner) = try parse_expr(p_skip_nl(p_adv(p0)))
    p2 = p_skip_nl(p1)
    if p_tok(p2, 0).tag != ")"
      return Error(SyntaxError(line: p_tok(p2, 0).line, reason: "expected closing ')'"))
    end
    Ok((p_adv(p2), inner))
  else if t.tag == "ident"
    p1 = p_adv(p0)
    if t.sval == "true"
      Ok((p1, ELit(VBool(true))))
    else if t.sval == "false"
      Ok((p1, ELit(VBool(false))))
    else if t.sval == "null" or t.sval == "None"
      Ok((p1, ELit(VNull)))
    else if p_tok(p1, 0).tag == "("
      (p2, args) = try parse_args(p1)
      Ok((p2, ECall(target: t.sval, args: args)))
    else
      Ok((p1, EVar(t.sval)))
    end
  else
    Error(SyntaxError(line: t.line, reason: "unexpected token '#{t.tag}' in expression"))
  end
end

fn capability_ns?(ns: Text) : Bool
  ns == "ws" or ns == "llm" or ns == "rlm" or ns == "Files" or ns == "Http" or
    ns == "Env" or
    ns == "Os" or
    ns == "os" or
    ns == "Net"
end

fn parse_postfix(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  (p1, cur0) = try parse_primary(p0)
  var p = p1
  var expr = cur0
  while true
    tk = p_tok(p, 0)
    if tk.tag == "."
      ft = p_tok(p_adv(p), 0)
      if ft.tag != "ident"
        return Error(SyntaxError(line: ft.line, reason: "expected identifier after '.'"))
      end
      p = p_adv(p_adv(p))
      if p_tok(p, 0).tag == "("
        (p2, args) = try parse_args(p)
        p = p2
        expr = case expr
          EVar(ns) if capability_ns?(ns): ECall(target: "#{ns}.#{ft.sval}", args: args)
          EVar(_) | ELit(_) | EList(_) | ERecord(_) | EField(obj: _, field: _) |
            EIndex(obj: _, idx: _) | EMethod(obj: _, method: _, args: _) |
            ECall(target: _, args: _) | EUnOp(op: _, expr: _) |
            EBinOp(op: _, left: _, right: _):
            EMethod(obj: expr, method: ft.sval, args: args)
        end
      else
        expr = EField(obj: expr, field: ft.sval)
      end
    else if tk.tag == "["
      (p2, idx_e) = try parse_expr(p_skip_nl(p_adv(p)))
      p3 = p_skip_nl(p2)
      if p_tok(p3, 0).tag != "]"
        return Error(SyntaxError(line: p_tok(p3, 0).line, reason: "expected ']'"))
      end
      p = p_adv(p3)
      expr = EIndex(obj: expr, idx: idx_e)
    else
      return Ok((p, expr))
    end
  end
  Ok((p, expr))
end

fn parse_unary(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  tk = p_tok(p0, 0)
  if kw?(tk, "not") or tk.tag == "!"
    (p1, inner) = try parse_unary(p_adv(p0))
    Ok((p1, EUnOp(op: UNot, expr: inner)))
  else if tk.tag == "-"
    (p1, inner) = try parse_unary(p_adv(p0))
    Ok((p1, EUnOp(op: UNeg, expr: inner)))
  else
    parse_postfix(p0)
  end
end

fn parse_mul(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  (p1, left0) = try parse_unary(p0)
  var p = p1
  var left = left0
  while p_tok(p, 0).tag == "*" or p_tok(p, 0).tag == "/"
    tg = p_tok(p, 0).tag
    (p2, r) = try parse_unary(p_adv(p))
    p = p2
    left = EBinOp(op: if tg == "*": BMul else: BDiv, left: left, right: r)
  end
  Ok((p, left))
end

fn parse_add(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  (p1, left0) = try parse_mul(p0)
  var p = p1
  var left = left0
  while p_tok(p, 0).tag == "+" or p_tok(p, 0).tag == "-"
    tg = p_tok(p, 0).tag
    (p2, r) = try parse_mul(p_adv(p))
    p = p2
    left = EBinOp(op: if tg == "+": BAdd else: BSub, left: left, right: r)
  end
  Ok((p, left))
end

fn parse_cmp(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  (p1, left0) = try parse_add(p0)
  var p = p1
  var left = left0
  while true
    tg = p_tok(p, 0).tag
    op_opt = if tg == "=="
      Some(BEq)
    else if tg == "!="
      Some(BNe)
    else if tg == "<"
      Some(BLt)
    else if tg == "<="
      Some(BLe)
    else if tg == ">"
      Some(BGt)
    else if tg == ">="
      Some(BGe)
    else
      None
    end
    case op_opt
      Some(op):
        (p2, r) = try parse_add(p_adv(p))
        p = p2
        left = EBinOp(op: op, left: left, right: r)
      None: return Ok((p, left))
    end
  end
  Ok((p, left))
end

fn parse_and(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  (p1, left0) = try parse_cmp(p0)
  var p = p1
  var left = left0
  while kw?(p_tok(p, 0), "and")
    (p2, r) = try parse_cmp(p_adv(p))
    p = p2
    left = EBinOp(op: BAnd, left: left, right: r)
  end
  Ok((p, left))
end

fn parse_expr(p0: Parser) : Result((Parser, RlmExpr), RlmVmError)
  (p1, left0) = try parse_and(p0)
  var p = p1
  var left = left0
  while kw?(p_tok(p, 0), "or")
    (p2, r) = try parse_and(p_adv(p))
    p = p2
    left = EBinOp(op: BOr, left: left, right: r)
  end
  Ok((p, left))
end

fn parse_block(p0: Parser, allow_else?: Bool) : Result((Parser, List(RlmStmt), Bool), RlmVmError)
  var p = p_skip_sep(p0)
  var stmts = []
  while true
    p = p_skip_sep(p)
    tk = p_tok(p, 0)
    if tk.tag == "eof"
      return Error(SyntaxError(line: tk.line, reason: "expected 'end' before end of script"))
    end
    if kw?(tk, "end")
      return Ok((p_adv(p), stmts, false))
    end
    if allow_else? and kw?(tk, "else")
      return Ok((p_adv(p), stmts, true))
    end
    (p1, st) = try parse_stmt(p)
    stmts = stmts.append(st)
    p = p1
  end
  Ok((p, stmts, false))
end

fn parse_if_stmt(p0: Parser) : Result((Parser, RlmStmt), RlmVmError)
  (p1, cond) = try parse_expr(p_adv(p0))
  (p2, then_body, saw_else) = try parse_block(p1, true)
  if not saw_else
    return Ok((p2, SIf(cond: cond, then_body: then_body, else_body: [])))
  end
  if kw?(p_tok(p2, 0), "if")
    (p3, nested_if) = try parse_if_stmt(p2)
    return Ok((p3, SIf(cond: cond, then_body: then_body, else_body: [nested_if])))
  end
  (p3, else_body, _) = try parse_block(p2, false)
  Ok((p3, SIf(cond: cond, then_body: then_body, else_body: else_body)))
end

fn parse_for_stmt(p0: Parser) : Result((Parser, RlmStmt), RlmVmError)
  vt = p_tok(p_adv(p0), 0)
  if vt.tag != "ident"
    return Error(SyntaxError(line: vt.line, reason: "expected loop variable after 'for'"))
  end
  p2 = p_adv(p_adv(p0))
  if not kw?(p_tok(p2, 0), "in")
    return Error(SyntaxError(line: p_tok(p2, 0).line, reason: "expected 'in' after loop var"))
  end
  (p3, iter_e) = try parse_expr(p_adv(p2))
  (p4, body, _) = try parse_block(p3, false)
  Ok((p4, SFor(var_name: vt.sval, iter_expr: iter_e, body: body)))
end

fn parse_stmt(p0: Parser) : Result((Parser, RlmStmt), RlmVmError)
  tk = p_tok(p0, 0)
  if kw?(tk, "return")
    (p1, e) = try parse_expr(p_adv(p0))
    Ok((p1, SReturn(expr: e)))
  else if kw?(tk, "if")
    parse_if_stmt(p0)
  else if kw?(tk, "for")
    parse_for_stmt(p0)
  else if kw?(tk, "var") or kw?(tk, "let")
    vt = p_tok(p_adv(p0), 0)
    if vt.tag != "ident"
      return Error(SyntaxError(line: vt.line, reason: "expected variable name after 'let'/'var'"))
    end
    p2 = p_adv(p_adv(p0))
    if p_tok(p2, 0).tag != "="
      return Error(SyntaxError(line: p_tok(p2, 0).line, reason: "expected '=' after '#{vt.sval}'"))
    end
    (p3, e) = try parse_expr(p_adv(p2))
    Ok((p3, SAssign(name: vt.sval, expr: e)))
  else if tk.tag == "ident" and p_tok(p0, 1).tag == "="
    (p3, e) = try parse_expr(p_adv(p_adv(p0)))
    Ok((p3, SAssign(name: tk.sval, expr: e)))
  else
    (p1, e) = try parse_expr(p0)
    Ok((p1, SExpr(expr: e)))
  end
end

fn parse_script(src: Text) : Result(List(RlmStmt), RlmVmError)
  if src.trim.empty?
    return Error(SyntaxError(line: 1, reason: "RLM VM script must not be empty"))
  end
  toks = try tokenize(src)
  var p = Parser(toks: toks, pos: 0)
  var stmts = []
  while true
    p = p_skip_sep(p)
    if p_tok(p, 0).tag == "eof"
      break
    end
    (p1, st) = try parse_stmt(p)
    stmts = stmts.append(st)
    p = p1
  end
  if stmts.empty?
    return Error(SyntaxError(line: 1, reason: "script contains no statements"))
  end
  Ok(stmts)
end

## Static capability allowlist validation (fail-closed before any execution).
fn allowed_call?(t: Text) : Bool
  [
    "ws.summaries",
    "ws.blocks",
    "ws.db_rows",
    "ws.search",
    "llm.ask",
    "rlm.sub",
    "len",
    "take",
    "slice",
    "join",
    "split",
    "lines",
    "trim",
    "lower",
    "upper",
    "contains",
    "append",
    "concat",
    "filter_contains",
    "map_field",
    "dedup_text",
    "str",
    "get",
    "has",
    "keys",
    "min",
    "max",
    "not_empty",
    "empty"
  ].contains?(t)
end

fn allowed_method?(m: Text) : Bool
  [
    "size",
    "len",
    "take",
    "slice",
    "join",
    "split",
    "lines",
    "trim",
    "ascii_lowercase",
    "lower",
    "upper",
    "contains?",
    "contains",
    "append",
    "concat",
    "filter_contains",
    "map_field",
    "dedup_text",
    "get",
    "has?",
    "keys",
    "first",
    "empty?"
  ].contains?(m)
end

fn validate_expr(e: RlmExpr) : Result(Unit, RlmVmError)
  case e
    ELit(_) | EVar(_): Ok(Unit)
    EList(xs):
      for x in xs
        try validate_expr(x)
      end
      Ok(Unit)
    ERecord(es):
      for (_k, ve) in es
        try validate_expr(ve)
      end
      Ok(Unit)
    EField(obj: o, field: _): validate_expr(o)
    EIndex(obj: o, idx: i):
      try validate_expr(o)
      validate_expr(i)
    EMethod(obj: o, method: m, args: args):
      try validate_expr(o)
      if not allowed_method?(m)
        return Error(DisallowedCapability(name: ".#{m}"))
      end
      for a in args
        try validate_expr(a)
      end
      Ok(Unit)
    ECall(target: t, args: args):
      if not allowed_call?(t)
        return Error(DisallowedCapability(name: t))
      end
      for a in args
        try validate_expr(a)
      end
      Ok(Unit)
    EUnOp(op: _, expr: inner): validate_expr(inner)
    EBinOp(op: _, left: l, right: r):
      try validate_expr(l)
      validate_expr(r)
  end
end

fn validate_program(stmts: List(RlmStmt)) : Result(Unit, RlmVmError)
  for st in stmts
    case st
      SAssign(name: _, expr: e) | SReturn(expr: e) | SExpr(expr: e): try validate_expr(e)
      SIf(cond: c, then_body: tb, else_body: eb):
        try validate_expr(c)
        try validate_program(tb)
        try validate_program(eb)
      SFor(var_name: _, iter_expr: it, body: b):
        try validate_expr(it)
        try validate_program(b)
    end
  end
  Ok(Unit)
end

## Compact evaluator state with grouped RlmAccum telemetry.
struct RlmAccum
  views_ops: Int
  rows_scanned: Int
  subcalls: Int
  max_depth_seen: Int
  grant_calls_debited: Int
  block_slices: List(RlmBlockSlice)
  db_slices: List(RlmDbSlice)
  trace: List(RlmTraceStep)
  child_sessions: List(Text)
  untrusted_tainted: Bool
  max_sensitivity_read: Text
  untrusted_sources: List(Text)
end

struct EvalCtx
  env: Map(Text, RlmVal)
  ops: Int
  acc: RlmAccum
  returned: Option(RlmVal)
  limits: RlmVmLimits
  depth: Int
end

fn ctx_step(ctx: EvalCtx) : Result(EvalCtx, RlmVmError)
  next_ops = ctx.ops + 1
  if next_ops > ctx.limits.max_ops
    return Error(BudgetExceeded(ops: next_ops, max_ops: ctx.limits.max_ops))
  end
  Ok(
    EvalCtx(
      env: ctx.env,
      ops: next_ops,
      acc: ctx.acc,
      returned: ctx.returned,
      limits: ctx.limits,
      depth: ctx.depth
    )
  )
end

fn ctx_with_env(ctx: EvalCtx, env: Map(Text, RlmVal)) : EvalCtx
  EvalCtx(
    env: env,
    ops: ctx.ops,
    acc: ctx.acc,
    returned: ctx.returned,
    limits: ctx.limits,
    depth: ctx.depth
  )
end

fn dedup_append_list(base: List(Text), extra: List(Text)) : List(Text)
  var seen = Set.empty
  var out = []
  for s in base.concat(extra)
    if not s.empty? and not seen.has?(s)
      seen = seen.add(s)
      out = out.append(s)
    end
  end
  out
end

fn dedup_append_blocks(base: List(RlmBlockSlice), extra: List(RlmBlockSlice)) : List(RlmBlockSlice)
  var seen = Set.empty
  var out = []
  for s in base.concat(extra)
    k = "#{s.page_id}:#{s.block_id}"
    if not seen.has?(k)
      seen = seen.add(k)
      out = out.append(s)
    end
  end
  out
end

fn dedup_append_dbs(base: List(RlmDbSlice), extra: List(RlmDbSlice)) : List(RlmDbSlice)
  var seen = Set.empty
  var out = []
  for d in base.concat(extra)
    k = "#{d.database_id}:#{d.row_id}"
    if not seen.has?(k)
      seen = seen.add(k)
      out = out.append(d)
    end
  end
  out
end

fn ctx_apply_delta(ctx: EvalCtx, d: RlmHostDelta, min_sc: Int, min_depth: Int) : EvalCtx
  a = ctx.acc
  sc_delta = if d.subcalls_delta > min_sc: d.subcalls_delta else: min_sc
  d_cand = if d.depth_reached > min_depth: d.depth_reached else: min_depth
  next_depth = if d_cand > a.max_depth_seen: d_cand else: a.max_depth_seen
  var next_trace = a.trace
  for st in d.trace
    next_trace = next_trace.append(
      RlmTraceStep(
        step: next_trace.size + 1,
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
  next_acc = RlmAccum(
    views_ops: a.views_ops + d.views_ops,
    rows_scanned: a.rows_scanned + d.rows_scanned,
    subcalls: a.subcalls + sc_delta,
    max_depth_seen: next_depth,
    grant_calls_debited: a.grant_calls_debited + d.grant_calls_debited,
    block_slices: dedup_append_blocks(a.block_slices, d.block_slices),
    db_slices: dedup_append_dbs(a.db_slices, d.db_slices),
    trace: next_trace,
    child_sessions: dedup_append_list(a.child_sessions, d.child_sessions),
    untrusted_tainted: a.untrusted_tainted or d.untrusted_tainted,
    max_sensitivity_read: max_sensitivity_label(a.max_sensitivity_read, d.max_sensitivity_read),
    untrusted_sources: dedup_append_list(a.untrusted_sources, d.untrusted_sources)
  )
  EvalCtx(
    env: ctx.env,
    ops: ctx.ops,
    acc: next_acc,
    returned: ctx.returned,
    limits: ctx.limits,
    depth: ctx.depth
  )
end

fn eval_field(obj: RlmVal, field: Text) : Result(RlmVal, RlmVmError)
  case obj
    VRecord(m): Ok(m.get(field) or VNull)
    VList(xs):
      if field == "size" or field == "len"
        Ok(VInt(xs.size))
      else if field == "empty?"
        Ok(VBool(xs.empty?))
      else if field == "first"
        Ok(xs.first or VNull)
      else
        Ok(VNull)
      end
    VText(t):
      if field == "size" or field == "len"
        Ok(VInt(t.byte_count))
      else if field == "empty?"
        Ok(VBool(t.empty?))
      else if field == "trim"
        Ok(VText(t.trim))
      else if field == "ascii_lowercase" or field == "lower"
        Ok(VText(t.ascii_lowercase))
      else if field == "upper"
        Ok(VText(t.ascii_uppercase))
      else
        Ok(VNull)
      end
    VNull | VBool(_) | VInt(_): Ok(VNull)
  end
end

fn as_int_arg(v: RlmVal, def_v: Int) : Int
  case v
    VInt(k): if k < 0: 0 else: k
    VNull | VBool(_) | VText(_) | VList(_) | VRecord(_): def_v
  end
end

fn as_list_items(v: RlmVal) : List(RlmVal)
  case v
    VList(l): l
    VNull | VBool(_) | VInt(_) | VText(_) | VRecord(_): []
  end
end

fn call_pure(name: Text, args: List(RlmVal), max_str: Int) : Result(RlmVal, RlmVmError)
  a0 = args.get(0) or VNull
  a1 = args.get(1) or VNull
  a2 = args.get(2) or VNull

  if name == "len" or name == "size"
    case a0
      VList(xs): Ok(VInt(xs.size))
      VText(t): Ok(VInt(t.byte_count))
      VRecord(m): Ok(VInt(m.entries.size))
      VNull | VBool(_) | VInt(_): Ok(VInt(0))
    end
  else if name == "empty" or name == "empty?"
    Ok(VBool(not truthy?(a0)))
  else if name == "not_empty"
    Ok(VBool(truthy?(a0)))
  else if name == "first"
    case a0
      VList(xs): Ok(xs.first or VNull)
      VNull | VBool(_) | VInt(_) | VText(_) | VRecord(_): Ok(VNull)
    end
  else if name == "str"
    Ok(VText(clip_text(rlm_val_to_text(a0), max_str)))
  else if name == "trim"
    Ok(VText(rlm_val_to_text(a0).trim))
  else if name == "lower" or name == "ascii_lowercase"
    Ok(VText(rlm_val_to_text(a0).ascii_lowercase))
  else if name == "upper"
    Ok(VText(rlm_val_to_text(a0).ascii_uppercase))
  else if name == "lines"
    Ok(VList(rlm_val_to_text(a0).split("\n").map(fn(s) VText(s) end)))
  else if name == "split"
    Ok(VList(rlm_val_to_text(a0).split(rlm_val_to_text(a1)).map(fn(s) VText(s) end)))
  else if name == "join"
    sep = if args.size >= 2: rlm_val_to_text(a1) else: "\n"
    case a0
      VList(xs): Ok(VText(clip_text(xs.map(fn(x) rlm_val_to_text(x) end).join(sep), max_str)))
      VNull | VBool(_) | VInt(_) | VText(_) | VRecord(_):
        Ok(VText(clip_text(rlm_val_to_text(a0), max_str)))
    end
  else if name == "take"
    n = as_int_arg(a1, 0)
    case a0
      VList(xs): Ok(VList(xs.take(n)))
      VText(t): Ok(VText(clip_text(t, n)))
      VNull | VBool(_) | VInt(_) | VRecord(_): Ok(VList([]))
    end
  else if name == "slice"
    si = as_int_arg(a1, 0)
    ci = as_int_arg(a2, 50)
    case a0
      VList(xs): Ok(VList(xs.drop(si).take(ci)))
      VText(t): Ok(VText(t.bytes.slice(si, si + ci).decode_utf8 or ""))
      VNull | VBool(_) | VInt(_) | VRecord(_): Ok(VList([]))
    end
  else if name == "append"
    case a0
      VList(xs): Ok(VList(xs.append(a1)))
      VNull | VBool(_) | VInt(_) | VText(_) | VRecord(_): Ok(VList([a1]))
    end
  else if name == "concat"
    Ok(VList(as_list_items(a0).concat(as_list_items(a1))))
  else if name == "contains" or name == "contains?"
    needle = rlm_val_to_text(a1).ascii_lowercase
    case a0
      VText(t): Ok(VBool(not needle.empty? and t.ascii_lowercase.contains?(needle)))
      VList(xs): Ok(VBool(xs.any?(fn(x) val_eq?(x, a1) end)))
      VNull | VBool(_) | VInt(_) | VRecord(_): Ok(VBool(false))
    end
  else if name == "get"
    case a0
      VRecord(m): Ok(m.get(rlm_val_to_text(a1)) or VNull)
      VList(xs):
        case a1
          VInt(idx): Ok(xs.get(idx) or VNull)
          VNull | VBool(_) | VText(_) | VList(_) | VRecord(_): Ok(VNull)
        end
      VNull | VBool(_) | VInt(_) | VText(_): Ok(VNull)
    end
  else if name == "has" or name == "has?"
    case a0
      VRecord(m): Ok(VBool(m.get(rlm_val_to_text(a1)) != None))
      VNull | VBool(_) | VInt(_) | VText(_) | VList(_): Ok(VBool(false))
    end
  else if name == "keys"
    case a0
      VRecord(m): Ok(VList(m.entries.map(fn(p) VText(p.0) end)))
      VNull | VBool(_) | VInt(_) | VText(_) | VList(_): Ok(VList([]))
    end
  else if name == "map_field"
    field = rlm_val_to_text(a1)
    var out = []
    for x in as_list_items(a0)
      v = try eval_field(x, field)
      if not (v is VNull)
        out = out.append(v)
      end
    end
    Ok(VList(out))
  else if name == "filter_contains"
    field = rlm_val_to_text(a1)
    needle = rlm_val_to_text(a2).trim.ascii_lowercase
    xs = as_list_items(a0)
    if needle.empty?
      Ok(VList(xs))
    else
      var out = []
      for x in xs
        fv = try eval_field(x, field)
        if rlm_val_to_text(fv).ascii_lowercase.contains?(needle)
          out = out.append(x)
        end
      end
      Ok(VList(out))
    end
  else if name == "dedup_text"
    var seen = Set.empty
    var out = []
    for x in as_list_items(a0)
      s = rlm_val_to_text(x).trim
      if not s.empty? and not seen.has?(s)
        seen = seen.add(s)
        out = out.append(VText(s))
      end
    end
    Ok(VList(out))
  else if name == "min" or name == "max"
    case (a0, a1)
      (VInt(x), VInt(y)):
        res = if name == "min"
          if x < y: x else: y
        else
          if x > y: x else: y
        end
        Ok(VInt(res))
      _: Error(TypeMismatch(reason: "#{name} expects 2 integer arguments"))
    end
  else
    Error(DisallowedCapability(name: name))
  end
end

fn cmp_ints(op: RlmBinOp, x: Int, y: Int) : Bool
  case op
    BLt: x < y
    BLe: x <= y
    BGt: x > y
    BGe: x >= y
    BAdd | BSub | BMul | BDiv | BEq | BNe | BAnd | BOr: false
  end
end

fn cmp_texts(op: RlmBinOp, x: Text, y: Text) : Bool
  case op
    BLt: x < y
    BLe: x <= y
    BGt: x > y
    BGe: x >= y
    BAdd | BSub | BMul | BDiv | BEq | BNe | BAnd | BOr: false
  end
end

fn eval_binop(op: RlmBinOp, lv: RlmVal, rv: RlmVal, max_str: Int) : Result(RlmVal, RlmVmError)
  case op
    BEq: Ok(VBool(val_eq?(lv, rv)))
    BNe: Ok(VBool(not val_eq?(lv, rv)))
    BAnd: Ok(VBool(truthy?(lv) and truthy?(rv)))
    BOr: Ok(VBool(truthy?(lv) or truthy?(rv)))
    BAdd:
      case (lv, rv)
        (VInt(x), VInt(y)): Ok(VInt(x + y))
        (VList(xs), VList(ys)): Ok(VList(xs.concat(ys)))
        (VText(a), _): Ok(VText(clip_text("#{a}#{rlm_val_to_text(rv)}", max_str)))
        (_, VText(b)): Ok(VText(clip_text("#{rlm_val_to_text(lv)}#{b}", max_str)))
        _: Error(TypeMismatch(reason: "cannot apply '+' to given operands"))
      end
    BSub | BMul | BDiv:
      case (op, lv, rv)
        (BSub, VInt(x), VInt(y)): Ok(VInt(x - y))
        (BMul, VInt(x), VInt(y)): Ok(VInt(x * y))
        (BDiv, VInt(_), VInt(0)): Error(TypeMismatch(reason: "division by zero in RLM VM"))
        (BDiv, VInt(x), VInt(y)): Ok(VInt(x / y))
        _: Error(TypeMismatch(reason: "arithmetic operator requires integer operands"))
      end
    BLt | BLe | BGt | BGe:
      case (lv, rv)
        (VInt(x), VInt(y)): Ok(VBool(cmp_ints(op, x, y)))
        (VText(x), VText(y)): Ok(VBool(cmp_texts(op, x, y)))
        _: Error(TypeMismatch(reason: "comparison requires matching int or string operands"))
      end
  end
end

fn eval_call_target(
  ctx0: EvalCtx,
  target: Text,
  args: List(RlmVal),
  files: Files,
  env: Env,
  net: Network,
  host: RlmHostFns
) : Result((EvalCtx, RlmVal), RlmVmError)
  a0 = args.get(0) or VNull
  a1 = args.get(1) or VNull
  a2 = args.get(2) or VNull

  if target == "ws.summaries"
    fn_call = host.on_summaries
    d = try fn_call(files, a0)
    Ok((ctx_apply_delta(ctx0, d, 0, 0), d.value))
  else if target == "ws.blocks"
    fn_call = host.on_blocks
    d = try fn_call(files, a0, a1, a2)
    Ok((ctx_apply_delta(ctx0, d, 0, 0), d.value))
  else if target == "ws.db_rows"
    fn_call = host.on_db_rows
    d = try fn_call(files, a0)
    Ok((ctx_apply_delta(ctx0, d, 0, 0), d.value))
  else if target == "ws.search"
    fn_call = host.on_search
    d = try fn_call(files, env, net, a0, a1)
    Ok((ctx_apply_delta(ctx0, d, 0, 0), d.value))
  else if target == "llm.ask"
    if ctx0.acc.subcalls >= ctx0.limits.max_subcalls
      return Error(
        SubcallLimitExceeded(used: ctx0.acc.subcalls, max_subcalls: ctx0.limits.max_subcalls)
      )
    end
    fn_call = host.on_llm_ask
    d = try fn_call(files, net, a0, a1)
    Ok((ctx_apply_delta(ctx0, d, 1, 0), d.value))
  else if target == "rlm.sub"
    next_depth = ctx0.depth + 1
    if next_depth > ctx0.limits.max_depth
      return Error(DepthLimitExceeded(depth: next_depth, max_depth: ctx0.limits.max_depth))
    end
    if ctx0.acc.subcalls >= ctx0.limits.max_subcalls
      return Error(
        SubcallLimitExceeded(used: ctx0.acc.subcalls, max_subcalls: ctx0.limits.max_subcalls)
      )
    end
    rem_sub = ctx0.limits.max_subcalls - ctx0.acc.subcalls
    fn_call = host.on_rlm_sub
    d = try fn_call(files, env, net, a0, a1, next_depth, rem_sub)
    Ok((ctx_apply_delta(ctx0, d, 1, next_depth), d.value))
  else
    v = try call_pure(target, args, ctx0.limits.max_string_len)
    Ok((ctx0, v))
  end
end

fn eval_expr_list(
  ctx0: EvalCtx,
  exprs: List(RlmExpr),
  files: Files,
  env: Env,
  net: Network,
  host: RlmHostFns
) : Result((EvalCtx, List(RlmVal)), RlmVmError)
  var ctx = ctx0
  var vals = []
  for ex in exprs
    (ctx1, v) = try eval_expr(ctx, ex, files, env, net, host)
    ctx = ctx1
    vals = vals.append(v)
  end
  Ok((ctx, vals))
end

fn eval_expr(
  ctx0: EvalCtx,
  e: RlmExpr,
  files: Files,
  env: Env,
  net: Network,
  host: RlmHostFns
) : Result((EvalCtx, RlmVal), RlmVmError)
  ctx = try ctx_step(ctx0)
  case e
    ELit(v): Ok((ctx, v))
    EVar(n):
      case ctx.env.get(n)
        Some(v): Ok((ctx, v))
        None: Error(UndefinedVar(name: n))
      end
    EList(xs):
      (ctx1, vals) = try eval_expr_list(ctx, xs, files, env, net, host)
      Ok((ctx1, VList(vals)))
    ERecord(es):
      var cur = ctx
      var rec = {}
      for (k, val_e) in es
        (cur1, v) = try eval_expr(cur, val_e, files, env, net, host)
        cur = cur1
        rec = rec.set(k, v)
      end
      Ok((cur, VRecord(rec)))
    EField(obj: o, field: f):
      (ctx1, ov) = try eval_expr(ctx, o, files, env, net, host)
      Ok((ctx1, try eval_field(ov, f)))
    EIndex(obj: o, idx: idx_e):
      (ctx1, ov) = try eval_expr(ctx, o, files, env, net, host)
      (ctx2, iv) = try eval_expr(ctx1, idx_e, files, env, net, host)
      case (ov, iv)
        (VList(xs), VInt(i)): Ok((ctx2, xs.get(i) or VNull))
        (VRecord(m), VText(k)): Ok((ctx2, m.get(k) or VNull))
        _: Error(TypeMismatch(reason: "invalid indexing target or index type in RLM VM"))
      end
    EMethod(obj: o, method: m, args: arg_exprs):
      (ctx1, ov) = try eval_expr(ctx, o, files, env, net, host)
      (ctx2, arg_vals) = try eval_expr_list(ctx1, arg_exprs, files, env, net, host)
      v = try call_pure(m, [ov].concat(arg_vals), ctx2.limits.max_string_len)
      Ok((ctx2, v))
    ECall(target: t, args: arg_exprs):
      (ctx1, arg_vals) = try eval_expr_list(ctx, arg_exprs, files, env, net, host)
      eval_call_target(ctx1, t, arg_vals, files, env, net, host)
    EUnOp(op: uo, expr: inner):
      (ctx1, iv) = try eval_expr(ctx, inner, files, env, net, host)
      case uo
        UNot: Ok((ctx1, VBool(not truthy?(iv))))
        UNeg:
          case iv
            VInt(n): Ok((ctx1, VInt(-n)))
            VNull | VBool(_) | VText(_) | VList(_) | VRecord(_):
              Error(TypeMismatch(reason: "unary '-' requires an integer operand"))
          end
      end
    EBinOp(op: BAnd, left: l, right: r):
      (ctx1, lv) = try eval_expr(ctx, l, files, env, net, host)
      if not truthy?(lv)
        Ok((ctx1, VBool(false)))
      else
        (ctx2, rv) = try eval_expr(ctx1, r, files, env, net, host)
        Ok((ctx2, VBool(truthy?(rv))))
      end
    EBinOp(op: BOr, left: l, right: r):
      (ctx1, lv) = try eval_expr(ctx, l, files, env, net, host)
      if truthy?(lv)
        Ok((ctx1, VBool(true)))
      else
        (ctx2, rv) = try eval_expr(ctx1, r, files, env, net, host)
        Ok((ctx2, VBool(truthy?(rv))))
      end
    EBinOp(op: bo, left: l, right: r):
      (ctx1, lv) = try eval_expr(ctx, l, files, env, net, host)
      (ctx2, rv) = try eval_expr(ctx1, r, files, env, net, host)
      Ok((ctx2, try eval_binop(bo, lv, rv, ctx2.limits.max_string_len)))
  end
end

fn eval_stmts(
  ctx0: EvalCtx,
  stmts: List(RlmStmt),
  files: Files,
  env: Env,
  net: Network,
  host: RlmHostFns
) : Result((EvalCtx, RlmVal), RlmVmError)
  var ctx = ctx0
  var last_val = VNull
  for st in stmts
    if ctx.returned != None
      return Ok((ctx, ctx.returned or VNull))
    end
    (ctx1, v) = try eval_stmt(ctx, st, files, env, net, host)
    ctx = ctx1
    last_val = v
  end
  Ok((ctx, last_val))
end

fn eval_stmt(
  ctx0: EvalCtx,
  st: RlmStmt,
  files: Files,
  env: Env,
  net: Network,
  host: RlmHostFns
) : Result((EvalCtx, RlmVal), RlmVmError)
  ctx = try ctx_step(ctx0)
  case st
    SAssign(name: n, expr: e):
      (ctx1, v) = try eval_expr(ctx, e, files, env, net, host)
      Ok((ctx_with_env(ctx1, ctx1.env.set(n, v)), v))
    SReturn(expr: e):
      (ctx1, v) = try eval_expr(ctx, e, files, env, net, host)
      next_ctx = EvalCtx(
        env: ctx1.env,
        ops: ctx1.ops,
        acc: ctx1.acc,
        returned: Some(v),
        limits: ctx1.limits,
        depth: ctx1.depth
      )
      Ok((next_ctx, v))
    SExpr(expr: e): eval_expr(ctx, e, files, env, net, host)
    SIf(cond: c, then_body: tb, else_body: eb):
      (ctx1, cv) = try eval_expr(ctx, c, files, env, net, host)
      if truthy?(cv)
        eval_stmts(ctx1, tb, files, env, net, host)
      else
        eval_stmts(ctx1, eb, files, env, net, host)
      end
    SFor(var_name: vn, iter_expr: it_e, body: b):
      (ctx1, iv) = try eval_expr(ctx, it_e, files, env, net, host)
      items = case iv
        VList(xs): xs
        VNull | VBool(_) | VInt(_) | VText(_) | VRecord(_):
          return Error(TypeMismatch(reason: "for-loop requires a list operand"))
      end
      if items.size > ctx1.limits.max_loop_iters
        return Error(LoopLimitExceeded(iters: items.size, max_iters: ctx1.limits.max_loop_iters))
      end
      var cur = ctx1
      var last = VNull
      for item in items
        if cur.returned != None
          return Ok((cur, cur.returned or VNull))
        end
        (next_ctx, v) = try eval_stmts(
          ctx_with_env(cur, cur.env.set(vn, item)),
          b,
          files,
          env,
          net,
          host
        )
        cur = next_ctx
        last = v
      end
      Ok((cur, last))
  end
end

fn eval_program(
  stmts: List(RlmStmt),
  initial_vars: Map(Text, RlmVal),
  limits: RlmVmLimits,
  depth: Int,
  files: Files,
  env: Env,
  net: Network,
  host: RlmHostFns
) : Result(RlmEvalOutcome, RlmVmError)
  if depth > limits.max_depth
    return Error(DepthLimitExceeded(depth: depth, max_depth: limits.max_depth))
  end
  try validate_program(stmts)
  acc0 = RlmAccum(
    views_ops: 0,
    rows_scanned: 0,
    subcalls: 0,
    max_depth_seen: depth,
    grant_calls_debited: 0,
    block_slices: [],
    db_slices: [],
    trace: [],
    child_sessions: [],
    untrusted_tainted: false,
    max_sensitivity_read: "public",
    untrusted_sources: []
  )
  ctx0 = EvalCtx(
    env: initial_vars,
    ops: 0,
    acc: acc0,
    returned: None,
    limits: limits,
    depth: depth
  )
  (fc, last_v) = try eval_stmts(ctx0, stmts, files, env, net, host)
  a = fc.acc
  Ok(
    RlmEvalOutcome(
      value: fc.returned or last_v,
      vm_ops: fc.ops,
      views_ops: a.views_ops,
      rows_scanned: a.rows_scanned,
      subcalls_used: a.subcalls,
      max_depth_reached: a.max_depth_seen,
      grant_calls_debited: a.grant_calls_debited,
      block_slices: a.block_slices,
      db_slices: a.db_slices,
      trace: a.trace,
      child_sessions: a.child_sessions,
      untrusted_tainted: a.untrusted_tainted,
      max_sensitivity_read: a.max_sensitivity_read,
      untrusted_sources: a.untrusted_sources
    )
  )
end

fn quote_vm_str(s: Text) : Text
  var out = ['"']
  for c in s.chars
    if c == '"' or c == '\\'
      out = out.append('\\').append(c)
    else if c == '\n'
      out = out.append('\\').append('n')
    else if c != '\r'
      out = out.append(c)
    end
  end
  Text.from_chars(out.append('"'))
end

## Generates a canonical Tier 2 Mo Micro-REPL script parameterized by filters & depth budgets.
fn default_tier2_script(
  question: Text,
  collection_id_opt: Option(Text),
  heading_contains_opt: Option(Text),
  allowed_kinds: List(Text),
  include_dbs?: Bool,
  max_pages: Int,
  max_blocks_per_page: Int,
  max_subcalls: Int,
  depth: Int,
  max_depth: Int
) : Text
  q_lit = quote_vm_str(question)
  col_lit = case collection_id_opt
    Some(c) if not c.trim.empty?: quote_vm_str(c.trim)
    Some(_) | None: "null"
  end
  hd_lit = case heading_contains_opt
    Some(h) if not h.trim.empty?: quote_vm_str(h.trim)
    Some(_) | None: "null"
  end
  kinds_lit = "[#{allowed_kinds.map(fn(k) quote_vm_str(k) end).join(", ")}]"
  inc_dbs_lit = if include_dbs?: "true" else: "false"
  lines = [
    "# Vellum Tier 2 Mo Micro-REPL Research Program",
    "let summaries = ws.summaries(#{col_lit})",
    "let hits = ws.search(#{q_lit}, #{col_lit})",
    "var page_ids = dedup_text(concat(map_field(hits, \"page_id\"), map_field(filter_contains(summaries, \"summary_text\", #{q_lit}), \"entity_id\")))",
    "if len(page_ids) == 0",
    "  page_ids = dedup_text(map_field(summaries, \"entity_id\"))",
    "end",
    "let selected_pages = take(page_ids, #{max_pages})",
    "let blocks = ws.blocks(selected_pages, #{kinds_lit}, #{hd_lit})",
    "var dbs = []",
    "if #{inc_dbs_lit}",
    "  dbs = ws.db_rows(take(dedup_text(map_field(filter_contains(summaries, \"entity_kind\", \"database\"), \"entity_id\")), 4))",
    "end",
    "var sub_notes = []",
    "if #{depth} < #{max_depth} and #{max_subcalls} > 1 and len(blocks) > 2",
    "  let mid = len(blocks) / 2",
    "  let note = llm.ask(\"Extract exact facts & [Title §block_id] citations for: \" + #{q_lit}, join(map_field(take(blocks, mid), \"excerpt\"), \"\\n\"))",
    "  sub_notes = append(sub_notes, note)",
    "end",
    "let ctx = join(concat(sub_notes, concat(map_field(take(blocks, #{max_pages * max_blocks_per_page}), \"excerpt\"), map_field(dbs, \"excerpt\"))), \"\\n\")",
    "let answer = llm.ask(\"Synthesize concise cited answer ([PageTitle §block_id], [DB: Title #row_id]) for: \" + #{q_lit}, ctx)",
    "return answer"
  ]
  lines.join("\n")
end
