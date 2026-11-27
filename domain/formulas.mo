## Deterministic, pure, zero-I/O Notion-subset formula lexer, parser, and evaluator.
## Supports block/line comments, multi-pass property resolution, relation chaining
## (`prop("Subtasks").filter(current.prop("Status") == "Done").length()`),
## exact Decimal math (`round`, `floor`, `ceil`, `abs`, `min`, `max`), `if`/`ifs`, `format`, `repeat`, and `formatDate`.
module Domain.Formulas
expose FormulaRelatedRow(..),
validate_formula,
evaluate_formula,
evaluate_row_formulas
use Date
use Domain.DatabaseModel{
  AiOutputKind,
  CellValue,
  DatabaseDef,
  DbRow,
  PropertyDef,
  PropertyKind,
  SelectOption
}

## Related row together with its owning `DatabaseDef` schema for `current.prop(...)` lookups.
struct FormulaRelatedRow
  def: DatabaseDef
  row: DbRow
end

struct FTok
  tag: Text
  sval: Text
  line: Int
end

enum FExpr
  FEmptyLit
  FBoolLit(Bool)
  FNumLit(Decimal)
  FTextLit(Text)
  FCurrent
  FCall(name: Text, args: List(FExpr))
  FMethod(obj: FExpr, name: Text, args: List(FExpr))
  FUn(op: Text, expr: FExpr)
  FBin(op: Text, left: FExpr, right: FExpr)
end

enum FVal
  FEmpty
  FBool(Bool)
  FNum(Decimal)
  FText(Text)
  FDate(Date.Date)
  FList(List(FVal))
  FRow(FormulaRelatedRow)
end

struct FParser
  toks: List(FTok)
  pos: Int
end

fn lex_string(chars: List(Char), i0: Int, quote: Char, line0: Int) : Result((Text, Int, Int), Text)
  var i = i0
  var cur_line = line0
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
        return Error("unterminated escape sequence in formula string literal")
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
  Error("unterminated string literal at line #{line0}")
end

fn tokenize_formula(src: Text) : Result(List(FTok), Text)
  chars = src.chars
  var i = 0
  var line = 1
  var toks = []
  while i < chars.size
    if toks.size > 2000
      return Error("formula exceeds maximum token limit (2000)")
    end
    c = chars.get(i) or ' '
    nc = chars.get(i + 1) or '\u{0000}'
    if c == ' ' or c == '\t' or c == '\r'
      i += 1
    else if c == '\n'
      line += 1
      i += 1
    else if c == '/' and nc == '*'
      i += 2
      var closed = false
      while i < chars.size
        ch = chars.get(i) or ' '
        nch = chars.get(i + 1) or '\u{0000}'
        if ch == '*' and nch == '/'
          i += 2
          closed = true
          break
        end
        if ch == '\n'
          line += 1
        end
        i += 1
      end
      if not closed
        return Error("unterminated /* comment */ in formula")
      end
    else if c == '/' and nc == '/'
      i += 2
      while i < chars.size and (chars.get(i) or ' ') != '\n'
        i += 1
      end
    else if c == '"' or c == '\''
      (s, ni, nl) = try lex_string(chars, i + 1, c, line)
      toks = toks.append(FTok(tag: "str", sval: s, line: line))
      i = ni
      line = nl
    else if c.ascii_digit?
      var buf = []
      while i < chars.size and (chars.get(i) or ' ').ascii_digit?
        buf = buf.append(chars.get(i) or '0')
        i += 1
      end
      dot_ch = chars.get(i) or '\u{0000}'
      after_dot = chars.get(i + 1) or '\u{0000}'
      if dot_ch == '.' and after_dot.ascii_digit?
        buf = buf.append('.')
        i += 1
        while i < chars.size and (chars.get(i) or ' ').ascii_digit?
          buf = buf.append(chars.get(i) or '0')
          i += 1
        end
      end
      raw_num = Text.from_chars(buf)
      if raw_num.to_decimal == None
        return Error("invalid numeric literal '#{raw_num}' at line #{line}")
      end
      toks = toks.append(FTok(tag: "num", sval: raw_num, line: line))
    else if c.ascii_letter? or c == '_'
      var buf = []
      while i < chars.size
        ch = chars.get(i) or ' '
        if not (ch.ascii_letter? or ch.ascii_digit? or ch == '_')
          break
        end
        buf = buf.append(ch)
        i += 1
      end
      ident = Text.from_chars(buf)
      toks = toks.append(FTok(tag: "ident", sval: ident, line: line))
    else
      two = Text.from_chars([c, nc])
      one = Text.from_chars([c])
      if two == "==" or two == "!=" or two == "<=" or two == ">=" or two == "&&" or two == "||"
        toks = toks.append(FTok(tag: two, sval: two, line: line))
        i += 2
      else if "().,+-*/<>!".contains?(one)
        toks = toks.append(FTok(tag: one, sval: one, line: line))
        i += 1
      else
        return Error("unexpected character '#{c}' in formula at line #{line}")
      end
    end
  end
  Ok(toks.append(FTok(tag: "eof", sval: "", line: line)))
end

fn f_peek(p: FParser) : FTok
  p.toks.get(p.pos) or FTok(tag: "eof", sval: "", line: 1)
end

fn f_adv(p: FParser) : FParser
  FParser(toks: p.toks, pos: p.pos + 1)
end

fn parse_arg_list(p0: FParser, depth: Int) : Result((List(FExpr), FParser), Text)
  var p = p0
  var args = []
  if f_peek(p).tag == ")"
    return Ok((args, f_adv(p)))
  end
  while true
    (arg, np) = try parse_or(p, depth + 1)
    args = args.append(arg)
    p = np
    t = f_peek(p)
    if t.tag == ","
      p = f_adv(p)
    else if t.tag == ")"
      return Ok((args, f_adv(p)))
    else
      return Error("expected ',' or ')' in argument list at line #{t.line}")
    end
  end
  Ok((args, p))
end

fn parse_primary(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  return Error("formula nesting depth exceeded (max 64)") if depth > 64
  t = f_peek(p0)
  if t.tag == "num"
    d = try t.sval.to_decimal.or_fail("invalid decimal '#{t.sval}'")
    Ok((FNumLit(d), f_adv(p0)))
  else if t.tag == "str"
    Ok((FTextLit(t.sval), f_adv(p0)))
  else if t.tag == "("
    (inner, p1) = try parse_or(f_adv(p0), depth + 1)
    if f_peek(p1).tag != ")"
      return Error("expected closing ')' in formula at line #{f_peek(p1).line}")
    end
    Ok((inner, f_adv(p1)))
  else if t.tag == "ident"
    p1 = f_adv(p0)
    if t.sval == "true"
      Ok((FBoolLit(true), p1))
    else if t.sval == "false"
      Ok((FBoolLit(false), p1))
    else if t.sval == "null" or t.sval == "Empty"
      Ok((FEmptyLit, p1))
    else if t.sval == "current" and f_peek(p1).tag != "("
      Ok((FCurrent, p1))
    else if f_peek(p1).tag == "("
      (args, p2) = try parse_arg_list(f_adv(p1), depth + 1)
      Ok((FCall(name: t.sval, args: args), p2))
    else
      Error("unexpected identifier '#{t.sval}' at line #{t.line} (use prop(\"...\") for properties)")
    end
  else
    Error("unexpected token '#{t.tag}' in formula at line #{t.line}")
  end
end

fn parse_postfix(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  return Error("formula nesting depth exceeded (max 64)") if depth > 64
  (cur_e, cur_p) = try parse_primary(p0, depth + 1)
  var expr = cur_e
  var p = cur_p
  while f_peek(p).tag == "."
    p1 = f_adv(p)
    mt = f_peek(p1)
    if mt.tag != "ident"
      return Error("expected method name after '.' at line #{mt.line}")
    end
    p2 = f_adv(p1)
    if f_peek(p2).tag != "("
      return Error("expected '(' after '.#{mt.sval}' at line #{f_peek(p2).line}")
    end
    (args, p3) = try parse_arg_list(f_adv(p2), depth + 1)
    expr = FMethod(obj: expr, name: mt.sval, args: args)
    p = p3
  end
  Ok((expr, p))
end

fn parse_unary_math(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  return Error("formula nesting depth exceeded (max 64)") if depth > 64
  t = f_peek(p0)
  if t.tag == "-"
    (rhs, np) = try parse_unary_math(f_adv(p0), depth + 1)
    Ok((FUn(op: "-", expr: rhs), np))
  else if t.tag == "+"
    parse_unary_math(f_adv(p0), depth + 1)
  else if t.tag == "!" or (t.tag == "ident" and t.sval == "not")
    (rhs, np) = try parse_unary_math(f_adv(p0), depth + 1)
    Ok((FUn(op: "not", expr: rhs), np))
  else
    parse_postfix(p0, depth + 1)
  end
end

fn parse_mul(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  (l, p1) = try parse_unary_math(p0, depth + 1)
  var lhs = l
  var p = p1
  while f_peek(p).tag == "*" or f_peek(p).tag == "/"
    op = f_peek(p).tag
    (rhs, np) = try parse_unary_math(f_adv(p), depth + 1)
    lhs = FBin(op: op, left: lhs, right: rhs)
    p = np
  end
  Ok((lhs, p))
end

fn parse_add(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  (l, p1) = try parse_mul(p0, depth + 1)
  var lhs = l
  var p = p1
  while f_peek(p).tag == "+" or f_peek(p).tag == "-"
    op = f_peek(p).tag
    (rhs, np) = try parse_mul(f_adv(p), depth + 1)
    lhs = FBin(op: op, left: lhs, right: rhs)
    p = np
  end
  Ok((lhs, p))
end

fn parse_cmp(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  (l, p1) = try parse_add(p0, depth + 1)
  var lhs = l
  var p = p1
  while true
    tg = f_peek(p).tag
    if tg == "==" or tg == "!=" or tg == "<" or tg == "<=" or tg == ">" or tg == ">="
      (rhs, np) = try parse_add(f_adv(p), depth + 1)
      lhs = FBin(op: tg, left: lhs, right: rhs)
      p = np
    else
      break
    end
  end
  Ok((lhs, p))
end

fn parse_not(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  return Error("formula nesting depth exceeded (max 64)") if depth > 64
  t = f_peek(p0)
  if t.tag == "!" or (t.tag == "ident" and t.sval == "not")
    (rhs, np) = try parse_not(f_adv(p0), depth + 1)
    Ok((FUn(op: "not", expr: rhs), np))
  else
    parse_cmp(p0, depth + 1)
  end
end

fn parse_and(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  (l, p1) = try parse_not(p0, depth + 1)
  var lhs = l
  var p = p1
  while true
    t = f_peek(p)
    if t.tag == "&&" or (t.tag == "ident" and t.sval == "and")
      (rhs, np) = try parse_not(f_adv(p), depth + 1)
      lhs = FBin(op: "and", left: lhs, right: rhs)
      p = np
    else
      break
    end
  end
  Ok((lhs, p))
end

fn parse_or(p0: FParser, depth: Int) : Result((FExpr, FParser), Text)
  (l, p1) = try parse_and(p0, depth + 1)
  var lhs = l
  var p = p1
  while true
    t = f_peek(p)
    if t.tag == "||" or (t.tag == "ident" and t.sval == "or")
      (rhs, np) = try parse_and(f_adv(p), depth + 1)
      lhs = FBin(op: "or", left: lhs, right: rhs)
      p = np
    else
      break
    end
  end
  Ok((lhs, p))
end

fn parse_formula_ast(expression: Text) : Result(FExpr, Text)
  return Error("formula expression must not be empty") if expression.trim.empty?
  toks = try tokenize_formula(expression)
  if (toks.get(0) or FTok(tag: "eof", sval: "", line: 1)).tag == "eof"
    return Error("formula expression contains no executable tokens")
  end
  (ast, p1) = try parse_or(FParser(toks: toks, pos: 0), 0)
  rem = f_peek(p1)
  if rem.tag != "eof"
    return Error("unexpected trailing token '#{rem.tag}' at line #{rem.line}")
  end
  Ok(ast)
end

## Validates syntax of a Notion formula expression (`None` when valid).
fn validate_formula(expression: Text) : Option(Text)
  case parse_formula_ast(expression)
    Ok(_): None
    Error(msg): Some(msg)
  end
end

fn format_decimal_clean(d: Decimal) : Text
  raw = d.to_text
  trimmed = if raw.contains?(".")
    cs = raw.chars
    var end_idx = cs.size
    while end_idx > 0
      ch = cs.get(end_idx - 1) or ' '
      if ch == '0'
        end_idx -= 1
      else
        break
      end
    end
    if end_idx > 0 and (cs.get(end_idx - 1) or ' ') == '.'
      end_idx -= 1
    end
    Text.from_chars(cs.take(end_idx))
  else
    raw
  end
  if trimmed == "-0" or trimmed.empty?: "0" else: trimmed
end

fn format_fval(v: FVal) : Text
  case v
    FEmpty: ""
    FBool(b): if b: "true" else: "false"
    FNum(d): format_decimal_clean(d)
    FText(s): s
    FDate(dt): dt.to_iso
    FList(xs): xs.map(format_fval).join(", ")
    FRow(rr): rr.row.id
  end
end

fn fval_empty?(v: FVal) : Bool
  case v
    FEmpty: true
    FBool(_): false
    FNum(_): false
    FText(s): s.empty?
    FDate(_): false
    FList(xs): xs.empty?
    FRow(_): false
  end
end

fn fval_truthy?(v: FVal) : Bool
  case v
    FEmpty: false
    FBool(b): b
    FNum(d): d != 0.0
    FText(s): not s.empty?
    FDate(_): true
    FList(xs): not xs.empty?
    FRow(_): true
  end
end

fn fval_eq?(a: FVal, b: FVal) : Bool
  case (a, b)
    (FEmpty, FEmpty): true
    (FBool(x), FBool(y)): x == y
    (FNum(x), FNum(y)): x == y
    (FText(x), FText(y)): x == y
    (FDate(x), FDate(y)): x == y
    (FList(xs), FList(ys)):
      xs.size == ys.size and xs.enumerate.all?(fn(pair) fval_eq?(pair.1, ys.get(pair.0) or FEmpty) end)
    (FRow(x), FRow(y)): x.row.id == y.row.id
    (_, _): false
  end
end

fn fval_cmp(a: FVal, b: FVal) : Result(Int, Text)
  case (a, b)
    (FNum(x), FNum(y)): Ok(if x < y: -1 else if x > y: 1 else: 0)
    (FDate(x), FDate(y)): Ok(if x < y: -1 else if x > y: 1 else: 0)
    (FText(x), FText(y)): Ok(if x < y: -1 else if x > y: 1 else: 0)
    (FEmpty, FNum(y)):
      z = 0.0
      Ok(if z < y: -1 else if z > y: 1 else: 0)
    (FNum(x), FEmpty):
      z = 0.0
      Ok(if x < z: -1 else if x > z: 1 else: 0)
    (_, _): Error("incompatible types in comparison operator")
  end
end

fn as_decimal(v: FVal, ctx: Text) : Result(Decimal, Text)
  case v
    FNum(d): Ok(d)
    FEmpty: Ok(0.0)
    FBool(b): Ok(if b: 1.0 else: 0.0)
    FText(s):
      case s.trim.to_decimal
        Some(d): Ok(d)
        None: Error("#{ctx}: expected number, got '#{s}'")
      end
    FDate(_) | FList(_) | FRow(_): Error("#{ctx}: expected number")
  end
end

fn resolve_option_label(opts: List(SelectOption), oid: Text) : Text
  for o in opts
    if o.id == oid
      return o.label
    end
  end
  oid
end

fn cell_to_fval(prop_opt: Option(PropertyDef), c: CellValue) : FVal
  case c
    Empty: FEmpty
    TextVal(s) | UrlVal(s): FText(s)
    NumberVal(d): FNum(d)
    BoolVal(b): FBool(b)
    DateVal(start: st, end_date: _): FDate(st)
    SelectVal(option_id: oid):
      lbl = case prop_opt
        Some(p):
          case p.kind
            Select(options: opts) | Status(options: opts, done_option_ids: _) | AiDerived(
              prompt: _,
              source_prop_ids: _,
              include_row_body: _,
              output_kind: AiSelect(options: opts),
              mode: _,
              daily_call_cap: _
            ): resolve_option_label(opts, oid)
            Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(
              options: _
            ) | Checkbox | Person | Email | FileList | Url | UniqueId(prefix: _) | Formula(
              expression: _,
              format: _
            ) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
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
        None: oid
      end
      FText(lbl)
    MultiSelectVal(option_ids: oids):
      lbls = case prop_opt
        Some(p):
          case p.kind
            MultiSelect(options: opts): oids.map(fn(oid) resolve_option_label(opts, oid) end)
            Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | Status(
              options: _,
              done_option_ids: _
            ) | Checkbox | Person | Email | FileList | Url | UniqueId(prefix: _) | Formula(
              expression: _,
              format: _
            ) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
              target_db_id: _,
              inverse_prop_id: _
            ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
              prompt: _,
              source_prop_ids: _,
              include_row_body: _,
              output_kind: _,
              mode: _,
              daily_call_cap: _
            ): oids
          end
        None: oids
      end
      FList(lbls.map(fn(s) FText(s) end))
    PrincipalVal(xs) | FilesVal(attachment_ids: xs) | RelationVal(row_ids: xs):
      FList(xs.map(fn(s) FText(s) end))
  end
end

fn find_prop_by_ref(def: DatabaseDef, name: Text) : Option(PropertyDef)
  for p in def.properties
    return Some(p) if p.name == name
  end
  low = name.trim.ascii_lowercase
  for p in def.properties
    return Some(p) if p.name.trim.ascii_lowercase == low
  end
  for p in def.properties
    return Some(p) if p.id == name
  end
  None
end

fn lookup_prop_val(
  name: Text,
  def: DatabaseDef,
  row: DbRow,
  computed: Map(Text, CellValue),
  related_rows: Map(Text, List(FormulaRelatedRow))
) : FVal
  case find_prop_by_ref(def, name)
    None: FEmpty
    Some(p):
      case p.kind
        Relation(target_db_id: _, inverse_prop_id: _):
          rels = related_rows.get(p.id) or []
          if not rels.empty?
            FList(rels.map(fn(rr) FRow(rr) end))
          else
            case row.cells.get(p.id)
              Some(RelationVal(row_ids: rids)):
                # Only wrap raw IDs if related_rows map didn't resolve them
                FList(
                  rids.map(fn(rid)
                    FRow(
                      FormulaRelatedRow(
                        def: def,
                        row: DbRow(
                          id: rid,
                          database_id: def.id,
                          page_id: "",
                          cells: {},
                          created_by: row.created_by,
                          created_at: row.created_at,
                          updated_at: row.updated_at,
                          archived_at: None,
                          version: 1
                        )
                      )
                    )
                  end)
                )
              Some(_) | None: FList([])
            end
          end
        Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
          options: _
        ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
          prefix: _
        ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Rollup(
          relation_prop_id: _,
          target_prop_id: _,
          agg: _
        ) | AiDerived(
          prompt: _,
          source_prop_ids: _,
          include_row_body: _,
          output_kind: _,
          mode: _,
          daily_call_cap: _
        ):
          c = computed.get(p.id) or (row.cells.get(p.id) or Empty)
          cell_to_fval(Some(p), c)
      end
  end
end

fn month_names_for_mm(mm: Text) : (Text, Text)
  if mm == "01"
    ("January", "Jan")
  else if mm == "02"
    ("February", "Feb")
  else if mm == "03"
    ("March", "Mar")
  else if mm == "04"
    ("April", "Apr")
  else if mm == "05"
    ("May", "May")
  else if mm == "06"
    ("June", "Jun")
  else if mm == "07"
    ("July", "Jul")
  else if mm == "08"
    ("August", "Aug")
  else if mm == "09"
    ("September", "Sep")
  else if mm == "10"
    ("October", "Oct")
  else if mm == "11"
    ("November", "Nov")
  else if mm == "12"
    ("December", "Dec")
  else
    ("", "")
  end
end

fn eval_format_date(val: FVal, pat: Text) : Result(FVal, Text)
  dt_opt = case val
    FEmpty: return Ok(FText(""))
    FDate(dt): Some(dt)
    FText(s):
      trimmed = s.trim
      if trimmed.chars.size >= 10
        Date.parse_iso(Text.from_chars(trimmed.chars.take(10)))
      else
        None
      end
    FBool(_) | FNum(_) | FList(_) | FRow(_): None
  end
  case dt_opt
    None: Error("formatDate requires a Date value")
    Some(dt):
      iso = dt.to_iso
      cs = iso.chars
      yyyy = Text.from_chars(cs.take(4))
      yy = Text.from_chars(cs.drop(2).take(2))
      mm = Text.from_chars(cs.drop(5).take(2))
      dd = Text.from_chars(cs.drop(8).take(2))
      (month_full, month_abbr) = month_names_for_mm(mm)
      rendered = pat
        .replace("YYYY", yyyy)
        .replace("YY", yy)
        .replace("MMMM", month_full)
        .replace("MMM", month_abbr)
        .replace("MM", mm)
        .replace("DD", dd)
      Ok(FText(rendered))
  end
end

fn fval_to_cell(v: FVal) : CellValue
  case v
    FEmpty: Empty
    FText(s): TextVal(s)
    FNum(d): NumberVal(d)
    FBool(b): BoolVal(b)
    FDate(dt): DateVal(start: dt, end_date: None)
    FList(xs):
      if xs.empty?: Empty else: TextVal(xs.map(format_fval).join(", "))
    FRow(rr): TextVal(rr.row.id)
  end
end

fn eval_expr(
  expr: FExpr,
  def: DatabaseDef,
  row: DbRow,
  computed: Map(Text, CellValue),
  related_rows: Map(Text, List(FormulaRelatedRow)),
  current_opt: Option(FVal),
  steps0: Int
) : Result((FVal, Int), Text)
  return Error("formula evaluation step budget exceeded (4000)") if steps0 >= 4000
  steps = steps0 + 1

  case expr
    FEmptyLit: Ok((FEmpty, steps))
    FBoolLit(b): Ok((FBool(b), steps))
    FNumLit(d): Ok((FNum(d), steps))
    FTextLit(s): Ok((FText(s), steps))
    FCurrent:
      case current_opt
        Some(cv): Ok((cv, steps))
        None: Error("'current' is only valid inside .filter() or .map()")
      end
    FUn(op: op, expr: sub):
      (v, ns) = try eval_expr(sub, def, row, computed, related_rows, current_opt, steps)
      if op == "not"
        Ok((FBool(not fval_truthy?(v)), ns))
      else if op == "-"
        d = try as_decimal(v, "unary '-'")
        Ok((FNum(0.0 - d), ns))
      else
        Error("unknown unary operator '#{op}'")
      end
    FBin(op: op, left: l, right: r):
      if op == "and"
        (lv, s1) = try eval_expr(l, def, row, computed, related_rows, current_opt, steps)
        if not fval_truthy?(lv)
          return Ok((FBool(false), s1))
        end
        (rv, s2) = try eval_expr(r, def, row, computed, related_rows, current_opt, s1)
        return Ok((FBool(fval_truthy?(rv)), s2))
      else if op == "or"
        (lv, s1) = try eval_expr(l, def, row, computed, related_rows, current_opt, steps)
        if fval_truthy?(lv)
          return Ok((FBool(true), s1))
        end
        (rv, s2) = try eval_expr(r, def, row, computed, related_rows, current_opt, s1)
        return Ok((FBool(fval_truthy?(rv)), s2))
      end

      (lv, s1) = try eval_expr(l, def, row, computed, related_rows, current_opt, steps)
      (rv, s2) = try eval_expr(r, def, row, computed, related_rows, current_opt, s1)
      if op == "=="
        Ok((FBool(fval_eq?(lv, rv)), s2))
      else if op == "!="
        Ok((FBool(not fval_eq?(lv, rv)), s2))
      else if op == "<" or op == "<=" or op == ">" or op == ">="
        c = try fval_cmp(lv, rv)
        res = if op == "<"
          c < 0
        else if op == "<="
          c <= 0
        else if op == ">"
          c > 0
        else
          c >= 0
        end
        Ok((FBool(res), s2))
      else if op == "+"
        case (lv, rv)
          (FText(_), _) | (_, FText(_)): Ok((FText("#{format_fval(lv)}#{format_fval(rv)}"), s2))
          (_, _):
            dl = try as_decimal(lv, "'+'")
            dr = try as_decimal(rv, "'+'")
            Ok((FNum(dl + dr), s2))
        end
      else if op == "-"
        dl = try as_decimal(lv, "'-'")
        dr = try as_decimal(rv, "'-'")
        Ok((FNum(dl - dr), s2))
      else if op == "*"
        dl = try as_decimal(lv, "'*'")
        dr = try as_decimal(rv, "'*'")
        Ok((FNum(dl * dr), s2))
      else if op == "/"
        dl = try as_decimal(lv, "'/'")
        dr = try as_decimal(rv, "'/'")
        if dr == 0.0
          Error("division by zero in formula")
        else
          Ok((FNum(dl / dr), s2))
        end
      else
        Error("unknown binary operator '#{op}'")
      end
    FCall(name: fname, args: args):
      eval_call(fname, args, def, row, computed, related_rows, current_opt, steps)
    FMethod(obj: obj_e, name: mname, args: args):
      (obj_v, s1) = try eval_expr(obj_e, def, row, computed, related_rows, current_opt, steps)
      eval_method(obj_v, mname, args, def, row, computed, related_rows, current_opt, s1)
  end
end

fn eval_call(
  fname: Text,
  args: List(FExpr),
  def: DatabaseDef,
  row: DbRow,
  computed: Map(Text, CellValue),
  related_rows: Map(Text, List(FormulaRelatedRow)),
  current_opt: Option(FVal),
  steps0: Int
) : Result((FVal, Int), Text)
  if fname == "empty"
    if args.empty?
      return Ok((FEmpty, steps0))
    else if args.size == 1
      a0 = args.get(0) or stop "arg0"
      (v0, s1) = try eval_expr(a0, def, row, computed, related_rows, current_opt, steps0)
      return Ok((FBool(fval_empty?(v0)), s1))
    else
      return Error("empty() takes 0 or 1 arguments")
    end
  end

  if fname == "if"
    return Error("if() requires 3 arguments") if args.size != 3
    (cv, s1) = try eval_expr(
      args.get(0) or stop "if0",
      def,
      row,
      computed,
      related_rows,
      current_opt,
      steps0
    )
    branch = if fval_truthy?(cv): args.get(1) or stop "if1" else: args.get(2) or stop "if2"
    return eval_expr(branch, def, row, computed, related_rows, current_opt, s1)
  end

  if fname == "ifs"
    return Error("ifs() requires at least 2 arguments") if args.size < 2
    var i = 0
    var s = steps0
    while i + 1 < args.size
      cond_e = args.get(i) or stop "ifsc"
      val_e = args.get(i + 1) or stop "ifsv"
      (cv, s1) = try eval_expr(cond_e, def, row, computed, related_rows, current_opt, s)
      s = s1
      if fval_truthy?(cv)
        return eval_expr(val_e, def, row, computed, related_rows, current_opt, s)
      end
      i += 2
    end
    if i < args.size
      return eval_expr(args.get(i) or stop "ifsd", def, row, computed, related_rows, current_opt, s)
    end
    return Ok((FEmpty, s))
  end

  # Eager evaluation for remaining built-in functions
  var vals = []
  var cur_steps = steps0
  for a in args
    (av, ns) = try eval_expr(a, def, row, computed, related_rows, current_opt, cur_steps)
    vals = vals.append(av)
    cur_steps = ns
  end

  if fname == "prop"
    return Error("prop() requires 1 string argument") if vals.size != 1
    pname = case vals.get(0) or FEmpty
      FText(s): s
      FEmpty | FBool(_) | FNum(_) | FDate(_) | FList(_) | FRow(_): return Error(
        "prop() argument must be a property name string"
      )
    end
    return Ok((lookup_prop_val(pname, def, row, computed, related_rows), cur_steps))
  end

  if fname == "round"
    return Error("round() takes 1 or 2 arguments") if vals.empty? or vals.size > 2
    d = try as_decimal(vals.get(0) or FEmpty, "round()")
    places = if vals.size == 2
      pd = try as_decimal(vals.get(1) or FEmpty, "round() places")
      pi = pd.floor.to_text.to_int or 0
      if pi < 0: 0 else if pi > 6: 6 else: pi
    else
      0
    end
    return Ok((FNum(d.round(places)), cur_steps))
  end

  if fname == "floor"
    return Error("floor() requires 1 argument") if vals.size != 1
    d = try as_decimal(vals.get(0) or FEmpty, "floor()")
    return Ok((FNum(d.floor), cur_steps))
  end

  if fname == "ceil"
    return Error("ceil() requires 1 argument") if vals.size != 1
    d = try as_decimal(vals.get(0) or FEmpty, "ceil()")
    return Ok((FNum(d.ceil), cur_steps))
  end

  if fname == "abs"
    return Error("abs() requires 1 argument") if vals.size != 1
    d = try as_decimal(vals.get(0) or FEmpty, "abs()")
    return Ok((FNum(d.abs), cur_steps))
  end

  if fname == "min" or fname == "max"
    return Error("#{fname}() requires at least 1 argument") if vals.empty?
    var best = try as_decimal(vals.get(0) or FEmpty, fname)
    for v in vals.drop(1)
      dv = try as_decimal(v, fname)
      if (fname == "min" and dv < best) or (fname == "max" and dv > best)
        best = dv
      end
    end
    return Ok((FNum(best), cur_steps))
  end

  if fname == "format"
    return Error("format() requires 1 argument") if vals.size != 1
    return Ok((FText(format_fval(vals.get(0) or FEmpty)), cur_steps))
  end

  if fname == "repeat"
    return Error("repeat() requires 2 arguments") if vals.size != 2
    s = format_fval(vals.get(0) or FEmpty)
    cnt_dec = try as_decimal(vals.get(1) or FEmpty, "repeat()")
    raw_cnt = cnt_dec.floor.to_text.to_int or 0
    cnt = if raw_cnt <= 0: 0 else if raw_cnt > 1000: 1000 else: raw_cnt
    return Ok((FText(s.repeat(cnt)), cur_steps))
  end

  if fname == "formatDate"
    return Error("formatDate() requires 2 arguments") if vals.size != 2
    pat = format_fval(vals.get(1) or FEmpty)
    dv = try eval_format_date(vals.get(0) or FEmpty, pat)
    return Ok((dv, cur_steps))
  end

  if fname == "length"
    return Error("length() requires 1 argument") if vals.size != 1
    return case vals.get(0) or FEmpty
      FList(xs): Ok((FNum(xs.size.to_decimal), cur_steps))
      FText(s): Ok((FNum(s.chars.size.to_decimal), cur_steps))
      FEmpty: Ok((FNum(0.0), cur_steps))
      FBool(_) | FNum(_) | FDate(_) | FRow(_): Error("length() expects a list or text value")
    end
  end

  if fname == "contains"
    return Error("contains() requires 2 arguments") if vals.size != 2
    hay = format_fval(vals.get(0) or FEmpty)
    ndl = format_fval(vals.get(1) or FEmpty)
    return Ok((FBool(hay.contains?(ndl)), cur_steps))
  end

  if fname == "lower"
    return Error("lower() requires 1 argument") if vals.size != 1
    return Ok((FText(format_fval(vals.get(0) or FEmpty).ascii_lowercase), cur_steps))
  end

  if fname == "upper"
    return Error("upper() requires 1 argument") if vals.size != 1
    return Ok((FText(format_fval(vals.get(0) or FEmpty).ascii_uppercase), cur_steps))
  end

  if fname == "concat"
    return Ok((FText(vals.map(format_fval).join("")), cur_steps))
  end

  if fname == "not"
    return Error("not() requires 1 argument") if vals.size != 1
    return Ok((FBool(not fval_truthy?(vals.get(0) or FEmpty)), cur_steps))
  end

  Error("unknown formula function '#{fname}'")
end

fn eval_method(
  obj: FVal,
  mname: Text,
  args: List(FExpr),
  def: DatabaseDef,
  row: DbRow,
  computed: Map(Text, CellValue),
  related_rows: Map(Text, List(FormulaRelatedRow)),
  _current_opt: Option(FVal),
  steps0: Int
) : Result((FVal, Int), Text)
  if mname == "length"
    return Error(".length() takes 0 arguments") if not args.empty?
    return case obj
      FList(xs): Ok((FNum(xs.size.to_decimal), steps0))
      FText(s): Ok((FNum(s.chars.size.to_decimal), steps0))
      FEmpty: Ok((FNum(0.0), steps0))
      FBool(_) | FNum(_) | FDate(_) | FRow(_): Error(".length() expects a list or text receiver")
    end
  end

  if mname == "empty"
    return Error(".empty() takes 0 arguments") if not args.empty?
    return Ok((FBool(fval_empty?(obj)), steps0))
  end

  if mname == "format"
    return Error(".format() takes 0 arguments") if not args.empty?
    return Ok((FText(format_fval(obj)), steps0))
  end

  if mname == "prop"
    return Error(".prop() requires 1 argument") if args.size != 1
    (arg_v, s1) = try eval_expr(args.get(0) or stop "mp0", def, row, computed, related_rows, None, steps0)
    pname = case arg_v
      FText(s): s
      FEmpty | FBool(_) | FNum(_) | FDate(_) | FList(_) | FRow(_): return Error(
        ".prop() argument must be a property name string"
      )
    end
    return case obj
      FRow(rr): Ok((lookup_prop_val(pname, rr.def, rr.row, {}, {}), s1))
      FEmpty: Ok((FEmpty, s1))
      FBool(_) | FNum(_) | FText(_) | FDate(_) | FList(_): Error(
        ".prop() receiver must be a related row"
      )
    end
  end

  if mname == "filter"
    return Error(".filter() requires 1 predicate argument") if args.size != 1
    pred = args.get(0) or stop "flt"
    xs = case obj
      FList(items): items
      FEmpty: []
      FBool(_) | FNum(_) | FText(_) | FDate(_) | FRow(_): return Error(
        ".filter() receiver must be a list"
      )
    end
    var kept = []
    var s = steps0
    for item in xs
      (keep_v, ns) = try eval_expr(pred, def, row, computed, related_rows, Some(item), s)
      s = ns
      if fval_truthy?(keep_v)
        kept = kept.append(item)
      end
    end
    return Ok((FList(kept), s))
  end

  if mname == "map"
    return Error(".map() requires 1 expression argument") if args.size != 1
    fn_expr = args.get(0) or stop "map"
    xs = case obj
      FList(items): items
      FEmpty: []
      FBool(_) | FNum(_) | FText(_) | FDate(_) | FRow(_): return Error(
        ".map() receiver must be a list"
      )
    end
    var mapped = []
    var s = steps0
    for item in xs
      (mv, ns) = try eval_expr(fn_expr, def, row, computed, related_rows, Some(item), s)
      s = ns
      mapped = mapped.append(mv)
    end
    return Ok((FList(mapped), s))
  end

  if mname == "join"
    return Error(".join() takes 0 or 1 argument") if args.size > 1
    xs = case obj
      FList(items): items
      FEmpty: []
      FBool(_) | FNum(_) | FText(_) | FDate(_) | FRow(_): return Error(
        ".join() receiver must be a list"
      )
    end
    (sep, s1) = if args.empty?
      (", ", steps0)
    else
      (sv, ns) = try eval_expr(args.get(0) or stop "jn0", def, row, computed, related_rows, None, steps0)
      (format_fval(sv), ns)
    end
    return Ok((FText(xs.map(format_fval).join(sep)), s1))
  end

  Error("unknown formula method '.#{mname}()'")
end

## Evaluates a single formula expression for `row` using `base_computed` (Rollups/Audit/prior formulas).
fn evaluate_formula(
  expression: Text,
  def: DatabaseDef,
  row: DbRow,
  computed: Map(Text, CellValue),
  related_rows: Map(Text, List(FormulaRelatedRow))
) : Result(CellValue, Text)
  ast = try parse_formula_ast(expression)
  (res_v, _steps) = try eval_expr(ast, def, row, computed, related_rows, None, 0)
  Ok(fval_to_cell(res_v))
end

## Evaluates all `Formula` columns of `def` for one `DbRow` in up to 3 dependency passes.
fn evaluate_row_formulas(
  def: DatabaseDef,
  row: DbRow,
  base_computed: Map(Text, CellValue),
  related_rows: Map(Text, List(FormulaRelatedRow))
) : Map(Text, CellValue)
  var formulas = []
  for p in def.properties
    case p.kind
      Formula(expression: expr, format: _): formulas = formulas.append((p.id, expr))
      Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
        prefix: _
      ) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
        target_db_id: _,
        inverse_prop_id: _
      ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): Unit
    end
  end
  return base_computed if formulas.empty?

  var acc = base_computed
  var pass = 0
  while pass < 3
    var changed = false
    for (pid, expr) in formulas
      next_cell = case evaluate_formula(expr, def, row, acc, related_rows)
        Ok(cv): cv
        Error(_): Empty
      end
      prev_opt = acc.get(pid)
      val_changed = case prev_opt
        None: true
        Some(prev_cell): next_cell != prev_cell
      end
      if val_changed
        acc = acc.set(pid, next_cell)
        changed = true
      end
    end
    break if not changed
    pass += 1
  end
  acc
end
