import { Link, router } from "@inertiajs/react";
import {
  ArrowRight,
  Check,
  ChevronDown,
  ChevronRight,
  Database,
  GitBranch,
  GitPullRequest,
  XCircle,
} from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import {
  formatNumberCell,
  formatSignedDecimal,
  renderCellDisplay,
} from "../../components/database/InlineCellEditor";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  BlockDiffEntry,
  BlockKind,
  Collection,
  DatabaseDef,
  DbRowDiffEntry,
  DbSchemaDiffEntry,
  DecimalDelta,
  PropertyKind,
  ProposalDiffResponse,
  ProposalMeta,
} from "../../lib/types";

interface ProposalsPageProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  proposals: ProposalMeta[];
}

function formatBlockKind(kind: BlockKind | null): string {
  if (!kind) return "None";
  if (typeof kind === "string") {
    if (kind === "paragraph") return "Paragraph";
    if (kind === "bullet_list_item") return "Bullet";
    if (kind === "quote") return "Quote";
    if (kind === "divider") return "Divider";
    return kind;
  }
  if ("heading" in kind) return `H${kind.heading.level}`;
  if ("ordered_list_item" in kind) return `List (${kind.ordered_list_item.start}.)`;
  if ("task_item" in kind) return kind.task_item.checked ? "Task [x]" : "Task [ ]";
  if ("callout" in kind) return `Callout (${kind.callout.tone})`;
  if ("code_block" in kind) return `Code (${kind.code_block.language || "text"})`;
  if ("image" in kind) return "Image";
  if ("file_embed" in kind) return "File";
  if ("page_link" in kind) return "Page Link";
  if ("database_view_embed" in kind) return "DB Embed";
  if ("ai_brief" in kind) return "AI Brief";
  return "Block";
}

function formatPropertyKind(kind: PropertyKind | null): string {
  if (!kind) return "None";
  if (typeof kind === "string") return kind;
  if ("number" in kind) return `number(${kind.number.format})`;
  if ("date_prop" in kind) return "date";
  if ("select" in kind) return `select(${kind.select.options.length} opts)`;
  if ("multi_select" in kind) return `multi_select(${kind.multi_select.options.length} opts)`;
  if ("relation" in kind) return `relation(${kind.relation.target_db_id})`;
  if ("rollup" in kind) return `rollup(${kind.rollup.agg})`;
  return "property";
}

function splitDiffLines(markdown: string | null): string[] {
  if (markdown === null) return [];
  if (markdown === "") return [""];
  return markdown.split("\n");
}

function BlockDiffCard({ entry }: { entry: BlockDiffEntry }) {
  const beforeLines = splitDiffLines(entry.before_markdown);
  const afterLines = splitDiffLines(entry.after_markdown);
  const badgeClasses =
    entry.change === "added"
      ? "bg-emerald-100 text-emerald-800 border-emerald-200"
      : entry.change === "removed"
        ? "bg-red-100 text-red-800 border-red-200"
        : "bg-amber-100 text-amber-800 border-amber-200";
  const kindLabel =
    entry.before_kind && entry.after_kind
      ? JSON.stringify(entry.before_kind) === JSON.stringify(entry.after_kind)
        ? formatBlockKind(entry.after_kind)
        : `${formatBlockKind(entry.before_kind)} → ${formatBlockKind(entry.after_kind)}`
      : formatBlockKind(entry.after_kind ?? entry.before_kind);

  return (
    <div className="rounded-xl border border-stone-200 bg-white overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-stone-200 bg-stone-50 px-3.5 py-2 text-xs">
        <div className="flex items-center gap-2">
          <span
            className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${badgeClasses}`}
          >
            {entry.change}
          </span>
          {entry.page_title && (
            <span className="font-medium text-stone-800">{entry.page_title} ·</span>
          )}
          <span className="font-mono text-stone-700">{entry.block_id}</span>
        </div>
        <span className="rounded bg-stone-200/70 px-2 py-0.5 font-mono text-[11px] text-stone-700">
          {kindLabel}
        </span>
      </div>
      <div className="divide-y divide-stone-100 font-mono text-xs leading-relaxed">
        {entry.before_markdown !== null && (
          <div className="bg-red-50/75 text-red-950 px-3.5 py-2 space-y-0.5">
            {beforeLines.map((line, i) => (
              <div key={i} className="flex gap-2 whitespace-pre-wrap break-words">
                <span className="select-none text-red-500 font-semibold shrink-0">-</span>
                <span>{line || " "}</span>
              </div>
            ))}
          </div>
        )}
        {entry.after_markdown !== null && (
          <div className="bg-emerald-50/75 text-emerald-950 px-3.5 py-2 space-y-0.5">
            {afterLines.map((line, i) => (
              <div key={i} className="flex gap-2 whitespace-pre-wrap break-words">
                <span className="select-none text-emerald-600 font-semibold shrink-0">+</span>
                <span>{line || " "}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function DbRowDiffCard({ entry }: { entry: DbRowDiffEntry }) {
  const badgeClasses =
    entry.change === "added"
      ? "bg-emerald-100 text-emerald-800 border-emerald-200"
      : entry.change === "removed"
        ? "bg-red-100 text-red-800 border-red-200"
        : "bg-amber-100 text-amber-800 border-amber-200";
  return (
    <div className="rounded-xl border border-stone-200 bg-white overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-stone-200 bg-stone-50 px-3.5 py-2 text-xs">
        <div className="flex items-center gap-2">
          <span
            className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${badgeClasses}`}
          >
            {entry.change}
          </span>
          <span className="font-semibold text-stone-900">{entry.row_title}</span>
          <span className="font-mono text-[11px] text-stone-500">({entry.row_id})</span>
        </div>
        <span className="text-[11px] text-stone-500">{entry.database_title}</span>
      </div>
      <div className="divide-y divide-stone-100 text-xs">
        {entry.cell_diffs.map((cd) => (
          <div key={cd.prop_id} className="px-3.5 py-2 flex flex-wrap items-center gap-2">
            <span className="font-medium text-stone-700 min-w-[110px]">{cd.prop_name}</span>
            <span className="rounded bg-red-50 px-2 py-0.5 font-mono text-red-800 line-through">
              {renderCellDisplay(cd.before)}
            </span>
            <ArrowRight className="h-3 w-3 text-stone-400" />
            <span className="rounded bg-emerald-50 px-2 py-0.5 font-mono text-emerald-800 font-medium">
              {renderCellDisplay(cd.after)}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

function DbSchemaDiffCard({ entry }: { entry: DbSchemaDiffEntry }) {
  const badgeClasses =
    entry.change === "added"
      ? "bg-emerald-100 text-emerald-800 border-emerald-200"
      : entry.change === "removed"
        ? "bg-red-100 text-red-800 border-red-200"
        : "bg-amber-100 text-amber-800 border-amber-200";
  return (
    <div className="rounded-xl border border-stone-200 bg-white px-3.5 py-2.5 flex flex-wrap items-center justify-between gap-2 text-xs">
      <div className="flex items-center gap-2">
        <span
          className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase ${badgeClasses}`}
        >
          {entry.change}
        </span>
        <span className="font-medium text-stone-900">{entry.prop_name}</span>
        <span className="font-mono text-stone-500">{entry.prop_id}</span>
      </div>
      <div className="font-mono text-[11px] text-stone-600">
        {formatPropertyKind(entry.before_kind)} → {formatPropertyKind(entry.after_kind)}
      </div>
    </div>
  );
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
  const [diffs, setDiffs] = useState<Record<string, ProposalDiffResponse>>({});
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
      const res = await apiFetch<ProposalDiffResponse>(`/api/proposals/${propId}/diff`);
      setDiffs((prev) => ({ ...prev, [propId]: res }));
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

  useEffect(() => {
    setProposals(initialProposals);
  }, [initialProposals]);

  const handleRealtimeEvent = useCallback((eventName: string) => {
    if (
      eventName === "proposal.opened" ||
      eventName === "proposal.updated" ||
      eventName === "proposal.accepted" ||
      eventName === "proposal.rejected" ||
      eventName === "resync_required"
    ) {
      router.reload({ only: ["proposals"] });
    }
  }, []);

  return (
    <WorkspaceLayout
      title="Change Proposals"
      collections={collections}
      databases={databases}
      onRealtimeEvent={handleRealtimeEvent}
    >
      <div className="space-y-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-stone-950">Change Proposals</h1>
            <p className="text-sm text-stone-500 mt-0.5">
              Speculative <code className="font-mono text-xs">Modb.World</code> branches &amp;
              What-If Scenarios across pages and databases with mandatory audit reasons.
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
            const isScenario = p.branch_kind === "scenario";
            const d = diffs[p.id];
            const blockDiffs = d?.block_diffs ?? [];
            const rowDiffs = d?.db_row_diffs ?? [];
            const schemaDiffs = d?.db_schema_diffs ?? [];
            const rollupDeltas: DecimalDelta[] = d?.rollup_deltas ?? [];

            return (
              <div
                key={p.id}
                className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3"
              >
                <div className="flex flex-wrap items-start justify-between gap-4">
                  <div className="space-y-1">
                    <div className="flex flex-wrap items-center gap-2">
                      {isScenario ? (
                        <GitBranch className="h-4 w-4 text-indigo-600" />
                      ) : (
                        <GitPullRequest className="h-4 w-4 text-teal-700" />
                      )}
                      <span className="font-semibold text-base text-stone-950">{p.title}</span>
                      <span
                        className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase ${
                          isScenario
                            ? "bg-indigo-100 text-indigo-800"
                            : "bg-teal-100 text-teal-800"
                        }`}
                      >
                        {isScenario ? "Scenario" : "Proposal"}
                      </span>
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
                      {p.target_database_id ? (
                        <Link
                          href={`/d/${p.target_database_id}`}
                          className="inline-flex items-center gap-1 text-indigo-600 hover:underline font-medium"
                        >
                          <Database className="h-3 w-3" />
                          Target Database →
                        </Link>
                      ) : (
                        <Link href={`/p/${p.target_page_id}`} className="text-blue-600 hover:underline">
                          Target Page →
                        </Link>
                      )}
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
                  <div className="space-y-3 pt-1">
                    {!d ? (
                      <div className="rounded-xl border border-stone-200 bg-stone-50 p-4 text-xs text-stone-500">
                        Loading diff...
                      </div>
                    ) : (
                      <>
                        {rollupDeltas.length > 0 && (
                          <div className="rounded-xl border border-indigo-200 bg-indigo-50/70 p-3 flex flex-wrap gap-2.5 text-xs">
                            {rollupDeltas.map((dd) => (
                              <div
                                key={`${dd.database_id}-${dd.prop_id}`}
                                className="rounded-lg border border-indigo-100 bg-white px-2.5 py-1.5 flex items-center gap-2"
                              >
                                <span className="font-medium text-stone-700">{dd.prop_name}</span>
                                <span className="font-mono text-stone-500">
                                  {formatNumberCell(dd.live_total, dd.format)}
                                </span>
                                <ArrowRight className="h-3 w-3 text-stone-400" />
                                <span className="font-mono font-semibold text-stone-950">
                                  {formatNumberCell(dd.scenario_total, dd.format)}
                                </span>
                                <span
                                  className={`rounded-full px-1.5 py-0.5 font-mono text-[10px] font-semibold ${
                                    !dd.changed
                                      ? "bg-stone-100 text-stone-600"
                                      : dd.delta.startsWith("-")
                                        ? "bg-rose-100 text-rose-800"
                                        : "bg-emerald-100 text-emerald-800"
                                  }`}
                                >
                                  {formatSignedDecimal(dd.delta, dd.format)}
                                </span>
                              </div>
                            ))}
                          </div>
                        )}

                        {schemaDiffs.length > 0 && (
                          <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-3.5 space-y-2">
                            <div className="text-xs font-semibold text-stone-800">
                              Database Schema Changes ({schemaDiffs.length})
                            </div>
                            <div className="space-y-1.5">
                              {schemaDiffs.map((sd, i) => (
                                <DbSchemaDiffCard key={`${sd.prop_id}-${i}`} entry={sd} />
                              ))}
                            </div>
                          </div>
                        )}

                        {rowDiffs.length > 0 && (
                          <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-3.5 space-y-2.5">
                            <div className="flex items-center justify-between text-xs">
                              <span className="font-semibold text-stone-800">
                                Database Row Changes ({rowDiffs.length})
                              </span>
                            </div>
                            <div className="space-y-2">
                              {rowDiffs.map((rd) => (
                                <DbRowDiffCard key={`${rd.database_id}-${rd.row_id}`} entry={rd} />
                              ))}
                            </div>
                          </div>
                        )}

                        <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-3.5 space-y-2.5">
                          <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
                            <span className="font-semibold text-stone-800">
                              Proposed Content Diff
                              {d.page_title ? ` — ${d.page_title}` : ""}
                            </span>
                            <span className="text-stone-500">
                              {blockDiffs.length}{" "}
                              {blockDiffs.length === 1 ? "block" : "blocks"} changed
                            </span>
                          </div>
                          {blockDiffs.length === 0 ? (
                            <div className="text-xs text-stone-500 italic">
                              No block-level markdown edits recorded in this branch yet.
                            </div>
                          ) : (
                            <div className="space-y-2.5">
                              {blockDiffs.map((bd) => (
                                <BlockDiffCard key={`${bd.page_id ?? ""}-${bd.block_id}`} entry={bd} />
                              ))}
                            </div>
                          )}
                        </div>

                        <details className="rounded-xl border border-stone-200 bg-stone-950 text-stone-100">
                          <summary className="cursor-pointer select-none px-4 py-2.5 text-xs font-medium text-stone-300 hover:text-white">
                            Raw MoDB Bucket Diff ({d.bucket_diffs.length}{" "}
                            {d.bucket_diffs.length === 1 ? "bucket" : "buckets"})
                          </summary>
                          <div className="border-t border-stone-800 p-4 overflow-x-auto">
                            <pre className="text-xs font-mono leading-relaxed">
                              {JSON.stringify(d.bucket_diffs, null, 2)}
                            </pre>
                          </div>
                        </details>
                      </>
                    )}
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
