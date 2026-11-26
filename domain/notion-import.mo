## Pure Notion Markdown & CSV export parser: 32-hex ID stripping, internal `[[page]]` link
## rewriting, RFC 4180 CSV decoding, and strongly typed `DatabaseDef` schema inference.
module Domain.NotionImport
expose NotionPageImport(..),
NotionCsvImport(..),
ParsedCsvTable(..),
InferredDbImport(..),
strip_notion_id_suffix,
notion_page_title,
rewrite_notion_links,
parse_csv,
infer_database_from_csv
use Date
use Domain.DatabaseModel{CellValue, PropertyDef, PropertyKind, SelectOption, SelectOptionColor}

## One Notion Markdown file passed to `POST /api/import/notion`.
struct NotionPageImport
  path: Text
  title: Option(Text)
  markdown: Text
end

## One Notion CSV database export passed to `POST /api/import/notion`.
struct NotionCsvImport
  title: Text
  csv_text: Text
end

## Decoded RFC 4180 CSV header + rows.
struct ParsedCsvTable
  headers: List(Text)
  rows: List(List(Text))
end

## Inferred Vellum relational database columns and typed row cell maps from CSV.
struct InferredDbImport
  properties: List(PropertyDef)
  row_cells: List(Map(Text, CellValue))
end

fn hex_char?(ch: Char) : Bool
  ch.ascii_digit? or (ch.code >= 97 and ch.code <= 102) or (ch.code >= 65 and ch.code <= 70)
end

## Strips folder paths, `.md`/`.csv` extensions, `%20` escapes, and Notion's trailing 32-hex UUID suffix.
fn strip_notion_id_suffix(raw: Text) : Text
  examples
    strip_notion_id_suffix("Engineering Runbook 9a1b2c3d4e5f67890123456789abcdef.md") ==
      "Engineering Runbook"
    strip_notion_id_suffix("docs/Team%20Handbook%200123456789abcdef0123456789abcdef.md") ==
      "Team Handbook"
    strip_notion_id_suffix("Plain Title.md") == "Plain Title"
  end

  base = (raw.trim.split("/").last or raw).replace("%20", " ")
  no_ext = if base.ends_with?(".md")
    base.drop_suffix(".md") or base
  else if base.ends_with?(".MD")
    base.drop_suffix(".MD") or base
  else if base.ends_with?(".csv")
    base.drop_suffix(".csv") or base
  else if base.ends_with?(".CSV")
    base.drop_suffix(".CSV") or base
  else
    base
  end
  trimmed = no_ext.trim
  chars = trimmed.chars
  if chars.size > 33
    sep_idx = chars.size - 33
    if chars.get(sep_idx) == Some(' ')
      tail = chars.drop(sep_idx + 1)
      if tail.size == 32 and tail.all?(hex_char?)
        return Text.from_chars(chars.take(sep_idx)).trim
      end
    end
  end
  trimmed
end

## Resolves the human title of an imported Notion Markdown page.
fn notion_page_title(imp: NotionPageImport) : Text
  case imp.title
    Some(t) if not t.trim.empty?: t.trim
    Some(_) | None:
      derived = strip_notion_id_suffix(imp.path)
      if derived.empty?: "Imported Page" else: derived
  end
end

fn split_md_link(trimmed: Text) : Option((Text, Text))
  return None if not trimmed.starts_with?("[") or not trimmed.ends_with?(")")
  pieces = trimmed.split("](")
  return None if pieces.size != 2
  raw_label = pieces.first or ""
  raw_href = pieces.get(1) or ""
  label = (raw_label.drop_prefix("[") or "").trim
  href = (raw_href.drop_suffix(")") or "").trim
  return None if label.empty? or href.empty?
  Some((label, href))
end

## Rewrites `[[Title]]` and `[Label](Title%20<32hex>.md)` lines matching `title_to_page_id`
## into Vellum's canonical `[[<page_id>|<label>]]` syntax (`BlockKind.PageLink`).
fn rewrite_notion_links(markdown: Text, title_to_page_id: Map(Text, Text)) : Text
  var norm_map = {}
  for (k, pid) in title_to_page_id.entries
    norm_map = norm_map.set(k.trim.ascii_lowercase, pid)
    norm_map = norm_map.set(strip_notion_id_suffix(k).ascii_lowercase, pid)
  end

  var out = []
  for raw_line in markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    t = raw_line.trim
    replaced = if t.starts_with?("[[") and t.ends_with?("]]") and not t.contains?("|")
      inner = (t.drop_prefix("[[") or "").drop_suffix("]]") or ""
      clean_target = strip_notion_id_suffix(inner)
      case norm_map.get(clean_target.ascii_lowercase)
        Some(pid): "[[#{pid}|#{clean_target}]]"
        None: raw_line
      end
    else
      case split_md_link(t)
        Some((label, href)):
          clean_target = strip_notion_id_suffix(href)
          case norm_map.get(clean_target.ascii_lowercase)
            Some(pid): "[[#{pid}|#{label}]]"
            None: raw_line
          end
        None: raw_line
      end
    end
    out = out.append(replaced)
  end
  out.join("\n")
end

## Parses RFC 4180 CSV supporting quoted cells, escaped `""` quotes, and newlines inside text.
fn parse_csv(csv_text: Text) : Result(ParsedCsvTable, Text)
  clean = csv_text.replace("\r\n", "\n").replace("\r", "\n")
  return Error("CSV input is empty") if clean.trim.empty?

  chars = clean.chars
  var rows = []
  var cur_row = []
  var cur_cell = []
  var in_quotes? = false
  var at_cell_start? = true
  var i = 0

  while i < chars.size
    ch = chars.get(i) or ' '
    if in_quotes?
      if ch == '"'
        next_ch = chars.get(i + 1)
        if next_ch == Some('"')
          cur_cell = cur_cell.append('"')
          i += 2
        else
          in_quotes? = false
          at_cell_start? = false
          i += 1
        end
      else
        cur_cell = cur_cell.append(ch)
        i += 1
      end
    else
      if ch == '"' and at_cell_start?
        in_quotes? = true
        at_cell_start? = false
        i += 1
      else if ch == ','
        cur_row = cur_row.append(Text.from_chars(cur_cell))
        cur_cell = []
        at_cell_start? = true
        i += 1
      else if ch == '\n'
        cur_row = cur_row.append(Text.from_chars(cur_cell))
        if not (cur_row.size == 1 and (cur_row.first or "").empty?)
          rows = rows.append(cur_row)
        end
        cur_row = []
        cur_cell = []
        at_cell_start? = true
        i += 1
      else
        cur_cell = cur_cell.append(ch)
        at_cell_start? = false
        i += 1
      end
    end
  end

  if in_quotes?
    return Error("unterminated quoted field in CSV")
  end
  if not cur_cell.empty? or not cur_row.empty?
    cur_row = cur_row.append(Text.from_chars(cur_cell))
    if not (cur_row.size == 1 and (cur_row.first or "").empty?)
      rows = rows.append(cur_row)
    end
  end

  headers_raw = case rows.first
    Some(h): h
    None: return Error("CSV has no header row")
  end
  headers = headers_raw.map(fn(x) x.trim end)
  if headers.empty? or headers.any?(fn(h) h.empty? end)
    return Error("CSV headers must be non-empty")
  end

  data_rows = rows.drop(1)
  for (r_idx, r) in data_rows.enumerate
    if r.size != headers.size
      return Error("CSV row #{r_idx + 1} has #{r.size} columns, expected #{headers.size}")
    end
  end
  Ok(ParsedCsvTable(headers: headers, rows: data_rows))
end

fn slugify_id(raw: Text, fallback: Text) : Text
  var chars = []
  for ch in raw.trim.ascii_lowercase.chars
    if ch.ascii_letter? or ch.ascii_digit?
      chars = chars.append(ch)
    else if ch == ' ' or ch == '-' or ch == '_'
      if chars.last != Some('_')
        chars = chars.append('_')
      end
    end
  end
  s = Text.from_chars(chars).trim
  if s.empty?: fallback else: s
end

fn parse_bool_str(raw: Text) : Option(Bool)
  low = raw.trim.ascii_lowercase
  if low == "true" or low == "yes"
    Some(true)
  else if low == "false" or low == "no"
    Some(false)
  else
    None
  end
end

fn color_at(idx: Int) : SelectOptionColor
  rem = idx % 6
  if rem == 0
    Gray
  else if rem == 1
    Blue
  else if rem == 2
    Green
  else if rem == 3
    Amber
  else if rem == 4
    Red
  else
    Purple
  end
end

## Infers typed Vellum `PropertyDef` columns and `CellValue` rows from a `ParsedCsvTable`.
fn infer_database_from_csv(table: ParsedCsvTable) : Result(InferredDbImport, Text)
  if table.headers.empty?
    return Error("CSV table must have at least one column")
  end

  var props = []
  var col_meta = []
  var used_prop_ids = Set.empty

  for (col_idx, h) in table.headers.enumerate
    sort_key = "c#{col_idx + 10}"
    if col_idx == 0
      props = props.append(
        PropertyDef(id: "title", name: h, kind: Title, required: true, sort_order: "a")
      )
      col_meta = col_meta.append(("title", {}))
      used_prop_ids = used_prop_ids.add("title")
    else
      base_pid = slugify_id(h, "col_#{col_idx}")
      pid = if used_prop_ids.has?(base_pid): "#{base_pid}_#{col_idx}" else: base_pid
      used_prop_ids = used_prop_ids.add(pid)

      var vals = []
      for r in table.rows
        v = (r.get(col_idx) or "").trim
        if not v.empty?
          vals = vals.append(v)
        end
      end

      var opt_map = {}
      kind = if vals.empty?
        RichText
      else if vals.all?(fn(v) parse_bool_str(v) != None end)
        Checkbox
      else if vals.all?(fn(v) Date.parse_iso(v) != None end)
        DateProp(include_time: false)
      else if vals.all?(fn(v) v.to_decimal != None end)
        Number(format: "plain")
      else if vals.all?(fn(v) v.starts_with?("https://") or v.starts_with?("http://") end)
        Url
      else
        distinct = vals.to_set.to_list
        if distinct.size <= 12 and vals.size >= 2 and distinct.all?(fn(d) d.byte_count <= 40 end)
          var opts = []
          var used_oids = Set.empty
          for (o_idx, label) in distinct.enumerate
            raw_oid = slugify_id(label, "opt_#{o_idx}")
            oid = if used_oids.has?(raw_oid): "#{raw_oid}_#{o_idx}" else: raw_oid
            used_oids = used_oids.add(oid)
            opt_map = opt_map.set(label, oid)
            opts = opts.append(SelectOption(id: oid, label: label, color: color_at(o_idx)))
          end
          Select(options: opts)
        else
          RichText
        end
      end

      props = props.append(
        PropertyDef(id: pid, name: h, kind: kind, required: false, sort_order: sort_key)
      )
      col_meta = col_meta.append((pid, opt_map))
    end
  end

  var out_rows = []
  for (r_idx, raw_row) in table.rows.enumerate
    var cells = {}
    for (col_idx, prop) in props.enumerate
      raw_val = (raw_row.get(col_idx) or "").trim
      (pid, opt_map) = col_meta.get(col_idx) or ("", {})
      cell = if col_idx == 0
        TextVal(if raw_val.empty?: "Row #{r_idx + 1}" else: raw_val)
      else if raw_val.empty?
        Empty
      else
        case prop.kind
          Checkbox: BoolVal(parse_bool_str(raw_val) or false)
          DateProp(include_time: _): DateVal(
            start: Date.parse_iso(raw_val) or stop "verified date",
            end_date: None
          )
          Number(format: _): NumberVal(raw_val.to_decimal or stop "verified decimal")
          Url: UrlVal(raw_val)
          Select(options: _):
            oid = opt_map.get(raw_val) or raw_val
            SelectVal(option_id: oid)
          RichText | Title | MultiSelect(options: _) | Person | Relation(
            target_db_id: _,
            inverse_prop_id: _
          ) | Rollup(relation_prop_id: _, target_prop_id: _, agg: _): TextVal(raw_val)
        end
      end
      cells = cells.set(pid, cell)
    end
    out_rows = out_rows.append(cells)
  end

  Ok(InferredDbImport(properties: props, row_cells: out_rows))
end

test "NotionImport ID stripping, internal link rewriting, RFC 4180 CSV parsing, and typed schema inference"
  p1 = NotionPageImport(
    path: "docs/Gateway%20Spec%209a1b2c3d4e5f67890123456789abcdef.md",
    title: None,
    markdown: "# Spec\n\n[[Runbook 0123456789abcdef0123456789abcdef]]\n\n[Read Runbook](Runbook%200123456789abcdef0123456789abcdef.md)"
  )
  assert notion_page_title(p1) == "Gateway Spec"
  rewritten = rewrite_notion_links(p1.markdown, {"Runbook": "pg_runbook"})
  assert rewritten.contains?("[[pg_runbook|Runbook]]")
  assert rewritten.contains?("[[pg_runbook|Read Runbook]]")

  csv_raw = "Incident,Severity,Cost,Date,Resolved,Link\n\"API, 502 spike\",Critical,125.50,2026-11-20,true,https://status.acme.io/1\nDB timeout,Warning,0.25,2026-11-21,false,https://status.acme.io/2\n"
  table = case parse_csv(csv_raw)
    Ok(t): t
    Error(_m): stop "parse_csv failed"
  end
  assert table.headers == ["Incident", "Severity", "Cost", "Date", "Resolved", "Link"]
  assert table.rows.size == 2
  inferred = case infer_database_from_csv(table)
    Ok(inf): inf
    Error(_m): stop "infer_database_from_csv failed"
  end
  assert inferred.properties.size == 6
  assert (inferred.properties.get(0) or stop "p0").kind == Title
  assert (inferred.properties.get(1) or stop "p1").kind is Select(options: _)
  assert (inferred.properties.get(2) or stop "p2").kind == Number(format: "plain")
  assert (inferred.properties.get(3) or stop "p3").kind == DateProp(include_time: false)
  assert (inferred.properties.get(4) or stop "p4").kind == Checkbox
  assert (inferred.properties.get(5) or stop "p5").kind == Url

  row0 = inferred.row_cells.first or stop "row0"
  assert row0.get("title") == Some(TextVal("API, 502 spike"))
  assert row0.get("cost") == Some(NumberVal("125.50".to_decimal or stop "dec"))
  assert row0.get("resolved") == Some(BoolVal(true))
end
