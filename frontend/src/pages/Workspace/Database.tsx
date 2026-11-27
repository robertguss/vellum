import { Link, router } from "@inertiajs/react";
import {
  Bot,
  Calendar as CalIcon,
  CalendarRange,
  Check,
  Columns,
  Copy,
  GitBranch,
  Layers,
  LayoutGrid,
  Pencil,
  Play,
  Plus,
  RefreshCw,
  Save,
  SlidersHorizontal,
  Sparkles,
  Table2,
  Trash2,
  X,
} from "lucide-react";
import type {
  AiCellMeta,
  AiColumnUsageSummary,
  AiFeedSyncResult,
  RunAiColumnResponse,
} from "../../lib/types";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import InlineCellEditor, {
  SELECT_COLOR_CLASSES,
  formatNumberCell,
  getEffectiveCell,
  getRowTitle,
  getSelectOptions,
  renderCellDisplay,
} from "../../components/database/InlineCellEditor";
import ScenarioDeltaRibbon from "../../components/database/ScenarioDeltaRibbon";
import SchemaBuilderDrawer from "../../components/database/SchemaBuilderDrawer";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  CellValue,
  Collection,
  DatabaseDef,
  DbFilterRule,
  DbSortRule,
  DbViewDef,
  DbViewKind,
  EnrichedRow,
  FilterOp,
  PrincipalSummary,
  PropertyDef,
  ProposalMeta,
  RelationTargetOption,
  ScenarioQueryResponse,
  SelectOptionColor,
  ViewQueryResult,
} from "../../lib/types";

interface DatabasePageProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  database: DatabaseDef;
  views: DbViewDef[];
  rows: EnrichedRow[];
  principals?: PrincipalSummary[];
  relation_targets?: Record<string, RelationTargetOption[]>;
  scenarios?: ProposalMeta[];
  ai_cell_meta?: Record<string, AiCellMeta>;
  ai_usage?: Record<string, AiColumnUsageSummary>;
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
  if (typeof prop.kind === "object" && ("select" in prop.kind || "status" in prop.kind)) {
    return { select_val: { option_id: trimmed } };
  }
  return { text_val: trimmed };
}

function viewKindIcon(kind: DbViewKind) {
  if ("board_view" in kind) return <Columns className="h-3.5 w-3.5" />;
  if ("calendar_view" in kind) return <CalIcon className="h-3.5 w-3.5" />;
  if ("gallery_view" in kind) return <LayoutGrid className="h-3.5 w-3.5" />;
  if ("timeline_view" in kind) return <CalendarRange className="h-3.5 w-3.5" />;
  return <Table2 className="h-3.5 w-3.5" />;
}

export default function DatabaseView({
  collections = [],
  databases = [],
  database: initialDatabase,
  views: initialViews = [],
  rows: initialRows = [],
  principals = [],
  relation_targets: initialRelationTargets = {},
  scenarios: initialScenarios = [],
  ai_cell_meta: initialAiCellMeta = {},
  ai_usage: initialAiUsage = {},
}: DatabasePageProps) {
  const [liveDb, setLiveDb] = useState<DatabaseDef>(initialDatabase);
  const [views, setViews] = useState<DbViewDef[]>(initialViews);
  const [activeViewId, setActiveViewId] = useState<string | null>(initialViews[0]?.id ?? null);
  const [liveRows, setLiveRows] = useState<EnrichedRow[]>(initialRows);
  const [relationTargets, setRelationTargets] = useState<Record<string, RelationTargetOption[]>>(
    initialRelationTargets
  );
  const [scenarios, setScenarios] = useState<ProposalMeta[]>(initialScenarios);

  const [activeScenario, setActiveScenario] = useState<ProposalMeta | null>(null);
  const [scenarioData, setScenarioData] = useState<ScenarioQueryResponse | null>(null);

  const [mode, setMode] = useState<"table" | "board" | "calendar" | "gallery" | "timeline">(
    () => {
      const firstKind = initialViews[0]?.kind;
      if (firstKind && "board_view" in firstKind) return "board";
      if (firstKind && "calendar_view" in firstKind) return "calendar";
      if (firstKind && "gallery_view" in firstKind) return "gallery";
      if (firstKind && "timeline_view" in firstKind) return "timeline";
      return "table";
    }
  );
  const [filterProp, setFilterProp] = useState<string>("");
  const [filterOp, setFilterOp] = useState<FilterOp>("eq");
  const [filterVal, setFilterVal] = useState<string>("");
  const [sortProp, setSortProp] = useState<string>("");
  const [sortDesc, setSortDesc] = useState(false);

  const [newTitle, setNewTitle] = useState("");
  const [newCellDrafts, setNewCellDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Saved-view editing state
  const [renamingViewId, setRenamingViewId] = useState<string | null>(null);
  const [renameViewName, setRenameViewName] = useState("");
  const [newViewOpen, setNewViewOpen] = useState(false);
  const [newViewName, setNewViewName] = useState("");
  const [newViewType, setNewViewType] = useState<
    "table" | "board" | "calendar" | "gallery" | "timeline"
  >("table");
  const [newViewGroupBy, setNewViewGroupBy] = useState("");
  const [newViewDateProp, setNewViewDateProp] = useState("");
  const [newViewCoverProp, setNewViewCoverProp] = useState("");
  const [newViewCardSize, setNewViewCardSize] = useState<"sm" | "md" | "lg">("md");
  const [newViewEndDateProp, setNewViewEndDateProp] = useState("");

  // Drawers & Modals
  const [schemaDrawerOpen, setSchemaDrawerOpen] = useState(false);
  const [forkModalOpen, setForkModalOpen] = useState(false);
  const [forkTitle, setForkTitle] = useState("");
  const [forkReason, setForkReason] = useState("");

  // Kanban drag state
  const [draggingRowId, setDraggingRowId] = useState<string | null>(null);
  const [dragOverColKey, setDragOverColKey] = useState<string | null>(null);

  const activeDb = activeScenario && scenarioData ? scenarioData.database : liveDb;
  const rows = activeScenario && scenarioData ? scenarioData.query_result.rows : liveRows;
  const activeView = useMemo(
    () => views.find((v) => v.id === activeViewId) ?? null,
    [views, activeViewId]
  );

  const [aiCellMeta, setAiCellMeta] = useState<Record<string, AiCellMeta>>(initialAiCellMeta);
  const [aiUsage, setAiUsage] = useState<Record<string, AiColumnUsageSummary>>(initialAiUsage);
  const [aiBusyPropId, setAiBusyPropId] = useState<string | null>(null);
  const [aiSyncing, setAiSyncing] = useState(false);
  const [aiLastSync, setAiLastSync] = useState<AiFeedSyncResult | null>(null);
  const [aiProposalNotice, setAiProposalNotice] = useState<{
    propName: string;
    proposalId: string;
    processed: number;
  } | null>(null);

  const hasAiDerivedProps = useMemo(
    () =>
      activeDb.properties.some(
        (p) => typeof p.kind === "object" && "ai_derived" in p.kind
      ),
    [activeDb.properties]
  );

  async function refreshAiStatus() {
    try {
      const data = await apiFetch<{
        cells?: Record<string, AiCellMeta>;
        usage?: Record<string, AiColumnUsageSummary>;
      }>(`/api/databases/${activeDb.id}/ai-columns/status`);
      if (data?.cells) setAiCellMeta(data.cells);
      if (data?.usage) setAiUsage(data.usage);
    } catch {
      // ignore background status refresh failures
    }
  }

  async function handleSyncAiFeed() {
    setAiSyncing(true);
    setError(null);
    try {
      const syncData = await apiFetch<AiFeedSyncResult>(
        `/api/databases/${activeDb.id}/ai-columns/sync-feed`,
        {
          method: "POST",
          body: "{}",
        }
      );
      setAiLastSync(syncData);
      await refreshAiStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to sync AI column feed");
    } finally {
      setAiSyncing(false);
    }
  }

  async function handleRunAiColumn(
    propId: string,
    rowIds: string[] | null = null,
    onlyStale = false
  ) {
    setAiBusyPropId(propId);
    setError(null);
    try {
      const data = await apiFetch<RunAiColumnResponse>(
        `/api/databases/${activeDb.id}/ai-columns/${propId}/run`,
        {
          method: "POST",
          body: JSON.stringify({
            row_ids: rowIds,
            only_stale: onlyStale,
            mode_override: null,
            deterministic_fallback: false,
          }),
        }
      );
      const prop = activeDb.properties.find((p) => p.id === propId);
      if (data.proposal) {
        setAiProposalNotice({
          propName: prop?.name ?? propId,
          proposalId: data.proposal.id,
          processed: data.updated_count,
        });
      }
      await Promise.all([runQuery(activeViewId), refreshAiStatus()]);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "AI column execution failed");
    } finally {
      setAiBusyPropId(null);
    }
  }

  const groupableProps = useMemo(
    () =>
      activeDb.properties.filter(
        (p) =>
          p.kind === "checkbox" ||
          (typeof p.kind === "object" && ("select" in p.kind || "status" in p.kind)) ||
          (typeof p.kind === "object" &&
            "ai_derived" in p.kind &&
            (p.kind.ai_derived.output_kind === "ai_bool" ||
              (typeof p.kind.ai_derived.output_kind === "object" &&
                "ai_select" in p.kind.ai_derived.output_kind)))
      ),
    [activeDb.properties]
  );

  const boardGroupProp = useMemo(() => {
    if (activeView && "board_view" in activeView.kind) {
      const gid = activeView.kind.board_view.group_by_prop_id;
      const found = activeDb.properties.find((p) => p.id === gid);
      if (found) return found;
    }
    return groupableProps[0] ?? null;
  }, [activeDb.properties, activeView, groupableProps]);

  const dateProps = useMemo(
    () =>
      activeDb.properties.filter(
        (p) =>
          (typeof p.kind === "object" && "date_prop" in p.kind) ||
          (typeof p.kind === "object" &&
            "ai_derived" in p.kind &&
            p.kind.ai_derived.output_kind === "ai_date")
      ),
    [activeDb.properties]
  );

  const dateProp = useMemo(() => {
    if (activeView && "calendar_view" in activeView.kind) {
      const dpid = activeView.kind.calendar_view.date_prop_id;
      const found = activeDb.properties.find((p) => p.id === dpid);
      if (found) return found;
    }
    return dateProps[0] ?? null;
  }, [activeDb.properties, activeView, dateProps]);

  const coverProps = useMemo(
    () =>
      activeDb.properties.filter(
        (p) => p.kind === "url" || p.kind === "rich_text" || p.kind === "title"
      ),
    [activeDb.properties]
  );

  const galleryCoverProp = useMemo(() => {
    if (activeView && "gallery_view" in activeView.kind) {
      const cid = activeView.kind.gallery_view.cover_prop_id;
      if (cid) {
        const found = activeDb.properties.find((p) => p.id === cid);
        if (found) return found;
      }
      return null;
    }
    return activeDb.properties.find((p) => p.kind === "url") ?? null;
  }, [activeDb.properties, activeView]);

  const galleryCardSize = useMemo(() => {
    if (activeView && "gallery_view" in activeView.kind) {
      const sz = activeView.kind.gallery_view.card_size;
      if (sz === "sm" || sz === "lg" || sz === "md") return sz;
    }
    return "md" as const;
  }, [activeView]);

  const timelineStartProp = useMemo(() => {
    if (activeView && "timeline_view" in activeView.kind) {
      const sp = activeView.kind.timeline_view.start_date_prop_id;
      const found = activeDb.properties.find((p) => p.id === sp);
      if (found) return found;
    }
    return dateProps[0] ?? null;
  }, [activeDb.properties, activeView, dateProps]);

  const timelineEndProp = useMemo(() => {
    if (activeView && "timeline_view" in activeView.kind) {
      const ep = activeView.kind.timeline_view.end_date_prop_id;
      if (ep) {
        const found = activeDb.properties.find((p) => p.id === ep);
        if (found) return found;
      }
    }
    return dateProps[1] ?? null;
  }, [activeDb.properties, activeView, dateProps]);

  const firstSelectProp = useMemo(
    () =>
      activeDb.properties.find(
        (p) => typeof p.kind === "object" && ("select" in p.kind || "status" in p.kind)
      ) ?? null,
    [activeDb.properties]
  );

  const firstNumberProp = useMemo(
    () =>
      activeDb.properties.find((p) => typeof p.kind === "object" && "number" in p.kind) ?? null,
    [activeDb.properties]
  );

  useEffect(() => {
    setLiveDb(initialDatabase);
  }, [initialDatabase]);

  useEffect(() => {
    setAiCellMeta(initialAiCellMeta);
  }, [initialAiCellMeta]);

  useEffect(() => {
    setAiUsage(initialAiUsage);
  }, [initialAiUsage]);

  useEffect(() => {
    setLiveRows(initialRows);
  }, [initialRows]);

  useEffect(() => {
    setViews(initialViews);
    if (initialViews.length > 0 && !initialViews.some((v) => v.id === activeViewId)) {
      setActiveViewId(initialViews[0].id);
    }
  }, [initialViews, activeViewId]);

  useEffect(() => {
    setRelationTargets(initialRelationTargets);
  }, [initialRelationTargets]);

  useEffect(() => {
    setScenarios(initialScenarios);
    if (activeScenario && !initialScenarios.some((s) => s.id === activeScenario.id)) {
      setActiveScenario(null);
      setScenarioData(null);
    }
  }, [initialScenarios, activeScenario]);

  async function runQuery(
    viewIdOverride?: string | null,
    opts?: {
      filterPropVal?: string;
      filterOpVal?: FilterOp;
      filterInputVal?: string;
      sortPropVal?: string;
      sortDescVal?: boolean;
      scenarioOverride?: ProposalMeta | null;
      skipAdhocFilter?: boolean;
    }
  ) {
    setBusy(true);
    setError(null);
    const fProp = opts?.filterPropVal ?? filterProp;
    const fOp = opts?.filterOpVal ?? filterOp;
    const fVal = opts?.filterInputVal ?? filterVal;
    const sProp = opts?.sortPropVal ?? sortProp;
    const sDesc = opts?.sortDescVal ?? sortDesc;
    const scen = opts && "scenarioOverride" in opts ? opts.scenarioOverride ?? null : activeScenario;

    try {
      const filters =
        !opts?.skipAdhocFilter &&
        fProp &&
        (fVal.trim() || fOp === "is_empty" || fOp === "is_not_empty")
          ? [{ prop_id: fProp, op: fOp, value: fVal.trim() }]
          : [];
      const sorts = sProp ? [{ prop_id: sProp, desc: sDesc }] : [];
      const payload = {
        view_id: viewIdOverride ?? null,
        filters,
        filter_match_all: true,
        sorts,
        from_date: null,
        to_date: null,
      };
      if (scen) {
        const sres = await apiFetch<ScenarioQueryResponse>(
          `/api/databases/${liveDb.id}/scenarios/${scen.id}/query`,
          {
            method: "POST",
            body: JSON.stringify(payload),
          }
        );
        setScenarioData(sres);
      } else {
        const res = await apiFetch<ViewQueryResult>(`/api/databases/${liveDb.id}/query`, {
          method: "POST",
          body: JSON.stringify(payload),
        });
        setLiveRows(res.rows);
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Query failed");
    } finally {
      setBusy(false);
    }
  }

  function applySavedView(v: DbViewDef, scenOverride?: ProposalMeta | null) {
    setActiveViewId(v.id);
    if ("board_view" in v.kind) setMode("board");
    else if ("calendar_view" in v.kind) setMode("calendar");
    else if ("gallery_view" in v.kind) setMode("gallery");
    else if ("timeline_view" in v.kind) setMode("timeline");
    else setMode("table");

    const f0 = v.filters[0];
    const nextFProp = f0?.prop_id ?? "";
    const nextFOp = f0?.op ?? "eq";
    const nextFVal = f0 && typeof f0.value === "string" ? f0.value : "";
    const s0 = v.sorts[0];
    const nextSProp = s0?.prop_id ?? "";
    const nextSDesc = s0?.desc ?? false;
    setFilterProp(nextFProp);
    setFilterOp(nextFOp);
    setFilterVal(nextFVal);
    setSortProp(nextSProp);
    setSortDesc(nextSDesc);
    void runQuery(v.id, {
      filterPropVal: nextFProp,
      filterOpVal: nextFOp,
      filterInputVal: nextFVal,
      sortPropVal: nextSProp,
      sortDescVal: nextSDesc,
      scenarioOverride: scenOverride !== undefined ? scenOverride : activeScenario,
      skipAdhocFilter: true,
    });
  }

  async function handleCreateRow(e: React.FormEvent) {
    e.preventDefault();
    if (!newTitle.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const titleProp =
        activeDb.properties.find((p) => p.kind === "title") ?? activeDb.properties[0];
      const cells: Record<string, CellValue> = {};
      if (titleProp) {
        cells[titleProp.id] = { text_val: newTitle.trim() };
      }
      for (const prop of activeDb.properties) {
        if (titleProp && prop.id === titleProp.id) continue;
        const raw = newCellDrafts[prop.id];
        if (raw && raw.trim()) {
          cells[prop.id] = encodeInputToCell(prop, raw);
        }
      }
      if (activeScenario) {
        await apiFetch(`/api/proposals/${activeScenario.id}/mutations`, {
          method: "POST",
          body: JSON.stringify({
            kind: "db_row_create",
            database_id: activeDb.id,
            cells,
            reason: `create row in scenario '${activeScenario.title}'`,
          }),
        });
      } else {
        await apiFetch(`/api/databases/${liveDb.id}/rows`, {
          method: "POST",
          body: JSON.stringify({
            cells,
            markdown: null,
            reason: "row added from UI",
          }),
        });
      }
      setNewTitle("");
      setNewCellDrafts({});
      await runQuery(activeViewId);
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
      if (activeScenario) {
        await apiFetch(`/api/proposals/${activeScenario.id}/mutations`, {
          method: "POST",
          body: JSON.stringify({
            kind: "db_row_update",
            database_id: activeDb.id,
            row_id: er.row.id,
            cells: { [propId]: cellValue },
            expected_version: null,
            reason: `updated ${propId} in scenario`,
          }),
        });
      } else {
        const nextCells = { ...er.row.cells, [propId]: cellValue };
        await apiFetch(`/api/databases/${liveDb.id}/rows/${er.row.id}`, {
          method: "PATCH",
          body: JSON.stringify({
            cells: nextCells,
            expected_version: er.row.version,
            reason: `updated ${propId}`,
          }),
        });
      }
      await runQuery(activeViewId);
      if (hasAiDerivedProps) {
        await refreshAiStatus();
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update cell");
    } finally {
      setBusy(false);
    }
  }

  async function handleDeleteRow(er: EnrichedRow) {
    setBusy(true);
    setError(null);
    try {
      if (activeScenario) {
        await apiFetch(`/api/proposals/${activeScenario.id}/mutations`, {
          method: "POST",
          body: JSON.stringify({
            kind: "db_row_delete",
            database_id: activeDb.id,
            row_id: er.row.id,
            reason: "removed row in scenario",
          }),
        });
      } else {
        await apiFetch(`/api/databases/${liveDb.id}/rows/${er.row.id}`, {
          method: "DELETE",
        });
      }
      await runQuery(activeViewId);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to delete row");
    } finally {
      setBusy(false);
    }
  }

  async function handleSaveSchema(nextProperties: PropertyDef[]) {
    setBusy(true);
    try {
      if (activeScenario) {
        await apiFetch(`/api/proposals/${activeScenario.id}/mutations`, {
          method: "POST",
          body: JSON.stringify({
            kind: "db_schema_update",
            database_id: activeDb.id,
            properties: nextProperties,
            expected_version: null,
            reason: "schema updated in What-If Scenario",
          }),
        });
        await runQuery(activeViewId);
      } else {
        const updatedDef = await apiFetch<DatabaseDef>(`/api/databases/${liveDb.id}`, {
          method: "PATCH",
          body: JSON.stringify({
            title: null,
            description: null,
            properties: nextProperties,
            expected_version: liveDb.version,
          }),
        });
        setLiveDb(updatedDef);
        router.reload({
          only: ["database", "views", "rows", "relation_targets", "ai_cell_meta", "ai_usage"],
        });
      }
    } finally {
      setBusy(false);
    }
  }

  async function handleCreateView(
    name: string,
    kind: DbViewKind,
    filters: DbFilterRule[] = filterProp && filterVal.trim()
      ? [{ prop_id: filterProp, op: filterOp, value: filterVal.trim() }]
      : [],
    sorts: DbSortRule[] = sortProp ? [{ prop_id: sortProp, desc: sortDesc }] : []
  ) {
    setBusy(true);
    setError(null);
    try {
      const saved = await apiFetch<DbViewDef>(`/api/databases/${liveDb.id}/views`, {
        method: "POST",
        body: JSON.stringify({
          name: name.trim(),
          kind,
          filters,
          filter_match_all: true,
          sorts,
        }),
      });
      setViews((prev) => [...prev, saved]);
      applySavedView(saved);
      setNewViewOpen(false);
      setNewViewName("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create view");
    } finally {
      setBusy(false);
    }
  }

  async function handleSaveCurrentView() {
    const kind: DbViewKind =
      mode === "board" && boardGroupProp
        ? {
            board_view: {
              group_by_prop_id: boardGroupProp.id,
              card_prop_ids: activeDb.properties.slice(0, 3).map((p) => p.id),
              hide_empty_groups: false,
            },
          }
        : mode === "calendar" && dateProp
          ? {
              calendar_view: {
                date_prop_id: dateProp.id,
                card_prop_ids: activeDb.properties.slice(0, 2).map((p) => p.id),
              },
            }
          : mode === "gallery"
            ? {
                gallery_view: {
                  cover_prop_id: galleryCoverProp?.id ?? null,
                  card_prop_ids: activeDb.properties.slice(0, 4).map((p) => p.id),
                  card_size: galleryCardSize,
                },
              }
            : mode === "timeline" && timelineStartProp
              ? {
                  timeline_view: {
                    start_date_prop_id: timelineStartProp.id,
                    end_date_prop_id:
                      timelineEndProp && timelineEndProp.id !== timelineStartProp.id
                        ? timelineEndProp.id
                        : null,
                    card_prop_ids: activeDb.properties.slice(0, 3).map((p) => p.id),
                  },
                }
              : {
                  table_view: {
                    visible_prop_ids: activeDb.properties.map((p) => p.id),
                    column_widths: {},
                  },
                };

    if (activeView) {
      setBusy(true);
      setError(null);
      try {
        const filters =
          filterProp && (filterVal.trim() || filterOp === "is_empty" || filterOp === "is_not_empty")
            ? [{ prop_id: filterProp, op: filterOp, value: filterVal.trim() }]
            : [];
        const sorts = sortProp ? [{ prop_id: sortProp, desc: sortDesc }] : [];
        const updated = await apiFetch<DbViewDef>(
          `/api/databases/${liveDb.id}/views/${activeView.id}`,
          {
            method: "PATCH",
            body: JSON.stringify({
              kind,
              filters,
              filter_match_all: true,
              sorts,
            }),
          }
        );
        setViews((prev) => prev.map((v) => (v.id === updated.id ? updated : v)));
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Failed to save view changes");
      } finally {
        setBusy(false);
      }
      return;
    }

    await handleCreateView(
      `${mode.charAt(0).toUpperCase()}${mode.slice(1)} View`,
      kind
    );
  }

  async function handleRenameViewSubmit(v: DbViewDef) {
    const trimmed = renameViewName.trim();
    setRenamingViewId(null);
    if (!trimmed || trimmed === v.name) return;
    setBusy(true);
    setError(null);
    try {
      const updated = await apiFetch<DbViewDef>(`/api/databases/${liveDb.id}/views/${v.id}`, {
        method: "PATCH",
        body: JSON.stringify({ name: trimmed }),
      });
      setViews((prev) => prev.map((x) => (x.id === updated.id ? updated : x)));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to rename view");
    } finally {
      setBusy(false);
    }
  }

  async function handleDuplicateView(v: DbViewDef) {
    await handleCreateView(`${v.name} (Copy)`, v.kind, v.filters, v.sorts);
  }

  async function handleDeleteView(v: DbViewDef) {
    if (views.length <= 1) return;
    setBusy(true);
    setError(null);
    try {
      await apiFetch(`/api/databases/${liveDb.id}/views/${v.id}`, { method: "DELETE" });
      const remaining = views.filter((x) => x.id !== v.id);
      setViews(remaining);
      if (activeViewId === v.id && remaining[0]) {
        applySavedView(remaining[0]);
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to delete view");
    } finally {
      setBusy(false);
    }
  }

  async function handleForkScenario(e: React.FormEvent) {
    e.preventDefault();
    if (!forkTitle.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const created = await apiFetch<ProposalMeta>(`/api/databases/${liveDb.id}/scenarios`, {
        method: "POST",
        body: JSON.stringify({
          title: forkTitle.trim(),
          reason: forkReason.trim() || `What-If Scenario: ${forkTitle.trim()}`,
          branch_kind: "scenario",
        }),
      });
      setScenarios((prev) => [created, ...prev]);
      setActiveScenario(created);
      setForkModalOpen(false);
      setForkTitle("");
      setForkReason("");
      await runQuery(activeViewId, { scenarioOverride: created });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to fork scenario");
    } finally {
      setBusy(false);
    }
  }

  async function handleMergeScenario() {
    if (!activeScenario) return;
    setBusy(true);
    setError(null);
    try {
      await apiFetch(`/api/proposals/${activeScenario.id}/accept`, {
        method: "POST",
        body: JSON.stringify({ reason: `Merge What-If Scenario '${activeScenario.title}'` }),
      });
      setScenarios((prev) => prev.filter((s) => s.id !== activeScenario.id));
      setActiveScenario(null);
      setScenarioData(null);
      router.reload({ only: ["database", "views", "rows", "scenarios", "relation_targets"] });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not merge scenario");
    } finally {
      setBusy(false);
    }
  }

  async function handleDiscardScenario() {
    if (!activeScenario) return;
    setBusy(true);
    setError(null);
    try {
      await apiFetch(`/api/proposals/${activeScenario.id}/reject`, {
        method: "POST",
        body: JSON.stringify({ reason: `Discard scenario '${activeScenario.title}'` }),
      });
      setScenarios((prev) => prev.filter((s) => s.id !== activeScenario.id));
      setActiveScenario(null);
      setScenarioData(null);
      await runQuery(activeViewId, { scenarioOverride: null });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to discard scenario");
    } finally {
      setBusy(false);
    }
  }

  const boardColumns = useMemo(() => {
    if (!boardGroupProp) return [];
    const colBuckets: Array<{
      id: string;
      label: string;
      color: SelectOptionColor;
      items: EnrichedRow[];
    }> = [];

    const selectOpts =
      typeof boardGroupProp.kind === "object" && "select" in boardGroupProp.kind
        ? boardGroupProp.kind.select.options
        : typeof boardGroupProp.kind === "object" && "status" in boardGroupProp.kind
          ? boardGroupProp.kind.status.options
          : typeof boardGroupProp.kind === "object" &&
              "ai_derived" in boardGroupProp.kind &&
              typeof boardGroupProp.kind.ai_derived.output_kind === "object" &&
              "ai_select" in boardGroupProp.kind.ai_derived.output_kind
            ? boardGroupProp.kind.ai_derived.output_kind.ai_select.options
            : null;
    const isBoolGroup =
      boardGroupProp.kind === "checkbox" ||
      (typeof boardGroupProp.kind === "object" &&
        "ai_derived" in boardGroupProp.kind &&
        boardGroupProp.kind.ai_derived.output_kind === "ai_bool");

    if (selectOpts) {
      for (const o of selectOpts) {
        colBuckets.push({ id: o.id, label: o.label, color: o.color, items: [] });
      }
      const uncategorized: EnrichedRow[] = [];
      for (const r of rows) {
        const c = getEffectiveCell(r, boardGroupProp.id);
        const optId =
          c && typeof c === "object" && "select_val" in c ? c.select_val.option_id : null;
        const target = optId ? colBuckets.find((g) => g.id === optId) : undefined;
        if (target) target.items.push(r);
        else uncategorized.push(r);
      }
      if (uncategorized.length > 0 || colBuckets.length === 0) {
        colBuckets.push({ id: "__none__", label: "Unassigned", color: "gray", items: uncategorized });
      }
    } else if (isBoolGroup) {
      const checkedItems: EnrichedRow[] = [];
      const uncheckedItems: EnrichedRow[] = [];
      for (const r of rows) {
        const c = getEffectiveCell(r, boardGroupProp.id);
        const flag = typeof c === "object" && "bool_val" in c ? c.bool_val : false;
        if (flag) checkedItems.push(r);
        else uncheckedItems.push(r);
      }
      colBuckets.push({ id: "true", label: `Checked (${boardGroupProp.name})`, color: "green", items: checkedItems });
      colBuckets.push({ id: "false", label: `Unchecked (${boardGroupProp.name})`, color: "gray", items: uncheckedItems });
    }
    return colBuckets;
  }, [rows, boardGroupProp]);

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

  const timelineData = useMemo(() => {
    if (!timelineStartProp) {
      return { scheduled: [] as Array<{ er: EnrichedRow; startIso: string; endIso: string; leftPct: number; widthPct: number }>, unscheduled: rows, ticks: [] as string[] };
    }
    const items: Array<{ er: EnrichedRow; startIso: string; endIso: string; startMs: number; endMs: number }> = [];
    const unscheduled: EnrichedRow[] = [];
    for (const er of rows) {
      const sc = getEffectiveCell(er, timelineStartProp.id);
      if (!sc || typeof sc !== "object" || !("date_val" in sc)) {
        unscheduled.push(er);
        continue;
      }
      const startIso = sc.date_val.start;
      const ec = timelineEndProp ? getEffectiveCell(er, timelineEndProp.id) : null;
      const explicitEnd =
        ec && typeof ec === "object" && "date_val" in ec
          ? ec.date_val.end_date ?? ec.date_val.start
          : null;
      const endIso = explicitEnd ?? sc.date_val.end_date ?? startIso;
      const startMs = Date.parse(startIso);
      const rawEndMs = Date.parse(endIso);
      if (!Number.isFinite(startMs)) {
        unscheduled.push(er);
        continue;
      }
      const endMs = Number.isFinite(rawEndMs) && rawEndMs >= startMs ? rawEndMs : startMs;
      items.push({ er, startIso, endIso, startMs, endMs });
    }
    if (items.length === 0) {
      return { scheduled: [], unscheduled, ticks: [] as string[] };
    }
    const DAY = 86400000;
    const minMs = Math.min(...items.map((it) => it.startMs));
    const maxMs = Math.max(...items.map((it) => it.endMs));
    const spanMs = Math.max(DAY, maxMs - minMs + DAY);
    const fmt = (ms: number) => new Date(ms).toISOString().slice(0, 10);
    const ticks = [0, 0.33, 0.66, 1].map((frac) => fmt(minMs + Math.round((spanMs - DAY) * frac)));
    const scheduled = items
      .sort((a, b) => a.startMs - b.startMs)
      .map((it) => {
        const leftPct = Math.max(0, Math.min(96, ((it.startMs - minMs) / spanMs) * 100));
        const rawW = ((it.endMs - it.startMs + DAY) / spanMs) * 100;
        const widthPct = Math.max(4, Math.min(100 - leftPct, rawW));
        return { er: it.er, startIso: it.startIso, endIso: it.endIso, leftPct, widthPct };
      });
    return { scheduled, unscheduled, ticks };
  }, [rows, timelineStartProp, timelineEndProp]);

  const runQueryRef = useRef(runQuery);
  runQueryRef.current = runQuery;
  const activeScenarioRef = useRef(activeScenario);
  activeScenarioRef.current = activeScenario;
  const activeViewIdRef = useRef(activeViewId);
  activeViewIdRef.current = activeViewId;

  const handleRealtimeEvent = useCallback((eventName: string) => {
    if (
      eventName === "db.schema_updated" ||
      eventName === "db.views_updated" ||
      eventName === "proposal.opened" ||
      eventName === "proposal.accepted" ||
      eventName === "proposal.rejected" ||
      eventName === "resync_required"
    ) {
      router.reload({
        only: [
          "database",
          "views",
          "rows",
          "scenarios",
          "relation_targets",
          "ai_cell_meta",
          "ai_usage",
        ],
      });
    }
    if (
      eventName === "db.row_created" ||
      eventName === "db.row_updated" ||
      eventName === "db.row_deleted" ||
      eventName === "proposal.updated"
    ) {
      void runQueryRef.current(activeViewIdRef.current, {
        scenarioOverride: activeScenarioRef.current,
      });
    }
  }, []);

  function moveRowToBoardCol(er: EnrichedRow, targetColId: string) {
    if (!boardGroupProp) return;
    if (
      boardGroupProp.kind === "checkbox" ||
      (typeof boardGroupProp.kind === "object" &&
        "ai_derived" in boardGroupProp.kind &&
        boardGroupProp.kind.ai_derived.output_kind === "ai_bool")
    ) {
      const targetBool = targetColId === "true";
      const curCell = getEffectiveCell(er, boardGroupProp.id);
      const curBool = typeof curCell === "object" && "bool_val" in curCell ? curCell.bool_val : false;
      if (curBool === targetBool) return;
      void handleUpdateRowCell(er, boardGroupProp.id, { bool_val: targetBool });
    } else {
      const curCell = getEffectiveCell(er, boardGroupProp.id);
      const curOpt = typeof curCell === "object" && "select_val" in curCell ? curCell.select_val.option_id : "__none__";
      if (curOpt === targetColId) return;
      void handleUpdateRowCell(
        er,
        boardGroupProp.id,
        targetColId === "__none__" ? "empty" : { select_val: { option_id: targetColId } }
      );
    }
  }

  return (
    <WorkspaceLayout
      title={activeDb.title}
      collections={collections}
      databases={databases}
      activeDatabaseId={liveDb.id}
      currentCollectionId={liveDb.collection_id}
      realtimeScope={{ databaseId: liveDb.id }}
      onRealtimeEvent={handleRealtimeEvent}
    >
      <div className="space-y-4">
        {/* Top Header Card */}
        <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div>
              <div className="flex items-center gap-2">
                <h1 className="text-2xl font-semibold text-stone-950">{activeDb.title}</h1>
                <span className="rounded-md bg-stone-100 px-2 py-0.5 font-mono text-[11px] text-stone-500">
                  v{activeDb.version}
                </span>
              </div>
              <p className="text-sm text-stone-500 mt-0.5">
                {activeDb.description ||
                  `${rows.length} rows · ${views.length} saved views · ${activeDb.properties.length} columns`}
              </p>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {/* Branch Switcher */}
              <div className="inline-flex items-center gap-1.5 rounded-xl border border-stone-200 bg-stone-50 px-2.5 py-1 text-xs">
                <GitBranch className="h-3.5 w-3.5 text-indigo-600" />
                <select
                  value={activeScenario?.id ?? ""}
                  onChange={(e) => {
                    const sid = e.target.value;
                    if (!sid) {
                      setActiveScenario(null);
                      setScenarioData(null);
                      void runQuery(activeViewId, { scenarioOverride: null });
                    } else {
                      const found = scenarios.find((s) => s.id === sid) ?? null;
                      setActiveScenario(found);
                      void runQuery(activeViewId, { scenarioOverride: found });
                    }
                  }}
                  className="bg-transparent font-medium text-stone-800 outline-none cursor-pointer"
                >
                  <option value="">Branch: Live</option>
                  {scenarios.map((s) => (
                    <option key={s.id} value={s.id}>
                      Scenario: {s.title}
                    </option>
                  ))}
                </select>
              </div>

              <button
                type="button"
                onClick={() => {
                  setForkTitle("");
                  setForkReason("");
                  setForkModalOpen(true);
                }}
                className="inline-flex items-center gap-1.5 rounded-xl border border-indigo-200 bg-indigo-50 px-3 py-1.5 text-xs font-medium text-indigo-800 hover:bg-indigo-100"
              >
                <GitBranch className="h-3.5 w-3.5" />
                Fork Scenario
              </button>

              {hasAiDerivedProps && (
                <button
                  type="button"
                  onClick={handleSyncAiFeed}
                  disabled={aiSyncing || aiBusyPropId !== null}
                  title="Sync persistent MoDB feed to detect stale AI cells"
                  className="inline-flex items-center gap-1.5 rounded-xl border border-violet-200 bg-violet-50 px-3 py-1.5 text-xs font-medium text-violet-700 hover:bg-violet-100 disabled:opacity-50"
                >
                  <RefreshCw className={`h-3.5 w-3.5 ${aiSyncing ? "animate-spin" : ""}`} />
                  Sync Stale Feed
                  {aiLastSync && aiLastSync.marked_stale_count > 0 && (
                    <span className="rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-semibold text-amber-800">
                      {aiLastSync.marked_stale_count}
                    </span>
                  )}
                </button>
              )}
              <button
                type="button"
                onClick={() => setSchemaDrawerOpen(true)}
                className="inline-flex items-center gap-1.5 rounded-xl border border-stone-200 bg-white px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50"
              >
                <SlidersHorizontal className="h-3.5 w-3.5" />
                Columns ({activeDb.properties.length})
              </button>

              {/* Quick Mode Switcher */}
              <div className="inline-flex rounded-xl border border-stone-200 bg-stone-50 p-1 text-xs">
                <button
                  type="button"
                  onClick={() => setMode("table")}
                  className={`inline-flex items-center gap-1 rounded-lg px-2.5 py-1 font-medium ${
                    mode === "table" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                  }`}
                >
                  <Table2 className="h-3.5 w-3.5" />
                  Table
                </button>
                <button
                  type="button"
                  onClick={() => setMode("board")}
                  className={`inline-flex items-center gap-1 rounded-lg px-2.5 py-1 font-medium ${
                    mode === "board" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                  }`}
                >
                  <Columns className="h-3.5 w-3.5" />
                  Board
                </button>
                <button
                  type="button"
                  onClick={() => setMode("calendar")}
                  className={`inline-flex items-center gap-1 rounded-lg px-2.5 py-1 font-medium ${
                    mode === "calendar" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                  }`}
                >
                  <CalIcon className="h-3.5 w-3.5" />
                  Calendar
                </button>
                <button
                  type="button"
                  onClick={() => setMode("gallery")}
                  className={`inline-flex items-center gap-1 rounded-lg px-2.5 py-1 font-medium ${
                    mode === "gallery" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                  }`}
                >
                  <LayoutGrid className="h-3.5 w-3.5" />
                  Gallery
                </button>
                <button
                  type="button"
                  onClick={() => setMode("timeline")}
                  className={`inline-flex items-center gap-1 rounded-lg px-2.5 py-1 font-medium ${
                    mode === "timeline" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                  }`}
                >
                  <CalendarRange className="h-3.5 w-3.5" />
                  Timeline
                </button>
              </div>
            </div>
          </div>

          {/* Saved Views Tab Strip */}
          <div className="flex flex-wrap items-center justify-between gap-2 border-t border-stone-100 pt-3">
            <div className="flex flex-wrap items-center gap-1.5">
              {views.map((v) => {
                const isActive = activeViewId === v.id;
                if (renamingViewId === v.id) {
                  return (
                    <div
                      key={v.id}
                      className="inline-flex items-center gap-1 rounded-lg border border-blue-300 bg-blue-50 px-2 py-1 text-xs"
                    >
                      <input
                        autoFocus
                        value={renameViewName}
                        onChange={(e) => setRenameViewName(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") void handleRenameViewSubmit(v);
                          if (e.key === "Escape") setRenamingViewId(null);
                        }}
                        className="w-28 bg-white rounded border border-blue-200 px-1.5 py-0.5 text-xs outline-none"
                      />
                      <button
                        type="button"
                        onClick={() => void handleRenameViewSubmit(v)}
                        className="text-emerald-700 hover:text-emerald-900"
                      >
                        <Check className="h-3.5 w-3.5" />
                      </button>
                      <button
                        type="button"
                        onClick={() => setRenamingViewId(null)}
                        className="text-stone-400 hover:text-stone-700"
                      >
                        <X className="h-3.5 w-3.5" />
                      </button>
                    </div>
                  );
                }
                return (
                  <button
                    key={v.id}
                    type="button"
                    onClick={() => applySavedView(v)}
                    className={`inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-xs font-medium transition ${
                      isActive
                        ? "border-stone-900 bg-stone-900 text-white"
                        : "border-stone-200 bg-stone-50 text-stone-600 hover:bg-stone-100 hover:text-stone-900"
                    }`}
                  >
                    {viewKindIcon(v.kind)}
                    <span>{v.name}</span>
                  </button>
                );
              })}

              <button
                type="button"
                onClick={() => {
                  setNewViewName("");
                  setNewViewGroupBy(groupableProps[0]?.id ?? "");
                  setNewViewDateProp(dateProps[0]?.id ?? "");
                  setNewViewEndDateProp(dateProps[1]?.id ?? "");
                  setNewViewCoverProp(coverProps[0]?.id ?? "");
                  setNewViewCardSize("md");
                  setNewViewOpen((prev) => !prev);
                }}
                className="inline-flex items-center gap-1 rounded-lg border border-dashed border-stone-300 px-2.5 py-1.5 text-xs font-medium text-stone-500 hover:border-stone-400 hover:text-stone-800"
              >
                <Plus className="h-3.5 w-3.5" />
                New View
              </button>
            </div>

            {activeView && (
              <div className="flex flex-wrap items-center gap-1.5 text-xs">
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void handleSaveCurrentView()}
                  className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1 text-stone-700 hover:bg-stone-50"
                  title="Save active filter/sort/layout to this view"
                >
                  <Save className="h-3 w-3" />
                  Save View
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    setRenamingViewId(activeView.id);
                    setRenameViewName(activeView.name);
                  }}
                  className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1 text-stone-700 hover:bg-stone-50"
                  title="Rename active view"
                >
                  <Pencil className="h-3 w-3" />
                  Rename
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void handleDuplicateView(activeView)}
                  className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1 text-stone-700 hover:bg-stone-50"
                  title="Duplicate view"
                >
                  <Copy className="h-3 w-3" />
                  Duplicate
                </button>
                <button
                  type="button"
                  disabled={busy || views.length <= 1}
                  onClick={() => void handleDeleteView(activeView)}
                  className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1 text-stone-500 hover:border-red-200 hover:bg-red-50 hover:text-red-700 disabled:opacity-40"
                  title={views.length <= 1 ? "At least one view must remain" : "Delete view"}
                >
                  <Trash2 className="h-3 w-3" />
                </button>
              </div>
            )}
          </div>

          {newViewOpen && (
            <div className="rounded-xl border border-stone-200 bg-stone-50 p-3 flex flex-wrap items-center gap-2 text-xs">
              <Layers className="h-3.5 w-3.5 text-stone-500" />
              <input
                value={newViewName}
                onChange={(e) => setNewViewName(e.target.value)}
                placeholder="View name (e.g. Q4 Board)"
                className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5 w-44 outline-none"
              />
              <select
                value={newViewType}
                onChange={(e) =>
                  setNewViewType(
                    e.target.value as "table" | "board" | "calendar" | "gallery" | "timeline"
                  )
                }
                className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5"
              >
                <option value="table">Table View</option>
                <option value="board">Kanban Board</option>
                <option value="calendar">Calendar View</option>
                <option value="gallery">Gallery View</option>
                <option value="timeline">Timeline View</option>
              </select>
              {newViewType === "board" && (
                <select
                  value={newViewGroupBy}
                  onChange={(e) => setNewViewGroupBy(e.target.value)}
                  className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5"
                >
                  <option value="">Group by column...</option>
                  {groupableProps.map((gp) => (
                    <option key={gp.id} value={gp.id}>
                      {gp.name}
                    </option>
                  ))}
                </select>
              )}
              {(newViewType === "calendar" || newViewType === "timeline") && (
                <select
                  value={newViewDateProp}
                  onChange={(e) => setNewViewDateProp(e.target.value)}
                  className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5"
                >
                  <option value="">
                    {newViewType === "timeline" ? "Start date column..." : "Date column..."}
                  </option>
                  {dateProps.map((dp) => (
                    <option key={dp.id} value={dp.id}>
                      {dp.name}
                    </option>
                  ))}
                </select>
              )}
              {newViewType === "timeline" && (
                <select
                  value={newViewEndDateProp}
                  onChange={(e) => setNewViewEndDateProp(e.target.value)}
                  className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5"
                >
                  <option value="">Optional end date column...</option>
                  {dateProps.map((dp) => (
                    <option key={dp.id} value={dp.id}>
                      End: {dp.name}
                    </option>
                  ))}
                </select>
              )}
              {newViewType === "gallery" && (
                <>
                  <select
                    value={newViewCoverProp}
                    onChange={(e) => setNewViewCoverProp(e.target.value)}
                    className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    <option value="">No cover column</option>
                    {coverProps.map((cp) => (
                      <option key={cp.id} value={cp.id}>
                        Cover: {cp.name}
                      </option>
                    ))}
                  </select>
                  <select
                    value={newViewCardSize}
                    onChange={(e) => setNewViewCardSize(e.target.value as "sm" | "md" | "lg")}
                    className="rounded-md border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    <option value="sm">Small cards</option>
                    <option value="md">Medium cards</option>
                    <option value="lg">Large cards</option>
                  </select>
                </>
              )}
              <button
                type="button"
                disabled={
                  busy ||
                  !newViewName.trim() ||
                  (newViewType === "board" && !newViewGroupBy) ||
                  ((newViewType === "calendar" || newViewType === "timeline") && !newViewDateProp)
                }
                onClick={() => {
                  const kind: DbViewKind =
                    newViewType === "board"
                      ? {
                          board_view: {
                            group_by_prop_id: newViewGroupBy,
                            card_prop_ids: activeDb.properties.slice(0, 3).map((p) => p.id),
                            hide_empty_groups: false,
                          },
                        }
                      : newViewType === "calendar"
                        ? {
                            calendar_view: {
                              date_prop_id: newViewDateProp,
                              card_prop_ids: activeDb.properties.slice(0, 2).map((p) => p.id),
                            },
                          }
                        : newViewType === "gallery"
                          ? {
                              gallery_view: {
                                cover_prop_id: newViewCoverProp || null,
                                card_prop_ids: activeDb.properties.slice(0, 4).map((p) => p.id),
                                card_size: newViewCardSize,
                              },
                            }
                          : newViewType === "timeline"
                            ? {
                                timeline_view: {
                                  start_date_prop_id: newViewDateProp,
                                  end_date_prop_id:
                                    newViewEndDateProp && newViewEndDateProp !== newViewDateProp
                                      ? newViewEndDateProp
                                      : null,
                                  card_prop_ids: activeDb.properties.slice(0, 3).map((p) => p.id),
                                },
                              }
                            : {
                                table_view: {
                                  visible_prop_ids: activeDb.properties.map((p) => p.id),
                                  column_widths: {},
                                },
                              };
                  void handleCreateView(newViewName, kind);
                }}
                className="rounded-lg bg-stone-900 px-3 py-1.5 font-medium text-white hover:bg-stone-800 disabled:opacity-50"
              >
                Create View
              </button>
              <button
                type="button"
                onClick={() => setNewViewOpen(false)}
                className="text-stone-500 hover:text-stone-800 px-2"
              >
                Cancel
              </button>
            </div>
          )}
        </div>

        {aiProposalNotice && (
          <div className="mb-4 flex items-center justify-between gap-3 rounded-xl border border-violet-200 bg-violet-50 px-4 py-2.5 text-xs text-violet-900">
            <div className="flex items-center gap-2">
              <Bot className="h-4 w-4 text-violet-600" />
              <span>
                AI column <strong>{aiProposalNotice.propName}</strong> staged{" "}
                <strong>{aiProposalNotice.processed}</strong> row update(s) into a{" "}
                <Link
                  href={`/proposals/${aiProposalNotice.proposalId}`}
                  className="font-semibold underline hover:text-violet-700"
                >
                  World Proposal
                </Link>{" "}
                for review.
              </span>
            </div>
            <button
              type="button"
              onClick={() => setAiProposalNotice(null)}
              className="rounded p-1 text-violet-600 hover:bg-violet-100"
              aria-label="Dismiss AI proposal notice"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </div>
        )}

        {/* Active Scenario Delta Ribbon */}
        {activeScenario && scenarioData && (
          <ScenarioDeltaRibbon
            scenarioData={scenarioData}
            busy={busy}
            onExitToLive={() => {
              setActiveScenario(null);
              setScenarioData(null);
              void runQuery(activeViewId, { scenarioOverride: null });
            }}
            onMerge={handleMergeScenario}
            onDiscard={handleDiscardScenario}
          />
        )}

        {/* Filter & Sort Query Bar */}
        <div className="rounded-xl border border-stone-200 bg-white p-3.5 flex flex-wrap items-center gap-2 text-xs">
          <span className="font-medium text-stone-500">Filter</span>
          <select
            value={filterProp}
            onChange={(e) => setFilterProp(e.target.value)}
            className="rounded-md border border-stone-200 px-2 py-1.5 bg-white"
          >
            <option value="">All columns</option>
            {activeDb.properties.map((p) => (
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
            <option value="gte">greater or eq</option>
            <option value="lt">less than</option>
            <option value="lte">less or eq</option>
            <option value="is_empty">is empty</option>
            <option value="is_not_empty">is not empty</option>
          </select>
          {filterOp !== "is_empty" && filterOp !== "is_not_empty" && (
            <input
              value={filterVal}
              onChange={(e) => setFilterVal(e.target.value)}
              placeholder="Filter value..."
              className="rounded-md border border-stone-200 px-2.5 py-1.5 w-36 outline-none"
            />
          )}
          <span className="text-stone-300 px-1">|</span>
          <select
            value={sortProp}
            onChange={(e) => setSortProp(e.target.value)}
            className="rounded-md border border-stone-200 px-2 py-1.5 bg-white"
          >
            <option value="">Default order</option>
            {activeDb.properties.map((p) => (
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
            onClick={() => void runQuery(activeViewId)}
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

        {/* TABLE VIEW */}
        {mode === "table" && (
          <div className="space-y-3">
            <div className="rounded-2xl border border-stone-200 bg-white overflow-x-auto">
              <table className="w-full text-left text-sm">
                <thead className="border-b border-stone-200 bg-stone-50/70 text-xs text-stone-500">
                  <tr>
                    {activeScenario && <th className="px-3 py-3 font-medium w-16">State</th>}
                    {activeDb.properties.map((p) => {
                      const aiCfg =
                        typeof p.kind === "object" && "ai_derived" in p.kind
                          ? p.kind.ai_derived
                          : null;
                      const isAi = aiCfg !== null;
                      const usage = isAi ? aiUsage[p.id] : undefined;
                      return (
                        <th key={p.id} className="px-4 py-3 font-medium whitespace-nowrap">
                          <div className="inline-flex items-center gap-1.5">
                            {isAi && <Sparkles className="h-3.5 w-3.5 text-violet-600" />}
                            <span>{p.name}</span>
                            {aiCfg && (
                              <>
                                <span
                                  className={`rounded-full px-1.5 py-0.5 text-[10px] font-medium ${
                                    aiCfg.mode === "auto_apply"
                                      ? "bg-emerald-50 text-emerald-700"
                                      : "bg-violet-50 text-violet-700"
                                  }`}
                                >
                                  {aiCfg.mode === "auto_apply" ? "Auto" : "PR"}
                                </span>
                                <span
                                  className="text-[10px] font-normal text-stone-400"
                                  title="Daily AI calls used / cap"
                                >
                                  {usage?.calls_used ?? 0}/{aiCfg.daily_call_cap}
                                </span>
                                <button
                                  type="button"
                                  onClick={() => handleRunAiColumn(p.id, null, false)}
                                  disabled={busy || aiBusyPropId !== null}
                                  title={`Run AI column "${p.name}"`}
                                  className="inline-flex items-center gap-0.5 rounded border border-violet-200 bg-violet-50 px-1.5 py-0.5 text-[10px] font-medium text-violet-700 hover:bg-violet-100 disabled:opacity-50"
                                >
                                  <Play className="h-2.5 w-2.5" />
                                  {aiBusyPropId === p.id ? "Running" : "Run"}
                                </button>
                              </>
                            )}
                          </div>
                        </th>
                      );
                    })}
                    <th className="px-3 py-3 font-medium text-right">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-stone-100">
                  {rows.map((er) => {
                    const rowChange = activeScenario
                      ? scenarioData?.row_changes[er.row.id]
                      : undefined;
                    return (
                      <tr
                        key={er.row.id}
                        className={
                          rowChange === "added"
                            ? "bg-emerald-50/40 hover:bg-emerald-50/70"
                            : rowChange === "modified"
                              ? "bg-amber-50/40 hover:bg-amber-50/70"
                              : "hover:bg-stone-50/70"
                        }
                      >
                        {activeScenario && (
                          <td className="px-3 py-2.5 whitespace-nowrap">
                            {rowChange === "added" ? (
                              <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-semibold uppercase text-emerald-800">
                                New
                              </span>
                            ) : rowChange === "modified" ? (
                              <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold uppercase text-amber-800">
                                Edited
                              </span>
                            ) : (
                              <span className="text-[10px] text-stone-400">—</span>
                            )}
                          </td>
                        )}
                        {activeDb.properties.map((p) => (
                          <td key={p.id} className="px-4 py-2.5 whitespace-nowrap">
                            <InlineCellEditor
                              er={er}
                              prop={p}
                              database={activeDb}
                              databases={databases}
                              principals={principals}
                              relationTargets={relationTargets}
                              disabled={busy || aiBusyPropId === p.id}
                              aiMeta={aiCellMeta[`${er.row.id}:${p.id}`]}
                              onRunSingleRowAi={
                                typeof p.kind === "object" && "ai_derived" in p.kind
                                  ? () => handleRunAiColumn(p.id, [er.row.id], false)
                                  : undefined
                              }
                              onCommit={(val) => handleUpdateRowCell(er, p.id, val)}
                            />
                          </td>
                        ))}
                        <td className="px-3 py-2.5 text-right whitespace-nowrap">
                          <button
                            type="button"
                            disabled={busy}
                            onClick={() => void handleDeleteRow(er)}
                            className="rounded p-1 text-stone-400 hover:bg-red-50 hover:text-red-600 disabled:opacity-40"
                            title="Delete row"
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                  {rows.length === 0 && (
                    <tr>
                      <td
                        colSpan={activeDb.properties.length + (activeScenario ? 2 : 1)}
                        className="px-4 py-6 text-center text-xs text-stone-400"
                      >
                        No matching rows yet.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            {activeScenario && scenarioData && scenarioData.removed_rows.length > 0 && (
              <details className="rounded-xl border border-rose-200 bg-rose-50/50 px-4 py-2.5 text-xs">
                <summary className="cursor-pointer font-medium text-rose-800">
                  Removed in Scenario ({scenarioData.removed_rows.length})
                </summary>
                <div className="mt-2 space-y-1">
                  {scenarioData.removed_rows.map((er) => (
                    <div key={er.row.id} className="flex items-center justify-between text-rose-700 line-through">
                      <span>{getRowTitle(er, activeDb.properties)}</span>
                      <span className="font-mono text-[11px]">{er.row.id}</span>
                    </div>
                  ))}
                </div>
              </details>
            )}
          </div>
        )}

        {/* DRAG-AND-DROP KANBAN BOARD VIEW */}
        {mode === "board" && (
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            {!boardGroupProp && (
              <div className="col-span-full rounded-xl border border-stone-200 bg-white p-6 text-sm text-stone-500">
                Add a Select or Checkbox property in Columns to group rows in Kanban Board view.
              </div>
            )}
            {boardGroupProp &&
              boardColumns.map((col) => {
                const summaryProps = activeDb.properties
                  .filter((p) => p.kind !== "title" && p.id !== boardGroupProp.id)
                  .slice(0, 3);
                const colNumFmt =
                  firstNumberProp &&
                  typeof firstNumberProp.kind === "object" &&
                  "number" in firstNumberProp.kind
                    ? firstNumberProp.kind.number.format
                    : "plain";
                const colSum = firstNumberProp
                  ? col.items.reduce((acc, er) => {
                      const c = getEffectiveCell(er, firstNumberProp.id);
                      const v =
                        typeof c === "object" && "number_val" in c ? Number(c.number_val) : 0;
                      return acc + (Number.isFinite(v) ? v : 0);
                    }, 0)
                  : null;
                const isDragOver = dragOverColKey === col.id;

                return (
                  <div
                    key={col.id}
                    onDragOver={(e) => {
                      e.preventDefault();
                      if (dragOverColKey !== col.id) setDragOverColKey(col.id);
                    }}
                    onDragLeave={() => {
                      if (dragOverColKey === col.id) setDragOverColKey(null);
                    }}
                    onDrop={(e) => {
                      e.preventDefault();
                      setDragOverColKey(null);
                      const droppedId = e.dataTransfer.getData("text/plain") || draggingRowId;
                      setDraggingRowId(null);
                      if (!droppedId) return;
                      const droppedRow = rows.find((r) => r.row.id === droppedId);
                      if (droppedRow) moveRowToBoardCol(droppedRow, col.id);
                    }}
                    className={`rounded-2xl border p-3 space-y-2.5 transition ${
                      isDragOver
                        ? "border-indigo-400 bg-indigo-50/40 ring-2 ring-indigo-200"
                        : "border-stone-200 bg-stone-50/70"
                    }`}
                  >
                    <div className="flex items-center justify-between px-1 text-xs font-semibold text-stone-700">
                      <span
                        className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-medium ${SELECT_COLOR_CLASSES[col.color]}`}
                      >
                        {col.label}
                      </span>
                      <div className="flex items-center gap-1.5">
                        {colSum !== null && col.items.length > 0 && (
                          <span className="font-mono text-[10px] text-stone-500">
                            {formatNumberCell(colSum.toFixed(2), colNumFmt)}
                          </span>
                        )}
                        <span className="rounded-full bg-stone-200 px-2 py-0.5 text-[10px] text-stone-700">
                          {col.items.length}
                        </span>
                      </div>
                    </div>

                    <div className="space-y-2 min-h-[48px]">
                      {col.items.map((er) => {
                        const rowChange = activeScenario
                          ? scenarioData?.row_changes[er.row.id]
                          : undefined;
                        return (
                          <div
                            key={er.row.id}
                            draggable={!busy}
                            onDragStart={(e) => {
                              setDraggingRowId(er.row.id);
                              e.dataTransfer.setData("text/plain", er.row.id);
                              e.dataTransfer.effectAllowed = "move";
                            }}
                            onDragEnd={() => {
                              setDraggingRowId(null);
                              setDragOverColKey(null);
                            }}
                            className={`rounded-xl border bg-white p-3.5 shadow-2xs space-y-2.5 cursor-grab active:cursor-grabbing ${
                              draggingRowId === er.row.id ? "opacity-50" : "border-stone-200"
                            }`}
                          >
                            <div className="flex items-start justify-between gap-2">
                              <Link
                                href={`/p/${er.row.page_id}`}
                                className="text-sm font-medium text-stone-900 hover:text-blue-700 hover:underline block"
                              >
                                {getRowTitle(er, activeDb.properties)}
                              </Link>
                              {rowChange && (
                                <span
                                  className={`rounded-full px-1.5 py-0.5 text-[9px] font-semibold uppercase ${
                                    rowChange === "added"
                                      ? "bg-emerald-100 text-emerald-800"
                                      : "bg-amber-100 text-amber-800"
                                  }`}
                                >
                                  {rowChange}
                                </span>
                              )}
                            </div>

                            {summaryProps.length > 0 && (
                              <div className="flex flex-wrap items-center gap-1.5 text-[11px]">
                                {summaryProps.map((sp) => {
                                  const c = getEffectiveCell(er, sp.id);
                                  if (!c || c === "empty") return null;
                                  return (
                                    <span
                                      key={sp.id}
                                      className="rounded bg-stone-100 px-1.5 py-0.5 text-[10px] text-stone-600"
                                    >
                                      {sp.name}:{" "}
                                      {renderCellDisplay(
                                        c,
                                        sp,
                                        principals,
                                        typeof sp.kind === "object" && "relation" in sp.kind
                                          ? relationTargets[sp.kind.relation.target_db_id]
                                          : undefined
                                      )}
                                    </span>
                                  );
                                })}
                              </div>
                            )}

                            {/* Accessible click-to-move buttons */}
                            <div className="flex flex-wrap gap-1 pt-0.5">
                              {boardColumns
                                .filter((targetCol) => targetCol.id !== "__none__")
                                .map((targetCol) => (
                                  <button
                                    key={targetCol.id}
                                    type="button"
                                    disabled={busy || col.id === targetCol.id}
                                    onClick={() => moveRowToBoardCol(er, targetCol.id)}
                                    className={`rounded px-2 py-0.5 text-[10px] border transition ${
                                      col.id === targetCol.id
                                        ? `${SELECT_COLOR_CLASSES[targetCol.color]} font-semibold`
                                        : "border-stone-200 text-stone-500 hover:bg-stone-50"
                                    }`}
                                  >
                                    {targetCol.label}
                                  </button>
                                ))}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                );
              })}
          </div>
        )}

        {/* CALENDAR VIEW */}
        {mode === "calendar" && (
          <div className="space-y-3">
            {!dateProp && (
              <div className="rounded-xl border border-stone-200 bg-white p-6 text-sm text-stone-500">
                Add a Date property in Columns to view items in Calendar mode.
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
                      <div
                        key={er.row.id}
                        className="rounded-lg border border-stone-200 bg-stone-50 px-3 py-2 flex items-center justify-between gap-2 text-xs"
                      >
                        <Link
                          href={`/p/${er.row.page_id}`}
                          className="font-medium text-stone-900 hover:text-blue-700 hover:underline truncate"
                        >
                          {getRowTitle(er, activeDb.properties)}
                        </Link>
                        <InlineCellEditor
                          er={er}
                          prop={dateProp}
                          database={activeDb}
                          databases={databases}
                          principals={principals}
                          relationTargets={relationTargets}
                          disabled={busy}
                          onCommit={(val) => handleUpdateRowCell(er, dateProp.id, val)}
                        />
                      </div>
                    ))}
                  </div>
                </div>
              ))}
          </div>
        )}

        {/* GALLERY VIEW */}
        {mode === "gallery" && (
          <div
            className={`grid grid-cols-1 gap-4 ${
              galleryCardSize === "sm"
                ? "sm:grid-cols-2 lg:grid-cols-4"
                : galleryCardSize === "lg"
                  ? "sm:grid-cols-1 lg:grid-cols-2"
                  : "sm:grid-cols-2 lg:grid-cols-3"
            }`}
          >
            {rows.length === 0 && (
              <div className="col-span-full rounded-xl border border-stone-200 bg-white p-6 text-center text-sm text-stone-400">
                No rows match this Gallery view.
              </div>
            )}
            {rows.map((er) => {
              const title = getRowTitle(er, activeDb.properties);
              const coverCell = galleryCoverProp ? getEffectiveCell(er, galleryCoverProp.id) : null;
              const coverVal =
                coverCell && typeof coverCell === "object"
                  ? "url_val" in coverCell
                    ? coverCell.url_val
                    : "text_val" in coverCell
                      ? coverCell.text_val
                      : null
                  : null;
              const isImg =
                coverVal &&
                (coverVal.startsWith("http://") ||
                  coverVal.startsWith("https://") ||
                  coverVal.startsWith("/api/attachments/"));
              const rowChange = scenarioData?.row_changes[er.row.id];
              const cardProps = activeDb.properties.filter(
                (p) => p.kind !== "title" && p.id !== galleryCoverProp?.id
              );
              return (
                <div
                  key={er.row.id}
                  className="rounded-2xl border border-stone-200 bg-white overflow-hidden shadow-2xs flex flex-col"
                >
                  {isImg ? (
                    <img
                      src={coverVal}
                      alt={title}
                      className={`w-full object-cover bg-stone-100 ${
                        galleryCardSize === "lg" ? "h-44" : galleryCardSize === "sm" ? "h-24" : "h-32"
                      }`}
                    />
                  ) : (
                    <div className="h-3 bg-gradient-to-r from-teal-500/70 via-blue-500/70 to-indigo-500/70" />
                  )}
                  <div className="p-4 space-y-2.5 flex-1">
                    <div className="flex items-start justify-between gap-2">
                      <Link
                        href={`/p/${er.row.page_id}`}
                        className="text-sm font-semibold text-stone-900 hover:text-blue-700 hover:underline truncate"
                      >
                        {title}
                      </Link>
                      {rowChange && (
                        <span
                          className={`rounded-full px-1.5 py-0.5 text-[9px] font-semibold uppercase ${
                            rowChange === "added"
                              ? "bg-emerald-100 text-emerald-800"
                              : "bg-amber-100 text-amber-800"
                          }`}
                        >
                          {rowChange}
                        </span>
                      )}
                    </div>
                    {coverVal && !isImg && (
                      <div className="text-xs text-stone-500 truncate">{coverVal}</div>
                    )}
                    <div className="space-y-1.5 pt-1 border-t border-stone-100 text-xs">
                      {cardProps.slice(0, 4).map((cp) => (
                        <div key={cp.id} className="flex items-center justify-between gap-2">
                          <span className="text-[11px] text-stone-400 shrink-0">{cp.name}</span>
                          <div className="min-w-0">
                            <InlineCellEditor
                              er={er}
                              prop={cp}
                              database={activeDb}
                              databases={databases}
                              principals={principals}
                              relationTargets={relationTargets}
                              disabled={busy}
                              onCommit={(val) => handleUpdateRowCell(er, cp.id, val)}
                            />
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* TIMELINE VIEW */}
        {mode === "timeline" && (
          <div className="space-y-4">
            {!timelineStartProp ? (
              <div className="rounded-xl border border-stone-200 bg-white p-6 text-sm text-stone-500">
                Add a Date property in Columns to render items on a Timeline.
              </div>
            ) : (
              <div className="rounded-2xl border border-stone-200 bg-white overflow-hidden">
                {/* Date Axis Header */}
                {timelineData.ticks.length > 0 && (
                  <div className="grid grid-cols-12 border-b border-stone-200 bg-stone-50 px-4 py-2 text-[11px] font-mono text-stone-500">
                    <div className="col-span-4 font-sans font-semibold text-stone-700">
                      Item ({timelineData.scheduled.length} scheduled)
                    </div>
                    <div className="col-span-8 flex items-center justify-between">
                      {timelineData.ticks.map((tk, idx) => (
                        <span key={`${tk}-${idx}`}>{tk}</span>
                      ))}
                    </div>
                  </div>
                )}

                <div className="divide-y divide-stone-100">
                  {timelineData.scheduled.length === 0 && (
                    <div className="p-6 text-center text-xs text-stone-400">
                      No scheduled rows with valid {timelineStartProp.name} dates yet.
                    </div>
                  )}
                  {timelineData.scheduled.map(({ er, startIso, endIso, leftPct, widthPct }) => {
                    const rowChange = scenarioData?.row_changes[er.row.id];
                    return (
                      <div
                        key={er.row.id}
                        className="grid grid-cols-12 items-center px-4 py-2.5 gap-3 text-xs hover:bg-stone-50/70"
                      >
                        <div className="col-span-4 flex items-center justify-between gap-2 min-w-0">
                          <Link
                            href={`/p/${er.row.page_id}`}
                            className="font-medium text-stone-900 hover:text-blue-700 hover:underline truncate"
                          >
                            {getRowTitle(er, activeDb.properties)}
                          </Link>
                          <div className="shrink-0">
                            <InlineCellEditor
                              er={er}
                              prop={timelineStartProp}
                              database={activeDb}
                              databases={databases}
                              principals={principals}
                              relationTargets={relationTargets}
                              disabled={busy}
                              onCommit={(val) => handleUpdateRowCell(er, timelineStartProp.id, val)}
                            />
                          </div>
                        </div>
                        <div className="col-span-8 relative h-7 rounded-md bg-stone-100/80 overflow-hidden">
                          <div
                            style={{ left: `${leftPct}%`, width: `${widthPct}%` }}
                            className={`absolute top-1 bottom-1 rounded-md px-2 flex items-center justify-between text-[10px] font-mono text-white truncate shadow-2xs ${
                              rowChange === "added"
                                ? "bg-emerald-600"
                                : rowChange === "modified"
                                  ? "bg-amber-600"
                                  : "bg-blue-600"
                            }`}
                            title={`${startIso} → ${endIso}`}
                          >
                            <span className="truncate">
                              {startIso}
                              {endIso !== startIso ? ` → ${endIso}` : ""}
                            </span>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                </div>

                {timelineData.unscheduled.length > 0 && (
                  <div className="border-t border-stone-200 bg-stone-50/50 p-4 space-y-2">
                    <div className="text-[11px] font-semibold text-stone-600">
                      Unscheduled ({timelineData.unscheduled.length}) — click to assign{" "}
                      {timelineStartProp.name}
                    </div>
                    <div className="flex flex-wrap gap-2">
                      {timelineData.unscheduled.map((er) => (
                        <div
                          key={er.row.id}
                          className="rounded-lg border border-stone-200 bg-white px-3 py-1.5 flex items-center gap-2 text-xs"
                        >
                          <Link
                            href={`/p/${er.row.page_id}`}
                            className="font-medium text-stone-800 hover:underline"
                          >
                            {getRowTitle(er, activeDb.properties)}
                          </Link>
                          <InlineCellEditor
                            er={er}
                            prop={timelineStartProp}
                            database={activeDb}
                            databases={databases}
                            principals={principals}
                            relationTargets={relationTargets}
                            disabled={busy}
                            onCommit={(val) => handleUpdateRowCell(er, timelineStartProp.id, val)}
                          />
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}
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
            placeholder={
              activeScenario
                ? `Add row to Scenario '${activeScenario.title}'...`
                : "New row title..."
            }
            className="flex-1 min-w-[180px] rounded-lg border border-stone-200 px-3 py-2 text-xs outline-none focus:border-stone-500"
          />
          {firstSelectProp && (
            <select
              value={newCellDrafts[firstSelectProp.id] ?? ""}
              onChange={(e) =>
                setNewCellDrafts((prev) => ({ ...prev, [firstSelectProp.id]: e.target.value }))
              }
              className="rounded-lg border border-stone-200 px-2.5 py-2 text-xs bg-white"
            >
              <option value="">{firstSelectProp.name}...</option>
              {getSelectOptions(firstSelectProp).map((o) => (
                <option key={o.id} value={o.id}>
                  {o.label}
                </option>
              ))}
            </select>
          )}
          {firstNumberProp && (
            <input
              inputMode="decimal"
              value={newCellDrafts[firstNumberProp.id] ?? ""}
              onChange={(e) =>
                setNewCellDrafts((prev) => ({ ...prev, [firstNumberProp.id]: e.target.value }))
              }
              placeholder={`${firstNumberProp.name}...`}
              className="w-28 rounded-lg border border-stone-200 px-2.5 py-2 font-mono text-xs outline-none focus:border-stone-500"
            />
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
            {activeScenario ? "Stage Row" : "Add Row"}
          </button>
        </form>
      </div>

      {/* Schema Builder Drawer */}
      <SchemaBuilderDrawer
        open={schemaDrawerOpen}
        onClose={() => setSchemaDrawerOpen(false)}
        database={activeDb}
        databases={databases}
        isScenario={activeScenario !== null}
        busy={busy}
        onSaveSchema={handleSaveSchema}
      />

      {/* Fork Scenario Modal */}
      {forkModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-stone-950/35 p-4 backdrop-blur-[1px]">
          <form
            onSubmit={handleForkScenario}
            className="w-full max-w-md rounded-2xl border border-stone-200 bg-white p-6 shadow-2xl space-y-4"
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <GitBranch className="h-4 w-4 text-indigo-600" />
                <h2 className="text-base font-semibold text-stone-950">
                  Fork What-If Scenario
                </h2>
              </div>
              <button
                type="button"
                onClick={() => setForkModalOpen(false)}
                className="rounded p-1 text-stone-400 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <p className="text-xs text-stone-500">
              Creates an isolated <code className="font-mono">Modb.World</code> branch so you can
              model cell/schema changes and inspect live exact-Decimal deltas before merging.
            </p>
            <div className="space-y-3 text-xs">
              <div>
                <label className="block font-medium text-stone-700 mb-1">Scenario Title</label>
                <input
                  required
                  autoFocus
                  value={forkTitle}
                  onChange={(e) => setForkTitle(e.target.value)}
                  placeholder="e.g. Q4 Budget +15% Infrastructure"
                  className="w-full rounded-lg border border-stone-200 px-3 py-2 outline-none focus:border-indigo-500"
                />
              </div>
              <div>
                <label className="block font-medium text-stone-700 mb-1">Reason / Hypothesis</label>
                <textarea
                  rows={2}
                  value={forkReason}
                  onChange={(e) => setForkReason(e.target.value)}
                  placeholder="Why are you branching this database?"
                  className="w-full rounded-lg border border-stone-200 px-3 py-2 outline-none focus:border-indigo-500"
                />
              </div>
            </div>
            <div className="flex justify-end gap-2 pt-1">
              <button
                type="button"
                onClick={() => setForkModalOpen(false)}
                className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={busy || !forkTitle.trim()}
                className="rounded-lg bg-indigo-600 px-4 py-1.5 text-xs font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
              >
                {busy ? "Forking..." : "Create Scenario Branch"}
              </button>
            </div>
          </form>
        </div>
      )}
    </WorkspaceLayout>
  );
}
