## Statamic-style Blueprint schemas, typed Page metadata validation, YAML frontmatter projection,
## and FTS/vector plain-text extraction for structured Vellum pages.
module Domain.Blueprints
expose BlueprintDef(..),
PageBlueprintMeta(..),
valid_blueprint_slug?,
validate_blueprint_def,
validate_page_meta,
page_meta_plain_text,
to_yaml_frontmatter
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
      Rollup(relation_prop_id: _, target_prop_id: _, agg: _): return Some(
        "blueprint field '#{fid}' cannot use Rollup kind"
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
    ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): oid
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
end
