import { Link, router } from "@inertiajs/react";
import { Check, ChevronDown, ChevronRight, GitPullRequest, XCircle } from "lucide-react";
import { useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type { Collection, DatabaseDef, ProposalMeta } from "../../lib/types";

interface ProposalsPageProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  proposals: ProposalMeta[];
}

export default function ProposalsView({
  collections = [],
  databases = [],
  proposals: initialProposals = [],
}: ProposalsPageProps) {
  const [proposals, setProposals] = useState<ProposalMeta[]>(initialProposals);
  const [statusFilter, setStatusFilter] = useState<"all" | "open" | "accepted" | "rejected">(
    "all"
  );
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [diffs, setDiffs] = useState<Record<string, unknown>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const visible = proposals.filter((p) =>
    statusFilter === "all" ? true : p.status === statusFilter
  );

  async function toggleDiff(propId: string) {
    if (expandedId === propId) {
      setExpandedId(null);
      return;
    }
    setExpandedId(propId);
    if (diffs[propId]) return;
    setError(null);
    try {
      const res = await apiFetch<{ proposal: ProposalMeta; bucket_diffs: unknown }>(
        `/api/proposals/${propId}/diff`
      );
      setDiffs((prev) => ({ ...prev, [propId]: res.bucket_diffs }));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not load proposal diff");
    }
  }

  async function handleAccept(p: ProposalMeta) {
    setBusyId(p.id);
    setError(null);
    try {
      const res = await apiFetch<{ proposal: ProposalMeta }>(`/api/proposals/${p.id}/accept`, {
        method: "POST",
        body: JSON.stringify({ reason: `accepted '${p.title}' from Proposals Inbox` }),
      });
      setProposals((prev) => prev.map((x) => (x.id === p.id ? res.proposal : x)));
      router.reload({ only: ["proposals"] });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not accept proposal");
    } finally {
      setBusyId(null);
    }
  }

  async function handleReject(p: ProposalMeta) {
    setBusyId(p.id);
    setError(null);
    try {
      const res = await apiFetch<{ proposal?: ProposalMeta }>(`/api/proposals/${p.id}/reject`, {
        method: "POST",
        body: JSON.stringify({ reason: `rejected '${p.title}'` }),
      });
      const nextStatus = res.proposal?.status ?? "rejected";
      setProposals((prev) =>
        prev.map((x) => (x.id === p.id ? { ...x, status: nextStatus } : x))
      );
      router.reload({ only: ["proposals"] });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not reject proposal");
    } finally {
      setBusyId(null);
    }
  }

  return (
    <WorkspaceLayout title="Change Proposals" collections={collections} databases={databases}>
      <div className="space-y-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-stone-950">Change Proposals</h1>
            <p className="text-sm text-stone-500 mt-0.5">
              Speculative <code className="font-mono text-xs">Modb.World</code> branches staged by
              agents or team members with mandatory accountability reasons.
            </p>
          </div>
          <div className="inline-flex rounded-xl border border-stone-200 bg-white p-1 text-xs">
            {(["all", "open", "accepted", "rejected"] as const).map((tab) => (
              <button
                key={tab}
                type="button"
                onClick={() => setStatusFilter(tab)}
                className={`rounded-lg px-3 py-1.5 font-medium capitalize ${
                  statusFilter === tab ? "bg-stone-900 text-white" : "text-stone-600"
                }`}
              >
                {tab}
              </button>
            ))}
          </div>
        </div>

        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}

        <div className="space-y-3">
          {visible.length === 0 && (
            <div className="rounded-2xl border border-stone-200 bg-white p-8 text-center text-sm text-stone-500">
              No {statusFilter === "all" ? "" : statusFilter} proposals found.
            </div>
          )}

          {visible.map((p) => {
            const isExpanded = expandedId === p.id;
            return (
              <div
                key={p.id}
                className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3"
              >
                <div className="flex flex-wrap items-start justify-between gap-4">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <GitPullRequest className="h-4 w-4 text-teal-700" />
                      <span className="font-semibold text-base text-stone-950">{p.title}</span>
                      <span
                        className={`rounded-full px-2.5 py-0.5 text-[11px] font-medium ${
                          p.status === "open"
                            ? "bg-amber-100 text-amber-800"
                            : p.status === "accepted"
                              ? "bg-emerald-100 text-emerald-800"
                              : "bg-stone-100 text-stone-600"
                        }`}
                      >
                        {p.status}
                      </span>
                    </div>
                    <div className="text-xs text-stone-500 flex flex-wrap items-center gap-2">
                      <span>by {p.author_handle}</span>
                      <span>·</span>
                      <span className="font-mono">{p.id}</span>
                      <span>·</span>
                      <Link href={`/p/${p.target_page_id}`} className="text-blue-600 hover:underline">
                        Target Page →
                      </Link>
                    </div>
                    <div className="text-xs text-stone-700 bg-stone-50 rounded-lg px-3 py-1.5 border border-stone-100 inline-block">
                      Reason: {p.reason}
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => void toggleDiff(p.id)}
                      className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50"
                    >
                      {isExpanded ? (
                        <ChevronDown className="h-3.5 w-3.5" />
                      ) : (
                        <ChevronRight className="h-3.5 w-3.5" />
                      )}
                      Inspect Diff
                    </button>
                    {p.status === "open" && (
                      <>
                        <button
                          type="button"
                          disabled={busyId === p.id}
                          onClick={() => void handleAccept(p)}
                          className="inline-flex items-center gap-1 rounded-lg bg-emerald-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-800 disabled:opacity-50"
                        >
                          <Check className="h-3.5 w-3.5" />
                          Accept &amp; Land
                        </button>
                        <button
                          type="button"
                          disabled={busyId === p.id}
                          onClick={() => void handleReject(p)}
                          className="inline-flex items-center gap-1 rounded-lg border border-red-200 px-3 py-1.5 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
                        >
                          <XCircle className="h-3.5 w-3.5" />
                          Reject
                        </button>
                      </>
                    )}
                  </div>
                </div>

                {isExpanded && (
                  <div className="rounded-xl border border-stone-200 bg-stone-950 text-stone-100 p-4 overflow-x-auto">
                    <pre className="text-xs font-mono leading-relaxed">
                      {JSON.stringify(diffs[p.id] ?? "Loading diff...", null, 2)}
                    </pre>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </WorkspaceLayout>
  );
}
