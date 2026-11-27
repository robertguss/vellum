## Unit tests extracted from `Domain.DatabaseModel` to keep production module lowering lean.
module Tests.UnitDatabaseModel
use Date
use Domain.DatabaseModel{
  AiColumnMode,
  AiOutputKind,
  CellValue,
  DatabaseDef,
  DbFilterRule,
  DbRow,
  DbSortRule,
  DbViewKind,
  EnrichedRow,
  FilterOp,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor,
  compute_ai_input_hash,
  compute_rollup,
  compute_rollup_with_target,
  filter_calendar_range,
  filter_timeline_range,
  group_rows_for_board,
  has_ai_derived_columns?,
  matches_filters?,
  parse_ai_cell_output,
  sort_enriched_rows,
  validate_cell,
  validate_database_def,
  validate_row_cells
}
use Json

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
  er2 = EnrichedRow(row: r2, rollups: {"proj_pts": NumberVal(0.0)})

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

test "AiDerived column schema validation, typed output parsing, input hash drift, and AiSelect board grouping"
  low_opt = SelectOption(id: "low", label: "Low Risk", color: Green)
  high_opt = SelectOption(id: "high", label: "High Risk", color: Red)
  ai_prop = PropertyDef(
    id: "risk",
    name: "Risk Tier",
    kind: AiDerived(
      prompt: "Classify operational risk",
      source_prop_ids: ["title"],
      include_row_body: false,
      output_kind: AiSelect(options: [low_opt, high_opt]),
      mode: AutoApply,
      daily_call_cap: 10
    ),
    required: false,
    sort_order: "b"
  )
  ai_score_prop = PropertyDef(
    id: "score",
    name: "Risk Score",
    kind: AiDerived(
      prompt: "Compute score",
      source_prop_ids: [],
      include_row_body: true,
      output_kind: AiNumber(format: "plain"),
      mode: StageProposal,
      daily_call_cap: 5
    ),
    required: false,
    sort_order: "c"
  )
  def = DatabaseDef(
    id: "db_ai",
    collection_id: "col_general",
    page_id: "pg_db_ai",
    title: "AI Ops",
    description: "AI derived test DB",
    properties: [
      PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
      ai_prop,
      ai_score_prop
    ],
    version: 1
  )
  assert validate_database_def(def) == None
  assert has_ai_derived_columns?(def)

  # Self-referencing source property rejected
  bad_self = PropertyDef(
    id: "bad",
    name: "Bad",
    kind: AiDerived(
      prompt: "Self",
      source_prop_ids: ["bad"],
      include_row_body: false,
      output_kind: AiText,
      mode: AutoApply,
      daily_call_cap: 5
    ),
    required: false,
    sort_order: "d"
  )
  assert validate_database_def(
    DatabaseDef(
      id: "db_bad",
      collection_id: "col_general",
      page_id: "pg_bad",
      title: "Bad",
      description: "",
      properties: [
        PropertyDef(id: "title", name: "Item", kind: Title, required: true, sort_order: "a"),
        bad_self
      ],
      version: 1
    )
  ) !=
    None

  # Fenced JSON select parsing + label matching + bogus option rejection
  parsed_sel = parse_ai_cell_output(
    AiSelect(options: [low_opt, high_opt]),
    "```json\n{\"value\": \"High Risk\", \"rationale\": \"Elevated outage cost\"}\n```"
  )
  assert parsed_sel == Ok((SelectVal(option_id: "high"), Some("Elevated outage cost")))
  assert parse_ai_cell_output(AiSelect(options: [low_opt, high_opt]), "bogus_option") is Error(_)
  assert parse_ai_cell_output(AiNumber(format: "currency"), "$1,250.50") ==
    Ok((NumberVal("1250.50".to_decimal or stop "dec"), None))
  assert parse_ai_cell_output(AiNumber(format: "plain"), "not-a-number") is Error(_)
  assert parse_ai_cell_output(AiDate, "2026-12-15") ==
    Ok((DateVal(start: Date.parse_iso("2026-12-15") or stop "dt", end_date: None), None))
  assert parse_ai_cell_output(AiBool, "{\"value\": true}") == Ok((BoolVal(true), None))

  # validate_cell rejects wrong cell variant for AiSelect / AiNumber
  assert validate_cell(ai_prop, SelectVal(option_id: "high")) == None
  assert validate_cell(ai_prop, SelectVal(option_id: "bogus")) != None
  assert validate_cell(ai_prop, TextVal("wrong")) != None

  # compute_ai_input_hash detects source cell drift
  t0 = Time.parse("2026-12-01T00:00:00Z") or stop "t0"
  r1 = DbRow(
    id: "r1",
    database_id: "db_ai",
    page_id: "pg_r1",
    cells: {"title": TextVal("Normal Check"), "risk": SelectVal(option_id: "low")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  r1_edited = DbRow(
    id: "r1",
    database_id: "db_ai",
    page_id: "pg_r1",
    cells: {"title": TextVal("Urgent Failover"), "risk": SelectVal(option_id: "low")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 2
  )
  h1 = compute_ai_input_hash(def, ai_prop, r1, "body")
  h2 = compute_ai_input_hash(def, ai_prop, r1_edited, "body")
  assert h1 != h2

  # AiSelect board grouping works identically to Select
  b_groups = group_rows_for_board(def, [EnrichedRow(row: r1, rollups: {})], "risk", false)
  assert b_groups.size == 3
  assert (b_groups.get(0) or stop "bg0").rows.size == 1

  # GalleryView / TimelineView JSON round-trip + filter_timeline_range chronological order & overlap
  g_kind = GalleryView(cover_prop_id: Some("cover"), card_prop_ids: ["risk"], card_size: "md")
  assert Json.decode[DbViewKind](Json.encode(g_kind).bytes) == Ok(g_kind)
  t_kind = TimelineView(
    start_date_prop_id: "start_at",
    end_date_prop_id: Some("end_at"),
    card_prop_ids: ["risk"]
  )
  assert Json.decode[DbViewKind](Json.encode(t_kind).bytes) == Ok(t_kind)

  tl_early = DbRow(
    id: "tl_1",
    database_id: "db_ai",
    page_id: "pg_tl1",
    cells: {
      "title": TextVal("Phase A"),
      "start_at": DateVal(start: Date.parse_iso("2026-12-01") or stop "d1", end_date: None),
      "end_at": DateVal(start: Date.parse_iso("2026-12-10") or stop "d2", end_date: None)
    },
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  tl_late = DbRow(
    id: "tl_2",
    database_id: "db_ai",
    page_id: "pg_tl2",
    cells: {
      "title": TextVal("Phase B"),
      "start_at": DateVal(start: Date.parse_iso("2026-12-15") or stop "d3", end_date: None),
      "end_at": DateVal(start: Date.parse_iso("2026-12-22") or stop "d4", end_date: None)
    },
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  tl_unsched = DbRow(
    id: "tl_3",
    database_id: "db_ai",
    page_id: "pg_tl3",
    cells: {"title": TextVal("Backlog")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  tl_in = [
    EnrichedRow(row: tl_late, rollups: {}),
    EnrichedRow(row: tl_unsched, rollups: {}),
    EnrichedRow(row: tl_early, rollups: {})
  ]
  tl_all = filter_timeline_range(tl_in, "start_at", Some("end_at"), None, None)
  assert tl_all.map(fn(e) e.row.id end) == ["tl_1", "tl_2", "tl_3"]
  tl_win = filter_timeline_range(
    tl_in,
    "start_at",
    Some("end_at"),
    Date.parse_iso("2026-12-08"),
    Date.parse_iso("2026-12-12")
  )
  assert tl_win.map(fn(e) e.row.id end) == ["tl_1"]
end

test "Status grouping, Email/FileList/UniqueId validation, Formula/Audit schema, and PercentPerGroup rollup"
  st_todo = SelectOption(id: "todo", label: "Not started", color: Gray)
  st_done = SelectOption(id: "done", label: "Done", color: Green)
  st_ship = SelectOption(id: "shipped", label: "Shipped", color: Purple)

  status_prop = PropertyDef(
    id: "status",
    name: "Status",
    kind: Status(options: [st_todo, st_done, st_ship], done_option_ids: ["done", "shipped"]),
    required: false,
    sort_order: "b"
  )
  email_prop = PropertyDef(id: "email", name: "Email", kind: Email, required: false, sort_order: "c")
  files_prop = PropertyDef(id: "files", name: "Files", kind: FileList, required: false, sort_order: "d")
  uid_prop = PropertyDef(
    id: "uid",
    name: "ID",
    kind: UniqueId(prefix: "TSK"),
    required: false,
    sort_order: "e"
  )
  formula_prop = PropertyDef(
    id: "disp",
    name: "Summary",
    kind: Formula(expression: "prop(\"ID\")", format: "text"),
    required: false,
    sort_order: "f"
  )
  ct_prop = PropertyDef(id: "ct", name: "Created", kind: CreatedTime, required: false, sort_order: "g")

  def = DatabaseDef(
    id: "db_m12",
    collection_id: "col_general",
    page_id: "pg_m12",
    title: "Engineering Tasks",
    description: "Schema parity check",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      status_prop,
      email_prop,
      files_prop,
      uid_prop,
      formula_prop,
      ct_prop
    ],
    version: 1
  )
  assert validate_database_def(def) == None

  # Invalid done_option_ids rejected
  bad_status_def = DatabaseDef(
    id: "db_bad_st",
    collection_id: "col_general",
    page_id: "pg_bad_st",
    title: "Bad Status",
    description: "",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "st",
        name: "Status",
        kind: Status(options: [st_todo], done_option_ids: ["missing_done"]),
        required: false,
        sort_order: "b"
      )
    ],
    version: 1
  )
  assert validate_database_def(bad_status_def) != None

  # Email, FileList, UniqueId, computed property cell validation
  assert validate_cell(email_prop, TextVal("ada@example.edu")) == None
  assert validate_cell(email_prop, TextVal("not-an-email")) != None
  assert validate_cell(files_prop, FilesVal(attachment_ids: ["att_1"])) == None
  assert validate_cell(files_prop, FilesVal(attachment_ids: [""])) != None
  assert validate_cell(uid_prop, TextVal("TSK-1")) == None
  assert validate_cell(uid_prop, TextVal("  ")) != None
  assert validate_cell(formula_prop, TextVal("write attempt")) != None
  assert validate_cell(ct_prop, TextVal("2026-11-27T00:00:00Z")) != None

  # PercentPerGroup rollup with done_option_ids and fallback label matching
  cells = [
    SelectVal(option_id: "done"),
    SelectVal(option_id: "shipped"),
    SelectVal(option_id: "todo"),
    Empty
  ]
  assert compute_rollup_with_target(PercentPerGroup, cells, Some(status_prop)) ==
    NumberVal("0.5".to_decimal or stop "p05")
  assert compute_rollup_with_target(
    PercentPerGroup,
    [SelectVal(option_id: "done"), SelectVal(option_id: "shipped"), SelectVal(option_id: "todo")],
    Some(status_prop)
  ) ==
    NumberVal("0.6667".to_decimal or stop "p6667")

  # Board grouping supports Status columns identically to Select
  t0 = Time.parse("2026-11-27T00:00:00Z") or stop "t0"
  r_done = DbRow(
    id: "r_done",
    database_id: "db_m12",
    page_id: "pg_rd",
    cells: {"title": TextVal("Ship"), "status": SelectVal(option_id: "shipped")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  bg = group_rows_for_board(def, [EnrichedRow(row: r_done, rollups: {})], "status", false)
  assert bg.size == 4
  assert (bg.get(2) or stop "bg2").rows.size == 1
end
