## Relational Database schemas, exact Decimal/Date cells, Relation/Rollup evaluation,
## and Table/Board/Calendar Multi-View filter, sort, and grouping logic.
module Domain.DatabaseModel
expose SelectOptionColor(..),
SelectOption(..),
RollupAgg(..),
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
validate_database_def,
validate_cell,
validate_row_cells,
extract_row_title,
cell_index_tokens,
compute_rollup,
effective_cell,
matches_filter?,
matches_filters?,
sort_enriched_rows,
group_rows_for_board,
filter_calendar_range,
row_plain_text
use Date
use Json

## Visual badge color for `Select` and `MultiSelect` property options.
enum SelectOptionColor
  Gray
  Blue
  Green
  Amber
  Red
  Purple
end

## Allowed discrete choice within a `Select` or `MultiSelect` column.
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
end

## Strongly typed column schema variants for Vellum relational databases.
enum PropertyKind
  Title
  RichText
  Number(format: Text)
  DateProp(include_time: Bool)
  Select(options: List(SelectOption))
  MultiSelect(options: List(SelectOption))
  Checkbox
  Person
  Url
  Relation(target_db_id: Text, inverse_prop_id: Option(Text))
  Rollup(relation_prop_id: Text, target_prop_id: Text, agg: RollupAgg)
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

## View presentation configuration for Table, Kanban Board, or Calendar views.
enum DbViewKind
  TableView(visible_prop_ids: List(Text), column_widths: Map(Text, Int))
  BoardView(group_by_prop_id: Text, card_prop_ids: List(Text), hide_empty_groups: Bool)
  CalendarView(date_prop_id: Text, card_prop_ids: List(Text))
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

## Validates a `DatabaseDef` schema (non-empty title, unique props, >= 1 `Title`, valid rollups).
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
      Relation(target_db_id: tdb, inverse_prop_id: _):
        if tdb.trim.empty?
          return Some("relation property '#{pid}' requires non-empty target_db_id")
        end
      RichText | DateProp(include_time: _) | Checkbox | Person | Url | Rollup(
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
              ) | Checkbox | Person | Url | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): return Some(
                "rollup '#{p.id}' source '#{rel_id}' is not a Relation property"
              )
            end
        end
      Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | MultiSelect(
        options: _
      ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _): Unit
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
    Empty: return if prop.required: Some("required property '#{prop.id}' cannot be Empty") else: None
    TextVal(_) | NumberVal(_) | DateVal(start: _, end_date: _) | SelectVal(option_id: _) | MultiSelectVal(
      option_ids: _
    ) | BoolVal(_) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
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
    (Select(options: opts), SelectVal(option_id: oid)):
      if has_option_id?(opts, oid)
        None
      else
        Some("invalid select option '#{oid}' for property '#{prop.id}'")
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
    (Url, UrlVal(u)):
      trimmed = u.trim
      if trimmed.starts_with?("https://") or trimmed.starts_with?("http://")
        None
      else
        Some("Url property '#{prop.id}' must start with http:// or https://")
      end
    (Relation(target_db_id: _, inverse_prop_id: _), RelationVal(row_ids: rids)):
      if rids.any?(fn(x) x.trim.empty? end)
        Some("Relation property '#{prop.id}' contains blank row ID")
      else
        None
      end
    (Rollup(relation_prop_id: _, target_prop_id: _, agg: _), _): Some(
      "Rollup property '#{prop.id}' is computed dynamically and cannot be written directly"
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
    if p.required
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
      ) | Checkbox | Person | Url | Relation(target_db_id: _, inverse_prop_id: _) | Rollup(
        relation_prop_id: _,
        target_prop_id: _,
        agg: _
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
    RelationVal(row_ids: rids): rids.map(fn(rid) (prop_id, rid) end)
  end
end

fn non_empty_cells(cells: List(CellValue)) : List(CellValue)
  cells.filter(fn(c) not cell_empty?(c) end)
end

## Computes a `Rollup` cell using exact `Decimal` arithmetic (`SumValues`, `MinValue`, `MaxValue`, etc.).
fn compute_rollup(agg: RollupAgg, target_cells: List(CellValue)) : CellValue
  case agg
    CountAll: NumberVal(target_cells.size.to_decimal)
    CountValues: NumberVal(non_empty_cells(target_cells).size.to_decimal)
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
          ) | BoolVal(_) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
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
          ) | UrlVal(_) | RelationVal(row_ids: _): Unit
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
          ) | UrlVal(_) | RelationVal(row_ids: _): Unit
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
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | RelationVal(row_ids: xs):
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
    Empty | MultiSelectVal(option_ids: _) | BoolVal(_) | PrincipalVal(_) | RelationVal(row_ids: _): None
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
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | RelationVal(row_ids: xs): xs.any?(
      fn(x) x.ascii_lowercase.contains?(needle) end
    )
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
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | RelationVal(row_ids: xs): xs.any?(
      fn(x) allowed.contains?(x) end
    )
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
    MultiSelectVal(option_ids: xs) | PrincipalVal(xs) | RelationVal(row_ids: xs): xs.join(",")
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

## Groups filtered/sorted rows into Kanban columns defined by a `Select` or `Checkbox` property.
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
        Select(options: opts):
          for o in opts
            ordered_buckets = ordered_buckets.append((o.id, o.label))
          end
        Checkbox: ordered_buckets = [("true", "Checked"), ("false", "Unchecked")]
        Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) | Person | Url | Relation(
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
      ) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): "__none__"
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
      ) | PrincipalVal(_) | UrlVal(_) | RelationVal(row_ids: _): Unit
    end
  end
  out
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
          Select(options: opts):
            for o in opts
              if o.id == oid
                parts = parts.append(o.label)
              end
            end
          Title | RichText | Number(format: _) | DateProp(include_time: _) | MultiSelect(options: _) | Checkbox | Person | Url | Relation(
            target_db_id: _,
            inverse_prop_id: _
          ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): Unit
        end
      Some(MultiSelectVal(option_ids: oids)):
        case p.kind
          MultiSelect(options: opts):
            for o in opts
              if oids.contains?(o.id)
                parts = parts.append(o.label)
              end
            end
          Title | RichText | Number(format: _) | DateProp(include_time: _) | Select(options: _) | Checkbox | Person | Url | Relation(
            target_db_id: _,
            inverse_prop_id: _
          ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): Unit
        end
      Some(NumberVal(d)): parts = parts.append(d.to_text)
      Some(DateVal(start: st, end_date: _)): parts = parts.append(st.to_iso)
      Some(Empty) | Some(BoolVal(_)) | Some(PrincipalVal(_)) | Some(RelationVal(row_ids: _)) | None: Unit
    end
  end
  parts.join("\n")
end

test "DatabaseModel validation, exact Decimal rollups, multi-view filters, sorts, Kanban grouping, and Calendar overlap"
  todo_opt = SelectOption(id: "todo", label: "Todo", color: Gray)
  done_opt = SelectOption(id: "done", label: "Done", color: Green)
  def = DatabaseDef(
    id: "db_tasks",
    collection_id: "col_general",
    page_id: "pg_db_tasks",
    title: "Tasks",
    description: "Sprint tasks",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(options: [todo_opt, done_opt]),
        required: true,
        sort_order: "b"
      ),
      PropertyDef(
        id: "points",
        name: "Points",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "c"
      ),
      PropertyDef(
        id: "due",
        name: "Due",
        kind: DateProp(include_time: false),
        required: false,
        sort_order: "d"
      ),
      PropertyDef(
        id: "project",
        name: "Project",
        kind: Relation(target_db_id: "db_proj", inverse_prop_id: None),
        required: false,
        sort_order: "e"
      ),
      PropertyDef(
        id: "proj_pts",
        name: "Total Pts",
        kind: Rollup(relation_prop_id: "project", target_prop_id: "points", agg: SumValues),
        required: false,
        sort_order: "f"
      )
    ],
    version: 1
  )
  assert validate_database_def(def) == None

  ## Exact Decimal arithmetic (0.1 + 0.2 == 0.3, never float drift)
  d1 = "0.1".to_decimal or stop "d1"
  d2 = "0.2".to_decimal or stop "d2"
  d3 = "0.3".to_decimal or stop "d3"
  sum_cell = compute_rollup(SumValues, [NumberVal(d1), NumberVal(d2), Empty])
  assert sum_cell == NumberVal(d3)
  assert compute_rollup(CountAll, [NumberVal(d1), Empty]) == NumberVal(2.to_decimal)
  assert compute_rollup(CountValues, [NumberVal(d1), Empty]) == NumberVal(1.to_decimal)

  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  dt1 = Date.parse_iso("2026-11-10") or stop "dt1"
  dt2 = Date.parse_iso("2026-11-25") or stop "dt2"
  r1 = DbRow(
    id: "row_1",
    database_id: "db_tasks",
    page_id: "pg_r1",
    cells: {
      "title": TextVal("Fix Auth"),
      "status": SelectVal(option_id: "todo"),
      "points": NumberVal(d1),
      "due": DateVal(start: dt1, end_date: None)
    },
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  r2 = DbRow(
    id: "row_2",
    database_id: "db_tasks",
    page_id: "pg_r2",
    cells: {
      "title": TextVal("Ship Ledger"),
      "status": SelectVal(option_id: "done"),
      "points": NumberVal(d2),
      "due": DateVal(start: dt2, end_date: None)
    },
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  assert validate_row_cells(def, r1) == None

  bad_opt = DbRow(
    id: "row_bad",
    database_id: "db_tasks",
    page_id: "pg_bad",
    cells: {"title": TextVal("Bad"), "status": SelectVal(option_id: "bogus")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  assert validate_row_cells(def, bad_opt) != None

  er1 = EnrichedRow(row: r1, rollups: {"proj_pts": sum_cell})
  er2 = EnrichedRow(row: r2, rollups: {"proj_pts": NumberVal(zero_decimal())})

  assert matches_filters?(
    er1,
    [DbFilterRule(prop_id: "status", op: Eq, value: Json.String("todo"))],
    true
  )
  assert not matches_filters?(
    er1,
    [DbFilterRule(prop_id: "status", op: Neq, value: Json.String("todo"))],
    true
  )
  assert matches_filters?(
    er2,
    [DbFilterRule(prop_id: "points", op: Gt, value: Json.String("0.15"))],
    true
  )
  assert matches_filters?(
    er1,
    [DbFilterRule(prop_id: "title", op: Contains, value: Json.String("auth"))],
    true
  )
  assert matches_filters?(
    er2,
    [DbFilterRule(prop_id: "status", op: InSet, value: Json.Array([Json.String("done")]))],
    true
  )

  sorted_desc = sort_enriched_rows([er1, er2], [DbSortRule(prop_id: "points", desc: true)])
  assert sorted_desc.map(fn(e) e.row.id end) == ["row_2", "row_1"]

  groups = group_rows_for_board(def, [er1, er2], "status", false)
  assert groups.size == 3
  assert (groups.get(0) or stop "g0").group_key == "todo"
  assert (groups.get(0) or stop "g0b").rows.size == 1

  cal = filter_calendar_range(
    [er1, er2],
    "due",
    Date.parse_iso("2026-11-20"),
    Date.parse_iso("2026-11-30")
  )
  assert cal.map(fn(e) e.row.id end) == ["row_2"]
end
