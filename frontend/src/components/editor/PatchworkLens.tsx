import { Link } from "@inertiajs/react";
import { Check, GitBranch, GitPullRequest, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { ApiError, apiFetch } from "../../lib/api";
import type { Page, ProposalDiffResponse, ProposalMeta } from "../../lib/types";
import { formatNumberCell, formatSignedDecimal } from "../database/InlineCellEditor";

interface PatchworkLensProps {
  page: Page;
  proposals: ProposalMeta[];
  onResolved: () => void;
}

export default function PatchworkLens({ page, proposals, onResolved }: PatchworkLensProps) {
  const openProposals = useMemo(
    () => proposals.filter((p) => p.status === "open"),
    [proposals]
  );
  const [selectedId, setSelectedId] = useState<string>(openProposals[0]?.id ?? proposals[0]?.id ?? "");
  const [diff, setDiff] = useState<ProposalDiffResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [acting, setActing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const nextDefault = openProposals[0]?.id ?? proposals[0]?.id ?? "";
    if (!selectedId || !proposals.some((p) => p.id === selectedId)) {
      setSelectedId(nextDefault);
    }
  }, [proposals, openProposals, selectedId]);

  useEffect(() => {
    if (!selectedId) {
      setDiff(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    apiFetch<ProposalDiffResponse>(`/api/proposals/${selectedId}/diff`)
      .then((res) => {
        if (!cancelled) setDiff(res);
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof ApiError ? err.message : "Failed to load proposal diff");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selectedId]);

  async function handleDecision(action: "accept" | "reject") {
    if (!selectedId) return;
    setActing(true);
    setError(null);
    try {
      await apiFetch(`/api/proposals/${selectedId}/${action}`, {
        method: "POST",
        body: JSON.stringify({
          reason:
            action === "accept"
              ? `Merged proposal on page ${page.id} via Patchwork Lens`
              : `Rejected proposal on page ${page.id} via Patchwork Lens`,
        }),
      });
      onResolved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : `Failed to ${action} proposal`);
    } finally {
      setActing(false);
    }
  }

  if (proposals.length === 0) {
    return (
      <div className="rounded-2xl border border-stone-200 bg-white p-8 text-center space-y-2">
        <GitPullRequest className="h-6 w-6 text-stone-400 mx-auto" />
        <h3 className="text-sm font-semibold text-stone-900">Patchwork Review Queue Empty</h3>
        <p className="text-xs text-stone-500 max-w-md mx-auto">
          No speculative <code className="font-mono">Modb.World</code> Change Proposals target{" "}
          <strong>{page.title}</strong> yet. Use AI Draft in Studio Lens or invite a scoped agent to
          propose edits without touching live truth.
        </p>
      </div>
    );
  }

  const selectedProposal = proposals.find((p) => p.id === selectedId) ?? proposals[0];

  return (
    <div className="space-y-4">
      {/* Selector & Decision Header */}
      <div className="rounded-2xl border border-stone-200 bg-white p-4 flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2.5">
          <GitBranch className="h-4 w-4 text-teal-700" />
          <select
            value={selectedId}
            onChange={(e) => setSelectedId(e.target.value)}
            className="rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-xs font-medium text-stone-900"
          >
            {proposals.map((p) => (
              <option key={p.id} value={p.id}>
                [{p.status.toUpperCase()}] {p.title} ({p.author_handle})
              </option>
            ))}
          </select>
          <span className="rounded-full bg-stone-100 px-2.5 py-0.5 text-[11px] font-mono text-stone-600">
            {openProposals.length} open
          </span>
        </div>

        <div className="flex items-center gap-2">
          <Link
            href="/proposals"
            className="rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs font-medium text-stone-600 hover:bg-stone-50"
          >
            All Proposals →
          </Link>
          {selectedProposal?.status === "open" && (
            <>
              <button
                type="button"
                disabled={acting}
                onClick={() => void handleDecision("reject")}
                className="inline-flex items-center gap-1 rounded-lg border border-red-200 bg-white px-3 py-1.5 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
              >
                <X className="h-3.5 w-3.5" />
                Reject
              </button>
              <button
                type="button"
                disabled={acting}
                onClick={() => void handleDecision("accept")}
                className="inline-flex items-center gap-1 rounded-lg bg-emerald-700 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-emerald-800 disabled:opacity-50"
              >
                <Check className="h-3.5 w-3.5" />
                {acting ? "Merging..." : "Accept & Merge"}
              </button>
            </>
          )}
        </div>
      </div>

      {error && (
        <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-2.5 text-xs text-red-800">
          {error}
        </div>
      )}

      {/* Diff Stream */}
      <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
        {loading && <div className="text-xs text-stone-500">Materializing World branch diff...</div>}

        {diff && (
          <>
            <div className="text-xs text-stone-600">
              Reason: <strong className="text-stone-900">{diff.proposal.reason}</strong> · Proposed by{" "}
              <span className="font-mono">{diff.proposal.author_handle}</span>
            </div>

            {diff.rollup_deltas && diff.rollup_deltas.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {diff.rollup_deltas.map((d) => (
                  <div
                    key={`${d.database_id}-${d.prop_id}`}
                    className="rounded-lg border border-indigo-200 bg-indigo-50/70 px-3 py-1.5 text-xs flex items-center gap-2"
                  >
                    <span className="font-medium text-indigo-900">{d.prop_name}:</span>
                    <span className="font-mono text-stone-600">
                      {formatNumberCell(d.live_total, d.format)} →{" "}
                      {formatNumberCell(d.scenario_total, d.format)}
                    </span>
                    <span className="font-mono font-semibold text-indigo-800">
                      ({formatSignedDecimal(d.delta, d.format)})
                    </span>
                  </div>
                ))}
              </div>
            )}

            <div className="space-y-3">
              {(diff.block_diffs ?? []).length === 0 ? (
                <p className="text-xs text-stone-500">
                  This proposal contains workspace or database changes outside page text blocks.
                </p>
              ) : (
                (diff.block_diffs ?? []).map((bd) => (
                  <div
                    key={bd.block_id}
                    className="rounded-xl border border-stone-200 overflow-hidden text-xs"
                  >
                    <div className="flex items-center justify-between bg-stone-50 px-3 py-1.5 border-b border-stone-200">
                      <span className="font-mono text-stone-600">{bd.block_id}</span>
                      <span
                        className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase ${
                          bd.change === "added"
                            ? "bg-emerald-100 text-emerald-800"
                            : bd.change === "removed"
                              ? "bg-rose-100 text-rose-800"
                              : "bg-amber-100 text-amber-800"
                        }`}
                      >
                        {bd.change}
                      </span>
                    </div>
                    <div className="divide-y divide-stone-100">
                      {bd.before_markdown !== null && (
                        <div className="bg-rose-50/70 px-3.5 py-2 font-mono text-rose-900 whitespace-pre-wrap">
                          - {bd.before_markdown}
                        </div>
                      )}
                      {bd.after_markdown !== null && (
                        <div className="bg-emerald-50/70 px-3.5 py-2 font-mono text-emerald-900 whitespace-pre-wrap">
                          + {bd.after_markdown}
                        </div>
                      )}
                    </div>
                  </div>
                ))
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
