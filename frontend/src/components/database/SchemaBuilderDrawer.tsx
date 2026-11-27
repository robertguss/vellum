import { ArrowDown, ArrowUp, Plus, Sparkles, Trash2, X } from "lucide-react";
import { useEffect, useState } from "react";
import { ApiError } from "../../lib/api";
import type {
  AiColumnMode,
  AiOutputKind,
  DatabaseDef,
  PropertyDef,
  PropertyKind,
  RollupAgg,
  SelectOption,
  SelectOptionColor,
} from "../../lib/types";
import { SELECT_COLOR_CLASSES } from "./InlineCellEditor";

type KindKey =
  | "title"
  | "rich_text"
  | "number"
  | "date_prop"
  | "select"
  | "multi_select"
  | "checkbox"
  | "person"
  | "url"
  | "relation"
  | "rollup"
  | "ai_derived";

type AiOutputKey = "ai_text" | "ai_number" | "ai_date" | "ai_bool" | "ai_select";

const KIND_LABELS: Record<KindKey, string> = {
  title: "Title",
  rich_text: "Text",
  number: "Number (Decimal)",
  date_prop: "Date",
  select: "Select",
  multi_select: "Multi-Select",
  checkbox: "Checkbox",
  person: "Person",
  url: "URL",
  relation: "Relation",
  rollup: "Rollup",
  ai_derived: "AI Compiled",
};

const ALL_COLORS: SelectOptionColor[] = ["gray", "blue", "green", "amber", "red", "purple"];

function kindKeyOf(kind: PropertyKind): KindKey {
  if (typeof kind === "string") return kind;
  if ("number" in kind) return "number";
  if ("date_prop" in kind) return "date_prop";
  if ("select" in kind) return "select";
  if ("multi_select" in kind) return "multi_select";
  if ("relation" in kind) return "relation";
  if ("ai_derived" in kind) return "ai_derived";
  return "rollup";
}

function slugifyId(raw: string): string {
  const base = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return base || "col";
}

function nextUniquePropId(name: string, existing: PropertyDef[]): string {
  const used = new Set(existing.map((p) => p.id));
  const base = slugifyId(name);
  if (!used.has(base)) return base;
  let i = 2;
  while (used.has(`${base}_${i}`)) i += 1;
  return `${base}_${i}`;
}

function nextSortOrder(props: PropertyDef[]): string {
  return String.fromCharCode(97 + Math.min(25, props.length)) + (props.length >= 26 ? String(props.length) : "");
}

interface SchemaBuilderDrawerProps {
  open: boolean;
  onClose: () => void;
  database: DatabaseDef;
  databases: DatabaseDef[];
  isScenario: boolean;
  busy: boolean;
  onSaveSchema: (nextProperties: PropertyDef[]) => Promise<void>;
}

export default function SchemaBuilderDrawer({
  open,
  onClose,
  database,
  databases,
  isScenario,
  busy,
  onSaveSchema,
}: SchemaBuilderDrawerProps) {
  const [draftProps, setDraftProps] = useState<PropertyDef[]>(database.properties);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [colName, setColName] = useState("");
  const [colRequired, setColRequired] = useState(false);
  const [colKind, setColKind] = useState<KindKey>("rich_text");
  const [numFormat, setNumFormat] = useState("plain");
  const [includeTime, setIncludeTime] = useState(false);
  const [options, setOptions] = useState<SelectOption[]>([
    { id: "opt_1", label: "Option 1", color: "blue" },
  ]);
  const [newOptLabel, setNewOptLabel] = useState("");
  const [newOptColor, setNewOptColor] = useState<SelectOptionColor>("blue");
  const [targetDbId, setTargetDbId] = useState("");
  const [rollupRelPropId, setRollupRelPropId] = useState("");
  const [rollupTargetPropId, setRollupTargetPropId] = useState("");
  const [rollupAgg, setRollupAgg] = useState<RollupAgg>("sum_values");
  const [aiPrompt, setAiPrompt] = useState("");
  const [aiOutputKey, setAiOutputKey] = useState<AiOutputKey>("ai_text");
  const [aiSourcePropIds, setAiSourcePropIds] = useState<string[]>([]);
  const [aiIncludeRowBody, setAiIncludeRowBody] = useState(false);
  const [aiMode, setAiMode] = useState<AiColumnMode>("stage_proposal");
  const [aiDailyCap, setAiDailyCap] = useState(100);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setDraftProps(database.properties);
      setError(null);
      resetForm(database.properties);
    }
  }, [open, database]);

  function resetForm(propsList: PropertyDef[]) {
    setEditingId(null);
    setColName("");
    setColRequired(false);
    setColKind("rich_text");
    setNumFormat("plain");
    setIncludeTime(false);
    setOptions([{ id: "opt_1", label: "Option 1", color: "blue" }]);
    setNewOptLabel("");
    setNewOptColor("blue");
    const firstRelTarget = databases.find((d) => d.id !== database.id)?.id ?? databases[0]?.id ?? "";
    setTargetDbId(firstRelTarget);
    const firstRelProp = propsList.find((p) => typeof p.kind === "object" && "relation" in p.kind);
    setRollupRelPropId(firstRelProp?.id ?? "");
    const relTargetDb =
      firstRelProp && typeof firstRelProp.kind === "object" && "relation" in firstRelProp.kind
        ? databases.find((d) => d.id === (firstRelProp.kind as { relation: { target_db_id: string } }).relation.target_db_id)
        : undefined;
    setRollupTargetPropId(relTargetDb?.properties[0]?.id ?? "");
    setRollupAgg("sum_values");
    setAiPrompt("");
    setAiOutputKey("ai_text");
    setAiSourcePropIds([]);
    setAiIncludeRowBody(false);
    setAiMode("stage_proposal");
    setAiDailyCap(100);
  }

  function startEditProp(p: PropertyDef) {
    setEditingId(p.id);
    setColName(p.name);
    setColRequired(p.required);
    const kk = kindKeyOf(p.kind);
    setColKind(kk);
    if (typeof p.kind === "object" && "number" in p.kind) setNumFormat(p.kind.number.format);
    if (typeof p.kind === "object" && "date_prop" in p.kind) setIncludeTime(p.kind.date_prop.include_time);
    if (typeof p.kind === "object" && "select" in p.kind) setOptions(p.kind.select.options);
    if (typeof p.kind === "object" && "multi_select" in p.kind) setOptions(p.kind.multi_select.options);
    if (typeof p.kind === "object" && "relation" in p.kind) setTargetDbId(p.kind.relation.target_db_id);
    if (typeof p.kind === "object" && "rollup" in p.kind) {
      setRollupRelPropId(p.kind.rollup.relation_prop_id);
      setRollupTargetPropId(p.kind.rollup.target_prop_id);
      setRollupAgg(p.kind.rollup.agg);
    }
    if (typeof p.kind === "object" && "ai_derived" in p.kind) {
      const ai = p.kind.ai_derived;
      setAiPrompt(ai.prompt);
      setAiSourcePropIds(ai.source_prop_ids);
      setAiIncludeRowBody(ai.include_row_body);
      setAiMode(ai.mode);
      setAiDailyCap(ai.daily_call_cap);
      if (typeof ai.output_kind === "string") {
        setAiOutputKey(ai.output_kind);
      } else if ("ai_number" in ai.output_kind) {
        setAiOutputKey("ai_number");
        setNumFormat(ai.output_kind.ai_number.format);
      } else if ("ai_select" in ai.output_kind) {
        setAiOutputKey("ai_select");
        setOptions(ai.output_kind.ai_select.options);
      }
    }
    setError(null);
  }

  const relationProps = draftProps.filter((p) => typeof p.kind === "object" && "relation" in p.kind);
  const selectedRelProp = relationProps.find((p) => p.id === rollupRelPropId);
  const selectedRelTargetDb =
    selectedRelProp && typeof selectedRelProp.kind === "object" && "relation" in selectedRelProp.kind
      ? databases.find((d) => d.id === (selectedRelProp.kind as { relation: { target_db_id: string } }).relation.target_db_id)
      : undefined;

  function buildPropertyKind(): PropertyKind | null {
    switch (colKind) {
      case "title":
        return "title";
      case "rich_text":
        return "rich_text";
      case "number":
        return { number: { format: numFormat } };
      case "date_prop":
        return { date_prop: { include_time: includeTime } };
      case "select":
        if (options.length === 0) {
          setError("Select column needs at least one option");
          return null;
        }
        return { select: { options } };
      case "multi_select":
        if (options.length === 0) {
          setError("Multi-Select column needs at least one option");
          return null;
        }
        return { multi_select: { options } };
      case "checkbox":
        return "checkbox";
      case "person":
        return "person";
      case "url":
        return "url";
      case "relation":
        if (!targetDbId) {
          setError("Select a target database for this Relation");
          return null;
        }
        return { relation: { target_db_id: targetDbId, inverse_prop_id: null } };
      case "rollup":
        if (!rollupRelPropId || !rollupTargetPropId) {
          setError("Rollup needs a Relation column and target property");
          return null;
        }
        return {
          rollup: {
            relation_prop_id: rollupRelPropId,
            target_prop_id: rollupTargetPropId,
            agg: rollupAgg,
          },
        };
      case "ai_derived": {
        if (!aiPrompt.trim()) {
          setError("AI Compiled column requires a prompt instruction");
          return null;
        }
        if (aiDailyCap < 1 || aiDailyCap > 10000) {
          setError("Daily call cap must be between 1 and 10000");
          return null;
        }
        let outKind: AiOutputKind = "ai_text";
        if (aiOutputKey === "ai_number") {
          outKind = { ai_number: { format: numFormat } };
        } else if (aiOutputKey === "ai_select") {
          if (options.length === 0) {
            setError("AI Select column needs at least one option");
            return null;
          }
          outKind = { ai_select: { options } };
        } else if (aiOutputKey === "ai_date") {
          outKind = "ai_date";
        } else if (aiOutputKey === "ai_bool") {
          outKind = "ai_bool";
        }
        return {
          ai_derived: {
            prompt: aiPrompt.trim(),
            source_prop_ids: aiSourcePropIds.filter((id) => id !== editingId),
            include_row_body: aiIncludeRowBody,
            output_kind: outKind,
            mode: aiMode,
            daily_call_cap: aiDailyCap,
          },
        };
      }
    }
  }

  function handleAddOrUpdateColumn(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    if (!colName.trim()) {
      setError("Column name cannot be empty");
      return;
    }
    const builtKind = buildPropertyKind();
    if (!builtKind) return;

    if (editingId) {
      setDraftProps((prev) =>
        prev.map((p) =>
          p.id === editingId
            ? {
                ...p,
                name: colName.trim(),
                kind: builtKind,
                required:
                  colKind === "rollup" || colKind === "ai_derived" ? false : colRequired,
              }
            : p
        )
      );
      resetForm(draftProps);
    } else {
      const id = nextUniquePropId(colName, draftProps);
      const next: PropertyDef = {
        id,
        name: colName.trim(),
        kind: builtKind,
        required: colKind === "rollup" || colKind === "ai_derived" ? false : colRequired,
        sort_order: nextSortOrder(draftProps),
      };
      const updated = [...draftProps, next];
      setDraftProps(updated);
      resetForm(updated);
    }
  }

  function moveProp(idx: number, dir: -1 | 1) {
    const target = idx + dir;
    if (target < 0 || target >= draftProps.length) return;
    const copy = [...draftProps];
    const tmp = copy[idx];
    copy[idx] = copy[target];
    copy[target] = tmp;
    setDraftProps(copy.map((p, i) => ({ ...p, sort_order: String.fromCharCode(97 + Math.min(25, i)) })));
  }

  function removeProp(propId: string) {
    setDraftProps((prev) => prev.filter((p) => p.id !== propId));
    if (editingId === propId) resetForm(draftProps);
  }

  function addOptionToList() {
    if (!newOptLabel.trim()) return;
    const used = new Set(options.map((o) => o.id));
    const base = slugifyId(newOptLabel);
    let oid = base;
    let n = 2;
    while (used.has(oid)) {
      oid = `${base}_${n}`;
      n += 1;
    }
    setOptions((prev) => [...prev, { id: oid, label: newOptLabel.trim(), color: newOptColor }]);
    setNewOptLabel("");
  }

  async function handlePersist() {
    setError(null);
    try {
      await onSaveSchema(draftProps);
      onClose();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save database schema");
    }
  }

  if (!open) return null;

  const titleCount = draftProps.filter((p) => p.kind === "title").length;

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-stone-950/35 backdrop-blur-[1px]">
      <div className="absolute inset-0" onClick={onClose} />
      <div className="relative z-10 flex h-full w-full max-w-lg flex-col bg-white shadow-2xl border-l border-stone-200">
        <div className="flex items-center justify-between border-b border-stone-200 px-5 py-4">
          <div>
            <h2 className="text-base font-semibold text-stone-950">
              Columns &amp; Schema Builder
            </h2>
            <p className="text-xs text-stone-500 mt-0.5">
              {isScenario
                ? "Staging schema edits inside active What-If Scenario"
                : `Configure typed properties for ${database.title}`}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1.5 text-stone-400 hover:bg-stone-100 hover:text-stone-700"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-5 space-y-6">
          {error && (
            <div className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-xs text-red-800">
              {error}
            </div>
          )}

          {/* Existing Properties */}
          <div className="space-y-2">
            <h3 className="text-xs font-semibold uppercase tracking-wider text-stone-500">
              Properties ({draftProps.length})
            </h3>
            <div className="space-y-1.5">
              {draftProps.map((p, idx) => {
                const kk = kindKeyOf(p.kind);
                const cannotDelete = p.kind === "title" && titleCount <= 1;
                return (
                  <div
                    key={p.id}
                    className={`flex items-center justify-between gap-2 rounded-xl border px-3 py-2 text-xs ${
                      editingId === p.id
                        ? "border-blue-300 bg-blue-50/50"
                        : "border-stone-200 bg-stone-50/60"
                    }`}
                  >
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        {kk === "ai_derived" && (
                          <Sparkles className="h-3 w-3 text-purple-600 shrink-0" />
                        )}
                        <span className="font-medium text-stone-900 truncate">{p.name}</span>
                        <span className="rounded bg-stone-200/80 px-1.5 py-0.5 font-mono text-[10px] text-stone-600">
                          {KIND_LABELS[kk]}
                        </span>
                        {p.required && (
                          <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800">
                            Required
                          </span>
                        )}
                      </div>
                      <div className="font-mono text-[10px] text-stone-400">{p.id}</div>
                    </div>
                    <div className="flex items-center gap-1 shrink-0">
                      <button
                        type="button"
                        disabled={idx === 0}
                        onClick={() => moveProp(idx, -1)}
                        className="rounded p-1 text-stone-400 hover:bg-stone-200/60 hover:text-stone-700 disabled:opacity-30"
                        title="Move up"
                      >
                        <ArrowUp className="h-3.5 w-3.5" />
                      </button>
                      <button
                        type="button"
                        disabled={idx === draftProps.length - 1}
                        onClick={() => moveProp(idx, 1)}
                        className="rounded p-1 text-stone-400 hover:bg-stone-200/60 hover:text-stone-700 disabled:opacity-30"
                        title="Move down"
                      >
                        <ArrowDown className="h-3.5 w-3.5" />
                      </button>
                      <button
                        type="button"
                        onClick={() => startEditProp(p)}
                        className="rounded px-2 py-1 text-[11px] font-medium text-stone-600 hover:bg-stone-200/70"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        disabled={cannotDelete}
                        onClick={() => removeProp(p.id)}
                        className="rounded p-1 text-stone-400 hover:bg-red-50 hover:text-red-600 disabled:opacity-30"
                        title={cannotDelete ? "At least one Title column required" : "Remove column"}
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          {/* Add / Edit Column Form */}
          <form
            onSubmit={handleAddOrUpdateColumn}
            className="rounded-2xl border border-stone-200 bg-stone-50/70 p-4 space-y-3.5 text-xs"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-stone-900">
                {editingId ? `Edit Column (${editingId})` : "Add New Column"}
              </h3>
              {editingId && (
                <button
                  type="button"
                  onClick={() => resetForm(draftProps)}
                  className="text-[11px] text-stone-500 hover:text-stone-800"
                >
                  Cancel edit
                </button>
              )}
            </div>

            <div className="grid grid-cols-2 gap-2.5">
              <div>
                <label className="block text-[11px] font-medium text-stone-600 mb-1">
                  Column Name
                </label>
                <input
                  value={colName}
                  onChange={(e) => setColName(e.target.value)}
                  placeholder="e.g. Owner, Estimate, Due..."
                  className="w-full rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs outline-none focus:border-stone-500"
                />
              </div>
              <div>
                <label className="block text-[11px] font-medium text-stone-600 mb-1">
                  Property Type
                </label>
                <select
                  value={colKind}
                  onChange={(e) => setColKind(e.target.value as KindKey)}
                  className="w-full rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs"
                >
                  {(Object.keys(KIND_LABELS) as KindKey[]).map((k) => (
                    <option key={k} value={k}>
                      {KIND_LABELS[k]}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            {colKind !== "rollup" && colKind !== "ai_derived" && (
              <label className="inline-flex items-center gap-2 text-stone-700">
                <input
                  type="checkbox"
                  checked={colRequired}
                  onChange={(e) => setColRequired(e.target.checked)}
                />
                Required on all rows
              </label>
            )}

            {(colKind === "number" ||
              (colKind === "ai_derived" && aiOutputKey === "ai_number")) && (
              <div>
                <label className="block text-[11px] font-medium text-stone-600 mb-1">
                  Display Format
                </label>
                <select
                  value={numFormat}
                  onChange={(e) => setNumFormat(e.target.value)}
                  className="w-full rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs"
                >
                  <option value="plain">Plain Number</option>
                  <option value="currency">Currency ($ USD)</option>
                  <option value="percent">Percent (%)</option>
                </select>
              </div>
            )}

            {colKind === "date_prop" && (
              <label className="flex items-center gap-2 text-stone-700">
                <input
                  type="checkbox"
                  checked={includeTime}
                  onChange={(e) => setIncludeTime(e.target.checked)}
                />
                Include timestamp metadata
              </label>
            )}

            {(colKind === "select" ||
              colKind === "multi_select" ||
              (colKind === "ai_derived" && aiOutputKey === "ai_select")) && (
              <div className="space-y-2 rounded-xl border border-stone-200 bg-white p-3">
                <div className="text-[11px] font-medium text-stone-600">Options</div>
                <div className="flex flex-wrap gap-1.5">
                  {options.map((o) => (
                    <span
                      key={o.id}
                      className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium ${SELECT_COLOR_CLASSES[o.color]}`}
                    >
                      {o.label}
                      <button
                        type="button"
                        onClick={() => setOptions((prev) => prev.filter((x) => x.id !== o.id))}
                        className="opacity-60 hover:opacity-100"
                      >
                        <X className="h-2.5 w-2.5" />
                      </button>
                    </span>
                  ))}
                </div>
                <div className="flex items-center gap-1.5">
                  <input
                    value={newOptLabel}
                    onChange={(e) => setNewOptLabel(e.target.value)}
                    placeholder="Add choice label..."
                    className="flex-1 rounded-md border border-stone-200 px-2 py-1 text-xs outline-none"
                  />
                  <select
                    value={newOptColor}
                    onChange={(e) => setNewOptColor(e.target.value as SelectOptionColor)}
                    className="rounded-md border border-stone-200 bg-white px-2 py-1 text-xs capitalize"
                  >
                    {ALL_COLORS.map((c) => (
                      <option key={c} value={c}>
                        {c}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={addOptionToList}
                    className="rounded-md border border-stone-200 px-2.5 py-1 text-xs font-medium text-stone-700 hover:bg-stone-50"
                  >
                    Add
                  </button>
                </div>
              </div>
            )}

            {colKind === "relation" && (
              <div>
                <label className="block text-[11px] font-medium text-stone-600 mb-1">
                  Target Database
                </label>
                <select
                  value={targetDbId}
                  onChange={(e) => setTargetDbId(e.target.value)}
                  className="w-full rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs"
                >
                  <option value="">Choose database...</option>
                  {databases.map((d) => (
                    <option key={d.id} value={d.id}>
                      {d.title} ({d.id})
                    </option>
                  ))}
                </select>
              </div>
            )}

            {colKind === "rollup" && (
              <div className="space-y-2 rounded-xl border border-stone-200 bg-white p-3">
                <div>
                  <label className="block text-[11px] font-medium text-stone-600 mb-1">
                    Source Relation Column
                  </label>
                  <select
                    value={rollupRelPropId}
                    onChange={(e) => {
                      const nextRelId = e.target.value;
                      setRollupRelPropId(nextRelId);
                      const rp = relationProps.find((p) => p.id === nextRelId);
                      if (rp && typeof rp.kind === "object" && "relation" in rp.kind) {
                        const td = databases.find(
                          (d) => d.id === (rp.kind as { relation: { target_db_id: string } }).relation.target_db_id
                        );
                        setRollupTargetPropId(td?.properties[0]?.id ?? "");
                      }
                    }}
                    className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs"
                  >
                    <option value="">Select relation column...</option>
                    {relationProps.map((rp) => (
                      <option key={rp.id} value={rp.id}>
                        {rp.name}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-stone-600 mb-1">
                    Target Property
                  </label>
                  <select
                    value={rollupTargetPropId}
                    onChange={(e) => setRollupTargetPropId(e.target.value)}
                    className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs"
                  >
                    <option value="">Select target column...</option>
                    {(selectedRelTargetDb?.properties ?? []).map((tp) => (
                      <option key={tp.id} value={tp.id}>
                        {tp.name}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-stone-600 mb-1">
                    Aggregation
                  </label>
                  <select
                    value={rollupAgg}
                    onChange={(e) => setRollupAgg(e.target.value as RollupAgg)}
                    className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs"
                  >
                    <option value="sum_values">Sum Values (Exact Decimal)</option>
                    <option value="count_all">Count All Linked Rows</option>
                    <option value="count_values">Count Non-Empty Values</option>
                    <option value="min_value">Minimum Value / Date</option>
                    <option value="max_value">Maximum Value / Date</option>
                  </select>
                </div>
              </div>
            )}

            {colKind === "ai_derived" && (
              <div className="space-y-3 rounded-xl border border-purple-200 bg-purple-50/40 p-3">
                <div className="flex items-center gap-1.5 font-semibold text-purple-900 text-[11px]">
                  <Sparkles className="h-3.5 w-3.5 text-purple-700" />
                  AI-Compiled Column Configuration
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-stone-600 mb-1">
                    Prompt Instruction
                  </label>
                  <textarea
                    rows={2}
                    value={aiPrompt}
                    onChange={(e) => setAiPrompt(e.target.value)}
                    placeholder="e.g. Classify operational severity from title & cost impact..."
                    className="w-full rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs outline-none focus:border-purple-500"
                  />
                </div>
                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="block text-[11px] font-medium text-stone-600 mb-1">
                      Strict Output Type
                    </label>
                    <select
                      value={aiOutputKey}
                      onChange={(e) => setAiOutputKey(e.target.value as AiOutputKey)}
                      className="w-full rounded-md border border-stone-200 bg-white px-2 py-1 text-xs"
                    >
                      <option value="ai_text">Text</option>
                      <option value="ai_number">Number (Decimal)</option>
                      <option value="ai_select">Select Option</option>
                      <option value="ai_bool">Checkbox (Boolean)</option>
                      <option value="ai_date">Date (YYYY-MM-DD)</option>
                    </select>
                  </div>
                  <div>
                    <label className="block text-[11px] font-medium text-stone-600 mb-1">
                      Write Routing Policy
                    </label>
                    <select
                      value={aiMode}
                      onChange={(e) => setAiMode(e.target.value as AiColumnMode)}
                      className="w-full rounded-md border border-stone-200 bg-white px-2 py-1 text-xs"
                    >
                      <option value="stage_proposal">Stage Change Proposal</option>
                      <option value="auto_apply">Auto-Apply Validated Cells</option>
                    </select>
                  </div>
                </div>
                <div className="grid grid-cols-2 gap-2 items-center">
                  <div>
                    <label className="block text-[11px] font-medium text-stone-600 mb-1">
                      Daily Call Cap (1-10000)
                    </label>
                    <input
                      type="number"
                      min={1}
                      max={10000}
                      value={aiDailyCap}
                      onChange={(e) => {
                        const n = Number.parseInt(e.target.value, 10);
                        if (Number.isFinite(n)) setAiDailyCap(n);
                      }}
                      className="w-full rounded-md border border-stone-200 bg-white px-2 py-1 font-mono text-xs"
                    />
                  </div>
                  <label className="flex items-center gap-2 text-stone-700 pt-4 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={aiIncludeRowBody}
                      onChange={(e) => setAiIncludeRowBody(e.target.checked)}
                    />
                    Include row doc blocks
                  </label>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-stone-600 mb-1">
                    Grounded Source Columns{" "}
                    <span className="text-stone-400">(blank = all non-AI columns)</span>
                  </label>
                  <div className="max-h-24 overflow-y-auto rounded-lg border border-stone-200 bg-white p-2 space-y-1">
                    {draftProps
                      .filter((dp) => dp.id !== editingId)
                      .map((dp) => (
                        <label
                          key={dp.id}
                          className="flex items-center gap-2 text-xs text-stone-700 cursor-pointer"
                        >
                          <input
                            type="checkbox"
                            checked={aiSourcePropIds.includes(dp.id)}
                            onChange={() =>
                              setAiSourcePropIds((prev) =>
                                prev.includes(dp.id)
                                  ? prev.filter((x) => x !== dp.id)
                                  : [...prev, dp.id]
                              )
                            }
                          />
                          <span className="truncate">{dp.name}</span>
                          <span className="font-mono text-[10px] text-stone-400 ml-auto">
                            {dp.id}
                          </span>
                        </label>
                      ))}
                  </div>
                </div>
              </div>
            )}

            <button
              type="submit"
              className="inline-flex items-center gap-1.5 rounded-lg border border-stone-300 bg-white px-3 py-1.5 text-xs font-medium text-stone-800 hover:bg-stone-100"
            >
              <Plus className="h-3.5 w-3.5" />
              {editingId ? "Update Draft Column" : "Add Column to Draft"}
            </button>
          </form>
        </div>

        <div className="border-t border-stone-200 px-5 py-3.5 flex items-center justify-between gap-3 bg-stone-50">
          <span className="text-[11px] text-stone-500">
            Schema v{database.version} · Safe row/view validation on save
          </span>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-stone-200 bg-white px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-100"
            >
              Cancel
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={() => void handlePersist()}
              className="rounded-lg bg-stone-900 px-4 py-1.5 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
            >
              {busy ? "Saving..." : isScenario ? "Stage Schema in Scenario" : "Save Schema"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
