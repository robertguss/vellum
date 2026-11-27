import { Activity, Bot, Calculator, Layers, Shield, User } from "lucide-react";
import type { AuditFeedItem, Block, Page, ResolvedMetric } from "../../lib/types";
import { formatNumberCell, formatSignedDecimal } from "../database/InlineCellEditor";

interface XRayLensProps {
  page: Page;
  blocks: Block[];
  resolvedMetrics: Record<string, ResolvedMetric>;
  yamlFrontmatter: string;
  pageAudit: AuditFeedItem[];
  onInspectBlock: (blockId: string) => void;
}

export default function XRayLens({
  page,
  blocks,
  resolvedMetrics,
  yamlFrontmatter,
  pageAudit,
  onInspectBlock,
}: XRayLensProps) {
  const metricEntries = Object.values(resolvedMetrics);

  return (
    <div className="space-y-6">
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
        <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
          <Shield className="h-4 w-4 text-blue-700" />
          Canonical Block Provenance Tree ({blocks.length} blocks)
        </div>
        <div className="divide-y divide-stone-100">
          {blocks.map((b) => {
            const isHuman = b.provenance.author_kind === "human_author";
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
