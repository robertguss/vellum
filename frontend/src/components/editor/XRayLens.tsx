import { Link } from "@inertiajs/react";
import {
  Activity,
  AlertTriangle,
  Bot,
  Calculator,
  GitPullRequest,
  History,
  Layers,
  Shield,
  ShieldAlert,
  ShieldCheck,
  User,
} from "lucide-react";
import { useEffect, useState } from "react";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  AuditFeedItem,
  Block,
  GardenCitationDrift,
  Page,
  PageHistoryResponse,
  PageTaintProvenance,
  PageTimeTravelResponse,
  ResolvedMetric,
} from "../../lib/types";
import { formatNumberCell, formatSignedDecimal } from "../database/InlineCellEditor";

interface XRayLensProps {
  page: Page;
  blocks: Block[];
  resolvedMetrics: Record<string, ResolvedMetric>;
  yamlFrontmatter: string;
  pageAudit: AuditFeedItem[];
  citationDrifts?: GardenCitationDrift[];
  taintProvenance?: PageTaintProvenance | null;
  stagingDriftId?: string | null;
  onStageDriftProposal?: (drift: GardenCitationDrift) => void;
  onInspectBlock: (blockId: string) => void;
}

export default function XRayLens({
  page,
  blocks,
  resolvedMetrics,
  yamlFrontmatter,
  pageAudit,
  citationDrifts = [],
  taintProvenance = null,
  stagingDriftId = null,
  onStageDriftProposal,
  onInspectBlock,
}: XRayLensProps) {
  const metricEntries = Object.values(resolvedMetrics);
  const [history, setHistory] = useState<PageHistoryResponse | null>(null);
  const [historyErr, setHistoryErr] = useState<string | null>(null);
  const [selectedStopIdx, setSelectedStopIdx] = useState<number>(-1);
  const [ttPreview, setTtPreview] = useState<PageTimeTravelResponse | null>(null);
  const [ttLoading, setTtLoading] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setHistoryErr(null);
    apiFetch<PageHistoryResponse>(`/api/pages/${page.id}/history`)
      .then((res) => {
        if (cancelled) return;
        setHistory(res);
        setSelectedStopIdx(res.stops.length > 0 ? res.stops.length - 1 : -1);
      })
      .catch((err) => {
        if (!cancelled) {
          setHistoryErr(err instanceof ApiError ? err.message : "Could not load page replay history");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [page.id, page.version]);

  async function scrubToStop(idx: number) {
    if (!history || idx < 0 || idx >= history.stops.length) return;
    setSelectedStopIdx(idx);
    const stop = history.stops[idx];
    setTtLoading(true);
    setHistoryErr(null);
    try {
      const res = await apiFetch<PageTimeTravelResponse>(
        `/api/pages/${page.id}/time-travel?stop_before_seq=${stop.stop_before_seq}`
      );
      setTtPreview(res);
    } catch (err) {
      setHistoryErr(err instanceof ApiError ? err.message : "Time-travel simulation failed");
    } finally {
      setTtLoading(false);
    }
  }

  return (
    <div className="space-y-6">
      {/* Modb.Replay Interactive Point-in-Time Scrubber */}
      <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
            <History className="h-4 w-4 text-amber-700" />
            Modb.Replay Time-Travel Scrubber
          </div>
          {history?.can_scrub ? (
            <span className="rounded-full bg-amber-50 border border-amber-200 px-2.5 py-0.5 text-[11px] font-medium text-amber-900">
              {history.stops.length} checkpoint{history.stops.length === 1 ? "" : "s"} · Offline Read-Only CoW
            </span>
          ) : (
            <Link
              href="/admin"
              className="text-[11px] font-medium text-blue-700 hover:underline"
            >
              Pin CoW Baseline in Admin →
            </Link>
          )}
        </div>

        {historyErr && <div className="text-xs text-red-700">{historyErr}</div>}

        {history && !history.can_scrub && (
          <p className="text-xs text-stone-500">
            Pin a <code className="font-mono">Modb.Replay</code> CoW baseline in{" "}
            <Link href="/admin" className="text-blue-700 hover:underline">
              Admin → Selective Undo
            </Link>{" "}
            to scrub historical revisions of <span className="font-medium">{page.title}</span>.
          </p>
        )}

        {history?.can_scrub && history.stops.length > 0 && (
          <div className="space-y-3">
            <div className="flex flex-wrap items-center gap-3">
              <input
                type="range"
                min={0}
                max={history.stops.length - 1}
                value={selectedStopIdx >= 0 ? selectedStopIdx : history.stops.length - 1}
                onChange={(e) => void scrubToStop(Number(e.target.value))}
                className="flex-1 accent-amber-700 cursor-pointer"
                aria-label="Time-travel checkpoint slider"
              />
              {ttLoading && (
                <span className="text-[11px] text-amber-700 font-medium">Replaying...</span>
              )}
            </div>
            <div className="flex flex-wrap gap-1.5">
              {history.stops.map((st, idx) => {
                const active = selectedStopIdx === idx;
                return (
                  <button
                    key={`${st.seq}-${idx}`}
                    type="button"
                    onClick={() => void scrubToStop(idx)}
                    className={`rounded-lg border px-2.5 py-1 text-[11px] font-medium transition ${
                      active
                        ? "border-amber-700 bg-amber-700 text-white"
                        : "border-stone-200 bg-stone-50 text-stone-700 hover:bg-stone-100"
                    }`}
                  >
                    {st.label}
                  </button>
                );
              })}
            </div>
            {selectedStopIdx >= 0 && history.stops[selectedStopIdx] && (
              <div className="rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs text-stone-600 flex flex-wrap items-center justify-between gap-2">
                <span>
                  <strong>{history.stops[selectedStopIdx].action}</strong> ·{" "}
                  {history.stops[selectedStopIdx].reason}
                </span>
                <span className="font-mono text-[11px] text-stone-400">
                  {history.stops[selectedStopIdx].at}
                </span>
              </div>
            )}
            {ttPreview && (
              <div className="rounded-xl border border-amber-200 bg-amber-50/40 p-3.5 space-y-2">
                <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
                  <div className="font-semibold text-amber-950">
                    {ttPreview.existed_at_point
                      ? `Historical Snapshot (stop_before_seq=${ttPreview.stop_before_seq})`
                      : `Page did not exist at stop_before_seq=${ttPreview.stop_before_seq}`}
                  </div>
                  <span className="rounded-full bg-white border border-amber-200 px-2 py-0.5 font-mono text-[11px] text-amber-900">
                    {ttPreview.ops_to_live_count} block diff{ttPreview.ops_to_live_count === 1 ? "" : "s"} vs Live
                  </span>
                </div>
                {ttPreview.existed_at_point && (
                  <pre className="rounded-lg bg-stone-950 text-stone-100 p-3 text-[11px] font-mono leading-relaxed whitespace-pre-wrap max-h-56 overflow-y-auto">
                    {ttPreview.historical_markdown || "(empty document at this checkpoint)"}
                  </pre>
                )}
              </div>
            )}
          </div>
        )}
      </section>

      {citationDrifts.length > 0 && (
        <section className="rounded-2xl border border-amber-300 bg-amber-50/70 p-5 space-y-3">
          <div className="flex items-center justify-between gap-2">
            <div className="flex items-center gap-2 text-sm font-semibold text-amber-950">
              <AlertTriangle className="h-4 w-4 text-amber-700" />
              Cited-Dependency Drift ({citationDrifts.length})
            </div>
            <span className="text-[11px] font-medium text-amber-800">
              Proposals-Only Safeguard Active
            </span>
          </div>
          <div className="space-y-2">
            {citationDrifts.map((d) => {
              const driftKey = `${d.dependent_block_id}->${d.cited_block_id}`;
              return (
                <div
                  key={driftKey}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-amber-200 bg-white px-3.5 py-2.5 text-xs"
                >
                  <div className="space-y-0.5">
                    <div className="font-medium text-stone-900">{d.summary}</div>
                    <div className="font-mono text-[11px] text-stone-500">
                      Local block {d.dependent_block_id} cites {d.cited_page_title} §
                      {d.cited_block_id} (v{d.cited_block_version})
                    </div>
                  </div>
                  {onStageDriftProposal && (
                    <button
                      type="button"
                      disabled={stagingDriftId === driftKey}
                      onClick={() => onStageDriftProposal(d)}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-amber-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-amber-800 disabled:opacity-50"
                    >
                      <GitPullRequest className="h-3.5 w-3.5" />
                      {stagingDriftId === driftKey ? "Staging..." : "Stage Refresh Proposal"}
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        </section>
      )}
      {/* Live Metric Computation Audit */}
      <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
        <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
          <Calculator className="h-4 w-4 text-teal-700" />
          Live Metric Lineage ({metricEntries.length})
        </div>
        {metricEntries.length === 0 ? (
          <p className="text-xs text-stone-400">
            No <code className="font-mono">{"{{metric:<db>.<prop>:<agg>}}"}</code> pills referenced
            on {page.title}.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left border-collapse text-xs">
              <thead>
                <tr className="border-b border-stone-200 text-[11px] font-medium text-stone-500">
                  <th className="py-2 pr-3">Token</th>
                  <th className="py-2 pr-3">Source Database · Property</th>
                  <th className="py-2 pr-3">Live</th>
                  <th className="py-2 pr-3">Scenario / Delta</th>
                  <th className="py-2">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-stone-100">
                {metricEntries.map((m) => (
                  <tr key={m.token}>
                    <td className="py-2 pr-3 font-mono text-[11px] text-stone-800">{m.token}</td>
                    <td className="py-2 pr-3 text-stone-600">
                      {m.database_title ?? m.database_id} · {m.property_name ?? m.property_id} (
                      {m.agg})
                    </td>
                    <td className="py-2 pr-3 font-mono font-semibold text-stone-900 tabular-nums">
                      {m.live_value !== null ? formatNumberCell(m.live_value, m.format) : "—"}
                    </td>
                    <td className="py-2 pr-3 font-mono tabular-nums">
                      {m.scenario_value !== null ? (
                        <span className="text-indigo-700">
                          {formatNumberCell(m.scenario_value, m.format)}{" "}
                          {m.delta ? `(${formatSignedDecimal(m.delta, m.format)})` : ""}
                        </span>
                      ) : (
                        <span className="text-stone-400">Live</span>
                      )}
                    </td>
                    <td className="py-2">
                      <span
                        className={`rounded-full px-2 py-0.5 text-[10px] font-medium uppercase ${
                          m.status === "ok"
                            ? "bg-emerald-100 text-emerald-800"
                            : "bg-amber-100 text-amber-800"
                        }`}
                      >
                        {m.status}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* Block Provenance Matrix */}
      <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
            <Shield className="h-4 w-4 text-blue-700" />
            Canonical Block Provenance Tree ({blocks.length} blocks)
          </div>
          {taintProvenance &&
          (taintProvenance.trust === "untrusted" ||
            taintProvenance.untrusted_block_ids.length > 0) ? (
            <span className="inline-flex items-center gap-1 rounded-full border border-amber-300 bg-amber-50 px-2.5 py-0.5 text-[11px] font-medium text-amber-900">
              <ShieldAlert className="h-3 w-3 text-amber-700" />
              Untrusted Provenance
            </span>
          ) : (
            <span className="inline-flex items-center gap-1 rounded-full border border-emerald-200 bg-emerald-50 px-2.5 py-0.5 text-[11px] font-medium text-emerald-800">
              <ShieldCheck className="h-3 w-3 text-emerald-600" />
              Trusted Provenance
            </span>
          )}
        </div>
        <div className="divide-y divide-stone-100">
          {blocks.map((b) => {
            const isHuman = b.provenance.author_kind === "human_author";
            const blockTaint = taintProvenance?.blocks?.[b.id];
            const isUntrusted = blockTaint?.trust === "untrusted";
            return (
              <div key={b.id} className="py-3 flex flex-wrap items-start justify-between gap-3">
                <div className="space-y-1 min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2 text-xs">
                    <button
                      type="button"
                      onClick={() => onInspectBlock(b.id)}
                      className="font-mono font-semibold text-blue-700 hover:underline"
                    >
                      {b.id}
                    </button>
                    <span className="rounded bg-stone-100 px-1.5 py-0.5 font-mono text-[10px] text-stone-600">
                      rank={b.rank}
                    </span>
                    <span className="rounded bg-stone-100 px-1.5 py-0.5 font-mono text-[10px] text-stone-600">
                      v{b.version}
                    </span>
                    <span
                      className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-medium ${
                        isHuman ? "bg-stone-100 text-stone-700" : "bg-teal-100 text-teal-800"
                      }`}
                    >
                      {isHuman ? <User className="h-2.5 w-2.5" /> : <Bot className="h-2.5 w-2.5" />}
                      {b.provenance.author_id}
                    </span>
                    {isUntrusted && (
                      <span className="inline-flex items-center gap-1 rounded-full border border-amber-300 bg-amber-50 px-2 py-0.5 font-mono text-[10px] text-amber-900">
                        <ShieldAlert className="h-2.5 w-2.5 text-amber-700" />
                        Untrusted · {blockTaint.writer}
                      </span>
                    )}
                    {b.provenance.proposal_id && (
                      <span className="rounded-full bg-indigo-50 border border-indigo-200 px-2 py-0.5 font-mono text-[10px] text-indigo-800">
                        {b.provenance.proposal_id}
                      </span>
                    )}
                  </div>
                  <div className="text-xs text-stone-700 truncate">
                    {b.markdown || JSON.stringify(b.kind)}
                  </div>
                  {b.provenance.reason && (
                    <div className="text-[11px] text-stone-400">
                      Reason: {b.provenance.reason} · Updated {b.provenance.updated_at}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* Raw YAML Frontmatter + Audit */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <section className="rounded-2xl border border-stone-200 bg-stone-950 text-stone-100 p-5 space-y-2">
          <div className="flex items-center gap-2 text-xs font-semibold text-stone-300">
            <Layers className="h-3.5 w-3.5 text-amber-400" />
            YAML + Anchored Source Projection
          </div>
          <pre className="text-[11px] font-mono leading-relaxed whitespace-pre-wrap max-h-72 overflow-y-auto text-stone-200">
            {yamlFrontmatter}
          </pre>
        </section>

        <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
          <div className="flex items-center gap-2 text-xs font-semibold text-stone-900">
            <Activity className="h-3.5 w-3.5 text-emerald-700" />
            Modb.Ledger Hash-Chained Page Audit ({pageAudit.length})
          </div>
          <div className="space-y-2 max-h-72 overflow-y-auto">
            {pageAudit.length === 0 ? (
              <p className="text-xs text-stone-400">No recent ledger entries filtered for {page.id}.</p>
            ) : (
              pageAudit.map((entry) => (
                <div
                  key={entry.seq}
                  className="rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs space-y-0.5"
                >
                  <div className="flex items-center justify-between text-[11px]">
                    <span className="font-mono font-semibold text-stone-800">{entry.action}</span>
                    <span className="font-mono text-stone-400">tx #{entry.txid}</span>
                  </div>
                  <div className="text-stone-700">{entry.summary}</div>
                  <div className="text-[11px] text-stone-400">
                    {entry.actor_name} · {entry.reason} · {entry.at ?? entry.created_at ?? ""}
                  </div>
                </div>
              ))
            )}
          </div>
        </section>
      </div>
    </div>
  );
}
