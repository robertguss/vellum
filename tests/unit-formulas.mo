## Unit tests extracted from `Domain.Formulas` to keep production module lowering lean.
module Tests.UnitFormulas
use Date
use Domain.DatabaseModel{
  CellValue,
  DatabaseDef,
  DbRow,
  PropertyDef,
  PropertyKind,
  SelectOption,
  SelectOptionColor
}
use Domain.Formulas{FormulaRelatedRow, evaluate_formula, evaluate_row_formulas, validate_formula}

test "Notion formula engine: comments, Decimal math, multi-pass references, Status filter, Unicode bars, and formatDate"
  st_todo = SelectOption(id: "todo", label: "Not started", color: Gray)
  st_done = SelectOption(id: "done", label: "Done", color: Green)
  st_ship = SelectOption(id: "shipped", label: "Shipped", color: Purple)
  mode_check = SelectOption(id: "chk", label: "Page checklist", color: Blue)
  mode_tasks = SelectOption(id: "sub", label: "Subtasks", color: Green)

  tasks_def = DatabaseDef(
    id: "db_tasks",
    collection_id: "col_eng",
    page_id: "pg_tasks",
    title: "Tasks",
    description: "Sprint items",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "status",
        name: "Status",
        kind: Status(options: [st_todo, st_done, st_ship], done_option_ids: ["done", "shipped"]),
        required: false,
        sort_order: "b"
      )
    ],
    version: 1
  )

  init_def = DatabaseDef(
    id: "db_inits",
    collection_id: "col_eng",
    page_id: "pg_inits",
    title: "Initiative Tracker",
    description: "Workstreams",
    properties: [
      PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
      PropertyDef(
        id: "subtasks",
        name: "Subtasks",
        kind: Relation(target_db_id: "db_tasks", inverse_prop_id: None),
        required: false,
        sort_order: "b"
      ),
      PropertyDef(
        id: "tmode",
        name: "Tracking mode",
        kind: Select(options: [mode_check, mode_tasks]),
        required: false,
        sort_order: "c"
      ),
      PropertyDef(
        id: "m_pct",
        name: "Manual progress %",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "d"
      ),
      PropertyDef(
        id: "m_sum",
        name: "Manual progress summary",
        kind: RichText,
        required: false,
        sort_order: "e"
      ),
      PropertyDef(
        id: "mins",
        name: "Minutes per occurrence",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "f"
      ),
      PropertyDef(
        id: "occ",
        name: "Occurrences per year",
        kind: Number(format: "plain"),
        required: false,
        sort_order: "g"
      ),
      PropertyDef(
        id: "demo",
        name: "Demo date",
        kind: DateProp(include_time: false),
        required: false,
        sort_order: "h"
      ),
      PropertyDef(
        id: "hrs",
        name: "Hours saved / year",
        kind: Formula(
          expression: "if(empty(prop(\"Minutes per occurrence\")) or empty(prop(\"Occurrences per year\")),\n  0,\n  /* Calculate total minutes per year and convert to hours */\n  round(prop(\"Minutes per occurrence\") * prop(\"Occurrences per year\") / 60, 1)\n)",
          format: "number"
        ),
        required: false,
        sort_order: "i"
      ),
      # Put Progress display BEFORE Progress bar/summary to test multi-pass convergence regardless of order
      PropertyDef(
        id: "p_disp",
        name: "Progress display",
        kind: Formula(
          expression: "ifs(prop(\"Tracking mode\") == \"Page checklist\" and not empty(prop(\"Manual progress summary\")), prop(\"Manual progress summary\"), prop(\"Tracking mode\") == \"Page checklist\" and not empty(prop(\"Manual progress %\")), format(round(prop(\"Manual progress %\") * 100, 0)) + \"% checklist\", prop(\"Subtasks\").length() > 0, prop(\"Progress bar\") + \" — \" + prop(\"Progress summary\"), \"\")",
          format: "text"
        ),
        required: false,
        sort_order: "j"
      ),
      PropertyDef(
        id: "p_bar",
        name: "Progress bar",
        kind: Formula(
          expression: "if(prop(\"Subtasks\").length() == 0, \"\", repeat(\"█\", floor(prop(\"Subtasks\").filter(current.prop(\"Status\") == \"Done\" or current.prop(\"Status\") == \"Shipped\").length() / prop(\"Subtasks\").length() * 10)) + repeat(\"░\", 10 - floor(prop(\"Subtasks\").filter(current.prop(\"Status\") == \"Done\" or current.prop(\"Status\") == \"Shipped\").length() / prop(\"Subtasks\").length() * 10)) + \" \" + format(round(prop(\"Subtasks\").filter(current.prop(\"Status\") == \"Done\" or current.prop(\"Status\") == \"Shipped\").length() / prop(\"Subtasks\").length() * 100, 0)) + \"%\")",
          format: "text"
        ),
        required: false,
        sort_order: "k"
      ),
      PropertyDef(
        id: "p_sum",
        name: "Progress summary",
        kind: Formula(
          expression: "if(prop(\"Subtasks\").length() == 0, \"\", format(prop(\"Subtasks\").filter(current.prop(\"Status\") == \"Done\" or current.prop(\"Status\") == \"Shipped\").length()) + \"/\" + format(prop(\"Subtasks\").length()) + \" subtasks\")",
          format: "text"
        ),
        required: false,
        sort_order: "l"
      ),
      PropertyDef(
        id: "p_ratio",
        name: "Completion ratio",
        kind: Formula(
          expression: "if(prop(\"Subtasks\").length() == 0, 0, round(prop(\"Subtasks\").filter(current.prop(\"Status\") == \"Done\" or current.prop(\"Status\") == \"Shipped\").length() / prop(\"Subtasks\").length(), 2))",
          format: "number"
        ),
        required: false,
        sort_order: "m"
      ),
      PropertyDef(
        id: "demo_mo",
        name: "Demo month",
        kind: Formula(
          expression: "if(empty(prop(\"Demo date\")), empty(), formatDate(prop(\"Demo date\"), \"YYYY-MM\"))",
          format: "text"
        ),
        required: false,
        sort_order: "n"
      )
    ],
    version: 1
  )

  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  task1 = DbRow(
    id: "t1",
    database_id: "db_tasks",
    page_id: "pg_t1",
    cells: {"title": TextVal("Schema"), "status": SelectVal(option_id: "done")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  task2 = DbRow(
    id: "t2",
    database_id: "db_tasks",
    page_id: "pg_t2",
    cells: {"title": TextVal("Parser"), "status": SelectVal(option_id: "ship")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  # Use option_id "shipped" from schema above
  task2_fixed = DbRow(
    id: "t2",
    database_id: "db_tasks",
    page_id: "pg_t2",
    cells: {"title": TextVal("Parser"), "status": SelectVal(option_id: "shipped")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  task3 = DbRow(
    id: "t3",
    database_id: "db_tasks",
    page_id: "pg_t3",
    cells: {"title": TextVal("UI"), "status": SelectVal(option_id: "todo")},
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  _ignore = task2

  init_row = DbRow(
    id: "i1",
    database_id: "db_inits",
    page_id: "pg_i1",
    cells: {
      "title": TextVal("Formula Parity"),
      "subtasks": RelationVal(row_ids: ["t1", "t2", "t3"]),
      "tmode": SelectVal(option_id: "sub"),
      "mins": NumberVal(10.0),
      "occ": NumberVal(52.0),
      "demo": DateVal(start: Date.parse_iso("2026-06-15") or stop "d1", end_date: None)
    },
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  rels = {
    "subtasks": [
      FormulaRelatedRow(def: tasks_def, row: task1),
      FormulaRelatedRow(def: tasks_def, row: task2_fixed),
      FormulaRelatedRow(def: tasks_def, row: task3)
    ]
  }
  out = evaluate_row_formulas(init_def, init_row, {}, rels)
  assert out.get("hrs") == Some(NumberVal("8.7".to_decimal or stop "8.7"))
  assert out.get("p_bar") == Some(TextVal("██████░░░░ 67%"))
  assert out.get("p_sum") == Some(TextVal("2/3 subtasks"))
  assert out.get("p_disp") == Some(TextVal("██████░░░░ 67% — 2/3 subtasks"))
  assert out.get("p_ratio") == Some(NumberVal("0.67".to_decimal or stop "0.67"))
  assert out.get("demo_mo") == Some(TextVal("2026-06"))
  assert evaluate_formula(
    "formatDate(prop(\"Demo date\"), \"MMM YYYY\")",
    init_def,
    init_row,
    {},
    rels
  ) == Ok(TextVal("Jun 2026"))
  assert evaluate_formula(
    "formatDate(prop(\"Demo date\"), \"MMMM DD, YYYY\")",
    init_def,
    init_row,
    {},
    rels
  ) == Ok(TextVal("June 15, 2026"))

  # Empty subtasks + manual checklist + 0-arg empty() return Empty
  empty_row = DbRow(
    id: "i2",
    database_id: "db_inits",
    page_id: "pg_i2",
    cells: {
      "title": TextVal("Checklist Work"),
      "tmode": SelectVal(option_id: "chk"),
      "m_pct": NumberVal("0.4".to_decimal or stop "0.4")
    },
    created_by: "usr_1",
    created_at: t0,
    updated_at: t0,
    archived_at: None,
    version: 1
  )
  out_empty = evaluate_row_formulas(init_def, empty_row, {}, {"subtasks": []})
  assert out_empty.get("hrs") == Some(NumberVal(0.0))
  assert out_empty.get("p_bar") == Some(TextVal(""))
  assert out_empty.get("p_disp") == Some(TextVal("40% checklist"))
  assert out_empty.get("p_ratio") == Some(NumberVal(0.0))
  assert out_empty.get("demo_mo") == Some(Empty)

  # Validation catches syntax / comment errors cleanly
  assert validate_formula("if(1, 2") != None
  assert validate_formula("/* unclosed comment") != None
  assert validate_formula("") != None
  assert validate_formula("1 + 2") == None
end
