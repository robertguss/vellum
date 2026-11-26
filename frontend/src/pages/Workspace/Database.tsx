import { Link } from "@inertiajs/react";
import { Calendar as CalIcon, Columns, ExternalLink, Filter, Plus, Table2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  CellValue,
  Collection,
  DatabaseDef,
  DbViewDef,
  EnrichedRow,
  FilterOp,
  PropertyDef,
  SelectOption,
  SelectOptionColor,
  ViewQueryResult,
} from "../../lib/types";

interface DatabasePageProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  database: DatabaseDef;
  views: DbViewDef[];
  rows: EnrichedRow[];
}

const SELECT_COLOR_CLASSES: Record<SelectOptionColor, string> = {
  gray: "border-stone-200 bg-stone-100 text-stone-700",
  blue: "border-blue-200 bg-blue-50 text-blue-700",
  green: "border-emerald-200 bg-emerald-50 text-emerald-700",
  amber: "border-amber-200 bg-amber-50 text-amber-800",
  red: "border-red-200 bg-red-50 text-red-700",
  purple: "border-purple-200 bg-purple-50 text-purple-700",
};

function getEffectiveCell(er: EnrichedRow, propId: string): CellValue {
  return er.effective_cells?.[propId] ?? er.rollups?.[propId] ?? er.row.cells?.[propId] ?? "empty";
}

function getRowTitle(er: EnrichedRow, properties: PropertyDef[]): string {
  if (er.title && er.title.trim()) return er.title;
  const titleProp = properties.find((p) => p.kind === "title");
  if (titleProp) {
    const c = getEffectiveCell(er, titleProp.id);
    if (c && typeof c === "object" && "text_val" in c && c.text_val.trim()) {
      return c.text_val;
    }
  }
  for (const p of properties) {
    const c = getEffectiveCell(er, p.id);
    if (c && typeof c === "object" && "text_val" in c && c.text_val.trim()) {
      return c.text_val;
    }
  }
  return er.row.id;
}

function formatNumberCell(raw: string, format: string): string {
  const num = Number(raw);
  if (!Number.isFinite(num)) return raw;
  if (format === "currency") {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: "USD",
      minimumFractionDigits: num % 1 === 0 ? 0 : 2,
      maximumFractionDigits: 2,
    }).format(num);
  }
  if (format === "percent") {
    return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(num)}%`;
  }
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 }).format(num);
}

function isSafeHttpUrl(url: string): boolean {
  return /^https?:\/\//i.test(url.trim());
}

function getSelectOptions(prop: PropertyDef): SelectOption[] {
  if (typeof prop.kind === "object" && "select" in prop.kind) {
    return prop.kind.select.options;
  }
  if (typeof prop.kind === "object" && "multi_select" in prop.kind) {
    return prop.kind.multi_select.options;
  }
  return [];
}

function renderCellDisplay(cell: CellValue | undefined, prop: PropertyDef): string {
  if (!cell || cell === "empty") return "—";
  if ("text_val" in cell) return cell.text_val;
  if ("number_val" in cell) {
    const fmt =
      typeof prop.kind === "object" && "number" in prop.kind ? prop.kind.number.format : "plain";
    return formatNumberCell(cell.number_val, fmt);
  }
  if ("date_val" in cell) {
    return cell.date_val.end_date
      ? `${cell.date_val.start} → ${cell.date_val.end_date}`
      : cell.date_val.start;
  }
  if ("select_val" in cell) {
    const opt = getSelectOptions(prop).find((o) => o.id === cell.select_val.option_id);
    return opt ? opt.label : cell.select_val.option_id;
  }
  if ("multi_select_val" in cell) {
    const opts = getSelectOptions(prop);
    return cell.multi_select_val.option_ids
      .map((id) => opts.find((o) => o.id === id)?.label ?? id)
      .join(", ");
  }
  if ("bool_val" in cell) return cell.bool_val ? "Yes" : "No";
  if ("principal_val" in cell) return cell.principal_val.join(", ");
  if ("url_val" in cell) return cell.url_val;
  if ("relation_val" in cell) return `${cell.relation_val.row_ids.length} linked`;
  return "";
}

function encodeInputToCell(prop: PropertyDef, raw: string): CellValue {
  const trimmed = raw.trim();
  if (!trimmed) return "empty";
  if (prop.kind === "title" || prop.kind === "rich_text") return { text_val: trimmed };
  if (prop.kind === "url") return { url_val: trimmed };
  if (prop.kind === "checkbox") return { bool_val: trimmed === "true" || trimmed === "yes" };
  if (typeof prop.kind === "object" && "number" in prop.kind) {
    return { number_val: trimmed };
  }
  if (typeof prop.kind === "object" && "date_prop" in prop.kind) {
    return { date_val: { start: trimmed, end_date: null } };
  }
  if (typeof prop.kind === "object" && "select" in prop.kind) {
    return { select_val: { option_id: trimmed } };
  }
  return { text_val: trimmed };
}

export default function DatabaseView({
  collections = [],
  databases = [],
  database,
  views: initialViews = [],
  rows: initialRows = [],
}: DatabasePageProps) {
  const [views, setViews] = useState<DbViewDef[]>(initialViews);
  const [rows, setRows] = useState<EnrichedRow[]>(initialRows);
  const [mode, setMode] = useState<"table" | "board" | "calendar">("table");
  const [filterProp, setFilterProp] = useState<string>("");
  const [filterOp, setFilterOp] = useState<FilterOp>("eq");
  const [filterVal, setFilterVal] = useState<string>("");
  const [sortProp, setSortProp] = useState<string>("");
  const [sortDesc, setSortDesc] = useState(false);

  const [newTitle, setNewTitle] = useState("");
  const [newCellDrafts, setNewCellDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selectProp = useMemo(
    () =>
      database.properties.find(
        (p) => typeof p.kind === "object" && "select" in p.kind
      ) ?? null,
    [database.properties]
  );

  const dateProp = useMemo(
    () =>
      database.properties.find(
        (p) => typeof p.kind === "object" && "date_prop" in p.kind
      ) ?? null,
    [database.properties]
  );

  async function runQuery(viewId?: string | null) {
    setBusy(true);
    setError(null);
    try {
      const filters =
        filterProp && (filterVal.trim() || filterOp === "is_empty" || filterOp === "is_not_empty")
          ? [{ prop_id: filterProp, op: filterOp, value: filterVal.trim() }]
          : [];
      const sorts = sortProp ? [{ prop_id: sortProp, desc: sortDesc }] : [];
      const res = await apiFetch<ViewQueryResult>(`/api/databases/${database.id}/query`, {
        method: "POST",
        body: JSON.stringify({
          view_id: viewId ?? null,
          filters,
          filter_match_all: true,
          sorts,
          from_date: null,
          to_date: null,
        }),
      });
      setRows(res.rows);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Query failed");
    } finally {
      setBusy(false);
    }
  }

  async function handleCreateRow(e: React.FormEvent) {
    e.preventDefault();
    if (!newTitle.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const titleProp = database.properties.find((p) => p.kind === "title") ?? database.properties[0];
      const cells: Record<string, CellValue> = {};
      if (titleProp) {
        cells[titleProp.id] = { text_val: newTitle.trim() };
      }
      for (const prop of database.properties) {
        if (titleProp && prop.id === titleProp.id) continue;
        const raw = newCellDrafts[prop.id];
        if (raw && raw.trim()) {
          cells[prop.id] = encodeInputToCell(prop, raw);
        }
      }
      await apiFetch(`/api/databases/${database.id}/rows`, {
        method: "POST",
        body: JSON.stringify({
          cells,
          markdown: null,
          reason: "row added from UI",
        }),
      });
      setNewTitle("");
      setNewCellDrafts({});
      await runQuery(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create row");
    } finally {
      setBusy(false);
    }
  }

  async function handleUpdateRowCell(er: EnrichedRow, propId: string, cellValue: CellValue) {
    setBusy(true);
    setError(null);
    try {
      const nextCells = { ...er.row.cells, [propId]: cellValue };
      await apiFetch(`/api/databases/${database.id}/rows/${er.row.id}`, {
        method: "PATCH",
        body: JSON.stringify({
          cells: nextCells,
          expected_version: er.row.version,
          reason: `updated ${propId}`,
        }),
      });
      await runQuery(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update row");
    } finally {
      setBusy(false);
    }
  }

  async function handleSaveCurrentView() {
    const kind =
      mode === "board" && selectProp
        ? {
            board_view: {
              group_by_prop_id: selectProp.id,
              card_prop_ids: database.properties.slice(0, 3).map((p) => p.id),
              hide_empty_groups: false,
            },
          }
        : mode === "calendar" && dateProp
          ? {
              calendar_view: {
                date_prop_id: dateProp.id,
                card_prop_ids: database.properties.slice(0, 2).map((p) => p.id),
              },
            }
          : {
              table_view: {
                visible_prop_ids: database.properties.map((p) => p.id),
                column_widths: {},
              },
            };
    try {
      const saved = await apiFetch<DbViewDef>(`/api/databases/${database.id}/views`, {
        method: "POST",
        body: JSON.stringify({
          name: `${mode.charAt(0).toUpperCase()}${mode.slice(1)} View`,
          kind,
          filters: [],
          filter_match_all: true,
          sorts: sortProp ? [{ prop_id: sortProp, desc: sortDesc }] : [],
        }),
      });
      setViews((prev) => [...prev, saved]);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save view");
    }
  }

  const boardColumns = useMemo(() => {
    if (!selectProp) return [];
    const opts = getSelectOptions(selectProp);
    const grouped: Array<{
      id: string;
      label: string;
      color: SelectOptionColor;
      items: EnrichedRow[];
    }> = opts.map((o) => ({
      id: o.id,
      label: o.label,
      color: o.color,
      items: [],
    }));
    const uncategorized: EnrichedRow[] = [];
    for (const r of rows) {
      const c = getEffectiveCell(r, selectProp.id);
      const optId = c && typeof c === "object" && "select_val" in c ? c.select_val.option_id : null;
      const target = optId ? grouped.find((g) => g.id === optId) : undefined;
      if (target) {
        target.items.push(r);
      } else {
        uncategorized.push(r);
      }
    }
    if (uncategorized.length > 0) {
      grouped.push({ id: "", label: "Unassigned", color: "gray", items: uncategorized });
    }
    return grouped;
  }, [rows, selectProp]);

  const calendarGroups = useMemo(() => {
    if (!dateProp) return [];
    const byDate = new Map<string, EnrichedRow[]>();
    for (const r of rows) {
      const c = getEffectiveCell(r, dateProp.id);
      const d =
        c && typeof c === "object" && "date_val" in c ? c.date_val.start : "Unscheduled";
      const list = byDate.get(d) ?? [];
      list.push(r);
      byDate.set(d, list);
    }
    return Array.from(byDate.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  }, [rows, dateProp]);

  const runQueryRef = useRef(runQuery);
  runQueryRef.current = runQuery;

  useEffect(() => {
    setRows(initialRows);
  }, [initialRows]);

  useEffect(() => {
    setViews(initialViews);
  }, [initialViews]);

  const handleRealtimeEvent = useCallback((eventName: string) => {
    if (
      eventName === "db.row_created" ||
      eventName === "db.row_updated" ||
      eventName === "db.row_deleted" ||
      eventName === "resync_required"
    ) {
      void runQueryRef.current(null);
    }
  }, []);

  return (
    <WorkspaceLayout
      title={database.title}
      collections={collections}
      databases={databases}
      activeDatabaseId={database.id}
      currentCollectionId={database.collection_id}
      realtimeScope={{ databaseId: database.id }}
      onRealtimeEvent={handleRealtimeEvent}
    >
      <div className="space-y-5">
        <div className="rounded-2xl border border-stone-200 bg-white p-6 flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-stone-950">{database.title}</h1>
            <p className="text-sm text-stone-500 mt-0.5">
              {database.description || `${rows.length} rows · ${views.length} saved views`}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <div className="inline-flex rounded-xl border border-stone-200 bg-stone-50 p-1 text-xs">
              <button
                type="button"
                onClick={() => setMode("table")}
                className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 font-medium ${
                  mode === "table" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <Table2 className="h-3.5 w-3.5" />
                Table
              </button>
              <button
                type="button"
                onClick={() => setMode("board")}
                className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 font-medium ${
                  mode === "board" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <Columns className="h-3.5 w-3.5" />
                Board
              </button>
              <button
                type="button"
                onClick={() => setMode("calendar")}
                className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 font-medium ${
                  mode === "calendar" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <CalIcon className="h-3.5 w-3.5" />
                Calendar
              </button>
            </div>
            <button
              type="button"
              onClick={() => void handleSaveCurrentView()}
              className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50"
            >
              Save View
            </button>
          </div>
        </div>

        {/* Filter & Sort Query Bar */}
        <div className="rounded-xl border border-stone-200 bg-white p-3.5 flex flex-wrap items-center gap-2 text-xs">
          <Filter className="h-3.5 w-3.5 text-stone-400" />
          <select
            value={filterProp}
            onChange={(e) => setFilterProp(e.target.value)}
            className="rounded-md border border-stone-200 px-2 py-1.5 bg-white"
          >
            <option value="">All columns</option>
            {database.properties.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
          <select
            value={filterOp}
            onChange={(e) => setFilterOp(e.target.value as FilterOp)}
            className="rounded-md border border-stone-200 px-2 py-1.5 bg-white"
          >
            <option value="eq">equals</option>
            <option value="neq">not equals</option>
            <option value="contains">contains</option>
            <option value="gt">greater than</option>
            <option value="lt">less than</option>
          </select>
          <input
            value={filterVal}
            onChange={(e) => setFilterVal(e.target.value)}
            placeholder="Filter value..."
            className="rounded-md border border-stone-200 px-2.5 py-1.5 w-36 outline-none"
          />
          <span className="text-stone-300 px-1">|</span>
          <select
            value={sortProp}
            onChange={(e) => setSortProp(e.target.value)}
            className="rounded-md border border-stone-200 px-2 py-1.5 bg-white"
          >
            <option value="">Default order</option>
            {database.properties.map((p) => (
              <option key={p.id} value={p.id}>
                Sort: {p.name}
              </option>
            ))}
          </select>
          <label className="flex items-center gap-1 text-stone-600">
            <input
              type="checkbox"
              checked={sortDesc}
              onChange={(e) => setSortDesc(e.target.checked)}
            />
            Desc
          </label>
          <button
            type="button"
            disabled={busy}
            onClick={() => void runQuery(null)}
            className="ml-auto rounded-lg bg-stone-900 px-3 py-1.5 font-medium text-white hover:bg-stone-800 disabled:opacity-50"
          >
            Run Query
          </button>
        </div>

        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}

        {/* Views */}
        {mode === "table" && (
          <div className="rounded-2xl border border-stone-200 bg-white overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-stone-200 bg-stone-50/70 text-xs text-stone-500">
                <tr>
                  {database.properties.map((p) => (
                    <th key={p.id} className="px-4 py-3 font-medium">
                      {p.name}
                    </th>
                  ))}
                  <th className="px-4 py-3 font-medium text-right">Page</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-stone-100">
                {rows.map((er) => {
                  const rowTitle = getRowTitle(er, database.properties);
                  return (
                    <tr key={er.row.id} className="hover:bg-stone-50/70">
                      {database.properties.map((p) => {
                        const opts = getSelectOptions(p);
                        const curCell = getEffectiveCell(er, p.id);
                        const curOptId =
                          curCell && typeof curCell === "object" && "select_val" in curCell
                            ? curCell.select_val.option_id
                            : "";
                        const selectedOpt = curOptId ? opts.find((o) => o.id === curOptId) : undefined;
                        const pillCls = selectedOpt
                          ? SELECT_COLOR_CLASSES[selectedOpt.color]
                          : "border-stone-200 bg-white text-stone-700";

                        return (
                          <td key={p.id} className="px-4 py-2.5 whitespace-nowrap">
                            {p.kind === "title" ? (
                              <Link
                                href={`/p/${er.row.page_id}`}
                                className="font-medium text-stone-900 hover:text-blue-700 hover:underline"
                              >
                                {rowTitle}
                              </Link>
                            ) : opts.length > 0 && typeof p.kind === "object" && "select" in p.kind ? (
                              <select
                                value={curOptId}
                                disabled={busy}
                                onChange={(e) =>
                                  void handleUpdateRowCell(
                                    er,
                                    p.id,
                                    e.target.value
                                      ? { select_val: { option_id: e.target.value } }
                                      : "empty"
                                  )
                                }
                                className={`rounded-full border px-2.5 py-0.5 text-xs font-medium outline-none cursor-pointer ${pillCls}`}
                              >
                                <option value="">—</option>
                                {opts.map((o) => (
                                  <option key={o.id} value={o.id}>
                                    {o.label}
                                  </option>
                                ))}
                              </select>
                            ) : opts.length > 0 &&
                              typeof p.kind === "object" &&
                              "multi_select" in p.kind ? (
                              <div className="flex flex-wrap gap-1">
                                {curCell &&
                                typeof curCell === "object" &&
                                "multi_select_val" in curCell &&
                                curCell.multi_select_val.option_ids.length > 0 ? (
                                  curCell.multi_select_val.option_ids.map((id) => {
                                    const opt = opts.find((o) => o.id === id);
                                    const cls = opt
                                      ? SELECT_COLOR_CLASSES[opt.color]
                                      : SELECT_COLOR_CLASSES.gray;
                                    return (
                                      <span
                                        key={id}
                                        className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-medium ${cls}`}
                                      >
                                        {opt?.label ?? id}
                                      </span>
                                    );
                                  })
                                ) : (
                                  <span className="text-stone-400">—</span>
                                )}
                              </div>
                            ) : p.kind === "checkbox" ? (
                              <label className="inline-flex items-center gap-2 cursor-pointer">
                                <input
                                  type="checkbox"
                                  disabled={busy}
                                  checked={
                                    typeof curCell === "object" && "bool_val" in curCell
                                      ? curCell.bool_val
                                      : false
                                  }
                                  onClick={(e) => e.stopPropagation()}
                                  onChange={(e) =>
                                    void handleUpdateRowCell(er, p.id, {
                                      bool_val: e.target.checked,
                                    })
                                  }
                                  className="h-4 w-4 rounded border-stone-300 text-stone-900 focus:ring-stone-500"
                                />
                              </label>
                            ) : p.kind === "url" &&
                              curCell &&
                              typeof curCell === "object" &&
                              "url_val" in curCell &&
                              isSafeHttpUrl(curCell.url_val) ? (
                              <a
                                href={curCell.url_val}
                                target="_blank"
                                rel="noreferrer"
                                className="text-xs text-blue-600 hover:underline"
                              >
                                {curCell.url_val}
                              </a>
                            ) : typeof p.kind === "object" &&
                              ("number" in p.kind || "rollup" in p.kind) ? (
                              <span className="font-mono text-xs tabular-nums text-stone-800">
                                {renderCellDisplay(curCell, p)}
                              </span>
                            ) : (
                              <span className="text-stone-800">{renderCellDisplay(curCell, p)}</span>
                            )}
                          </td>
                        );
                      })}
                      <td className="px-4 py-2.5 text-right whitespace-nowrap">
                        <Link
                          href={`/p/${er.row.page_id}`}
                          className="inline-flex items-center gap-1 text-xs text-blue-600 hover:underline"
                        >
                          Open
                          <ExternalLink className="h-3 w-3" />
                        </Link>
                      </td>
                    </tr>
                  );
                })}
                {rows.length === 0 && (
                  <tr>
                    <td
                      colSpan={database.properties.length + 1}
                      className="px-4 py-6 text-center text-xs text-stone-400"
                    >
                      No matching rows yet.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        )}

        {mode === "board" && (
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            {!selectProp && (
              <div className="col-span-full rounded-xl border border-stone-200 bg-white p-6 text-sm text-stone-500">
                Add a Select property to group rows in Kanban Board view.
              </div>
            )}
            {selectProp &&
              boardColumns.map((col) => {
                const summaryProps = database.properties
                  .filter((p) => p.kind !== "title" && p.id !== selectProp.id)
                  .slice(0, 3);
                return (
                  <div
                    key={col.id || "none"}
                    className="rounded-2xl border border-stone-200 bg-stone-50/70 p-3 space-y-2.5"
                  >
                    <div className="flex items-center justify-between px-1 text-xs font-semibold text-stone-700">
                      <span
                        className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-medium ${SELECT_COLOR_CLASSES[col.color]}`}
                      >
                        {col.label}
                      </span>
                      <span className="rounded-full bg-stone-200 px-2 py-0.5 text-[10px] text-stone-700">
                        {col.items.length}
                      </span>
                    </div>
                    <div className="space-y-2">
                      {col.items.map((er) => (
                        <div
                          key={er.row.id}
                          className="rounded-xl border border-stone-200 bg-white p-3.5 shadow-2xs space-y-2.5"
                        >
                          <Link
                            href={`/p/${er.row.page_id}`}
                            className="text-sm font-medium text-stone-900 hover:text-blue-700 hover:underline block"
                          >
                            {getRowTitle(er, database.properties)}
                          </Link>

                          {summaryProps.length > 0 && (
                            <div className="flex flex-wrap items-center gap-1.5 text-[11px]">
                              {summaryProps.map((sp) => {
                                const c = getEffectiveCell(er, sp.id);
                                if (!c || c === "empty") return null;
                                if (typeof c === "object" && "select_val" in c) {
                                  const opt = getSelectOptions(sp).find(
                                    (o) => o.id === c.select_val.option_id
                                  );
                                  const cls = opt
                                    ? SELECT_COLOR_CLASSES[opt.color]
                                    : SELECT_COLOR_CLASSES.gray;
                                  return (
                                    <span
                                      key={sp.id}
                                      className={`rounded-full border px-2 py-0.5 text-[10px] font-medium ${cls}`}
                                    >
                                      {opt?.label ?? c.select_val.option_id}
                                    </span>
                                  );
                                }
                                if (typeof c === "object" && "bool_val" in c) {
                                  return (
                                    <span
                                      key={sp.id}
                                      className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${
                                        c.bool_val
                                          ? "bg-emerald-50 text-emerald-700 border border-emerald-200"
                                          : "bg-stone-100 text-stone-500 border border-stone-200"
                                      }`}
                                    >
                                      {c.bool_val ? `✓ ${sp.name}` : `○ ${sp.name}`}
                                    </span>
                                  );
                                }
                                return (
                                  <span
                                    key={sp.id}
                                    className="rounded bg-stone-100 px-1.5 py-0.5 text-[10px] text-stone-600"
                                  >
                                    {sp.name}: {renderCellDisplay(c, sp)}
                                  </span>
                                );
                              })}
                            </div>
                          )}

                          <div className="flex flex-wrap gap-1 pt-0.5">
                            {getSelectOptions(selectProp).map((opt) => (
                              <button
                                key={opt.id}
                                type="button"
                                disabled={busy || col.id === opt.id}
                                onClick={() =>
                                  void handleUpdateRowCell(er, selectProp.id, {
                                    select_val: { option_id: opt.id },
                                  })
                                }
                                className={`rounded px-2 py-0.5 text-[10px] border transition ${
                                  col.id === opt.id
                                    ? `${SELECT_COLOR_CLASSES[opt.color]} font-semibold`
                                    : "border-stone-200 text-stone-500 hover:bg-stone-50"
                                }`}
                              >
                                {opt.label}
                              </button>
                            ))}
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                );
              })}
          </div>
        )}

        {mode === "calendar" && (
          <div className="space-y-3">
            {!dateProp && (
              <div className="rounded-xl border border-stone-200 bg-white p-6 text-sm text-stone-500">
                Add a Date property to view items in Calendar mode.
              </div>
            )}
            {dateProp &&
              calendarGroups.map(([dateKey, items]) => (
                <div
                  key={dateKey}
                  className="rounded-2xl border border-stone-200 bg-white p-4 space-y-2"
                >
                  <div className="text-xs font-mono font-semibold text-blue-700">{dateKey}</div>
                  <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2.5">
                    {items.map((er) => (
                      <Link
                        key={er.row.id}
                        href={`/p/${er.row.page_id}`}
                        className="rounded-lg border border-stone-200 bg-stone-50 px-3 py-2 text-xs font-medium text-stone-900 hover:bg-stone-100"
                      >
                        {getRowTitle(er, database.properties)}
                      </Link>
                    ))}
                  </div>
                </div>
              ))}
          </div>
        )}

        {/* Quick Create Row */}
        <form
          onSubmit={handleCreateRow}
          className="rounded-2xl border border-stone-200 bg-white p-4 flex flex-wrap items-center gap-2.5"
        >
          <input
            required
            value={newTitle}
            onChange={(e) => setNewTitle(e.target.value)}
            placeholder="New row title..."
            className="flex-1 min-w-[180px] rounded-lg border border-stone-200 px-3 py-2 text-xs outline-none focus:border-stone-500"
          />
          {selectProp && (
            <select
              value={newCellDrafts[selectProp.id] ?? ""}
              onChange={(e) =>
                setNewCellDrafts((prev) => ({ ...prev, [selectProp.id]: e.target.value }))
              }
              className="rounded-lg border border-stone-200 px-2.5 py-2 text-xs bg-white"
            >
              <option value="">Status...</option>
              {getSelectOptions(selectProp).map((o) => (
                <option key={o.id} value={o.id}>
                  {o.label}
                </option>
              ))}
            </select>
          )}
          {dateProp && (
            <input
              type="date"
              value={newCellDrafts[dateProp.id] ?? ""}
              onChange={(e) =>
                setNewCellDrafts((prev) => ({ ...prev, [dateProp.id]: e.target.value }))
              }
              className="rounded-lg border border-stone-200 px-2.5 py-2 text-xs"
            />
          )}
          <button
            type="submit"
            disabled={busy || !newTitle.trim()}
            className="inline-flex items-center gap-1 rounded-lg bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
          >
            <Plus className="h-3.5 w-3.5" />
            Add Row
          </button>
        </form>
      </div>
    </WorkspaceLayout>
  );
}
