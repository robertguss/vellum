import { Link } from "@inertiajs/react";
import {
  AtSign,
  Calendar,
  Check,
  Clock,
  ExternalLink,
  Hash,
  Link2,
  Paperclip,
  Pencil,
  RefreshCw,
  Sigma,
  Sparkles,
  User,
  X,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type {
  AiCellMeta,
  CellValue,
  DatabaseDef,
  EnrichedRow,
  PrincipalSummary,
  PropertyDef,
  RelationTargetOption,
  SelectOption,
  SelectOptionColor,
} from "../../lib/types";

export const SELECT_COLOR_CLASSES: Record<SelectOptionColor, string> = {
  gray: "border-stone-200 bg-stone-100 text-stone-700",
  blue: "border-blue-200 bg-blue-50 text-blue-700",
  green: "border-emerald-200 bg-emerald-50 text-emerald-700",
  amber: "border-amber-200 bg-amber-50 text-amber-800",
  red: "border-red-200 bg-red-50 text-red-700",
  purple: "border-purple-200 bg-purple-50 text-purple-700",
};

export const SELECT_DOT_CLASSES: Record<SelectOptionColor, string> = {
  gray: "bg-stone-500",
  blue: "bg-blue-500",
  green: "bg-emerald-500",
  amber: "bg-amber-500",
  red: "bg-red-500",
  purple: "bg-purple-500",
};

export function getEffectiveCell(er: EnrichedRow, propId: string): CellValue {
  return er.effective_cells?.[propId] ?? er.rollups?.[propId] ?? er.row.cells?.[propId] ?? "empty";
}

export function getRowTitle(er: EnrichedRow, properties: PropertyDef[]): string {
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

export function formatNumberCell(raw: string, format: string): string {
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
  if (format === "percent_fraction") {
    return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(num * 100)}%`;
  }
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 }).format(num);
}

export function formatSignedDecimal(raw: string, format: string): string {
  const trimmed = raw.trim();
  if (!trimmed || trimmed === "0" || trimmed === "0.0" || trimmed === "0.00") {
    return formatNumberCell("0", format);
  }
  const neg = trimmed.startsWith("-");
  const absRaw = neg ? trimmed.slice(1) : trimmed.startsWith("+") ? trimmed.slice(1) : trimmed;
  const formattedAbs = formatNumberCell(absRaw, format);
  return `${neg ? "-" : "+"}${formattedAbs}`;
}

export function isSafeHttpUrl(url: string): boolean {
  return /^https?:\/\//i.test(url.trim());
}

export function getSelectOptions(prop: PropertyDef): SelectOption[] {
  if (typeof prop.kind === "object" && "select" in prop.kind) {
    return prop.kind.select.options;
  }
  if (typeof prop.kind === "object" && "status" in prop.kind) {
    return prop.kind.status.options;
  }
  if (typeof prop.kind === "object" && "multi_select" in prop.kind) {
    return prop.kind.multi_select.options;
  }
  if (
    typeof prop.kind === "object" &&
    "ai_derived" in prop.kind &&
    typeof prop.kind.ai_derived.output_kind === "object" &&
    "ai_select" in prop.kind.ai_derived.output_kind
  ) {
    return prop.kind.ai_derived.output_kind.ai_select.options;
  }
  return [];
}

export function resolveRollupFormat(prop: PropertyDef, databases: DatabaseDef[], currentDb: DatabaseDef): string {
  if (typeof prop.kind !== "object" || !("rollup" in prop.kind)) return "plain";
  const { relation_prop_id, target_prop_id, agg } = prop.kind.rollup;
  if (agg === "percent_per_group") return "percent_fraction";
  if (agg === "count_all" || agg === "count_values") return "plain";
  const relProp = currentDb.properties.find((p) => p.id === relation_prop_id);
  if (!relProp || typeof relProp.kind !== "object" || !("relation" in relProp.kind)) return "plain";
  const targetDb = databases.find((d) => d.id === (relProp.kind as { relation: { target_db_id: string } }).relation.target_db_id);
  const targetProp = targetDb?.properties.find((p) => p.id === target_prop_id);
  if (targetProp && typeof targetProp.kind === "object" && "number" in targetProp.kind) {
    return targetProp.kind.number.format;
  }
  return "plain";
}

export function renderCellDisplay(
  cell: CellValue | undefined,
  prop?: PropertyDef,
  principals?: PrincipalSummary[],
  relationTargets?: RelationTargetOption[]
): string {
  if (!cell || cell === "empty") return "—";
  if ("text_val" in cell) return cell.text_val || "—";
  if ("number_val" in cell) {
    let fmt = "plain";
    if (prop && typeof prop.kind === "object") {
      if ("number" in prop.kind) {
        fmt = prop.kind.number.format;
      } else if ("formula" in prop.kind) {
        fmt = prop.kind.formula.format || "plain";
      } else if ("rollup" in prop.kind && prop.kind.rollup.agg === "percent_per_group") {
        fmt = "percent_fraction";
      } else if (
        "ai_derived" in prop.kind &&
        typeof prop.kind.ai_derived.output_kind === "object" &&
        "ai_number" in prop.kind.ai_derived.output_kind
      ) {
        fmt = prop.kind.ai_derived.output_kind.ai_number.format;
      }
    }
    return formatNumberCell(cell.number_val, fmt);
  }
  if ("date_val" in cell) {
    return cell.date_val.end_date
      ? `${cell.date_val.start} → ${cell.date_val.end_date}`
      : cell.date_val.start;
  }
  if ("select_val" in cell) {
    const opt = prop ? getSelectOptions(prop).find((o) => o.id === cell.select_val.option_id) : undefined;
    return opt ? opt.label : cell.select_val.option_id;
  }
  if ("multi_select_val" in cell) {
    if (cell.multi_select_val.option_ids.length === 0) return "—";
    const opts = prop ? getSelectOptions(prop) : [];
    return cell.multi_select_val.option_ids
      .map((id) => opts.find((o) => o.id === id)?.label ?? id)
      .join(", ");
  }
  if ("bool_val" in cell) return cell.bool_val ? "Yes" : "No";
  if ("principal_val" in cell) {
    if (cell.principal_val.length === 0) return "—";
    return cell.principal_val
      .map((id) => {
        const pr = principals?.find((p) => p.id === id);
        return pr ? pr.display_name : id;
      })
      .join(", ");
  }
  if ("files_val" in cell) {
    if (cell.files_val.attachment_ids.length === 0) return "—";
    return `${cell.files_val.attachment_ids.length} file${cell.files_val.attachment_ids.length === 1 ? "" : "s"}`;
  }
  if ("url_val" in cell) return cell.url_val || "—";
  if ("relation_val" in cell) {
    if (cell.relation_val.row_ids.length === 0) return "—";
    if (relationTargets && relationTargets.length > 0) {
      return cell.relation_val.row_ids
        .map((rid) => relationTargets.find((t) => t.row_id === rid)?.title ?? rid)
        .join(", ");
    }
    return `${cell.relation_val.row_ids.length} linked`;
  }
  return "";
}

interface InlineCellEditorProps {
  er: EnrichedRow;
  prop: PropertyDef;
  database: DatabaseDef;
  databases: DatabaseDef[];
  principals: PrincipalSummary[];
  relationTargets: Record<string, RelationTargetOption[]>;
  aiMeta?: AiCellMeta;
  onRunSingleRowAi?: () => void;
  disabled?: boolean;
  onCommit: (cellValue: CellValue) => Promise<void>;
}

export default function InlineCellEditor({
  er,
  prop,
  database,
  databases,
  principals,
  relationTargets,
  aiMeta,
  onRunSingleRowAi,
  disabled = false,
  onCommit,
}: InlineCellEditorProps) {
  const cell = getEffectiveCell(er, prop.id);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [endDateDraft, setEndDateDraft] = useState("");
  const [searchText, setSearchText] = useState("");
  const [localError, setLocalError] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!editing) return;
    function onDocMouseDown(ev: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(ev.target as Node)) {
        setEditing(false);
        setLocalError(null);
      }
    }
    function onKeyDown(ev: KeyboardEvent) {
      if (ev.key === "Escape") {
        setEditing(false);
        setLocalError(null);
      }
    }
    document.addEventListener("mousedown", onDocMouseDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("mousedown", onDocMouseDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [editing]);

  // 1. TITLE
  if (prop.kind === "title") {
    const titleStr =
      typeof cell === "object" && "text_val" in cell ? cell.text_val : getRowTitle(er, database.properties);
    if (editing) {
      const saveTitle = () => {
        const t = draft.trim();
        setEditing(false);
        if (!t || t === titleStr) return;
        void onCommit({ text_val: t });
      };
      return (
        <div ref={containerRef} className="flex items-center gap-1 min-w-[150px]">
          <input
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={saveTitle}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                saveTitle();
              } else if (e.key === "Escape") {
                setEditing(false);
              }
            }}
            className="w-full rounded border border-blue-400 bg-white px-2 py-0.5 text-sm font-medium text-stone-900 outline-none ring-2 ring-blue-100"
          />
        </div>
      );
    }
    return (
      <div className="group flex items-center gap-1.5 min-w-[140px]">
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setDraft(titleStr);
            setEditing(true);
          }}
          className="text-left font-medium text-stone-900 hover:text-blue-700 truncate max-w-[260px]"
          title="Click to rename inline"
        >
          {titleStr}
        </button>
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setDraft(titleStr);
            setEditing(true);
          }}
          className="opacity-0 group-hover:opacity-100 text-stone-400 hover:text-stone-700 transition"
          title="Rename cell"
        >
          <Pencil className="h-3 w-3" />
        </button>
        <Link
          href={`/p/${er.row.page_id}`}
          className="text-stone-400 hover:text-blue-600 transition shrink-0"
          title="Open row document"
        >
          <ExternalLink className="h-3.5 w-3.5" />
        </Link>
      </div>
    );
  }

  // 2. SELECT / STATUS
  if (typeof prop.kind === "object" && ("select" in prop.kind || "status" in prop.kind)) {
    const isStatus = "status" in prop.kind;
    const opts = isStatus ? (prop.kind as { status: { options: SelectOption[]; done_option_ids: string[] } }).status.options : (prop.kind as { select: { options: SelectOption[] } }).select.options;
    const doneIds = isStatus ? (prop.kind as { status: { options: SelectOption[]; done_option_ids: string[] } }).status.done_option_ids : [];
    const curOptId =
      typeof cell === "object" && "select_val" in cell ? cell.select_val.option_id : "";
    const selectedOpt = curOptId ? opts.find((o) => o.id === curOptId) : undefined;
    const pillCls = selectedOpt
      ? SELECT_COLOR_CLASSES[selectedOpt.color]
      : "border-stone-200 bg-white text-stone-500";
    return (
      <div className="inline-flex items-center gap-1">
        <select
          value={curOptId}
          disabled={disabled}
          onChange={(e) =>
            void onCommit(
              e.target.value ? { select_val: { option_id: e.target.value } } : "empty"
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
        {isStatus && selectedOpt && doneIds.includes(selectedOpt.id) && (
          <Check className="h-3 w-3 text-emerald-600 shrink-0" />
        )}
      </div>
    );
  }

  // 3. CHECKBOX
  if (prop.kind === "checkbox") {
    const checked = typeof cell === "object" && "bool_val" in cell ? cell.bool_val : false;
    return (
      <label className="inline-flex items-center gap-2 cursor-pointer">
        <input
          type="checkbox"
          disabled={disabled}
          checked={checked}
          onClick={(e) => e.stopPropagation()}
          onChange={(e) => void onCommit({ bool_val: e.target.checked })}
          className="h-4 w-4 rounded border-stone-300 text-stone-900 focus:ring-stone-500"
        />
      </label>
    );
  }

  // 4. ROLLUP (read-only exact computation)
  if (typeof prop.kind === "object" && "rollup" in prop.kind) {
    const fmt = resolveRollupFormat(prop, databases, database);
    const display =
      typeof cell === "object" && "number_val" in cell
        ? formatNumberCell(cell.number_val, fmt)
        : renderCellDisplay(cell, prop, principals);
    const r = prop.kind.rollup;
    return (
      <span
        className="inline-flex items-center gap-1 rounded-md border border-stone-200 bg-stone-50 px-2 py-0.5 font-mono text-xs tabular-nums text-stone-700"
        title={`Read-only Rollup (${r.agg} of ${r.relation_prop_id}.${r.target_prop_id})`}
      >
        <Sigma className="h-3 w-3 text-stone-400" />
        {display}
      </span>
    );
  }

  // 4a. FORMULA (read-only deterministic computation)
  if (typeof prop.kind === "object" && "formula" in prop.kind) {
    const display = renderCellDisplay(cell, prop, principals, relationTargets[prop.id]);
    return (
      <span
        className="inline-flex items-center gap-1.5 rounded-md border border-indigo-200 bg-indigo-50/70 px-2 py-0.5 text-xs text-indigo-950"
        title={prop.kind.formula.expression}
      >
        <span className="font-mono text-[10px] font-semibold text-indigo-600 shrink-0">fx</span>
        <span className="max-w-[220px] truncate">{display}</span>
      </span>
    );
  }

  // 4c. UNIQUE_ID (immutable auto-increment key)
  if (typeof prop.kind === "object" && "unique_id" in prop.kind) {
    const valStr = typeof cell === "object" && "text_val" in cell ? cell.text_val : "—";
    return (
      <span
        className="inline-flex items-center gap-1 rounded border border-stone-200 bg-stone-100 px-2 py-0.5 font-mono text-xs font-medium text-stone-700"
        title="Auto-increment Unique ID"
      >
        <Hash className="h-3 w-3 text-stone-400" />
        {valStr}
      </span>
    );
  }

  // 4d. AUDIT TIMESTAMPS (created_time / last_edited_time)
  if (prop.kind === "created_time" || prop.kind === "last_edited_time") {
    const ts = typeof cell === "object" && "text_val" in cell ? cell.text_val : "—";
    const shortTs = ts.length >= 16 ? `${ts.slice(0, 10)} ${ts.slice(11, 16)}` : ts;
    return (
      <span
        className="inline-flex items-center gap-1 font-mono text-[11px] text-stone-500"
        title={ts}
      >
        <Clock className="h-3 w-3 text-stone-400" />
        {shortTs}
      </span>
    );
  }

  // 4e. AUDIT ACTORS (created_by / last_edited_by)
  if (prop.kind === "created_by" || prop.kind === "last_edited_by") {
    const ids = typeof cell === "object" && "principal_val" in cell ? cell.principal_val : [];
    const pid = ids[0];
    const pr = pid ? principals.find((x) => x.id === pid) : undefined;
    return (
      <span className="inline-flex items-center gap-1 rounded-full border border-stone-200 bg-stone-50 px-2 py-0.5 text-[11px] text-stone-600">
        <User className="h-2.5 w-2.5 text-stone-400" />
        {pid ? (pr ? pr.display_name : pid) : "—"}
      </span>
    );
  }

  // 4b. AI-COMPILED CELL (strictly typed value + citation/staleness popover)
  if (typeof prop.kind === "object" && "ai_derived" in prop.kind) {
    const aiDef = prop.kind.ai_derived;
    const isEmpty = !cell || cell === "empty";
    const selectOpt =
      typeof cell === "object" && "select_val" in cell
        ? getSelectOptions(prop).find((o) => o.id === cell.select_val.option_id)
        : undefined;
    const displayStr = isEmpty ? "Not run" : renderCellDisplay(cell, prop, principals);

    return (
      <div ref={containerRef} className="relative inline-flex items-center gap-1.5">
        <button
          type="button"
          onClick={() => setEditing((prev) => !prev)}
          title={aiMeta?.rationale || aiDef.prompt}
          className={`inline-flex items-center gap-1.5 rounded-lg border px-2 py-0.5 text-xs transition ${
            selectOpt
              ? SELECT_COLOR_CLASSES[selectOpt.color]
              : isEmpty
                ? "border-dashed border-stone-300 bg-stone-50 text-stone-400 hover:border-purple-300 hover:text-purple-700"
                : aiMeta?.stale
                  ? "border-amber-300 bg-amber-50/70 text-stone-900"
                  : "border-purple-200 bg-purple-50/60 text-stone-900 hover:bg-purple-100/70"
          }`}
        >
          <Sparkles className="h-3 w-3 text-purple-600 shrink-0" />
          <span className="max-w-[180px] truncate">{displayStr}</span>
          {aiMeta?.stale && (
            <span className="rounded bg-amber-200/80 px-1 py-0 text-[9px] font-semibold uppercase text-amber-900">
              Stale
            </span>
          )}
        </button>

        {editing && (
          <div className="absolute left-0 top-full mt-1 z-30 w-72 rounded-xl border border-stone-200 bg-white p-3 shadow-xl space-y-2.5 text-xs">
            <div className="flex items-center justify-between border-b border-stone-100 pb-2">
              <div className="flex items-center gap-1.5 font-semibold text-purple-950">
                <Sparkles className="h-3.5 w-3.5 text-purple-600" />
                <span>{prop.name}</span>
              </div>
              {aiMeta && (
                <span className="rounded bg-stone-100 px-1.5 py-0.5 font-mono text-[10px] text-stone-600">
                  {aiMeta.model}
                </span>
              )}
            </div>

            {aiMeta?.rationale && (
              <div className="text-xs text-stone-700 leading-relaxed">{aiMeta.rationale}</div>
            )}

            {aiMeta && aiMeta.citations.length > 0 && (
              <div className="space-y-1">
                <div className="text-[10px] font-semibold uppercase tracking-wider text-stone-400">
                  Citations
                </div>
                <div className="flex flex-wrap gap-1">
                  {aiMeta.citations.map((cit, idx) => (
                    <Link
                      key={idx}
                      href={
                        cit.source_kind === "block"
                          ? `/p/${er.row.page_id}#${cit.source_ref}`
                          : `/p/${er.row.page_id}`
                      }
                      className="inline-flex items-center rounded border border-blue-200 bg-blue-50 px-1.5 py-0.5 text-[10px] text-blue-700 hover:bg-blue-100"
                    >
                      {cit.label}
                    </Link>
                  ))}
                </div>
              </div>
            )}

            {aiMeta?.proposal_id && (
              <Link
                href="/proposals"
                className="inline-flex items-center gap-1 text-[11px] font-medium text-teal-700 hover:underline"
              >
                Proposal {aiMeta.proposal_id} →
              </Link>
            )}

            <div className="flex items-center justify-between gap-2 border-t border-stone-100 pt-2">
              <span className="font-mono text-[10px] text-stone-400">
                {aiMeta ? (aiMeta.stale ? "Needs recompute" : "Up to date") : "Not computed"}
              </span>
              {onRunSingleRowAi && (
                <button
                  type="button"
                  disabled={disabled}
                  onClick={() => {
                    setEditing(false);
                    onRunSingleRowAi();
                  }}
                  className="inline-flex items-center gap-1 rounded-md bg-purple-700 px-2.5 py-1 text-[11px] font-medium text-white hover:bg-purple-800 disabled:opacity-50"
                >
                  <RefreshCw className="h-3 w-3" />
                  Re-run row
                </button>
              )}
            </div>
          </div>
        )}
      </div>
    );
  }

  // 5. NUMBER (exact decimal text preservation)
  if (typeof prop.kind === "object" && "number" in prop.kind) {
    const fmt = prop.kind.number.format;
    const curRaw = typeof cell === "object" && "number_val" in cell ? cell.number_val : "";
    if (editing) {
      const saveNum = () => {
        const t = draft.trim();
        if (!t) {
          setEditing(false);
          setLocalError(null);
          if (curRaw) void onCommit("empty");
          return;
        }
        if (!/^-?\d+(\.\d+)?$/.test(t)) {
          setLocalError("Enter a valid decimal number");
          return;
        }
        setEditing(false);
        setLocalError(null);
        if (t !== curRaw) void onCommit({ number_val: t });
      };
      return (
        <div ref={containerRef} className="relative min-w-[100px]">
          <input
            autoFocus
            inputMode="decimal"
            value={draft}
            placeholder="0.00"
            onChange={(e) => {
              setDraft(e.target.value);
              setLocalError(null);
            }}
            onBlur={saveNum}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                saveNum();
              } else if (e.key === "Escape") {
                setEditing(false);
                setLocalError(null);
              }
            }}
            className={`w-28 rounded border px-2 py-0.5 font-mono text-xs outline-none ${
              localError
                ? "border-red-400 bg-red-50 ring-2 ring-red-100"
                : "border-blue-400 bg-white ring-2 ring-blue-100"
            }`}
          />
          {localError && (
            <div className="absolute left-0 top-full mt-1 z-20 rounded bg-red-700 px-2 py-0.5 text-[10px] text-white whitespace-nowrap shadow">
              {localError}
            </div>
          )}
        </div>
      );
    }
    return (
      <button
        type="button"
        disabled={disabled}
        onClick={() => {
          setDraft(curRaw);
          setLocalError(null);
          setEditing(true);
        }}
        className="font-mono text-xs tabular-nums text-stone-800 hover:bg-stone-100 rounded px-1.5 py-0.5 min-w-[48px] text-left"
        title="Click to edit exact decimal"
      >
        {curRaw ? formatNumberCell(curRaw, fmt) : <span className="text-stone-400">—</span>}
      </button>
    );
  }

  // 6. RICH TEXT
  if (prop.kind === "rich_text") {
    const curText = typeof cell === "object" && "text_val" in cell ? cell.text_val : "";
    if (editing) {
      const saveText = () => {
        const t = draft.trim();
        setEditing(false);
        if (t === curText) return;
        void onCommit(t ? { text_val: draft.trim() } : "empty");
      };
      return (
        <div ref={containerRef} className="min-w-[140px]">
          <input
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={saveText}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                saveText();
              } else if (e.key === "Escape") {
                setEditing(false);
              }
            }}
            className="w-full rounded border border-blue-400 bg-white px-2 py-0.5 text-xs text-stone-900 outline-none ring-2 ring-blue-100"
          />
        </div>
      );
    }
    return (
      <button
        type="button"
        disabled={disabled}
        onClick={() => {
          setDraft(curText);
          setEditing(true);
        }}
        className="text-left text-xs text-stone-700 hover:bg-stone-100 rounded px-1.5 py-0.5 max-w-[220px] truncate block"
      >
        {curText || <span className="text-stone-400">—</span>}
      </button>
    );
  }

  // 7. URL
  if (prop.kind === "url") {
    const curUrl = typeof cell === "object" && "url_val" in cell ? cell.url_val : "";
    if (editing) {
      const saveUrl = () => {
        const t = draft.trim();
        if (!t) {
          setEditing(false);
          setLocalError(null);
          if (curUrl) void onCommit("empty");
          return;
        }
        if (!isSafeHttpUrl(t)) {
          setLocalError("URL must start with http:// or https://");
          return;
        }
        setEditing(false);
        setLocalError(null);
        if (t !== curUrl) void onCommit({ url_val: t });
      };
      return (
        <div ref={containerRef} className="relative min-w-[180px]">
          <input
            autoFocus
            type="url"
            placeholder="https://..."
            value={draft}
            onChange={(e) => {
              setDraft(e.target.value);
              setLocalError(null);
            }}
            onBlur={saveUrl}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                saveUrl();
              } else if (e.key === "Escape") {
                setEditing(false);
                setLocalError(null);
              }
            }}
            className={`w-full rounded border px-2 py-0.5 text-xs outline-none ${
              localError
                ? "border-red-400 bg-red-50 ring-2 ring-red-100"
                : "border-blue-400 bg-white ring-2 ring-blue-100"
            }`}
          />
          {localError && (
            <div className="absolute left-0 top-full mt-1 z-20 rounded bg-red-700 px-2 py-0.5 text-[10px] text-white whitespace-nowrap shadow">
              {localError}
            </div>
          )}
        </div>
      );
    }
    return (
      <div className="group flex items-center gap-1.5">
        {curUrl && isSafeHttpUrl(curUrl) ? (
          <a
            href={curUrl}
            target="_blank"
            rel="noreferrer"
            className="text-xs text-blue-600 hover:underline truncate max-w-[180px]"
          >
            {curUrl.replace(/^https?:\/\//i, "")}
          </a>
        ) : (
          <button
            type="button"
            disabled={disabled}
            onClick={() => {
              setDraft("");
              setEditing(true);
            }}
            className="text-xs text-stone-400 hover:text-stone-700"
          >
            —
          </button>
        )}
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setDraft(curUrl);
            setEditing(true);
          }}
          className="opacity-0 group-hover:opacity-100 text-stone-400 hover:text-stone-700 transition"
          title="Edit URL"
        >
          <Pencil className="h-3 w-3" />
        </button>
      </div>
    );
  }

  // 7b. EMAIL
  if (prop.kind === "email") {
    const curEmail = typeof cell === "object" && "text_val" in cell ? cell.text_val : "";
    if (editing) {
      const saveEmail = () => {
        const t = draft.trim();
        if (!t) {
          setEditing(false);
          setLocalError(null);
          if (curEmail) void onCommit("empty");
          return;
        }
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(t)) {
          setLocalError("Enter a valid email address");
          return;
        }
        setEditing(false);
        setLocalError(null);
        if (t !== curEmail) void onCommit({ text_val: t });
      };
      return (
        <div ref={containerRef} className="relative min-w-[180px]">
          <input
            autoFocus
            type="email"
            placeholder="name@domain.edu"
            value={draft}
            onChange={(e) => {
              setDraft(e.target.value);
              setLocalError(null);
            }}
            onBlur={saveEmail}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                saveEmail();
              } else if (e.key === "Escape") {
                setEditing(false);
                setLocalError(null);
              }
            }}
            className={`w-full rounded border px-2 py-0.5 text-xs outline-none ${
              localError
                ? "border-red-400 bg-red-50 ring-2 ring-red-100"
                : "border-blue-400 bg-white ring-2 ring-blue-100"
            }`}
          />
          {localError && (
            <div className="absolute left-0 top-full mt-1 z-20 rounded bg-red-700 px-2 py-0.5 text-[10px] text-white whitespace-nowrap shadow">
              {localError}
            </div>
          )}
        </div>
      );
    }
    return (
      <div className="group flex items-center gap-1.5">
        {curEmail ? (
          <a
            href={`mailto:${curEmail}`}
            className="inline-flex items-center gap-1 text-xs text-blue-600 hover:underline truncate max-w-[190px]"
          >
            <AtSign className="h-3 w-3 text-stone-400 shrink-0" />
            {curEmail}
          </a>
        ) : (
          <button
            type="button"
            disabled={disabled}
            onClick={() => {
              setDraft("");
              setEditing(true);
            }}
            className="text-xs text-stone-400 hover:text-stone-700"
          >
            —
          </button>
        )}
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setDraft(curEmail);
            setEditing(true);
          }}
          className="opacity-0 group-hover:opacity-100 text-stone-400 hover:text-stone-700 transition"
          title="Edit email"
        >
          <Pencil className="h-3 w-3" />
        </button>
      </div>
    );
  }

  // 7c. FILE LIST
  if (prop.kind === "file_list") {
    const ids =
      typeof cell === "object" && "files_val" in cell ? cell.files_val.attachment_ids : [];
    const removeFile = (fid: string) => {
      const next = ids.filter((x) => x !== fid);
      void onCommit(next.length > 0 ? { files_val: { attachment_ids: next } } : "empty");
    };
    const addFile = () => {
      const t = searchText.trim();
      if (!t) return;
      if (ids.includes(t)) {
        setSearchText("");
        return;
      }
      setSearchText("");
      void onCommit({ files_val: { attachment_ids: [...ids, t] } });
    };
    return (
      <div ref={containerRef} className="relative flex flex-wrap items-center gap-1">
        {ids.map((fid) => (
          <span
            key={fid}
            className="inline-flex items-center gap-1 rounded border border-stone-200 bg-stone-50 px-2 py-0.5 text-[11px] text-stone-700"
          >
            <Paperclip className="h-2.5 w-2.5 text-stone-400" />
            {fid.startsWith("att_") ? (
              <a
                href={`/api/attachments/${fid}/download`}
                target="_blank"
                rel="noreferrer"
                className="hover:underline font-mono text-[10px]"
              >
                {fid}
              </a>
            ) : (
              <span className="truncate max-w-[140px]">{fid}</span>
            )}
            {!disabled && (
              <button
                type="button"
                onClick={() => removeFile(fid)}
                className="text-stone-400 hover:text-red-600"
                title="Remove file"
              >
                <X className="h-2.5 w-2.5" />
              </button>
            )}
          </span>
        ))}
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setSearchText("");
            setEditing((prev) => !prev);
          }}
          className="inline-flex items-center gap-1 rounded border border-dashed border-stone-300 px-1.5 py-0.5 text-[11px] text-stone-500 hover:border-stone-400 hover:text-stone-800"
          title="Add file attachment ID"
        >
          <Paperclip className="h-3 w-3" />
          {ids.length === 0 ? "Add file" : "+"}
        </button>
        {editing && (
          <div className="absolute left-0 top-full mt-1 z-30 w-60 rounded-xl border border-stone-200 bg-white p-2 shadow-lg space-y-2">
            <div className="flex gap-1">
              <input
                autoFocus
                value={searchText}
                onChange={(e) => setSearchText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    addFile();
                  }
                }}
                placeholder="att_... or filename"
                className="flex-1 rounded-md border border-stone-200 px-2 py-1 text-xs outline-none"
              />
              <button
                type="button"
                onClick={addFile}
                className="rounded-md bg-stone-900 px-2 py-1 text-xs font-medium text-white hover:bg-stone-800"
              >
                Add
              </button>
            </div>
          </div>
        )}
      </div>
    );
  }

  // 8. DATE / DATE RANGE
  if (typeof prop.kind === "object" && "date_prop" in prop.kind) {
    const startVal = typeof cell === "object" && "date_val" in cell ? cell.date_val.start : "";
    const endVal = typeof cell === "object" && "date_val" in cell ? cell.date_val.end_date ?? "" : "";
    return (
      <div ref={containerRef} className="relative inline-block">
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setDraft(startVal);
            setEndDateDraft(endVal);
            setLocalError(null);
            setEditing((prev) => !prev);
          }}
          className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-xs text-stone-700 hover:bg-stone-100 font-mono"
        >
          <Calendar className="h-3 w-3 text-stone-400" />
          {startVal ? (
            endVal ? `${startVal} → ${endVal}` : startVal
          ) : (
            <span className="text-stone-400 font-sans">—</span>
          )}
        </button>
        {editing && (
          <div className="absolute left-0 top-full mt-1 z-30 w-60 rounded-xl border border-stone-200 bg-white p-3 shadow-lg space-y-2.5 text-xs">
            <div>
              <label className="block text-[11px] font-medium text-stone-600 mb-1">Start date</label>
              <input
                type="date"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs"
              />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-stone-600 mb-1">End date (optional)</label>
              <input
                type="date"
                value={endDateDraft}
                onChange={(e) => setEndDateDraft(e.target.value)}
                className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs"
              />
            </div>
            {localError && <div className="text-[11px] text-red-600">{localError}</div>}
            <div className="flex items-center justify-between gap-2 pt-1">
              <button
                type="button"
                onClick={() => {
                  setEditing(false);
                  void onCommit("empty");
                }}
                className="text-stone-500 hover:text-red-600 text-[11px]"
              >
                Clear
              </button>
              <button
                type="button"
                onClick={() => {
                  if (!draft) {
                    setEditing(false);
                    void onCommit("empty");
                    return;
                  }
                  if (endDateDraft && endDateDraft < draft) {
                    setLocalError("End date must be on or after start date");
                    return;
                  }
                  setEditing(false);
                  void onCommit({
                    date_val: {
                      start: draft,
                      end_date: endDateDraft || null,
                    },
                  });
                }}
                className="rounded-md bg-stone-900 px-2.5 py-1 text-[11px] font-medium text-white hover:bg-stone-800"
              >
                Save Date
              </button>
            </div>
          </div>
        )}
      </div>
    );
  }

  // 9. MULTI-SELECT
  if (typeof prop.kind === "object" && "multi_select" in prop.kind) {
    const opts = prop.kind.multi_select.options;
    const selectedIds =
      typeof cell === "object" && "multi_select_val" in cell ? cell.multi_select_val.option_ids : [];
    const toggleOpt = (optId: string) => {
      const exists = selectedIds.includes(optId);
      const next = exists ? selectedIds.filter((x) => x !== optId) : [...selectedIds, optId];
      void onCommit(next.length > 0 ? { multi_select_val: { option_ids: next } } : "empty");
    };
    return (
      <div ref={containerRef} className="relative inline-block">
        <button
          type="button"
          disabled={disabled}
          onClick={() => setEditing((prev) => !prev)}
          className="flex flex-wrap items-center gap-1 rounded px-1 py-0.5 hover:bg-stone-100 min-w-[60px] text-left"
        >
          {selectedIds.length > 0 ? (
            selectedIds.map((oid) => {
              const opt = opts.find((o) => o.id === oid);
              const cls = opt ? SELECT_COLOR_CLASSES[opt.color] : SELECT_COLOR_CLASSES.gray;
              return (
                <span
                  key={oid}
                  className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-medium ${cls}`}
                >
                  {opt?.label ?? oid}
                </span>
              );
            })
          ) : (
            <span className="text-xs text-stone-400">—</span>
          )}
        </button>
        {editing && (
          <div className="absolute left-0 top-full mt-1 z-30 w-52 rounded-xl border border-stone-200 bg-white p-2 shadow-lg space-y-1">
            {opts.map((o) => {
              const active = selectedIds.includes(o.id);
              return (
                <button
                  key={o.id}
                  type="button"
                  disabled={disabled}
                  onClick={() => toggleOpt(o.id)}
                  className="w-full flex items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-xs hover:bg-stone-50"
                >
                  <span className="flex items-center gap-2">
                    <span className={`h-2 w-2 rounded-full ${SELECT_DOT_CLASSES[o.color]}`} />
                    <span className="text-stone-800">{o.label}</span>
                  </span>
                  {active && <Check className="h-3.5 w-3.5 text-stone-900" />}
                </button>
              );
            })}
          </div>
        )}
      </div>
    );
  }

  // 10. PERSON
  if (prop.kind === "person") {
    const selectedIds =
      typeof cell === "object" && "principal_val" in cell ? cell.principal_val : [];
    const filteredPrincipals = principals.filter((p) => {
      if (!searchText.trim()) return true;
      const q = searchText.trim().toLowerCase();
      return (
        p.display_name.toLowerCase().includes(q) || p.handle.toLowerCase().includes(q)
      );
    });
    const togglePerson = (pid: string) => {
      const exists = selectedIds.includes(pid);
      const next = exists ? selectedIds.filter((x) => x !== pid) : [...selectedIds, pid];
      void onCommit(next.length > 0 ? { principal_val: next } : "empty");
    };
    return (
      <div ref={containerRef} className="relative inline-block">
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setSearchText("");
            setEditing((prev) => !prev);
          }}
          className="flex flex-wrap items-center gap-1 rounded px-1 py-0.5 hover:bg-stone-100 min-w-[64px]"
        >
          {selectedIds.length > 0 ? (
            selectedIds.map((pid) => {
              const pr = principals.find((x) => x.id === pid);
              return (
                <span
                  key={pid}
                  className="inline-flex items-center gap-1 rounded-full border border-stone-200 bg-stone-50 px-2 py-0.5 text-[11px] font-medium text-stone-700"
                >
                  <User className="h-2.5 w-2.5 text-stone-400" />
                  {pr ? pr.display_name : pid}
                </span>
              );
            })
          ) : (
            <span className="text-xs text-stone-400">—</span>
          )}
        </button>
        {editing && (
          <div className="absolute left-0 top-full mt-1 z-30 w-64 rounded-xl border border-stone-200 bg-white p-2 shadow-lg space-y-2">
            <input
              autoFocus
              value={searchText}
              onChange={(e) => setSearchText(e.target.value)}
              placeholder="Filter people & agents..."
              className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs outline-none"
            />
            <div className="max-h-48 overflow-y-auto space-y-0.5">
              {filteredPrincipals.length === 0 ? (
                <div className="px-2 py-2 text-[11px] text-stone-400">No matching members</div>
              ) : (
                filteredPrincipals.map((pr) => {
                  const active = selectedIds.includes(pr.id);
                  return (
                    <button
                      key={pr.id}
                      type="button"
                      disabled={disabled}
                      onClick={() => togglePerson(pr.id)}
                      className="w-full flex items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-xs hover:bg-stone-50 text-left"
                    >
                      <div className="truncate">
                        <span className="font-medium text-stone-800">{pr.display_name}</span>
                        <span className="ml-1.5 text-[11px] text-stone-400">{pr.handle}</span>
                        {pr.kind === "agent" && (
                          <span className="ml-1.5 rounded bg-violet-100 px-1 py-0.5 text-[9px] font-semibold uppercase text-violet-700">
                            Agent
                          </span>
                        )}
                      </div>
                      {active && <Check className="h-3.5 w-3.5 text-stone-900 shrink-0" />}
                    </button>
                  );
                })
              )}
            </div>
          </div>
        )}
      </div>
    );
  }

  // 11. RELATION
  if (typeof prop.kind === "object" && "relation" in prop.kind) {
    const targetDbId = prop.kind.relation.target_db_id;
    const options = relationTargets[targetDbId] ?? [];
    const selectedIds =
      typeof cell === "object" && "relation_val" in cell ? cell.relation_val.row_ids : [];
    const filteredOptions = options.filter((o) =>
      !searchText.trim() || o.title.toLowerCase().includes(searchText.trim().toLowerCase())
    );
    const toggleRel = (rowId: string) => {
      const exists = selectedIds.includes(rowId);
      const next = exists ? selectedIds.filter((x) => x !== rowId) : [...selectedIds, rowId];
      void onCommit(next.length > 0 ? { relation_val: { row_ids: next } } : "empty");
    };
    return (
      <div ref={containerRef} className="relative flex flex-wrap items-center gap-1">
        {selectedIds.map((rid) => {
          const opt = options.find((o) => o.row_id === rid);
          return opt ? (
            <span
              key={rid}
              className="inline-flex items-center gap-1 rounded-md border border-blue-200 bg-blue-50/70 px-2 py-0.5 text-[11px] font-medium text-blue-800"
            >
              <Link href={`/p/${opt.page_id}`} className="hover:underline">
                {opt.title}
              </Link>
              <button
                type="button"
                disabled={disabled}
                onClick={() => toggleRel(rid)}
                className="text-blue-400 hover:text-blue-800"
                title="Unlink row"
              >
                <X className="h-2.5 w-2.5" />
              </button>
            </span>
          ) : (
            <span
              key={rid}
              className="inline-flex items-center gap-1 rounded-md border border-stone-200 bg-stone-50 px-2 py-0.5 font-mono text-[10px] text-stone-600"
            >
              {rid}
            </span>
          );
        })}
        <button
          type="button"
          disabled={disabled}
          onClick={() => {
            setSearchText("");
            setEditing((prev) => !prev);
          }}
          className="inline-flex items-center gap-1 rounded-md border border-dashed border-stone-300 px-1.5 py-0.5 text-[11px] text-stone-500 hover:border-stone-400 hover:text-stone-800"
          title="Link related rows"
        >
          <Link2 className="h-3 w-3" />
          {selectedIds.length === 0 ? "Link" : "+"}
        </button>
        {editing && (
          <div className="absolute left-0 top-full mt-1 z-30 w-64 rounded-xl border border-stone-200 bg-white p-2 shadow-lg space-y-2">
            <input
              autoFocus
              value={searchText}
              onChange={(e) => setSearchText(e.target.value)}
              placeholder="Search target rows..."
              className="w-full rounded-md border border-stone-200 px-2 py-1 text-xs outline-none"
            />
            <div className="max-h-48 overflow-y-auto space-y-0.5">
              {filteredOptions.length === 0 ? (
                <div className="px-2 py-2 text-[11px] text-stone-400">No rows available to link</div>
              ) : (
                filteredOptions.map((o) => {
                  const active = selectedIds.includes(o.row_id);
                  return (
                    <button
                      key={o.row_id}
                      type="button"
                      disabled={disabled}
                      onClick={() => toggleRel(o.row_id)}
                      className="w-full flex items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-xs hover:bg-stone-50 text-left"
                    >
                      <span className="truncate font-medium text-stone-800">{o.title}</span>
                      {active && <Check className="h-3.5 w-3.5 text-stone-900 shrink-0" />}
                    </button>
                  );
                })
              )}
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <span className="text-xs text-stone-700">
      {renderCellDisplay(cell, prop, principals)}
    </span>
  );
}
