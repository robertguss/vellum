## Relational Database schemas, exact Decimal/Date cells, Relation/Rollup evaluation,
## and Table/Board/Calendar Multi-View filter, sort, and grouping logic.
module Domain.DatabaseModel
expose SelectOptionColor(..),
SelectOption(..),
RollupAgg(..),
AiOutputKind(..),
AiColumnMode(..),
AiCellMeta(..),
AiColumnUsage(..),
PropertyKind(..),
PropertyDef(..),
DatabaseDef(..),
CellValue(..),
DbRow(..),
DbViewKind(..),
FilterOp(..),
DbFilterRule(..),
DbSortRule(..),
DbViewDef(..),
EnrichedRow(..),
BoardGroup(..),
ViewQueryResult(..),
ai_output_to_property_kind,
has_ai_derived_columns?,
ai_cell_meta_key,
ai_col_usage_key,
compute_ai_prompt_hash,
compute_ai_input_hash,
parse_ai_cell_output,
compute_deterministic_ai_cell,
validate_database_def,
validate_cell,
validate_row_cells,
extract_row_title,
cell_index_tokens,
compute_rollup,
compute_rollup_with_target,
is_computed_property?,
effective_cell,
matches_filter?,
matches_filters?,
sort_enriched_rows,
group_rows_for_board,
filter_calendar_range,
filter_timeline_range,
row_plain_text,
decode_cell_map_json,
decode_property_defs_json,
decode_filter_rules_json,
decode_sort_rules_json,
check_unique_id_immutable
use Crypto
use Date
use Domain.Types{Citation}
use Json

## Visual badge color for `Select`, `Status`, and `MultiSelect` property options.
enum SelectOptionColor
  Gray
  Blue
  Green
  Amber
  Red
  Purple
end

## Allowed discrete choice within a `Select`, `Status`, or `MultiSelect` column.
struct SelectOption
  id: Text
  label: Text
  color: SelectOptionColor
end

## Aggregation operator evaluated dynamically across related rows for `Rollup` columns.
enum RollupAgg
  CountAll
  CountValues
  SumValues
  MinValue
  MaxValue
  PercentPerGroup
end

## Output type enforced when compiling an `AiDerived` property via `validate_cell`.
enum AiOutputKind
  AiText
  AiNumber(format: Text)
  AiDate
  AiBool
  AiSelect(options: List(SelectOption))
end

## Write routing policy for an AI-compiled column (`AutoApply` vs `Modb.World` `StageProposal`).
enum AiColumnMode
  AutoApply
  StageProposal
end

## Provenance, staleness hash, and grounded citations stored per `(database, row, ai_prop)`.
struct AiCellMeta
  id: Text
  database_id: Text
  row_id: Text
  prop_id: Text
  model: Text
  prompt_hash: Text
  input_hash: Text
  stale: Bool
  rationale: Option(Text)
  citations: List(Citation)
  proposal_id: Option(Text)
  computed_at: Time
end

## Daily AI call counter persisted in `vlm_ai_col_usage` to enforce per-column daily caps.
struct AiColumnUsage
  id: Text
  database_id: Text
  prop_id: Text
  day_iso: Text
  calls_used: Int
  updated_at: Time
end

## Strongly typed column schema variants for Vellum relational databases.
enum PropertyKind
  Title
  RichText
  Number(format: Text)
  DateProp(include_time: Bool)
  Select(options: List(SelectOption))
  MultiSelect(options: List(SelectOption))
  Status(options: List(SelectOption), done_option_ids: List(Text))
  Checkbox
  Person
  Email
  FileList
  Url
  UniqueId(prefix: Text)
  Formula(expression: Text, format: Text)
  CreatedTime
  CreatedBy
  LastEditedTime
  LastEditedBy
  Relation(target_db_id: Text, inverse_prop_id: Option(Text))
  Rollup(relation_prop_id: Text, target_prop_id: Text, agg: RollupAgg)
  AiDerived(
    prompt: Text,
    source_prop_ids: List(Text),
    include_row_body: Bool,
    output_kind: AiOutputKind,
    mode: AiColumnMode,
    daily_call_cap: Int
  )
end

## Single column definition inside a `DatabaseDef`.
struct PropertyDef
  id: Text
  name: Text
  kind: PropertyKind
  required: Bool
  sort_order: Text
end

## Relational database schema record persisted in MoDB (`vlm_databases`).
struct DatabaseDef
  id: Text
  collection_id: Text
  page_id: Text
  title: Text
  description: Text
  properties: List(PropertyDef)
  version: Int
end

## Typed cell value stored inside `DbRow.cells` (`Decimal` numbers, never IEEE float drift).
enum CellValue
  Empty
  TextVal(Text)
  NumberVal(Decimal)
  DateVal(start: Date.Date, end_date: Option(Date.Date))
  SelectVal(option_id: Text)
  MultiSelectVal(option_ids: List(Text))
  BoolVal(Bool)
  PrincipalVal(List(Text))
  FilesVal(attachment_ids: List(Text))
  UrlVal(Text)
  RelationVal(row_ids: List(Text))
end

## Database item record backed 1:1 by a `Page(kind: DatabaseRow(...))`.
struct DbRow
  id: Text
  database_id: Text
  page_id: Text
  cells: Map(Text, CellValue)
  created_by: Text
  created_at: Time
  updated_at: Time
  archived_at: Option(Time)
  version: Int
end

## View presentation configuration for Table, Kanban Board, Calendar, Gallery, or Timeline views.
enum DbViewKind
  TableView(visible_prop_ids: List(Text), column_widths: Map(Text, Int))
  BoardView(group_by_prop_id: Text, card_prop_ids: List(Text), hide_empty_groups: Bool)
  CalendarView(date_prop_id: Text, card_prop_ids: List(Text))
  GalleryView(cover_prop_id: Option(Text), card_prop_ids: List(Text), card_size: Text)
  TimelineView(start_date_prop_id: Text, end_date_prop_id: Option(Text), card_prop_ids: List(Text))
end

## Saved view filter predicate operators.
enum FilterOp
  Eq
  Neq
  Gt
  Gte
  Lt
  Lte
  Contains
  InSet
  IsEmpty
  IsNotEmpty
end

## Single property filter predicate inside a saved view or ad-hoc query.
struct DbFilterRule
  prop_id: Text
  op: FilterOp
  value: Json
end

## Sort specification clause applied to enriched rows.
struct DbSortRule
  prop_id: Text
  desc: Bool
end

## Saved database view record persisted in MoDB (`vlm_db_views`).
struct DbViewDef
  id: Text
  database_id: Text
  name: Text
  kind: DbViewKind
  filters: List(DbFilterRule)
  filter_match_all: Bool
  sorts: List(DbSortRule)
  sort_order: Text
end

## Row combined with computed virtual `Rollup` property values.
struct EnrichedRow
  row: DbRow
  rollups: Map(Text, CellValue)
end

## Single column/swimlane returned when querying a Kanban `BoardView`.
struct BoardGroup
  group_key: Text
  label: Text
  rows: List(EnrichedRow)
end

## Unified multi-view query response returned by `POST /api/databases/:id/query`.
struct ViewQueryResult
  view: Option(DbViewDef)
  rows: List(EnrichedRow)
  board_groups: Option(List(BoardGroup))
  total_count: Int
end

fn zero_decimal() : Decimal
  0.0
end

## Maps an `AiOutputKind` to its equivalent base `PropertyKind` for validation and formatting.
fn ai_output_to_property_kind(out: AiOutputKind) : PropertyKind
  case out
    AiText: RichText
    AiNumber(format: f): Number(format: f)
    AiDate: DateProp(include_time: false)
    AiBool: Checkbox
    AiSelect(options: opts): Select(options: opts)
  end
end

fn prop_is_ai_derived?(kind: PropertyKind) : Bool
  case kind
    AiDerived(
      prompt: _,
      source_prop_ids: _,
      include_row_body: _,
      output_kind: _,
      mode: _,
      daily_call_cap: _
    ): true
    Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
      options: _
    ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
      prefix: _
    ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
      target_db_id: _,
      inverse_prop_id: _
    ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): false
  end
end

## Whether a property's value is computed dynamically at query time (`Rollup`, `Formula`, or audit metadata).
fn is_computed_property?(kind: PropertyKind) : Bool
  case kind
    Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | Formula(
      expression: _,
      format: _
    ) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy: true
    Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
      options: _
    ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
      prefix: _
    ) | Relation(target_db_id: _, inverse_prop_id: _) | AiDerived(
      prompt: _,
      source_prop_ids: _,
      include_row_body: _,
      output_kind: _,
      mode: _,
      daily_call_cap: _
    ): false
  end
end

fn is_done_status_label?(label: Text) : Bool
  low = label.trim.ascii_lowercase
  low == "done" or low == "complete" or low == "completed" or low == "shipped" or low == "closed"
end

fn valid_email?(raw: Text) : Bool
  t = raw.trim
  return false if t.empty? or t.contains?(" ") or t.contains?("\t") or t.contains?("\n") or t.contains?("\r")
  parts = t.split("@")
  return false if parts.size != 2
  local = parts.get(0) or ""
  dom = parts.get(1) or ""
  not local.empty? and dom.contains?(".") and not dom.starts_with?(".") and not dom.ends_with?(".")
end

## Whether `def` declares at least one `AiDerived` column.
fn has_ai_derived_columns?(def: DatabaseDef) : Bool
  def.properties.any?(fn(p) prop_is_ai_derived?(p.kind) end)
end

## Canonical primary key in `vlm_ai_cell_meta`.
fn ai_cell_meta_key(db_id: Text, row_id: Text, prop_id: Text) : Text
  "#{db_id}:#{row_id}:#{prop_id}"
end

## Canonical primary key in `vlm_ai_col_usage`.
fn ai_col_usage_key(db_id: Text, prop_id: Text, day_iso: Text) : Text
  "#{db_id}:#{prop_id}:#{day_iso}"
end

## Deterministic SHA-256 hash of an `AiDerived` column's prompt and output schema.
fn compute_ai_prompt_hash(prompt: Text, output_kind: AiOutputKind) : Text
  Crypto.sha256("#{prompt.trim}|#{output_kind.to_json.to_text}".bytes).to_hex
end

## Deterministic SHA-256 digest of a row's grounded source inputs for `AiDerived` staleness detection.
fn compute_ai_input_hash(def: DatabaseDef, prop: PropertyDef, row: DbRow, body_plain: Text) : Text
  (src_ids, include_body?) = case prop.kind
    AiDerived(
      prompt: _,
      source_prop_ids: sids,
      include_row_body: inc,
      output_kind: _,
      mode: _,
      daily_call_cap: _
    ): (sids, inc)
    Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
      options: _
    ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
      prefix: _
    ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
      target_db_id: _,
      inverse_prop_id: _
    ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): ([], false)
  end

  var target_ids = []
  if src_ids.empty?
    for p in def.properties
      if not prop_is_ai_derived?(p.kind) and not target_ids.contains?(p.id)
        target_ids = target_ids.append(p.id)
      end
    end
  else
    for sid in src_ids
      clean = sid.trim
      if not clean.empty? and not target_ids.contains?(clean)
        target_ids = target_ids.append(clean)
      end
    end
  end
  sorted_ids = target_ids.sort_by(fn(x) x end)
  var parts = []
  for sid in sorted_ids
    cell = row.cells.get(sid) or Empty
    parts = parts.append("#{sid}=#{cell.to_json.to_text}")
  end
  if include_body?
    parts = parts.append("__body__=#{body_plain.trim}")
  end
  Crypto.sha256(parts.join("\n").bytes).to_hex
end

fn strip_markdown_code_fence(raw: Text) : Text
  t = raw.trim
  return t if not t.starts_with?("```")
  lines = t.lines
  return t if lines.size < 2
  tail = lines.drop(1)
  body = case tail.last
    Some(last_ln) if last_ln.trim == "```": tail.take(tail.size - 1)
    Some(_) | None: tail
  end
  body.join("\n").trim
end

fn strip_numeric_decorations(raw: Text) : Text
  raw.trim.replace("$", "").replace(",", "").replace("%", "").replace(" ", "")
end

## Strictly parses an LLM string or JSON response (`{"value":..., "rationale":...}`) into a typed `CellValue`.
fn parse_ai_cell_output(output_kind: AiOutputKind, raw_text: Text) : Result(
  (CellValue, Option(Text)),
  Text
)
  cleaned = strip_markdown_code_fence(raw_text)
  if cleaned.empty?
    return Error("AI column returned empty response")
  end

  (val_json, rationale) = case Json.parse(cleaned)
    Ok(Json.Object(fields)):
      case fields.get("value")
        Some(v):
          rat = case fields.get("rationale")
            Some(Json.String(r)) if not r.trim.empty?: Some(r.trim)
            Some(_) | None: None
          end
          (v, rat)
        None: (Json.String(cleaned), None)
      end
    Ok(j): (j, None)
    Error(_): (Json.String(cleaned), None)
  end

  case output_kind
    AiText:
      txt = case val_json
        Json.String(s): s.trim
        Json.Number(n): n.to_text
        Json.Boolean(b): if b: "true" else: "false"
        Json.Null | Json.Array(_) | Json.Object(_): ""
      end
      if txt.empty?
        Error("AI text output is empty")
      else
        Ok((TextVal(txt), rationale))
      end
    AiNumber(format: _):
      raw_num = case val_json
        Json.Number(n): n.to_text
        Json.String(s): strip_numeric_decorations(s)
        Json.Null | Json.Boolean(_) | Json.Array(_) | Json.Object(_): ""
      end
      case raw_num.to_decimal
        Some(d): Ok((NumberVal(d), rationale))
        None: Error("AI number output '#{raw_num}' is not a valid Decimal")
      end
    AiDate:
      raw_dt = case val_json
        Json.String(s): s.trim
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): ""
      end
      case Date.parse_iso(raw_dt)
        Some(dt): Ok((DateVal(start: dt, end_date: None), rationale))
        None: Error("AI date output '#{raw_dt}' must be ISO YYYY-MM-DD")
      end
    AiBool:
      case val_json
        Json.Boolean(b): Ok((BoolVal(b), rationale))
        Json.String(s):
          low = s.trim.ascii_lowercase
          if low == "true" or low == "yes" or low == "1"
            Ok((BoolVal(true), rationale))
          else if low == "false" or low == "no" or low == "0"
            Ok((BoolVal(false), rationale))
          else
            Error("AI boolean output '#{s.trim}' must be true/false")
          end
        Json.Null | Json.Number(_) | Json.Array(_) | Json.Object(_): Error(
          "AI boolean output must be a JSON boolean or true/false string"
        )
      end
    AiSelect(options: opts):
      raw_opt = case val_json
        Json.String(s): s.trim
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): ""
      end
      low = raw_opt.ascii_lowercase
      if low.empty?
        return Error("AI select output must be a non-empty option id or label")
      end
      for o in opts
        if o.id == raw_opt
          return Ok((SelectVal(option_id: o.id), rationale))
        end
      end
      for o in opts
        if o.id.ascii_lowercase == low or o.label.trim.ascii_lowercase == low
          return Ok((SelectVal(option_id: o.id), rationale))
        end
      end
      Error("AI select output '#{raw_opt}' does not match any allowed option")
  end
end

## Offline deterministic fallback synthesizer when `VELLUM_AI_API_KEY` is absent and `deterministic_fallback == true`.
fn compute_deterministic_ai_cell(
  prop: PropertyDef,
  output_kind: AiOutputKind,
  row_title: Text,
  source_text: Text
) : (CellValue, Text)
  low = "#{row_title} #{source_text}".ascii_lowercase
  case output_kind
    AiText:
      snip = if source_text.trim.empty?
        row_title.trim
      else
        source_text.trim
      end
      compact = if snip.byte_count > 160
        snip.bytes.slice(0, 160).decode_utf8 or snip
      else
        snip
      end
      (TextVal("#{prop.name}: #{compact}"), "Deterministic offline synthesis from source cells")
    AiNumber(format: _):
      d = (row_title.trim.byte_count + source_text.trim.byte_count).to_decimal
      (NumberVal(d), "Deterministic offline numeric score from source length")
    AiDate:
      dt = Date.parse_iso("2026-12-01") or stop "det date"
      (DateVal(start: dt, end_date: None), "Deterministic offline date fallback")
    AiBool:
      flagged? = low.contains?("urgent") or low.contains?("critical") or low.contains?("high") or
        low.contains?("yes") or low.contains?("true")
      (BoolVal(flagged?), "Deterministic keyword classification")
    AiSelect(options: opts):
      var chosen = opts.first.map(fn(o) o.id end) or "default"
      for o in opts
        if low.contains?(o.id.ascii_lowercase) or low.contains?(o.label.ascii_lowercase)
          chosen = o.id
          break
        end
      end
      (SelectVal(option_id: chosen), "Deterministic option match against row source text")
  end
end

fn validate_options(opts: List(SelectOption)) : Option(Text)
  if opts.empty?
    return Some("Select/MultiSelect property requires at least one option")
  end
  var seen = Set.empty
  for o in opts
    oid = o.id.trim
    if oid.empty? or o.label.trim.empty?
      return Some("select option id and label must be non-empty")
    end
    if seen.has?(oid)
      return Some("duplicate select option id '#{oid}'")
    end
    seen = seen.add(oid)
  end
  None
end

## Validates a `DatabaseDef` schema (non-empty title, unique props, >= 1 `Title`, valid rollups, status, unique_id, formula).
fn validate_database_def(def: DatabaseDef) : Option(Text)
  return Some("database title must not be empty") if def.title.trim.empty?
  return Some("database version must be >= 1") if def.version < 1
  return Some("database must define at least one property") if def.properties.empty?

  var prop_by_id = {}
  var title_count = 0
  for p in def.properties
    pid = p.id.trim
    if pid.empty? or p.name.trim.empty?
      return Some("property id and name must be non-empty")
    end
    if prop_by_id.get(pid) != None
      return Some("duplicate property id '#{pid}'")
    end
    prop_by_id = prop_by_id.set(pid, p)
    case p.kind
      Title: title_count += 1
      Number(format: fmt):
        if fmt != "plain" and fmt != "currency" and fmt != "percent"
          return Some("invalid Number format '#{fmt}' on property '#{pid}'")
        end
      Select(options: opts) | MultiSelect(options: opts):
        case validate_options(opts)
          Some(msg): return Some(msg)
          None: Unit
        end
      Status(options: opts, done_option_ids: done_ids):
        case validate_options(opts)
          Some(msg): return Some(msg)
          None: Unit
        end
        for did in done_ids
          if not has_option_id?(opts, did)
            return Some("Status property '#{pid}' done_option_ids references unknown option '#{did}'")
          end
        end
      UniqueId(prefix: pfx):
        trimmed_pfx = pfx.trim
        if trimmed_pfx.byte_count > 24 or pfx.contains?("\n") or pfx.contains?("\r") or
          trimmed_pfx.contains?(" ")
          return Some(
            "UniqueId property '#{pid}' prefix must be <= 24 chars without spaces or newlines"
          )
        end
      Formula(expression: expr, format: fmt):
        if expr.trim.empty?
          return Some("Formula property '#{pid}' requires a non-empty expression")
        end
        if fmt != "" and fmt != "plain" and fmt != "number" and fmt != "currency" and fmt != "percent" and
          fmt != "text" and fmt != "date" and fmt != "bool"
          return Some("invalid Formula format '#{fmt}' on property '#{pid}'")
        end
      Relation(target_db_id: tdb, inverse_prop_id: _):
        if tdb.trim.empty?
          return Some("relation property '#{pid}' requires non-empty target_db_id")
        end
      AiDerived(
        prompt: pr,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: out_k,
        mode: _,
        daily_call_cap: cap
      ):
        if pr.trim.empty?
          return Some("AI column '#{pid}' requires a non-empty prompt")
        end
        if cap < 1 or cap > 10000
          return Some("AI column '#{pid}' daily_call_cap must be between 1 and 10000")
        end
        case out_k
          AiNumber(format: fmt):
            if fmt != "plain" and fmt != "currency" and fmt != "percent"
              return Some("invalid Number format '#{fmt}' on AI column '#{pid}'")
            end
          AiSelect(options: opts):
            case validate_options(opts)
              Some(msg): return Some(msg)
              None: Unit
            end
          AiText | AiDate | AiBool: Unit
        end
      RichText | DateProp(include_time: _) | Checkbox | Person | Email | FileList | Url | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Rollup(
        relation_prop_id: _,
        target_prop_id: _,
        agg: _
      ): Unit
    end
  end

  if title_count < 1
    return Some("database must include at least one Title property")
  end

  for p in def.properties
    case p.kind
      Rollup(relation_prop_id: rel_id, target_prop_id: tgt_id, agg: _):
        if tgt_id.trim.empty?
          return Some("rollup '#{p.id}' requires non-empty target_prop_id")
        end
        case prop_by_id.get(rel_id)
          None: return Some("rollup '#{p.id}' references missing relation '#{rel_id}'")
          Some(rel_prop):
            case rel_prop.kind
              Relation(target_db_id: _, inverse_prop_id: _): Unit
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
              ): return Some(
                "rollup '#{p.id}' source '#{rel_id}' is not a Relation property"
              )
            end
        end
      AiDerived(
        prompt: _,
        source_prop_ids: sids,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ):
        for sid in sids
          if sid == p.id
            return Some("AI column '#{p.id}' cannot reference itself as a source property")
          end
          if prop_by_id.get(sid) == None
            return Some("AI column '#{p.id}' references missing source property '#{sid}'")
          end
        end
      Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
        prefix: _
      ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
        target_db_id: _,
        inverse_prop_id: _
      ): Unit
    end
  end
  None
end

fn cell_empty?(val: CellValue) : Bool
  case val
    Empty: true
    TextVal(s) | UrlVal(s): s.trim.empty?
    SelectVal(option_id: oid): oid.trim.empty?
    MultiSelectVal(option_ids: oids): oids.empty?
    PrincipalVal(pids): pids.empty?
    FilesVal(attachment_ids: aids): aids.empty?
    RelationVal(row_ids: rids): rids.empty?
    NumberVal(_) | DateVal(start: _, end_date: _) | BoolVal(_): false
  end
end

fn has_option_id?(opts: List(SelectOption), option_id: Text) : Bool
  opts.any?(fn(o) o.id == option_id end)
end

## Validates one `CellValue` against its column `PropertyDef` schema.
fn validate_cell(prop: PropertyDef, val: CellValue) : Option(Text)
  case val
    Empty: return if prop.required and not is_computed_property?(prop.kind): Some(
      "required property '#{prop.id}' cannot be Empty"
    ) else: None
    TextVal(_) | NumberVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
      option_ids: _
    ) | BoolVal(_) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(
      row_ids: _
    ): Unit
  end

  case (prop.kind, val)
    (Title, TextVal(s)):
      if s.trim.empty?
        Some("Title property '#{prop.id}' must not be blank")
      else
        None
      end
    (RichText, TextVal(_)): None
    (Number(format: _), NumberVal(_)): None
    (DateProp(include_time: _), DateVal(start: st, end_date: ed_opt)):
      case ed_opt
        Some(ed) if ed < st: Some("date property '#{prop.id}' end_date cannot precede start")
        Some(_) | None: None
      end
    (Select(options: opts), SelectVal(option_id: oid)) | (
      Status(options: opts, done_option_ids: _),
      SelectVal(option_id: oid)
    ):
      if has_option_id?(opts, oid)
        None
      else
        Some("invalid option '#{oid}' for property '#{prop.id}'")
      end
    (MultiSelect(options: opts), MultiSelectVal(option_ids: oids)):
      for oid in oids
        if not has_option_id?(opts, oid)
          return Some("invalid multi-select option '#{oid}' for property '#{prop.id}'")
        end
      end
      None
    (Checkbox, BoolVal(_)): None
    (Person, PrincipalVal(pids)):
      if pids.any?(fn(x) x.trim.empty? end)
        Some("Person property '#{prop.id}' contains blank principal ID")
      else
        None
      end
    (Email, TextVal(e)):
      if valid_email?(e)
        None
      else
        Some("Email property '#{prop.id}' must be a valid email address")
      end
    (FileList, FilesVal(attachment_ids: aids)):
      if aids.any?(fn(x) x.trim.empty? end)
        Some("FileList property '#{prop.id}' contains blank attachment ID")
      else
        None
      end
    (Url, UrlVal(u)):
      trimmed = u.trim
      if trimmed.starts_with?("https://") or trimmed.starts_with?("http://")
        None
      else
        Some("Url property '#{prop.id}' must start with http:// or https://")
      end
    (UniqueId(prefix: _), TextVal(s)):
      if s.trim.empty?
        Some("UniqueId property '#{prop.id}' must not be blank")
      else
        None
      end
    (Relation(target_db_id: _, inverse_prop_id: _), RelationVal(row_ids: rids)):
      if rids.any?(fn(x) x.trim.empty? end)
        Some("Relation property '#{prop.id}' contains blank row ID")
      else
        None
      end
    (Rollup(relation_prop_id: _, target_prop_id: _, agg: _), _) | (
      Formula(expression: _, format: _),
      _
    ) | (CreatedTime, _) | (CreatedBy, _) | (LastEditedTime, _) | (LastEditedBy, _): Some(
      "computed property '#{prop.id}' cannot be written directly"
    )
    (
      AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: out_k,
        mode: _,
        daily_call_cap: _
      ),
      _
    ): validate_cell(
      PropertyDef(
        id: prop.id,
        name: prop.name,
        kind: ai_output_to_property_kind(out_k),
        required: prop.required,
        sort_order: prop.sort_order
      ),
      val
    )
    (_, _): Some("cell type does not match property '#{prop.id}' schema")
  end
end

## Validates all cells of a `DbRow` against `def` (unknown keys, types, required fields).
fn validate_row_cells(def: DatabaseDef, row: DbRow) : Option(Text)
  return Some("row version must be >= 1") if row.version < 1
  return Some("row database_id mismatch") if row.database_id != def.id

  var by_id = {}
  for p in def.properties
    by_id = by_id.set(p.id, p)
  end

  for (pid, cval) in row.cells.entries
    prop = case by_id.get(pid)
      Some(p): p
      None: return Some("unknown property '#{pid}' in database '#{def.id}'")
    end
    case validate_cell(prop, cval)
      Some(err): return Some(err)
      None: Unit
    end
  end

  for p in def.properties
    if p.required and not is_computed_property?(p.kind)
      cval = row.cells.get(p.id) or Empty
      if cell_empty?(cval)
        return Some("required property '#{p.id}' is missing")
      end
    end
  end
  None
end

## Extracts the row's human-readable title from the database's `Title` property.
fn extract_row_title(def: DatabaseDef, cells: Map(Text, CellValue)) : Text
  for p in def.properties
    case p.kind
      Title:
        case cells.get(p.id)
          Some(TextVal(s)) if not s.trim.empty?: return s.trim
          Some(_) | None: Unit
        end
      RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Status(options: _, done_option_ids: _) | Checkbox | Person | Email | FileList | Url | UniqueId(
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
      ): Unit
    end
  end
  "Untitled"
end

## Emits `(prop_id, normalized_value)` pairs indexed in `vlm_db_cells` for equality/grouping/relation lookups.
fn cell_index_tokens(prop_id: Text, val: CellValue) : List((Text, Text))
  case val
    Empty: []
    TextVal(_) | UrlVal(_): []
    NumberVal(d): [(prop_id, d.to_text)]
    DateVal(start: st, end_date: _): [(prop_id, st.to_iso)]
    SelectVal(option_id: oid): [(prop_id, oid)]
    MultiSelectVal(option_ids: oids): oids.map(fn(oid) (prop_id, oid) end)
    BoolVal(b): [(prop_id, if b: "true" else: "false")]
    PrincipalVal(pids): pids.map(fn(pid) (prop_id, pid) end)
    FilesVal(attachment_ids: aids): aids.map(fn(aid) (prop_id, aid) end)
    RelationVal(row_ids: rids): rids.map(fn(rid) (prop_id, rid) end)
  end
end

fn non_empty_cells(cells: List(CellValue)) : List(CellValue)
  cells.filter(fn(c) not cell_empty?(c) end)
end

fn rollup_cell_done?(c: CellValue, target_prop: Option(PropertyDef)) : Bool
  case c
    BoolVal(b): b
    SelectVal(option_id: oid):
      case target_prop
        Some(tp):
          case tp.kind
            Status(options: opts, done_option_ids: dids):
              if not dids.empty?
                dids.contains?(oid)
              else
                var matched_label = oid
                for o in opts
                  if o.id == oid
                    matched_label = o.label
                  end
                end
                is_done_status_label?(matched_label)
              end
            Select(options: opts) | AiDerived(
              prompt: _,
              source_prop_ids: _,
              include_row_body: _,
              output_kind: AiSelect(options: opts),
              mode: _,
              daily_call_cap: _
            ):
              var matched_label = oid
              for o in opts
                if o.id == oid
                  matched_label = o.label
                end
              end
              is_done_status_label?(matched_label)
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
            ): is_done_status_label?(oid)
          end
        None: is_done_status_label?(oid)
      end
    Empty | TextVal(_) | NumberVal(_) | DateVal(start: _, end_date: _) | MultiSelectVal(
      option_ids: _
    ) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): false
  end
end

## Computes a `Rollup` cell using exact `Decimal` arithmetic (`SumValues`, `PercentPerGroup`, `MinValue`, `MaxValue`, etc.).
fn compute_rollup_with_target(
  agg: RollupAgg,
  target_cells: List(CellValue),
  target_prop: Option(PropertyDef)
) : CellValue
  case agg
    CountAll: NumberVal(target_cells.size.to_decimal)
    CountValues: NumberVal(non_empty_cells(target_cells).size.to_decimal)
    PercentPerGroup:
      if target_cells.empty?
        NumberVal(zero_decimal())
      else
        var done_cnt = 0
        for c in target_cells
          if rollup_cell_done?(c, target_prop)
            done_cnt += 1
          end
        end
        ratio = (done_cnt.to_decimal / target_cells.size.to_decimal).round(4)
        NumberVal(ratio)
      end
    SumValues:
      var acc = zero_decimal()
      var count = 0
      for c in target_cells
        case c
          NumberVal(d):
            acc += d
            count += 1
          Empty | TextVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
            option_ids: _
          ) | BoolVal(_) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(
            row_ids: _
          ): Unit
        end
      end
      if count == 0: NumberVal(zero_decimal()) else: NumberVal(acc)
    MinValue:
      var best_num = None
      var best_date = None
      for c in target_cells
        case c
          NumberVal(d): best_num = case best_num
            None: Some(d)
            Some(cur): Some(if d < cur: d else: cur)
          end
          DateVal(start: dt, end_date: _): best_date = case best_date
            None: Some(dt)
            Some(cur): Some(if dt < cur: dt else: cur)
          end
          Empty | TextVal(_) | SelectVal(option_id: _) | MultiSelectVal(option_ids: _) | BoolVal(_) | PrincipalVal(
            _
          ) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): Unit
        end
      end
      case best_num
        Some(n): NumberVal(n)
        None:
          case best_date
            Some(dt): DateVal(start: dt, end_date: None)
            None: Empty
          end
      end
    MaxValue:
      var best_num = None
      var best_date = None
      for c in target_cells
        case c
          NumberVal(d): best_num = case best_num
            None: Some(d)
            Some(cur): Some(if d > cur: d else: cur)
          end
          DateVal(start: dt, end_date: _): best_date = case best_date
            None: Some(dt)
            Some(cur): Some(if dt > cur: dt else: cur)
          end
          Empty | TextVal(_) | SelectVal(option_id: _) | MultiSelectVal(option_ids: _) | BoolVal(_) | PrincipalVal(
            _
          ) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): Unit
        end
      end
      case best_num
        Some(n): NumberVal(n)
        None:
          case best_date
            Some(dt): DateVal(start: dt, end_date: None)
            None: Empty
          end
      end
  end
end

## Computes a `Rollup` cell using exact `Decimal` arithmetic (`SumValues`, `MinValue`, `MaxValue`, etc.).
fn compute_rollup(agg: RollupAgg, target_cells: List(CellValue)) : CellValue
  compute_rollup_with_target(agg, target_cells, None)
end

## Reads a property's effective cell from either stored row cells or computed rollups.
fn effective_cell(erow: EnrichedRow, prop_id: Text) : CellValue
  case erow.row.cells.get(prop_id)
    Some(c): c
    None: erow.rollups.get(prop_id) or Empty
  end
end

fn json_to_text(j: Json) : Option(Text)
  case j
    Json.String(s): Some(s)
    Json.Number(n): Some(n.to_text)
    Json.Boolean(b): Some(if b: "true" else: "false")
    Json.Null | Json.Array(_) | Json.Object(_): None
  end
end

fn json_to_decimal(j: Json) : Option(Decimal)
  case j
    Json.Number(n): n.to_decimal
    Json.String(s): s.trim.to_decimal
    Json.Null | Json.Boolean(_) | Json.Array(_) | Json.Object(_): None
  end
end

fn json_to_date(j: Json) : Option(Date.Date)
  case j
    Json.String(s): Date.parse_iso(s.trim)
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): None
  end
end

fn json_to_text_list(j: Json) : List(Text)
  case j
    Json.Array(items):
      var out = []
      for item in items
        case json_to_text(item)
          Some(s): out = out.append(s)
          None: Unit
        end
      end
      out
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): []
  end
end

fn cell_equals_json?(cell: CellValue, target: Json) : Bool
  case cell
    Empty: target == Json.Null
    TextVal(s) | UrlVal(s):
      case json_to_text(target)
        Some(t): s == t
        None: false
      end
    NumberVal(d):
      case json_to_decimal(target)
        Some(td): d == td
        None: false
      end
    DateVal(start: dt, end_date: _):
      case json_to_date(target)
        Some(td): dt == td
        None: false
      end
    SelectVal(option_id: oid):
      case json_to_text(target)
        Some(t): oid == t
        None: false
      end
    BoolVal(b):
      case target
        Json.Boolean(tb): b == tb
        Json.String(s):
          low = s.trim.ascii_lowercase
          (b and low == "true") or (not b and low == "false")
        Json.Null | Json.Number(_) | Json.Array(_) | Json.Object(_): false
      end
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | FilesVal(attachment_ids: xs) | RelationVal(
      row_ids: xs
    ):
      case target
        Json.String(t): xs.contains?(t)
        Json.Array(_): xs == json_to_text_list(target)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Object(_): false
      end
  end
end

fn cell_compare_json(cell: CellValue, target: Json) : Option(Int)
  case cell
    NumberVal(d): json_to_decimal(target).map(fn(td)
      if d < td
        -1
      else if d > td
        1
      else
        0
      end
    end)
    DateVal(start: dt, end_date: _): json_to_date(target).map(fn(td)
      if dt < td
        -1
      else if dt > td
        1
      else
        0
      end
    end)
    TextVal(s) | UrlVal(s) | SelectVal(option_id: s): json_to_text(target).map(fn(ts)
      if s < ts
        -1
      else if s > ts
        1
      else
        0
      end
    end)
    Empty | MultiSelectVal(option_ids: _) | BoolVal(_) | PrincipalVal(_) | FilesVal(
      attachment_ids: _
    ) | RelationVal(row_ids: _): None
  end
end

fn cell_contains_text?(cell: CellValue, needle_raw: Text) : Bool
  needle = needle_raw.ascii_lowercase
  return false if needle.empty?
  case cell
    Empty: false
    TextVal(s) | UrlVal(s) | SelectVal(option_id: s): s.ascii_lowercase.contains?(needle)
    NumberVal(d): d.to_text.contains?(needle)
    DateVal(start: st, end_date: ed_opt): st.to_iso.contains?(needle) or (
      case ed_opt
        Some(ed): ed.to_iso.contains?(needle)
        None: false
      end
    )
    BoolVal(b): (if b: "true" else: "false").contains?(needle)
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | FilesVal(attachment_ids: xs) | RelationVal(
      row_ids: xs
    ): xs.any?(fn(x) x.ascii_lowercase.contains?(needle) end)
  end
end

fn cell_in_set?(cell: CellValue, allowed: List(Text)) : Bool
  case cell
    Empty: false
    SelectVal(option_id: oid): allowed.contains?(oid)
    TextVal(s) | UrlVal(s): allowed.contains?(s)
    DateVal(start: st, end_date: _): allowed.contains?(st.to_iso)
    NumberVal(d): allowed.any?(fn(x)
      case x.trim.to_decimal
        Some(td): d == td
        None: x == d.to_text
      end
    end)
    BoolVal(b): allowed.contains?(if b: "true" else: "false")
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | FilesVal(attachment_ids: xs) | RelationVal(
      row_ids: xs
    ): xs.any?(fn(x) allowed.contains?(x) end)
  end
end

## Evaluates a single `DbFilterRule` against an `EnrichedRow`.
fn matches_filter?(erow: EnrichedRow, rule: DbFilterRule) : Bool
  cell = effective_cell(erow, rule.prop_id)
  case rule.op
    IsEmpty: cell_empty?(cell)
    IsNotEmpty: not cell_empty?(cell)
    Eq: cell_equals_json?(cell, rule.value)
    Neq: not cell_equals_json?(cell, rule.value)
    Gt:
      case cell_compare_json(cell, rule.value)
        Some(c): c > 0
        None: false
      end
    Gte:
      case cell_compare_json(cell, rule.value)
        Some(c): c >= 0
        None: false
      end
    Lt:
      case cell_compare_json(cell, rule.value)
        Some(c): c < 0
        None: false
      end
    Lte:
      case cell_compare_json(cell, rule.value)
        Some(c): c <= 0
        None: false
      end
    Contains:
      case json_to_text(rule.value)
        Some(needle): cell_contains_text?(cell, needle)
        None: false
      end
    InSet: cell_in_set?(cell, json_to_text_list(rule.value))
  end
end

## Evaluates AND (`match_all = true`) or OR (`match_all = false`) across `rules`.
fn matches_filters?(erow: EnrichedRow, rules: List(DbFilterRule), match_all?: Bool) : Bool
  return true if rules.empty?
  if match_all?
    rules.all?(fn(r) matches_filter?(erow, r) end)
  else
    rules.any?(fn(r) matches_filter?(erow, r) end)
  end
end

fn cell_sort_text(cell: CellValue) : Text
  case cell
    Empty: ""
    TextVal(s) | UrlVal(s) | SelectVal(option_id: s): s.ascii_lowercase
    NumberVal(d): d.to_text
    DateVal(start: dt, end_date: _): dt.to_iso
    BoolVal(b): if b: "1" else: "0"
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | FilesVal(attachment_ids: xs) | RelationVal(
      row_ids: xs
    ): xs.join(",")
  end
end

fn compare_cell(a: CellValue, b: CellValue) : Int
  a_empty = cell_empty?(a)
  b_empty = cell_empty?(b)
  return 0 if a_empty and b_empty
  return 1 if a_empty
  return -1 if b_empty

  case (a, b)
    (NumberVal(da), NumberVal(db)):
      if da < db
        -1
      else if da > db
        1
      else
        0
      end
    (DateVal(start: da, end_date: _), DateVal(start: db, end_date: _)):
      if da < db
        -1
      else if da > db
        1
      else
        0
      end
    (BoolVal(ba), BoolVal(bb)):
      if ba == bb
        0
      else if not ba and bb
        -1
      else
        1
      end
    (_, _):
      sa = cell_sort_text(a)
      sb = cell_sort_text(b)
      if sa < sb
        -1
      else if sa > sb
        1
      else
        0
      end
  end
end

fn compare_enriched_rows(a: EnrichedRow, b: EnrichedRow, sorts: List(DbSortRule)) : Int
  for s in sorts
    ca = effective_cell(a, s.prop_id)
    cb = effective_cell(b, s.prop_id)
    a_empty = cell_empty?(ca)
    b_empty = cell_empty?(cb)
    if a_empty and not b_empty
      return 1
    else if not a_empty and b_empty
      return -1
    else if not a_empty and not b_empty
      c = compare_cell(ca, cb)
      if c != 0
        return if s.desc: -c else: c
      end
    end
  end
  if a.row.id < b.row.id
    -1
  else if a.row.id > b.row.id
    1
  else
    0
  end
end

fn merge_sorted_rows(left: List(EnrichedRow), right: List(EnrichedRow), sorts: List(DbSortRule)) : List(
  EnrichedRow
)
  var i = 0
  var j = 0
  var out = []
  while i < left.size and j < right.size
    a = left.get(i) or stop "left"
    b = right.get(j) or stop "right"
    if compare_enriched_rows(a, b, sorts) <= 0
      out = out.append(a)
      i += 1
    else
      out = out.append(b)
      j += 1
    end
  end
  while i < left.size
    out = out.append(left.get(i) or stop "left tail")
    i += 1
  end
  while j < right.size
    out = out.append(right.get(j) or stop "right tail")
    j += 1
  end
  out
end

## Sorts `EnrichedRow`s deterministically according to multi-column `DbSortRule`s (`Empty` always last).
fn sort_enriched_rows(rows: List(EnrichedRow), sorts: List(DbSortRule)) : List(EnrichedRow)
  n = rows.size
  return rows if n <= 1
  mid = n.floor_div(2)
  left = sort_enriched_rows(rows.take(mid), sorts)
  right = sort_enriched_rows(rows.drop(mid), sorts)
  merge_sorted_rows(left, right, sorts)
end

## Groups filtered/sorted rows into Kanban columns defined by a `Select`, `Status`, or `Checkbox` property.
fn group_rows_for_board(
  def: DatabaseDef,
  rows: List(EnrichedRow),
  group_by_prop_id: Text,
  hide_empty: Bool
) : List(BoardGroup)
  var prop_opt = None
  for p in def.properties
    if p.id == group_by_prop_id
      prop_opt = Some(p)
    end
  end

  var ordered_buckets = []
  case prop_opt
    Some(p):
      case p.kind
        Select(options: opts) | Status(options: opts, done_option_ids: _):
          for o in opts
            ordered_buckets = ordered_buckets.append((o.id, o.label))
          end
        Checkbox: ordered_buckets = [("true", "Checked"), ("false", "Unchecked")]
        AiDerived(
          prompt: _,
          source_prop_ids: _,
          include_row_body: _,
          output_kind: out_k,
          mode: _,
          daily_call_cap: _
        ):
          case out_k
            AiSelect(options: opts):
              for o in opts
                ordered_buckets = ordered_buckets.append((o.id, o.label))
              end
            AiBool: ordered_buckets = [("true", "Checked"), ("false", "Unchecked")]
            AiText | AiNumber(format: _) | AiDate: Unit
          end
        Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) | Person | Email | FileList | Url | UniqueId(
          prefix: _
        ) | Formula(expression: _, format: _) | CreatedTime | CreatedBy | LastEditedTime | LastEditedBy | Relation(
          target_db_id: _,
          inverse_prop_id: _
        ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): Unit
      end
    None: Unit
  end
  ordered_buckets = ordered_buckets.append(("__none__", "No Status"))

  var grouped = {}
  for r in rows
    gkey = case effective_cell(r, group_by_prop_id)
      SelectVal(option_id: oid) if not oid.trim.empty?: oid
      BoolVal(b): if b: "true" else: "false"
      TextVal(s) if not s.trim.empty?: s.trim
      Empty | TextVal(_) | SelectVal(option_id: _) | NumberVal(_) | DateVal(start: _, end_date: _) | MultiSelectVal(
        option_ids: _
      ) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): "__none__"
    end
    cur = grouped.get(gkey) or []
    grouped = grouped.set(gkey, cur.append(r))
  end

  var groups = []
  for (gkey, label) in ordered_buckets
    bucket_rows = grouped.get(gkey) or []
    if not hide_empty or not bucket_rows.empty?
      groups = groups.append(BoardGroup(group_key: gkey, label: label, rows: bucket_rows))
    end
  end
  groups
end

## Filters rows whose `DateProp` interval `[start, end_date]` overlaps `[from_date, to_date]`.
fn filter_calendar_range(
  rows: List(EnrichedRow),
  date_prop_id: Text,
  from_date: Option(Date.Date),
  to_date: Option(Date.Date)
) : List(EnrichedRow)
  var out = []
  for r in rows
    case effective_cell(r, date_prop_id)
      DateVal(start: st, end_date: ed_opt):
        eff_end = ed_opt or st
        after_from = case from_date
          Some(f): eff_end >= f
          None: true
        end
        before_to = case to_date
          Some(t): st <= t
          None: true
        end
        if after_from and before_to
          out = out.append(r)
        end
      Empty | TextVal(_) | NumberVal(_) | SelectVal(option_id: _) | MultiSelectVal(option_ids: _) | BoolVal(
        _
      ) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): Unit
    end
  end
  out
end

fn timeline_row_span(
  r: EnrichedRow,
  start_prop_id: Text,
  end_prop_id_opt: Option(Text)
) : Option((Date.Date, Date.Date))
  case effective_cell(r, start_prop_id)
    DateVal(start: st, end_date: inline_end):
      explicit_end = case end_prop_id_opt
        Some(ep_id):
          case effective_cell(r, ep_id)
            DateVal(start: est, end_date: eed_opt): Some(eed_opt or est)
            Empty | TextVal(_) | NumberVal(_) | SelectVal(option_id: _) | MultiSelectVal(
              option_ids: _
            ) | BoolVal(_) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(
              row_ids: _
            ): None
          end
        None: None
      end
      eff_end = case explicit_end
        Some(d): d
        None: inline_end or st
      end
      final_end = if eff_end < st: st else: eff_end
      Some((st, final_end))
    Empty | TextVal(_) | NumberVal(_) | SelectVal(option_id: _) | MultiSelectVal(option_ids: _) | BoolVal(
      _
    ) | PrincipalVal(_) | FilesVal(attachment_ids: _) | UrlVal(_) | RelationVal(row_ids: _): None
  end
end

## Filters rows overlapping optional `[from_date, to_date]` across `[start_date_prop_id, end_date_prop_id]`
## and sorts scheduled items chronologically ascending (unscheduled rows retained at the end when unfiltered).
fn filter_timeline_range(
  rows: List(EnrichedRow),
  start_prop_id: Text,
  end_prop_id_opt: Option(Text),
  from_date: Option(Date.Date),
  to_date: Option(Date.Date)
) : List(EnrichedRow)
  has_bound = from_date != None or to_date != None
  var scheduled = []
  var unscheduled = []
  for r in rows
    case timeline_row_span(r, start_prop_id, end_prop_id_opt)
      Some((st, eff_end)):
        after_from = case from_date
          Some(f): eff_end >= f
          None: true
        end
        before_to = case to_date
          Some(t): st <= t
          None: true
        end
        if after_from and before_to
          scheduled = scheduled.append((st.to_iso, r))
        end
      None:
        if not has_bound
          unscheduled = unscheduled.append(r)
        end
    end
  end
  ordered = scheduled.sort_by(fn(pair) pair.0 end).map(fn(pair) pair.1 end)
  ordered.concat(unscheduled)
end

## Extracts searchable plain text from a `DbRow`'s cells for `Modb.Fts` indexing.
fn row_plain_text(def: DatabaseDef, row: DbRow) : Text
  var parts = []
  for p in def.properties
    case row.cells.get(p.id)
      Some(TextVal(s)) | Some(UrlVal(s)):
        if not s.trim.empty?
          parts = parts.append(s.trim)
        end
      Some(SelectVal(option_id: oid)):
        case p.kind
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
                parts = parts.append(o.label)
              end
            end
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
          ): Unit
        end
      Some(MultiSelectVal(option_ids: oids)):
        case p.kind
          MultiSelect(options: opts):
            for o in opts
              if oids.contains?(o.id)
                parts = parts.append(o.label)
              end
            end
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
          ): Unit
        end
      Some(NumberVal(d)): parts = parts.append(d.to_text)
      Some(DateVal(start: st, end_date: _)): parts = parts.append(st.to_iso)
      Some(FilesVal(attachment_ids: aids)):
        if not aids.empty?
          parts = parts.append(aids.join(" "))
        end
      Some(Empty) | Some(BoolVal(_)) | Some(PrincipalVal(_)) | Some(RelationVal(row_ids: _)) | None: Unit
    end
  end
  parts.join("\n")
end

fn decode_strict_string_list(j: Json) : Result(List(Text), Text)
  items = case j
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): return Error(
      "expected JSON array of strings"
    )
  end
  var out = []
  for item in items
    case item
      Json.String(s): out = out.append(s)
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): return Error(
        "expected string array element"
      )
    end
  end
  Ok(out)
end

fn decode_cell_value_json(v: Json) : Result(CellValue, Text)
  case v
    Json.String(s):
      if s == "empty"
        Ok(Empty)
      else
        Error("unknown CellValue string '#{s}'")
      end
    Json.Object(m):
      entries = m.entries
      if entries.size != 1
        return Error("expected single-key CellValue object")
      end
      (k, val) = entries.first or ("", Json.Null)
      if k == "text_val"
        case val
          Json.String(s): Ok(TextVal(s))
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): Error(
            "text_val must be a string"
          )
        end
      else if k == "url_val"
        case val
          Json.String(s): Ok(UrlVal(s))
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): Error(
            "url_val must be a string"
          )
        end
      else if k == "bool_val"
        case val
          Json.Boolean(b): Ok(BoolVal(b))
          Json.Null | Json.Number(_) | Json.String(_) | Json.Array(_) | Json.Object(_): Error(
            "bool_val must be a boolean"
          )
        end
      else if k == "number_val"
        case json_to_decimal(val)
          Some(d): Ok(NumberVal(d))
          None: Error("number_val must be a decimal number")
        end
      else if k == "date_val"
        case val
          Json.Object(_): Unit
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
            "date_val must be a JSON object"
          )
        end
        st = case json_to_date(val.get("start") or Json.Null)
          Some(d): d
          None: return Error("date_val missing valid ISO 'start' date")
        end
        ed_opt = case val.get("end_date")
          Some(Json.Null) | None: None
          Some(edv):
            case json_to_date(edv)
              Some(ed): Some(ed)
              None: return Error("date_val has invalid 'end_date'")
            end
        end
        Ok(DateVal(start: st, end_date: ed_opt))
      else if k == "select_val"
        case val
          Json.Object(_): Unit
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
            "select_val must be a JSON object"
          )
        end
        case val.text_at("option_id")
          Some(oid): Ok(SelectVal(option_id: oid))
          None: Error("select_val missing 'option_id'")
        end
      else if k == "multi_select_val"
        case val
          Json.Object(_): Unit
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
            "multi_select_val must be a JSON object"
          )
        end
        oids = try decode_strict_string_list(val.get("option_ids") or Json.Null)
        Ok(MultiSelectVal(option_ids: oids))
      else if k == "principal_val"
        pids = try decode_strict_string_list(val)
        Ok(PrincipalVal(pids))
      else if k == "files_val"
        case val
          Json.Object(_): Unit
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
            "files_val must be a JSON object"
          )
        end
        aids = try decode_strict_string_list(val.get("attachment_ids") or Json.Null)
        Ok(FilesVal(attachment_ids: aids))
      else if k == "relation_val"
        case val
          Json.Object(_): Unit
          Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
            "relation_val must be a JSON object"
          )
        end
        rids = try decode_strict_string_list(val.get("row_ids") or Json.Null)
        Ok(RelationVal(row_ids: rids))
      else
        Error("unknown CellValue variant '#{k}'")
      end
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_): Error(
      "expected CellValue string or variant object"
    )
  end
end

## Decodes a JSON object into `Map(Text, CellValue)` without generic `Json.decode_strict` lowering.
fn decode_cell_map_json(raw: Bytes) : Result(Map(Text, CellValue), Text)
  txt = case raw.decode_utf8
    Some(s): s
    None: return Error("expected valid UTF-8 JSON")
  end
  parsed = case Json.parse(txt)
    Ok(j): j
    Error(e): return Error(e.to_text)
  end
  obj = case parsed
    Json.Object(m): m
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
      "expected cell map JSON object"
    )
  end
  var out = {}
  for (k, v) in obj.entries
    cv = try decode_cell_value_json(v)
    out = out.set(k, cv)
  end
  Ok(out)
end

fn req_obj_text(j: Json, field: Text) : Result(Text, Text)
  case j.text_at(field)
    Some(s): Ok(s)
    None: Error("missing string field '#{field}'")
  end
end

fn req_obj_opt_text(j: Json, field: Text) : Result(Option(Text), Text)
  case j.get(field)
    None | Some(Json.Null): Ok(None)
    Some(Json.String(s)): Ok(Some(s))
    Some(Json.Boolean(_)) | Some(Json.Number(_)) | Some(Json.Array(_)) | Some(Json.Object(_)):
      Error("field '#{field}' must be string or null")
  end
end

fn req_obj_bool(j: Json, field: Text) : Result(Bool, Text)
  case j.get(field)
    Some(Json.Boolean(b)): Ok(b)
    None | Some(Json.Null) | Some(Json.Number(_)) | Some(Json.String(_)) | Some(Json.Array(_)) |
      Some(Json.Object(_)): Error("missing boolean field '#{field}'")
  end
end

fn req_obj_int(j: Json, field: Text) : Result(Int, Text)
  case j.int_at(field)
    Some(n): Ok(n)
    None: Error("missing integer field '#{field}'")
  end
end

fn decode_select_color_json(raw: Text) : Result(SelectOptionColor, Text)
  if raw == "gray"
    Ok(Gray)
  else if raw == "blue"
    Ok(Blue)
  else if raw == "green"
    Ok(Green)
  else if raw == "amber"
    Ok(Amber)
  else if raw == "red"
    Ok(Red)
  else if raw == "purple"
    Ok(Purple)
  else
    Error("unknown option color '#{raw}'")
  end
end

fn decode_select_options_json(j: Json) : Result(List(SelectOption), Text)
  arr = case j
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): return Error(
      "expected options JSON array"
    )
  end
  var out = []
  for item in arr
    case item
      Json.Object(_): Unit
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
        "option item must be a JSON object"
      )
    end
    oid = try req_obj_text(item, "id")
    lbl = try req_obj_text(item, "label")
    col_str = try req_obj_text(item, "color")
    col = try decode_select_color_json(col_str)
    out = out.append(SelectOption(id: oid, label: lbl, color: col))
  end
  Ok(out)
end

fn decode_rollup_agg_json(j: Json) : Result(RollupAgg, Text)
  s = case j
    Json.String(raw): raw
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): return Error(
      "rollup agg must be a string"
    )
  end
  if s == "count_all"
    Ok(CountAll)
  else if s == "count_values"
    Ok(CountValues)
  else if s == "sum_values"
    Ok(SumValues)
  else if s == "min_value"
    Ok(MinValue)
  else if s == "max_value"
    Ok(MaxValue)
  else if s == "percent_per_group"
    Ok(PercentPerGroup)
  else
    Error("unknown rollup agg '#{s}'")
  end
end

fn decode_ai_output_kind_json(j: Json) : Result(AiOutputKind, Text)
  case j
    Json.String(s):
      if s == "ai_text"
        Ok(AiText)
      else if s == "ai_date"
        Ok(AiDate)
      else if s == "ai_bool"
        Ok(AiBool)
      else
        Error("unknown AiOutputKind '#{s}'")
      end
    Json.Object(m):
      if m.entries.size != 1
        return Error("expected single-key AiOutputKind object")
      end
      (k, val) = m.entries.first or ("", Json.Null)
      case val
        Json.Object(_): Unit
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
          "AiOutputKind payload must be an object"
        )
      end
      if k == "ai_number"
        Ok(AiNumber(format: try req_obj_text(val, "format")))
      else if k == "ai_select"
        opts = try decode_select_options_json(val.get("options") or Json.Null)
        Ok(AiSelect(options: opts))
      else
        Error("unknown AiOutputKind object '#{k}'")
      end
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_): Error(
      "invalid AiOutputKind JSON"
    )
  end
end

fn decode_ai_col_mode_json(j: Json) : Result(AiColumnMode, Text)
  s = case j
    Json.String(raw): raw
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): return Error(
      "AiColumnMode must be a string"
    )
  end
  if s == "auto_apply"
    Ok(AutoApply)
  else if s == "stage_proposal"
    Ok(StageProposal)
  else
    Error("unknown AiColumnMode '#{s}'")
  end
end

fn decode_property_kind_json(j: Json) : Result(PropertyKind, Text)
  case j
    Json.String(s):
      if s == "title"
        Ok(Title)
      else if s == "rich_text"
        Ok(RichText)
      else if s == "checkbox"
        Ok(Checkbox)
      else if s == "person"
        Ok(Person)
      else if s == "email"
        Ok(Email)
      else if s == "file_list"
        Ok(FileList)
      else if s == "url"
        Ok(Url)
      else if s == "created_time"
        Ok(CreatedTime)
      else if s == "created_by"
        Ok(CreatedBy)
      else if s == "last_edited_time"
        Ok(LastEditedTime)
      else if s == "last_edited_by"
        Ok(LastEditedBy)
      else
        Error("unknown PropertyKind string '#{s}'")
      end
    Json.Object(m):
      if m.entries.size != 1
        return Error("expected single-key PropertyKind object")
      end
      (k, val) = m.entries.first or ("", Json.Null)
      case val
        Json.Object(_): Unit
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
          "PropertyKind payload must be an object"
        )
      end
      if k == "number"
        Ok(Number(format: try req_obj_text(val, "format")))
      else if k == "date_prop"
        Ok(DateProp(include_time: try req_obj_bool(val, "include_time")))
      else if k == "select"
        Ok(Select(options: try decode_select_options_json(val.get("options") or Json.Null)))
      else if k == "multi_select"
        Ok(MultiSelect(options: try decode_select_options_json(val.get("options") or Json.Null)))
      else if k == "status"
        opts = try decode_select_options_json(val.get("options") or Json.Null)
        done_ids = try decode_strict_string_list(val.get("done_option_ids") or Json.Null)
        Ok(Status(options: opts, done_option_ids: done_ids))
      else if k == "unique_id"
        Ok(UniqueId(prefix: try req_obj_text(val, "prefix")))
      else if k == "formula"
        expr = try req_obj_text(val, "expression")
        fmt = try req_obj_text(val, "format")
        Ok(Formula(expression: expr, format: fmt))
      else if k == "relation"
        tid = try req_obj_text(val, "target_db_id")
        inv = try req_obj_opt_text(val, "inverse_prop_id")
        Ok(Relation(target_db_id: tid, inverse_prop_id: inv))
      else if k == "rollup"
        rpid = try req_obj_text(val, "relation_prop_id")
        tpid = try req_obj_text(val, "target_prop_id")
        agg = try decode_rollup_agg_json(val.get("agg") or Json.Null)
        Ok(Rollup(relation_prop_id: rpid, target_prop_id: tpid, agg: agg))
      else if k == "ai_derived"
        prompt = try req_obj_text(val, "prompt")
        srcs = try decode_strict_string_list(val.get("source_prop_ids") or Json.Null)
        inc_body = try req_obj_bool(val, "include_row_body")
        okind = try decode_ai_output_kind_json(val.get("output_kind") or Json.Null)
        mode = try decode_ai_col_mode_json(val.get("mode") or Json.Null)
        cap = try req_obj_int(val, "daily_call_cap")
        Ok(
          AiDerived(
            prompt: prompt,
            source_prop_ids: srcs,
            include_row_body: inc_body,
            output_kind: okind,
            mode: mode,
            daily_call_cap: cap
          )
        )
      else
        Error("unknown PropertyKind object '#{k}'")
      end
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_): Error("invalid PropertyKind JSON")
  end
end

## Decodes a JSON array into `List(PropertyDef)` without generic `Json.decode_strict` lowering.
fn decode_property_defs_json(raw: Bytes) : Result(List(PropertyDef), Text)
  txt = case raw.decode_utf8
    Some(s): s
    None: return Error("expected valid UTF-8 JSON")
  end
  parsed = case Json.parse(txt)
    Ok(j): j
    Error(e): return Error(e.to_text)
  end
  items = case parsed
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): return Error(
      "expected property definitions JSON array"
    )
  end
  var out = []
  for item in items
    case item
      Json.Object(_): Unit
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
        "property definition must be a JSON object"
      )
    end
    pid = try req_obj_text(item, "id")
    pname = try req_obj_text(item, "name")
    pkind = try decode_property_kind_json(item.get("kind") or Json.Null)
    preq = try req_obj_bool(item, "required")
    psort = try req_obj_text(item, "sort_order")
    out = out.append(
      PropertyDef(id: pid, name: pname, kind: pkind, required: preq, sort_order: psort)
    )
  end
  Ok(out)
end

## Decodes a JSON array into `List(DbFilterRule)` without generic `Json.decode_strict` lowering.
fn decode_filter_rules_json(raw: Bytes) : Result(List(DbFilterRule), Text)
  txt = case raw.decode_utf8
    Some(s): s
    None: return Error("expected valid UTF-8 JSON")
  end
  parsed = case Json.parse(txt)
    Ok(j): j
    Error(e): return Error(e.to_text)
  end
  items = case parsed
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): return Error(
      "expected JSON array"
    )
  end
  var out = []
  for item in items
    case item
      Json.Object(_): Unit
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
        "expected filter rule object"
      )
    end
    prop_id = case item.text_at("prop_id")
      Some(s): s
      None: return Error("missing 'prop_id'")
    end
    op_str = case item.text_at("op")
      Some(s): s
      None: return Error("missing 'op'")
    end
    op = if op_str == "eq"
      Eq
    else if op_str == "neq"
      Neq
    else if op_str == "gt"
      Gt
    else if op_str == "gte"
      Gte
    else if op_str == "lt"
      Lt
    else if op_str == "lte"
      Lte
    else if op_str == "contains"
      Contains
    else if op_str == "in_set"
      InSet
    else if op_str == "is_empty"
      IsEmpty
    else if op_str == "is_not_empty"
      IsNotEmpty
    else
      return Error("invalid filter op '#{op_str}'")
    end
    val = item.get("value") or Json.Null
    out = out.append(DbFilterRule(prop_id: prop_id, op: op, value: val))
  end
  Ok(out)
end

## Decodes a JSON array into `List(DbSortRule)` without generic `Json.decode_strict` lowering.
fn decode_sort_rules_json(raw: Bytes) : Result(List(DbSortRule), Text)
  txt = case raw.decode_utf8
    Some(s): s
    None: return Error("expected valid UTF-8 JSON")
  end
  parsed = case Json.parse(txt)
    Ok(j): j
    Error(e): return Error(e.to_text)
  end
  items = case parsed
    Json.Array(xs): xs
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Object(_): return Error(
      "expected JSON array"
    )
  end
  var out = []
  for item in items
    case item
      Json.Object(_): Unit
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
        "expected sort rule object"
      )
    end
    prop_id = case item.text_at("prop_id")
      Some(s): s
      None: return Error("missing 'prop_id'")
    end
    desc = case item.bool_at("desc")
      Some(b): b
      None: return Error("missing 'desc'")
    end
    out = out.append(DbSortRule(prop_id: prop_id, desc: desc))
  end
  Ok(out)
end

## Rejects any attempt to overwrite an auto-assigned `UniqueId` property value after row creation.
fn check_unique_id_immutable(
  def: DatabaseDef,
  old_cells: Map(Text, CellValue),
  updates: Map(Text, CellValue)
) : Result(Unit, Text)
  for p in def.properties
    if p.kind is UniqueId(prefix: _)
      case (old_cells.get(p.id), updates.get(p.id))
        (Some(ov), Some(nv)) if ov != nv:
          return Error("UniqueId property '#{p.id}' cannot be modified after creation")
        (_, _): Unit
      end
    end
  end
  Ok(Unit)
end
