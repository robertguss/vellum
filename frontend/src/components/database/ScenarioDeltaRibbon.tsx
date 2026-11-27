import { Link } from "@inertiajs/react";
import { ArrowRight, Check, GitBranch, GitMerge, Trash2 } from "lucide-react";
import type { ScenarioQueryResponse } from "../../lib/types";
import { formatNumberCell, formatSignedDecimal } from "./InlineCellEditor";

interface ScenarioDeltaRibbonProps {
  scenarioData: ScenarioQueryResponse;
  busy: boolean;
  onExitToLive: () => void;
  onMerge: () => Promise<void>;
  onDiscard: () => Promise<void>;
}

export default function ScenarioDeltaRibbon({
  scenarioData,
  busy,
  onExitToLive,
  onMerge,
  onDiscard,
}: ScenarioDeltaRibbonProps) {
  const {
    proposal,
    deltas,
    live_row_count,
    scenario_row_count,
    schema_changed,
    step_count,
  } = scenarioData;

  return (
    <div className="rounded-2xl border border-indigo-200 bg-gradient-to-r from-indigo-50/90 via-violet-50/70 to-white p-4 space-y-3 shadow-2xs">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          <span className="inline-flex items-center gap-1.5 rounded-full bg-indigo-600 px-2.5 py-0.5 text-[11px] font-semibold text-white">
            <GitBranch className="h-3 w-3" />
            What-If Scenario
          </span>
          <span className="text-sm font-semibold text-indigo-950">{proposal.title}</span>
          <span className="rounded-full border border-indigo-200 bg-white px-2 py-0.5 font-mono text-[11px] text-indigo-700">
            {step_count} {step_count === 1 ? "step" : "steps"}
          </span>
          <span className="rounded-full border border-indigo-200 bg-white px-2 py-0.5 text-[11px] text-indigo-800">
            Rows: {live_row_count} → {scenario_row_count}
          </span>
          {schema_changed && (
            <span className="rounded-full border border-amber-200 bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-800">
              Schema changed
            </span>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            disabled={busy}
            onClick={onExitToLive}
            className="rounded-lg border border-indigo-200 bg-white px-2.5 py-1.5 text-xs font-medium text-indigo-800 hover:bg-indigo-50"
          >
            Back to Live
          </button>
          <Link
            href="/proposals"
            className="rounded-lg border border-indigo-200 bg-white px-2.5 py-1.5 text-xs font-medium text-indigo-800 hover:bg-indigo-50"
          >
            Inspect Diff
          </Link>
          <button
            type="button"
            disabled={busy}
            onClick={() => void onDiscard()}
            className="inline-flex items-center gap-1 rounded-lg border border-red-200 bg-white px-2.5 py-1.5 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
          >
            <Trash2 className="h-3.5 w-3.5" />
            Discard
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={() => void onMerge()}
            className="inline-flex items-center gap-1 rounded-lg bg-emerald-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-800 disabled:opacity-50"
          >
            <GitMerge className="h-3.5 w-3.5" />
            <Check className="h-3.5 w-3.5 -ml-1" />
            Merge to Live
          </button>
        </div>
      </div>

      {deltas.length > 0 && (
        <div className="flex flex-wrap gap-2.5">
          {deltas.map((d) => {
            const isPos = !d.delta.startsWith("-");
            const deltaColor = !d.changed
              ? "bg-stone-100 text-stone-600 border-stone-200"
              : isPos
                ? "bg-emerald-100 text-emerald-800 border-emerald-200"
                : "bg-rose-100 text-rose-800 border-rose-200";
            return (
              <div
                key={d.prop_id}
                className="rounded-xl border border-indigo-100 bg-white/90 px-3 py-2 flex items-center gap-2.5 text-xs shadow-2xs"
              >
                <span className="font-medium text-stone-700">
                  {d.prop_name}
                  {d.is_rollup ? " (Rollup)" : ""}
                </span>
                <span className="font-mono text-stone-500 tabular-nums">
                  {formatNumberCell(d.live_total, d.format)}
                </span>
                <ArrowRight className="h-3 w-3 text-stone-400" />
                <span className="font-mono font-semibold text-stone-950 tabular-nums">
                  {formatNumberCell(d.scenario_total, d.format)}
                </span>
                <span
                  className={`rounded-full border px-2 py-0.5 font-mono text-[11px] font-semibold tabular-nums ${deltaColor}`}
                >
                  {formatSignedDecimal(d.delta, d.format)}
                </span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
