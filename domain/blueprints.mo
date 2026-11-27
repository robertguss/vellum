## Statamic-style Blueprint schemas, typed Page metadata validation, YAML frontmatter projection,
## and FTS/vector plain-text extraction for structured Vellum pages.
module Domain.Blueprints
expose BlueprintDef(..),
PageBlueprintMeta(..),
ParsedFrontmatter(..),
valid_blueprint_slug?,
validate_blueprint_def,
validate_page_meta,
page_meta_plain_text,
to_yaml_frontmatter,
parse_yaml_frontmatter,
parse_yaml_meta_values
use Date
use Domain.DatabaseModel{
  CellValue,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor,
  validate_cell
}
use Domain.Policy{valid_collection_slug?}
use Domain.Types{Page, PageKind}
use Json

## Statamic-style field schema blueprint that can be attached to any non-database Vellum page.
struct BlueprintDef
  id: Text
  slug: Text
  name: Text
  description: Text
  icon: Option(Text)
  fields: List(PropertyDef)
  default_template_markdown: Text
  version: Int
end

## Typed field metadata attached to a `Page` referencing a `BlueprintDef`.
struct PageBlueprintMeta
  page_id: Text
  blueprint_id: Text
  values: Map(Text, CellValue)
  updated_at: Time
end

## Returns `true` when `slug` matches `^[a-z0-9][a-z0-9-]{0,63}$`.
fn valid_blueprint_slug?(slug: Text) : Bool
  valid_collection_slug?(slug)
end

fn validate_blueprint_options(options: List(SelectOption)) : Option(Text)
  var seen_ids = {}
  for opt in options
    oid = opt.id.trim
    if oid.empty? or opt.label.trim.empty?
      return Some("select option id and label must be non-empty")
    end
    if seen_ids.get(oid) != None
      return Some("duplicate select option id '#{oid}'")
    end
    seen_ids = seen_ids.set(oid, true)
  end
  None
end

## Validates a `BlueprintDef` before persistence in MoDB.
fn validate_blueprint_def(bp: BlueprintDef) : Option(Text)
  return Some("blueprint id must not be empty") if bp.id.trim.empty?
  if not valid_blueprint_slug?(bp.slug)
    return Some("blueprint slug '#{bp.slug}' must match ^[a-z0-9][a-z0-9-]{0,63}$")
  end
  return Some("blueprint name must not be empty") if bp.name.trim.empty?
  return Some("blueprint version must be >= 1") if bp.version < 1

  var seen_fields = {}
  for f in bp.fields
    fid = f.id.trim
    if fid.empty? or f.name.trim.empty?
      return Some("blueprint field id and name must be non-empty")
    end
    if seen_fields.get(fid) != None
      return Some("duplicate blueprint field id '#{fid}'")
    end
    seen_fields = seen_fields.set(fid, true)

    case f.kind
      Number(format: fmt):
        if fmt != "plain" and fmt != "currency" and fmt != "percent"
          return Some("invalid Number format '#{fmt}' on field '#{fid}'")
        end
      Select(options: opts) | MultiSelect(options: opts):
        case validate_blueprint_options(opts)
          Some(msg): return Some(msg)
          None: Unit
        end
      Relation(target_db_id: tdb, inverse_prop_id: _):
        if tdb.trim.empty?
          return Some("relation field '#{fid}' requires non-empty target_db_id")
        end
      Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): return Some(
        "blueprint field '#{fid}' cannot use Rollup or AiDerived kind"
      )
      Title | RichText | DateProp(include_time: _) | Checkbox | Person | Url: Unit
    end
  end
  None
end

## Validates `values` against `bp.fields` (`required` checks + exact `DatabaseModel.validate_cell` rules).
fn validate_page_meta(bp: BlueprintDef, values: Map(Text, CellValue)) : Option(Text)
  var by_id = {}
  for f in bp.fields
    by_id = by_id.set(f.id, f)
  end
  for (k, _v) in values
    if by_id.get(k) == None
      return Some("unknown field '#{k}' for blueprint '#{bp.slug}'")
    end
  end
  for f in bp.fields
    val = values.get(f.id) or Empty
    if f.required and val == Empty
      return Some("required field '#{f.name}' (#{f.id}) is missing")
    end
    case validate_cell(f, val)
      Some(msg): return Some(msg)
      None: Unit
    end
  end
  None
end

fn option_label_or_id(prop: PropertyDef, oid: Text) : Text
  case prop.kind
    Select(options: opts) | MultiSelect(options: opts):
      for opt in opts
        if opt.id == oid
          return opt.label
        end
      end
      oid
    Title | RichText | Number(format: _) | DateProp(include_time: _) | Checkbox | Person | Url | Relation(
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
end

fn cell_plain_value(prop: PropertyDef, val: CellValue) : Text
  case val
    Empty: ""
    TextVal(t): t
    NumberVal(d): d.to_text
    DateVal(start: s, end_date: ed):
      case ed
        Some(e): "#{s.to_text} #{e.to_text}"
        None: s.to_text
      end
    SelectVal(option_id: oid): option_label_or_id(prop, oid)
    MultiSelectVal(option_ids: oids): oids.map(fn(o) option_label_or_id(prop, o) end).join(" ")
    BoolVal(b): if b: "true" else: "false"
    PrincipalVal(pids): pids.join(" ")
    UrlVal(u): u
    RelationVal(row_ids: rids): rids.join(" ")
  end
end

## Formats attached blueprint metadata into human-readable lines for FTS + vector indexing.
fn page_meta_plain_text(bp: BlueprintDef, meta: PageBlueprintMeta) : Text
  var lines = ["blueprint: #{bp.name} (#{bp.slug})"]
  for f in bp.fields
    val = meta.values.get(f.id) or Empty
    txt = cell_plain_value(f, val).trim
    if not txt.empty?
      lines = lines.append("#{f.name}: #{txt}")
    end
  end
  lines.join("\n")
end

fn yaml_escape_string(s: Text) : Text
  escaped = s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "")
  "\"#{escaped}\""
end

fn yaml_list(items: List(Text)) : Text
  return "[]" if items.empty?
  inner = items.map(yaml_escape_string).join(", ")
  "[#{inner}]"
end

fn cell_yaml_value(val: CellValue) : Option(Text)
  case val
    Empty: None
    TextVal(t): Some(yaml_escape_string(t))
    NumberVal(d): Some(d.to_text)
    DateVal(start: s, end_date: ed):
      case ed
        Some(e): Some(yaml_escape_string("#{s.to_text}..#{e.to_text}"))
        None: Some(yaml_escape_string(s.to_text))
      end
    SelectVal(option_id: oid): Some(yaml_escape_string(oid))
    MultiSelectVal(option_ids: oids): Some(yaml_list(oids))
    BoolVal(b): Some(if b: "true" else: "false")
    PrincipalVal(pids): Some(yaml_list(pids))
    UrlVal(u): Some(yaml_escape_string(u))
    RelationVal(row_ids: rids): Some(yaml_list(rids))
  end
end

## Serializes YAML frontmatter (title, collection, optional blueprint + typed fields) prepended to `body_markdown`.
fn to_yaml_frontmatter(
  page: Page,
  bp_opt: Option(BlueprintDef),
  meta_opt: Option(PageBlueprintMeta),
  body_markdown: Text
) : Text
  var lines = [
    "---",
    "id: #{yaml_escape_string(page.id)}",
    "title: #{yaml_escape_string(page.title)}",
    "collection_id: #{yaml_escape_string(page.collection_id)}",
    "version: #{page.version}"
  ]
  case bp_opt
    Some(bp):
      lines = lines.append("blueprint: #{yaml_escape_string(bp.slug)}")
      lines = lines.append("blueprint_version: #{bp.version}")
      case meta_opt
        Some(meta):
          var meta_lines = []
          for f in bp.fields
            val = meta.values.get(f.id) or Empty
            case cell_yaml_value(val)
              Some(yv): meta_lines = meta_lines.append("  #{f.id}: #{yv}")
              None: Unit
            end
          end
          if not meta_lines.empty?
            lines = lines.append("meta:")
            for ml in meta_lines
              lines = lines.append(ml)
            end
          end
        None: Unit
      end
    None: Unit
  end
  lines = lines.append("---")
  header = lines.join("\n")
  if body_markdown.trim.empty?
    header
  else
    "#{header}\n\n#{body_markdown}"
  end
end

## Structured result of parsing optional Vellum YAML frontmatter from a mirrored `.md` file.
struct ParsedFrontmatter
  page_id: Option(Text)
  title: Option(Text)
  collection_id: Option(Text)
  version: Option(Int)
  blueprint_slug: Option(Text)
  meta_raw: Map(Text, Text)
  body_markdown: Text
  has_frontmatter: Bool
end

fn non_empty_text(s: Text) : Option(Text)
  t = s.trim
  if t.empty?: None else: Some(t)
end

fn unescape_yaml_scalar(raw: Text) : Text
  t = raw.trim
  if t.byte_count >= 2 and t.starts_with?("\"") and t.ends_with?("\"")
    inner = (t.drop_prefix("\"") or "").drop_suffix("\"") or ""
    var out = []
    var esc = false
    for c in inner.chars
      if esc
        if c == 'n'
          out = out.append('\n')
        else if c == 'r'
          out = out.append('\r')
        else if c == 't'
          out = out.append('\t')
        else
          out = out.append(c)
        end
        esc = false
      else if c == '\\'
        esc = true
      else
        out = out.append(c)
      end
    end
    if esc
      out = out.append('\\')
    end
    Text.from_chars(out)
  else if t.byte_count >= 2 and t.starts_with?("'") and t.ends_with?("'")
    ((t.drop_prefix("'") or "").drop_suffix("'") or "").replace("''", "'")
  else
    t
  end
end

fn split_yaml_kv(line: Text) : Option((Text, Text))
  parts = line.split(":")
  return None if parts.size < 2
  key = (parts.first or "").trim
  return None if key.empty?
  val = parts.drop(1).join(":").trim
  Some((key, val))
end

## Parses optional Vellum YAML frontmatter and returns typed header fields + Markdown body.
fn parse_yaml_frontmatter(raw: Text) : Result(ParsedFrontmatter, Text)
  raw_lines = raw.lines.map(fn(l) l.replace("\r", "") end)
  first_trimmed = (raw_lines.first or "").trim
  if raw_lines.empty? or first_trimmed != "---"
    return Ok(
      ParsedFrontmatter(
        page_id: None,
        title: None,
        collection_id: None,
        version: None,
        blueprint_slug: None,
        meta_raw: {},
        body_markdown: raw,
        has_frontmatter: false
      )
    )
  end

  var close_idx = -1
  var idx = 1
  n = raw_lines.size
  while idx < n
    if (raw_lines.get(idx) or "").trim == "---"
      close_idx = idx
      break
    end
    idx += 1
  end
  if close_idx < 0
    return Error("unterminated YAML frontmatter block")
  end

  var page_id = None
  var title = None
  var collection_id = None
  var version = None
  var blueprint_slug = None
  var meta_raw = {}
  var in_meta = false

  var hi = 1
  while hi < close_idx
    hline = raw_lines.get(hi) or ""
    trimmed = hline.trim
    hi += 1
    continue if trimmed.empty? or trimmed.starts_with?("#")
    if in_meta and (hline.starts_with?("  ") or hline.starts_with?("\t"))
      case split_yaml_kv(trimmed)
        Some((mk, mv)): meta_raw = meta_raw.set(mk, mv)
        None: Unit
      end
      continue
    end
    in_meta = false
    case split_yaml_kv(trimmed)
      Some((k, v)):
        if k == "meta" and v.empty?
          in_meta = true
        else if k == "id"
          page_id = non_empty_text(unescape_yaml_scalar(v))
        else if k == "title"
          title = non_empty_text(unescape_yaml_scalar(v))
        else if k == "collection_id"
          collection_id = non_empty_text(unescape_yaml_scalar(v))
        else if k == "version"
          version = unescape_yaml_scalar(v).to_int
        else if k == "blueprint"
          blueprint_slug = non_empty_text(unescape_yaml_scalar(v))
        end
      None: Unit
    end
  end

  after_lines = raw_lines.drop(close_idx + 1)
  trimmed_after = case after_lines.first
    Some(l) if l.trim.empty?: after_lines.drop(1)
    Some(_) | None: after_lines
  end
  body_md = trimmed_after.join("\n")
  Ok(
    ParsedFrontmatter(
      page_id: page_id,
      title: title,
      collection_id: collection_id,
      version: version,
      blueprint_slug: blueprint_slug,
      meta_raw: meta_raw,
      body_markdown: body_md,
      has_frontmatter: true
    )
  )
end

fn parse_yaml_string_list(raw: Text) : Result(List(Text), Text)
  t = raw.trim
  return Ok([]) if t == "[]" or t.empty?
  if t.starts_with?("[") and t.ends_with?("]")
    return Json.decode_strict[List(Text)](t.bytes).map_error(fn(e) e.to_text end)
  end
  Error("expected JSON/YAML string array '[...]' for list field, got '#{t}'")
end

## Converts parsed `meta_raw` YAML fields into validated `CellValue`s for `bp`.
fn parse_yaml_meta_values(bp: BlueprintDef, meta_raw: Map(Text, Text)) : Result(
  Map(Text, CellValue),
  Text
)
  var by_id = {}
  for f in bp.fields
    by_id = by_id.set(f.id, f)
  end

  var out = {}
  for (fid, raw_v) in meta_raw.entries
    prop = try by_id.get(fid).or_fail("unknown field '#{fid}' for blueprint '#{bp.slug}'")
    cval = case prop.kind
      Title | RichText: TextVal(unescape_yaml_scalar(raw_v))
      Url: UrlVal(unescape_yaml_scalar(raw_v))
      Number(format: _):
        s = unescape_yaml_scalar(raw_v).trim
        d = try s.to_decimal.or_fail("invalid decimal value '#{s}' for field '#{fid}'")
        NumberVal(d)
      DateProp(include_time: _):
        s = unescape_yaml_scalar(raw_v).trim
        parts = s.split("..")
        st_str = (parts.first or "").trim
        st = try Date.parse_iso(st_str).or_fail("invalid ISO date '#{st_str}' for field '#{fid}'")
        ed = if parts.size > 1
          ed_str = (parts.get(1) or "").trim
          if ed_str.empty?
            None
          else
            Some(try Date.parse_iso(ed_str).or_fail("invalid ISO end date '#{ed_str}'"))
          end
        else
          None
        end
        DateVal(start: st, end_date: ed)
      Select(options: _): SelectVal(option_id: unescape_yaml_scalar(raw_v))
      MultiSelect(options: _): MultiSelectVal(option_ids: try parse_yaml_string_list(raw_v))
      Checkbox:
        low = unescape_yaml_scalar(raw_v).trim.ascii_lowercase
        if low == "true" or low == "yes"
          BoolVal(true)
        else if low == "false" or low == "no"
          BoolVal(false)
        else
          return Error("invalid boolean '#{raw_v}' for field '#{fid}'")
        end
      Person: PrincipalVal(try parse_yaml_string_list(raw_v))
      Relation(target_db_id: _, inverse_prop_id: _): RelationVal(
        row_ids: try parse_yaml_string_list(raw_v)
      )
      Rollup(relation_prop_id: _, target_prop_id: _, agg: _) | AiDerived(
        prompt: _,
        source_prop_ids: _,
        include_row_body: _,
        output_kind: _,
        mode: _,
        daily_call_cap: _
      ): return Error("unsupported blueprint field kind on '#{fid}'")
    end
    out = out.set(fid, cval)
  end

  case validate_page_meta(bp, out)
    Some(err): Error(err)
    None: Ok(out)
  end
end

test "blueprint validation, page meta validation, plain text, and yaml frontmatter"
  opt_open = SelectOption(id: "open", label: "Open", color: Green)
  opt_closed = SelectOption(id: "closed", label: "Closed", color: Red)
  bp = BlueprintDef(
    id: "bp_decision",
    slug: "decision-record",
    name: "Decision Record",
    description: "Architectural or budget decision",
    icon: Some("scale"),
    fields: [
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Select(options: [opt_open, opt_closed]),
        required: true,
        sort_order: "a"
      ),
      PropertyDef(
        id: "budget",
        name: "Budget",
        kind: Number(format: "currency"),
        required: false,
        sort_order: "b"
      ),
      PropertyDef(
        id: "owner",
        name: "Owner",
        kind: Person,
        required: false,
        sort_order: "c"
      )
    ],
    default_template_markdown: "## Decision Context\n\n## Recommendation",
    version: 1
  )
  assert validate_blueprint_def(bp) == None

  bad_slug_bp = BlueprintDef(
    id: bp.id,
    slug: "Invalid Slug!",
    name: bp.name,
    description: bp.description,
    icon: bp.icon,
    fields: bp.fields,
    default_template_markdown: bp.default_template_markdown,
    version: bp.version
  )
  assert validate_blueprint_def(bad_slug_bp) != None

  now = Time.parse("2026-11-26T12:00:00Z") or stop "now"
  budget_dec = "1250.50".to_decimal or stop "dec"
  page = Page(
    id: "pg_1",
    collection_id: "col_1",
    parent_page_id: None,
    title: "Migrate Storage",
    icon: None,
    cover_attachment_id: None,
    kind: Document,
    sort_order: "i",
    database_id: None,
    freshness_ttl_days: None,
    verified_at: None,
    verified_by: None,
    created_by: "usr_1",
    created_at: now,
    updated_at: now,
    archived_at: None,
    version: 3
  )

  missing_req = PageBlueprintMeta(
    page_id: "pg_1",
    blueprint_id: "bp_decision",
    values: {"budget": NumberVal(budget_dec)},
    updated_at: now
  )
  assert validate_page_meta(bp, missing_req.values) != None

  unknown_key = {"status": SelectVal(option_id: "open"), "extra": TextVal("bad")}
  assert validate_page_meta(bp, unknown_key) != None

  good_meta = PageBlueprintMeta(
    page_id: "pg_1",
    blueprint_id: "bp_decision",
    values: {
      "status": SelectVal(option_id: "open"),
      "budget": NumberVal(budget_dec),
      "owner": PrincipalVal(["usr_alice"])
    },
    updated_at: now
  )
  assert validate_page_meta(bp, good_meta.values) == None

  plain = page_meta_plain_text(bp, good_meta)
  assert plain.contains?("Status: Open")
  assert plain.contains?("Budget: 1250.5")

  yaml = to_yaml_frontmatter(page, Some(bp), Some(good_meta), "Hello")
  assert yaml.starts_with?("---\nid: \"pg_1\"\n")
  assert yaml.contains?("blueprint: \"decision-record\"")
  assert yaml.contains?("  status: \"open\"")
  assert yaml.contains?("  budget: 1250.5")
  assert yaml.ends_with?("---\n\nHello")

  parsed_fm = case parse_yaml_frontmatter(yaml)
    Ok(p): p
    Error(_): stop "parse_yaml_frontmatter"
  end
  assert parsed_fm.has_frontmatter
  assert parsed_fm.page_id == Some("pg_1")
  assert parsed_fm.title == Some("Migrate Storage")
  assert parsed_fm.collection_id == Some("col_1")
  assert parsed_fm.version == Some(3)
  assert parsed_fm.blueprint_slug == Some("decision-record")
  assert parsed_fm.body_markdown == "Hello"
  assert parse_yaml_meta_values(bp, parsed_fm.meta_raw) == Ok(good_meta.values)

  plain_md = case parse_yaml_frontmatter("# Just Markdown\n\nBody")
    Ok(p): p
    Error(_): stop "plain_md"
  end
  assert not plain_md.has_frontmatter
  assert plain_md.body_markdown == "# Just Markdown\n\nBody"
end
