## Vellum v3 Milestone 1 Slice 1.2 Integration Tests:
## Status, Email, FileList, UniqueId, Audit Columns, PercentPerGroup Rollups,
## Multi-Pass Deterministic Notion Formulas, Kanban Status Board, and What-If Scenarios.
module Tests.V3m1b
use Main
use Api
use Arvo.WebTest
use Date
use Domain.DatabaseModel{
  CellValue,
  DbViewKind,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor
}
use Domain.Types{CollectionWritePolicy}
use Json
use Routes.Databases
use Routes.Workspace

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
  end
end

test "v3 M1.2: Schema Parity, UniqueId, Audit Columns, PercentPerGroup, Multi-Pass Formulas & What-If Scenario"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-v3m1b.js",
        "css": ["assets/main-v3m1b.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-v3m1b.js": "console.log('v3m1b');",
    "public/assets/main-v3m1b.css": "body{margin:0}"
  })
  t0 = Time.parse("2026-12-06T10:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({"VELLUM_MODE": "solo", "VELLUM_INSECURE_COOKIES": "1"})
  rng = SecureRandom.seeded(20261208)
  empty_net = Network.fake({})

  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  cb = ApiTest.send(
    Main,
    WebTest.prepare(
      guest,
      Api.get("/auth/solo/login?return_to=/").with_header("Host", "127.0.0.1:8080")
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cb.status == 303
  owner = WebTest.absorb(guest, cb)

  col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "delivery-ops",
          name: "Delivery Ops",
          description: None,
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert col_res.status == 201
  col_id = must_json(col_res.text).text_at("id") or stop "col_id"

  # 1. Invalid formula syntax is rejected on POST /api/databases with 422
  bad_db_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Broken Formula DB",
          description: None,
          properties: [
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "bad_f",
              name: "Bad",
              kind: Formula(expression: "if(1, 2", format: "plain"),
              required: false,
              sort_order: "b"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_db_res.status == 422

  # 2. Create Tasks DB with Status, Email, FileList, UniqueId, Audit columns & Formula
  status_opts = [
    SelectOption(id: "not_started", label: "Not Started", color: Gray),
    SelectOption(id: "in_progress", label: "In Progress", color: Blue),
    SelectOption(id: "done", label: "Done", color: Green)
  ]
  tasks_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Tasks",
          description: Some("Tracked tasks"),
          properties: [
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "status",
              name: "Status",
              kind: Status(options: status_opts, done_option_ids: ["done"]),
              required: false,
              sort_order: "b"
            ),
            PropertyDef(id: "contact", name: "Contact", kind: Email, required: false, sort_order: "c"),
            PropertyDef(
              id: "attachments",
              name: "Attachments",
              kind: FileList,
              required: false,
              sort_order: "d"
            ),
            PropertyDef(
              id: "ticket_id",
              name: "Ticket ID",
              kind: UniqueId(prefix: "TSK"),
              required: false,
              sort_order: "e"
            ),
            PropertyDef(
              id: "created_at",
              name: "Created At",
              kind: CreatedTime,
              required: false,
              sort_order: "f"
            ),
            PropertyDef(
              id: "created_by",
              name: "Created By",
              kind: CreatedBy,
              required: false,
              sort_order: "g"
            ),
            PropertyDef(
              id: "updated_at",
              name: "Updated At",
              kind: LastEditedTime,
              required: false,
              sort_order: "h"
            ),
            PropertyDef(
              id: "updated_by",
              name: "Updated By",
              kind: LastEditedBy,
              required: false,
              sort_order: "i"
            ),
            PropertyDef(
              id: "minutes",
              name: "Minutes",
              kind: Number(format: "plain"),
              required: false,
              sort_order: "j"
            ),
            PropertyDef(
              id: "freq",
              name: "Freq",
              kind: Number(format: "plain"),
              required: false,
              sort_order: "k"
            ),
            PropertyDef(
              id: "hours_saved",
              name: "Hours saved / year",
              kind: Formula(
                expression: "/* annual */ round((prop(\"Minutes\") * prop(\"Freq\")) / 60, 1)",
                format: "plain"
              ),
              required: false,
              sort_order: "l"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tasks_res.status == 201
  tj = must_json(tasks_res.text)
  tasks_db_id = tj.text_at("database.id") or stop "tasks_db_id"
  tasks_ver = tj.int_at("database.version") or stop "tasks_ver"

  # 3. Create 3 Task rows -> TSK-1, TSK-2, TSK-3
  t1_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Ship schema engine"),
            "status": SelectVal(option_id: "done"),
            "contact": TextVal("ops@example.test"),
            "attachments": FilesVal(attachment_ids: ["att_demo_1"]),
            "minutes": NumberVal(10.0),
            "freq": NumberVal(52.0)
          },
          markdown: None,
          reason: Some("seed task 1")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert t1_res.status == 201
  t1_j = must_json(t1_res.text)
  t1_id = t1_j.text_at("row.id") or stop "t1_id"
  assert (t1_j.get("row") or Json.Null).text_at("cells.ticket_id.text_val") == Some("TSK-1")

  t2_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Verify rollup formulas"),
            "status": SelectVal(option_id: "in_progress"),
            "contact": TextVal("eng@example.test"),
            "minutes": NumberVal(15.0),
            "freq": NumberVal(12.0)
          },
          markdown: None,
          reason: Some("seed task 2")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert t2_res.status == 201
  t2_j = must_json(t2_res.text)
  t2_id = t2_j.text_at("row.id") or stop "t2_id"
  assert (t2_j.get("row") or Json.Null).text_at("cells.ticket_id.text_val") == Some("TSK-2")

  t3_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Add board grouping"),
            "status": SelectVal(option_id: "in_progress"),
            "minutes": NumberVal(5.0),
            "freq": NumberVal(24.0)
          },
          markdown: None,
          reason: Some("seed task 3")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert t3_res.status == 201
  t3_j = must_json(t3_res.text)
  t3_id = t3_j.text_at("row.id") or stop "t3_id"
  assert (t3_j.get("row") or Json.Null).text_at("cells.ticket_id.text_val") == Some("TSK-3")

  # Query Tasks DB -> audit columns + formula (10 * 52 / 60 -> 8.7)
  tq_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: None,
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert tq_res.status == 200
  t_rows = must_json(tq_res.text).list_at("rows") or []
  t1_enr = t_rows.find(fn(er) (er.get("row") or Json.Null).text_at("id") == Some(t1_id) end) or
    stop "t1_enr"
  t1_rolls = t1_enr.get("rollups") or Json.Null
  assert t1_rolls.text_at("hours_saved.number_val") == Some("8.7")
  assert t1_rolls.text_at("created_at.text_val") != None
  assert t1_rolls.text_at("updated_at.text_val") != None
  assert (t1_rolls.get("created_by") or Json.Null).list_at("principal_val") != None
  assert (t1_rolls.get("updated_by") or Json.Null).list_at("principal_val") != None

  # Patch Task 2 validly + verify 422 on invalid Email, UniqueId overwrite, and bad Formula schema patch
  patch_ok = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{tasks_db_id}/rows/#{t2_id}").with_json(
        Databases.UpdateRowInput(
          cells: {"contact": TextVal("eng-updated@example.test")},
          expected_version: 1,
          reason: Some("update contact")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert patch_ok.status == 200
  patch_ok_j = must_json(patch_ok.text)
  assert (patch_ok_j.get("row") or Json.Null).text_at("cells.ticket_id.text_val") == Some("TSK-2")
  t2_ver = patch_ok_j.int_at("row.version") or stop "t2_ver"

  bad_email = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Bad Email Row"), "contact": TextVal("not-an-email")},
          markdown: None,
          reason: Some("invalid email")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_email.status == 422

  mut_uid = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{tasks_db_id}/rows/#{t2_id}").with_json(
        Databases.UpdateRowInput(
          cells: {"ticket_id": TextVal("TSK-999")},
          expected_version: t2_ver,
          reason: Some("overwrite uid")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_uid.status == 422

  bad_patch_schema = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/databases/#{tasks_db_id}").with_json(
        Databases.UpdateDatabaseSchemaInput(
          title: None,
          description: None,
          properties: Some([
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "broken",
              name: "Broken",
              kind: Formula(expression: "/* unclosed comment", format: "plain"),
              required: false,
              sort_order: "b"
            )
          ]),
          expected_version: tasks_ver
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_patch_schema.status == 422

  # 4. Create Initiatives DB with Relation, PercentPerGroup Rollup, DateProp & multi-pass Formulas
  init_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases").with_json(
        Databases.CreateDatabaseInput(
          collection_id: col_id,
          parent_page_id: None,
          title: "Initiatives",
          description: Some("Tracked initiatives"),
          properties: [
            PropertyDef(id: "title", name: "Title", kind: Title, required: true, sort_order: "a"),
            PropertyDef(
              id: "tasks",
              name: "Tasks",
              kind: Relation(target_db_id: tasks_db_id, inverse_prop_id: None),
              required: false,
              sort_order: "b"
            ),
            PropertyDef(
              id: "completion",
              name: "Completion",
              kind: Rollup(
                relation_prop_id: "tasks",
                target_prop_id: "status",
                agg: PercentPerGroup
              ),
              required: false,
              sort_order: "c"
            ),
            PropertyDef(
              id: "demo_date",
              name: "Demo Date",
              kind: DateProp(include_time: false),
              required: false,
              sort_order: "d"
            ),
            PropertyDef(
              id: "progress_display",
              name: "Progress display",
              kind: Formula(
                expression: "prop(\"Progress bar\") + \" \" + prop(\"Progress summary\")",
                format: "plain"
              ),
              required: false,
              sort_order: "e"
            ),
            PropertyDef(
              id: "progress_bar",
              name: "Progress bar",
              kind: Formula(
                expression: "repeat(\"█\", floor(prop(\"Completion\") * 10)) + repeat(\"░\", 10 - floor(prop(\"Completion\") * 10))",
                format: "plain"
              ),
              required: false,
              sort_order: "f"
            ),
            PropertyDef(
              id: "progress_summary",
              name: "Progress summary",
              kind: Formula(
                expression: "format(round(prop(\"Completion\") * 100, 0)) + \"% complete\"",
                format: "plain"
              ),
              required: false,
              sort_order: "g"
            ),
            PropertyDef(
              id: "demo_month",
              name: "Demo month",
              kind: Formula(
                expression: "if(empty(prop(\"Demo Date\")), empty(), formatDate(prop(\"Demo Date\"), \"MMM YYYY\"))",
                format: "plain"
              ),
              required: false,
              sort_order: "h"
            )
          ]
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert init_res.status == 201
  init_db_id = must_json(init_res.text).text_at("database.id") or stop "init_db_id"

  dt_oct = Date.parse_iso("2026-10-15") or stop "dt_oct"
  init_a_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{init_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {
            "title": TextVal("Q4 Platform Initiative"),
            "tasks": RelationVal(row_ids: [t1_id, t2_id, t3_id]),
            "demo_date": DateVal(start: dt_oct, end_date: None)
          },
          markdown: None,
          reason: Some("seed initiative A")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert init_a_res.status == 201
  init_a_id = must_json(init_a_res.text).text_at("row.id") or stop "init_a_id"

  init_b_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{init_db_id}/rows").with_json(
        Databases.CreateRowInput(
          cells: {"title": TextVal("Unscheduled Initiative")},
          markdown: None,
          reason: Some("seed initiative B")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert init_b_res.status == 201
  init_b_id = must_json(init_b_res.text).text_at("row.id") or stop "init_b_id"

  iq_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{init_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: None,
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert iq_res.status == 200
  i_rows = must_json(iq_res.text).list_at("rows") or []
  enr_a = i_rows.find(fn(er) (er.get("row") or Json.Null).text_at("id") == Some(init_a_id) end) or
    stop "enr_a"
  rolls_a = enr_a.get("rollups") or Json.Null
  assert rolls_a.text_at("completion.number_val") == Some("0.3333")
  assert rolls_a.text_at("progress_bar.text_val") == Some("███░░░░░░░")
  assert rolls_a.text_at("progress_summary.text_val") == Some("33% complete")
  assert rolls_a.text_at("progress_display.text_val") == Some("███░░░░░░░ 33% complete")
  assert rolls_a.text_at("demo_month.text_val") == Some("Oct 2026")

  enr_b = i_rows.find(fn(er) (er.get("row") or Json.Null).text_at("id") == Some(init_b_id) end) or
    stop "enr_b"
  rolls_b = enr_b.get("rollups") or Json.Null
  comp_b = rolls_b.text_at("completion.number_val") or ""
  assert comp_b == "0" or comp_b == "0.0"
  assert rolls_b.get("demo_month") == Some(Json.String("empty"))

  # 5. Kanban BoardView grouped by Status
  bv_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/views").with_json(
        Databases.CreateViewInput(
          name: "Status Board",
          kind: BoardView(group_by_prop_id: "status", card_prop_ids: ["ticket_id"], hide_empty_groups: false),
          filters: [],
          filter_match_all: true,
          sorts: []
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bv_res.status == 201
  bv_id = must_json(bv_res.text).text_at("id") or stop "bv_id"

  bv_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{tasks_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: Some(bv_id),
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bv_q.status == 200
  groups = must_json(bv_q.text).list_at("board_groups") or []
  assert groups.size == 4
  assert (groups.get(0) or Json.Null).text_at("group_key") == Some("not_started")
  assert ((groups.get(0) or Json.Null).list_at("rows") or []).size == 0
  assert (groups.get(1) or Json.Null).text_at("group_key") == Some("in_progress")
  assert ((groups.get(1) or Json.Null).list_at("rows") or []).size == 2
  assert (groups.get(2) or Json.Null).text_at("group_key") == Some("done")
  assert ((groups.get(2) or Json.Null).list_at("rows") or []).size == 1
  assert (groups.get(3) or Json.Null).text_at("group_key") == Some("__none__")
  assert ((groups.get(3) or Json.Null).list_at("rows") or []).size == 0

  # 6. What-If Scenario dynamic PercentPerGroup + Formula recomputation
  scen_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{init_db_id}/scenarios").with_json(
        Json.Object({
          "title": Json.String("Sprint Completion What-If"),
          "reason": Json.String("Model completing Task 2"),
          "branch_kind": Json.String("scenario")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen_res.status == 201
  scen_id = must_json(scen_res.text).text_at("id") or stop "scen_id"

  mut_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{scen_id}/mutations").with_json(
        Json.Object({
          "kind": Json.String("db_row_update"),
          "database_id": Json.String(tasks_db_id),
          "row_id": Json.String(t2_id),
          "cells": Json.Object({"status": Json.Object({"select_val": Json.Object({"option_id": Json.String("done")})})}),
          "expected_version": Json.int(t2_ver),
          "reason": Json.String("mark task 2 done in scenario")
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mut_res.status == 200

  scen_q = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{init_db_id}/scenarios/#{scen_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: None,
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert scen_q.status == 200
  s_rows = must_json(scen_q.text).list_at("query_result.rows") or []
  scen_a = s_rows.find(fn(er) (er.get("row") or Json.Null).text_at("id") == Some(init_a_id) end) or
    stop "scen_a"
  scen_rolls = scen_a.get("rollups") or Json.Null
  assert scen_rolls.text_at("completion.number_val") == Some("0.6667")
  assert scen_rolls.text_at("progress_summary.text_val") == Some("67% complete")

  # Confirm Live Initiatives remained 0.3333
  live_q_after = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/databases/#{init_db_id}/query").with_json(
        Databases.QueryDatabaseInput(
          view_id: None,
          filters: [],
          filter_match_all: None,
          sorts: [],
          from_date: None,
          to_date: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert live_q_after.status == 200
  l_rows = must_json(live_q_after.text).list_at("rows") or []
  live_a = l_rows.find(fn(er) (er.get("row") or Json.Null).text_at("id") == Some(init_a_id) end) or
    stop "live_a"
  assert (live_a.get("rollups") or Json.Null).text_at("completion.number_val") == Some("0.3333")
end
