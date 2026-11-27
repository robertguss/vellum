import { Link } from "@inertiajs/react";
import { ArrowUpRight, Database as DbIcon, Kanban, Plus, RefreshCw, Table as TableIcon } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { ApiError, apiFetch } from "../lib/api";
import type {
  CellValue,
  DatabaseDef,
  DbViewDef,
  EnrichedRow,
  PrincipalSummary,
  RelationTargetOption,
  ScenarioQueryResponse,
  ViewQueryResult,
} from "../lib/types";
import InlineCellEditor, {
  formatNumberCell,
  formatSignedDecimal,
  getEffectiveCell,
  getRowTitle,
} from "./database/InlineCellEditor";

interface DatabaseShowPayload {
  database: DatabaseDef;
  views: DbViewDef[];
  rows: EnrichedRow[];
  principals: PrincipalSummary[];
  relation_targets: Record<string, RelationTargetOption[]>;
  scenarios: Array<{ id: string; title: string; status: string; target_database_id: string | null }>;
}

interface EmbeddedDatabaseProps {
  databaseId: string;
  viewId: string | null;
  databases?: DatabaseDef[];
  principals?: PrincipalSummary[];
  relationTargets?: Record<string, RelationTargetOption[]>;
  activeScenarioId?: string | null;
  onInspectRow?: (databaseId: string, rowId: string, pageId: string) => void;
  onMetricInvalidated?: () => void;
}

export default function EmbeddedDatabase({
  databaseId,
  viewId,
  databases = [],
  principals: propPrincipals = [],
  relationTargets: propRelationTargets = {},
  activeScenarioId = null,
  onInspectRow,
  onMetricInvalidated,
}: EmbeddedDatabaseProps) {
  const [database, setDatabase] = useState<DatabaseDef | null>(null);
  const [views, setViews] = useState<DbViewDef[]>([]);
  const [rows, setRows] = useState<EnrichedRow[]>([]);
  const [principals, setPrincipals] = useState<PrincipalSummary[]>(propPrincipals);
  const [relationTargets, setRelationTargets] = useState<Record<string, RelationTargetOption[]>>(
    propRelationTargets
  );
  const [scenarioData, setScenarioData] = useState<ScenarioQueryResponse | null>(null);
  const [selectedViewId, setSelectedViewId] = useState<string | null>(viewId);
  const [mode, setMode] = useState<"table" | "board">("table");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [newRowTitle, setNewRowTitle] = useState("");
  const [creating, setCreating] = useState(false);

  useEffect(() => {
    setSelectedViewId(viewId);
  }, [viewId]);

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const show = await apiFetch<DatabaseShowPayload>(`/api/databases/${databaseId}`);
      setDatabase(show.database);
      setViews(show.views);
      setPrincipals(show.principals);
      setRelationTargets(show.relation_targets);

      const effectiveViewId =
        selectedViewId && show.views.some((v) => v.id === selectedViewId)
          ? selectedViewId
          : (show.views[0]?.id ?? null);
      if (effectiveViewId !== selectedViewId) {
        setSelectedViewId(effectiveViewId);
      }

      const activeView = show.views.find((v) => v.id === effectiveViewId);
      if (activeView && typeof activeView.kind === "object" && "board_view" in activeView.kind) {
        setMode("board");
      }

      if (activeScenarioId) {
        try {
          const scenRes = await apiFetch<ScenarioQueryResponse>(
            `/api/databases/${databaseId}/scenarios/${activeScenarioId}/query`,
            {
              method: "POST",
              body: JSON.stringify({
                view_id: effectiveViewId,
                filters: [],
                filter_match_all: true,
                sorts: [],
                from_date: null,
                to_date: null,
              }),
            }
          );
          setScenarioData(scenRes);
          setRows(scenRes.query_result.rows);
          return;
        } catch {
          setScenarioData(null);
        }
      } else {
        setScenarioData(null);
      }

      if (effectiveViewId) {
        const q = await apiFetch<ViewQueryResult>(`/api/databases/${databaseId}/query`, {
          method: "POST",
          body: JSON.stringify({
            view_id: effectiveViewId,
            filters: [],
            filter_match_all: true,
            sorts: [],
            from_date: null,
            to_date: null,
          }),
        });
        setRows(q.rows);
      } else {
        setRows(show.rows);
      }
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.message
          : "Unable to load embedded database (restricted or missing)."
      );
    } finally {
      setLoading(false);
    }
  }, [databaseId, selectedViewId, activeScenarioId]);

  useEffect(() => {
    void loadData();
  }, [loadData]);

  const titleProp = useMemo(
    () => database?.properties.find((p) => p.kind === "title") ?? database?.properties[0],
    [database]
  );

  const visibleProps = useMemo(() => {
    if (!database) return [];
    const activeView = views.find((v) => v.id === selectedViewId);
    if (activeView && typeof activeView.kind === "object" && "table_view" in activeView.kind) {
      const ids = activeView.kind.table_view.visible_prop_ids;
      const byId = new Map(database.properties.map((p) => [p.id, p]));
      const ordered = ids.map((id) => byId.get(id)).filter(Boolean);
      if (ordered.length > 0) return ordered as typeof database.properties;
    }
    return database.properties.slice(0, 5);
  }, [database, views, selectedViewId]);

  const boardGroupProp = useMemo(
    () =>
      database?.properties.find(
        (p) => (typeof p.kind === "object" && "select" in p.kind) || p.kind === "checkbox"
      ) ?? null,
    [database]
  );

  async function handleCellCommit(er: EnrichedRow, propId: string, cellValue: CellValue) {
    if (!database) return;
    if (activeScenarioId && scenarioData) {
      await apiFetch(`/api/proposals/${activeScenarioId}/mutations`, {
        method: "POST",
        body: JSON.stringify({
          kind: "db_row_update",
          database_id: database.id,
          row_id: er.row.id,
          cells: { [propId]: cellValue },
          expected_version: er.row.version,
          reason: `Inline scenario edit on embedded DB`,
        }),
      });
    } else {
      await apiFetch(`/api/databases/${database.id}/rows/${er.row.id}`, {
        method: "PATCH",
        body: JSON.stringify({
          cells: { [propId]: cellValue },
          expected_version: er.row.version,
          reason: `Inline edit from embedded database block`,
        }),
      });
    }
    await loadData();
    onMetricInvalidated?.();
  }

  async function handleQuickAddRow(e: React.FormEvent) {
    e.preventDefault();
    if (!database || !titleProp || !newRowTitle.trim()) return;
    setCreating(true);
    setError(null);
    try {
      const cells: Record<string, CellValue> = {
        [titleProp.id]: { text_val: newRowTitle.trim() },
      };
      if (activeScenarioId && scenarioData) {
        await apiFetch(`/api/proposals/${activeScenarioId}/mutations`, {
          method: "POST",
          body: JSON.stringify({
            kind: "db_row_create",
            database_id: database.id,
            cells,
            markdown: null,
            reason: `Quick add row via embedded DB`,
          }),
        });
      } else {
        await apiFetch(`/api/databases/${database.id}/rows`, {
          method: "POST",
          body: JSON.stringify({
            cells,
            markdown: null,
            reason: `Quick add row via embedded DB`,
          }),
        });
      }
      setNewRowTitle("");
      await loadData();
      onMetricInvalidated?.();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to add row");
    } finally {
      setCreating(false);
    }
  }

  if (loading && !database) {
    return (
      <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-4 text-xs text-stone-500">
        Loading embedded database <span className="font-mono">{databaseId}</span>...
      </div>
    );
  }

  if (error || !database) {
    return (
      <div className="rounded-xl border border-amber-200 bg-amber-50/60 p-4 flex items-center justify-between gap-3 text-xs text-amber-900">
        <div className="flex items-center gap-2">
          <DbIcon className="h-4 w-4 text-amber-700 shrink-0" />
          <span>{error ?? `Embedded database ${databaseId} unavailable`}</span>
        </div>
        <Link
          href={`/d/${databaseId}`}
          className="inline-flex items-center gap-1 font-medium text-amber-800 hover:underline shrink-0"
        >
          Open DB <ArrowUpRight className="h-3 w-3" />
        </Link>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-stone-200 bg-white overflow-hidden shadow-2xs my-1">
      {/* Header bar */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-stone-200 bg-stone-50/80 px-3.5 py-2.5">
        <div className="flex items-center gap-2 min-w-0">
          <DbIcon className="h-4 w-4 text-stone-600 shrink-0" />
          <span className="text-xs font-semibold text-stone-900 truncate">{database.title}</span>
          <span className="rounded-full bg-stone-200/70 px-2 py-0.5 text-[10px] font-mono text-stone-600">
            {rows.length} {rows.length === 1 ? "row" : "rows"}
          </span>
          {scenarioData && (
            <span className="rounded-full bg-indigo-100 border border-indigo-200 px-2 py-0.5 text-[10px] font-medium text-indigo-800">
              Scenario: {scenarioData.proposal.title}
            </span>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          {views.length > 1 && (
            <select
              value={selectedViewId ?? ""}
              onChange={(e) => setSelectedViewId(e.target.value || null)}
              className="rounded-md border border-stone-200 bg-white px-2 py-1 text-[11px] text-stone-700"
            >
              {views.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.name}
                </option>
              ))}
            </select>
          )}
          <div className="flex items-center rounded-md border border-stone-200 bg-white p-0.5">
            <button
              type="button"
              onClick={() => setMode("table")}
              className={`inline-flex items-center gap-1 rounded px-2 py-0.5 text-[11px] font-medium ${
                mode === "table" ? "bg-stone-900 text-white" : "text-stone-500 hover:text-stone-800"
              }`}
            >
              <TableIcon className="h-3 w-3" />
              Table
            </button>
            {boardGroupProp && (
              <button
                type="button"
                onClick={() => setMode("board")}
                className={`inline-flex items-center gap-1 rounded px-2 py-0.5 text-[11px] font-medium ${
                  mode === "board"
                    ? "bg-stone-900 text-white"
                    : "text-stone-500 hover:text-stone-800"
                }`}
              >
                <Kanban className="h-3 w-3" />
                Board
              </button>
            )}
          </div>
          <button
            type="button"
            onClick={() => void loadData()}
            className="rounded-md border border-stone-200 bg-white p-1 text-stone-500 hover:text-stone-800"
            title="Refresh embedded database"
          >
            <RefreshCw className={`h-3 w-3 ${loading ? "animate-spin" : ""}`} />
          </button>
          <Link
            href={`/d/${database.id}`}
            onClick={(e) => e.stopPropagation()}
            className="inline-flex items-center gap-1 rounded-md border border-stone-200 bg-white px-2 py-1 text-[11px] font-medium text-blue-700 hover:bg-blue-50"
          >
            Open DB <ArrowUpRight className="h-3 w-3" />
          </Link>
        </div>
      </div>

      {/* Scenario Delta Strip if active */}
      {scenarioData && scenarioData.deltas.some((d) => d.changed) && (
        <div className="flex flex-wrap items-center gap-2 border-b border-indigo-100 bg-indigo-50/70 px-3.5 py-1.5 text-[11px]">
          {scenarioData.deltas
            .filter((d) => d.changed)
            .map((d) => (
              <span
                key={d.prop_id}
                className="inline-flex items-center gap-1.5 rounded-full bg-white border border-indigo-200 px-2 py-0.5 font-mono text-indigo-900"
              >
                <span className="font-sans font-medium text-indigo-700">{d.prop_name}:</span>
                <span>{formatNumberCell(d.live_total, d.format)} →</span>
                <strong>{formatNumberCell(d.scenario_total, d.format)}</strong>
                <span className="text-emerald-700 font-semibold">
                  ({formatSignedDecimal(d.delta, d.format)})
                </span>
              </span>
            ))}
        </div>
      )}

      {/* Body */}
      {mode === "table" ? (
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse text-xs">
            <thead>
              <tr className="border-b border-stone-200 bg-stone-50/50 text-[11px] font-medium text-stone-500">
                {visibleProps.map((prop) => (
                  <th key={prop.id} className="px-3 py-2 whitespace-nowrap">
                    {prop.name}
                  </th>
                ))}
                <th className="px-2 py-2 w-16 text-right">Inspect</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-stone-100">
              {rows.length === 0 && (
                <tr>
                  <td
                    colSpan={visibleProps.length + 1}
                    className="px-3 py-4 text-center text-xs text-stone-400"
                  >
                    No rows match this view yet.
                  </td>
                </tr>
              )}
              {rows.map((er) => {
                const rowBadge = scenarioData?.row_changes[er.row.id];
                return (
                  <tr
                    key={er.row.id}
                    className={`hover:bg-stone-50/80 ${
                      rowBadge === "added"
                        ? "bg-emerald-50/40"
                        : rowBadge === "modified"
                          ? "bg-amber-50/40"
                          : ""
                    }`}
                  >
                    {visibleProps.map((prop) => (
                      <td key={prop.id} className="px-3 py-1.5 align-middle">
                        <InlineCellEditor
                          er={er}
                          prop={prop}
                          database={database}
                          databases={databases.length > 0 ? databases : [database]}
                          principals={principals}
                          relationTargets={relationTargets}
                          onCommit={(val) => handleCellCommit(er, prop.id, val)}
                        />
                      </td>
                    ))}
                    <td className="px-2 py-1.5 text-right whitespace-nowrap">
                      {onInspectRow ? (
                        <button
                          type="button"
                          onClick={() => onInspectRow(database.id, er.row.id, er.row.page_id)}
                          className="rounded px-1.5 py-0.5 text-[11px] font-medium text-stone-500 hover:bg-stone-100 hover:text-stone-900"
                        >
                          Drawer
                        </button>
                      ) : (
                        <Link
                          href={`/p/${er.row.page_id}`}
                          className="text-[11px] text-blue-600 hover:underline"
                        >
                          Page
                        </Link>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="p-3 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2.5 bg-stone-50/50">
          {rows.map((er) => {
            const title = getRowTitle(er, database.properties);
            const grpCell = boardGroupProp ? getEffectiveCell(er, boardGroupProp.id) : null;
            const grpLabel =
              grpCell && typeof grpCell === "object" && "select_val" in grpCell
                ? grpCell.select_val.option_id
                : "Item";
            return (
              <button
                key={er.row.id}
                type="button"
                onClick={() => onInspectRow?.(database.id, er.row.id, er.row.page_id)}
                className="text-left rounded-lg border border-stone-200 bg-white p-2.5 hover:border-stone-400 transition space-y-1 shadow-2xs"
              >
                <div className="text-[10px] font-mono text-stone-400 uppercase">{grpLabel}</div>
                <div className="text-xs font-medium text-stone-900 truncate">{title}</div>
              </button>
            );
          })}
        </div>
      )}

      {/* Quick Add Row */}
      <form
        onSubmit={(e) => void handleQuickAddRow(e)}
        className="flex items-center gap-2 border-t border-stone-100 bg-stone-50/40 px-3 py-2"
      >
        <Plus className="h-3.5 w-3.5 text-stone-400 shrink-0" />
        <input
          type="text"
          value={newRowTitle}
          onChange={(e) => setNewRowTitle(e.target.value)}
          placeholder={`Quick add to ${database.title}...`}
          className="flex-1 bg-transparent text-xs text-stone-800 placeholder:text-stone-400 outline-none"
        />
        {newRowTitle.trim() && (
          <button
            type="submit"
            disabled={creating}
            className="rounded-md bg-stone-900 px-2.5 py-1 text-[11px] font-medium text-white hover:bg-stone-800 disabled:opacity-50"
          >
            {creating ? "Adding..." : "Add Row"}
          </button>
        )}
      </form>
    </div>
  );
}
