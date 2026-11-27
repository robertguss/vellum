import { Link } from "@inertiajs/react";
import {
  Bot,
  Check,
  CheckCircle2,
  GitBranch,
  GitPullRequest,
  MessageSquare,
  RotateCcw,
  Send,
  Sparkles,
  User,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  Page,
  ProposalComment,
  ProposalDiffResponse,
  ProposalMeta,
  SteerProposalResponse,
} from "../../lib/types";
import { computeWordDiff, formatDiffMagnitude } from "../../lib/wordDiff";
import {
  formatNumberCell,
  formatSignedDecimal,
  renderCellDisplay,
} from "../database/InlineCellEditor";

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
  const [rawDiffMode, setRawDiffMode] = useState(false);
  const [rejectingId, setRejectingId] = useState<string | null>(null);
  const [steeringBlockId, setSteeringBlockId] = useState<string | null>(null);
  const [steerInstruction, setSteerInstruction] = useState("");
  const [steering, setSteering] = useState(false);
  const [commentTargetBlockId, setCommentTargetBlockId] = useState<string | null>(null);
  const [blockCommentText, setBlockCommentText] = useState("");
  const [proposalCommentText, setProposalCommentText] = useState("");
  const [postingComment, setPostingComment] = useState(false);
  const [resolvingId, setResolvingId] = useState<string | null>(null);

  useEffect(() => {
    const nextDefault = openProposals[0]?.id ?? proposals[0]?.id ?? "";
    if (!selectedId || !proposals.some((p) => p.id === selectedId)) {
      setSelectedId(nextDefault);
    }
  }, [proposals, openProposals, selectedId]);

  const reloadDiff = useCallback(async () => {
    if (!selectedId) {
      setDiff(null);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const res = await apiFetch<ProposalDiffResponse>(`/api/proposals/${selectedId}/diff`);
      setDiff(res);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load proposal diff");
    } finally {
      setLoading(false);
    }
  }, [selectedId]);

  useEffect(() => {
    void reloadDiff();
  }, [reloadDiff]);

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

  async function handleRejectHunk(
    targetKind: "block" | "db_row",
    targetId: string,
    pageId?: string,
    databaseId?: string
  ) {
    if (!selectedId) return;
    setRejectingId(targetId);
    setError(null);
    try {
      await apiFetch(`/api/proposals/${selectedId}/hunks/reject`, {
        method: "POST",
        body: JSON.stringify({
          target_kind: targetKind,
          target_id: targetId,
          page_id: pageId ?? null,
          database_id: databaseId ?? null,
          reason: `Rejected ${targetKind} hunk ${targetId} in Patchwork Lens`,
        }),
      });
      await reloadDiff();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to reject hunk");
    } finally {
      setRejectingId(null);
    }
  }

  async function handleSteerBlock(blockId: string, pageId?: string) {
    if (!selectedId || !steerInstruction.trim()) return;
    setSteering(true);
    setError(null);
    try {
      await apiFetch<SteerProposalResponse>(`/api/proposals/${selectedId}/steer`, {
        method: "POST",
        body: JSON.stringify({
          target_block_id: blockId,
          target_page_id: pageId ?? null,
          instruction: steerInstruction.trim(),
          deterministic_fallback: false,
        }),
      });
      setSteerInstruction("");
      setSteeringBlockId(null);
      await reloadDiff();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Steer-in-Place failed");
    } finally {
      setSteering(false);
    }
  }

  async function handlePostComment(targetKind: "proposal" | "block", targetRef: string | null) {
    if (!selectedId) return;
    const body = (targetKind === "block" ? blockCommentText : proposalCommentText).trim();
    if (!body) return;
    setPostingComment(true);
    setError(null);
    try {
      await apiFetch(`/api/proposals/${selectedId}/comments`, {
        method: "POST",
        body: JSON.stringify({
          target_kind: targetKind,
          target_ref: targetRef,
          parent_comment_id: null,
          body_markdown: body,
          steer_requested: false,
        }),
      });
      if (targetKind === "block") {
        setBlockCommentText("");
        setCommentTargetBlockId(null);
      } else {
        setProposalCommentText("");
      }
      await reloadDiff();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to post proposal comment");
    } finally {
      setPostingComment(false);
    }
  }

  async function handleResolveComment(cmt: ProposalComment) {
    if (!selectedId) return;
    setResolvingId(cmt.id);
    setError(null);
    try {
      await apiFetch(`/api/proposals/${selectedId}/comments/${cmt.id}/resolve`, {
        method: "POST",
        body: JSON.stringify({ resolved: cmt.resolved_at === null }),
      });
      await reloadDiff();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update comment status");
    } finally {
      setResolvingId(null);
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
  const isOpen = selectedProposal?.status === "open";
  const allComments = diff?.comments ?? [];
  const proposalLevelComments = allComments.filter((c) => c.target_kind === "proposal");

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
          {isOpen && (
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
        {loading && !diff && (
          <div className="text-xs text-stone-500">Materializing World branch diff...</div>
        )}

        {diff && (
          <>
            <div className="flex flex-wrap items-center justify-between gap-3 border-b border-stone-100 pb-3">
              <div className="space-y-1">
                <div className="text-xs text-stone-600">
                  Reason: <strong className="text-stone-900">{diff.proposal.reason}</strong> · Proposed
                  by <span className="font-mono">{diff.proposal.author_handle}</span>
                </div>
                <div className="inline-flex items-center gap-1.5 rounded-full bg-stone-100 px-2.5 py-0.5 text-[11px] font-medium text-stone-700">
                  <span>{formatDiffMagnitude(diff)}</span>
                </div>
              </div>
              <button
                type="button"
                onClick={() => setRawDiffMode((v) => !v)}
                className="rounded-lg border border-stone-200 bg-stone-50 px-2.5 py-1 text-[11px] font-medium text-stone-700 hover:bg-stone-100"
              >
                {rawDiffMode ? "Word Diff View" : "Raw Line View"}
              </button>
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

            {(diff.db_row_diffs ?? []).length > 0 && (
              <div className="space-y-2">
                {(diff.db_row_diffs ?? []).map((rd) => (
                  <div
                    key={`${rd.database_id}-${rd.row_id}`}
                    className="rounded-xl border border-stone-200 overflow-hidden text-xs"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2 bg-stone-50 px-3 py-1.5 border-b border-stone-200">
                      <div className="flex items-center gap-2">
                        <span className="font-semibold text-stone-900">{rd.row_title}</span>
                        <span className="font-mono text-stone-500">{rd.row_id}</span>
                        <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold uppercase text-amber-800">
                          {rd.change}
                        </span>
                      </div>
                      {isOpen && rd.change !== "removed" && (
                        <button
                          type="button"
                          disabled={rejectingId === rd.row_id}
                          onClick={() =>
                            void handleRejectHunk("db_row", rd.row_id, undefined, rd.database_id)
                          }
                          className="inline-flex items-center gap-1 rounded border border-red-200 bg-white px-2 py-0.5 text-[11px] font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
                        >
                          <RotateCcw className="h-3 w-3" />
                          Reject Row Hunk
                        </button>
                      )}
                    </div>
                    <div className="divide-y divide-stone-100">
                      {rd.cell_diffs.map((cd) => (
                        <div key={cd.prop_id} className="px-3 py-1.5 flex items-center gap-2">
                          <span className="font-medium text-stone-700 min-w-[100px]">
                            {cd.prop_name}
                          </span>
                          <span className="rounded bg-rose-50 px-1.5 py-0.5 font-mono text-rose-800 line-through">
                            {renderCellDisplay(cd.before)}
                          </span>
                          <span>→</span>
                          <span className="rounded bg-emerald-50 px-1.5 py-0.5 font-mono text-emerald-800">
                            {renderCellDisplay(cd.after)}
                          </span>
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            )}

            <div className="space-y-3">
              {(diff.block_diffs ?? []).length === 0 ? (
                <p className="text-xs text-stone-500">
                  No block-level markdown edits recorded in this branch.
                </p>
              ) : (
                (diff.block_diffs ?? []).map((bd) => {
                  const wd = computeWordDiff(bd.before_markdown, bd.after_markdown);
                  const blockComments = allComments.filter(
                    (c) => c.target_kind === "block" && c.target_ref === bd.block_id
                  );
                  return (
                    <div
                      key={bd.block_id}
                      className="rounded-xl border border-stone-200 overflow-hidden text-xs"
                    >
                      <div className="flex flex-wrap items-center justify-between gap-2 bg-stone-50 px-3 py-2 border-b border-stone-200">
                        <div className="flex items-center gap-2">
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
                          <span className="font-mono text-[10px] text-stone-500">
                            +{wd.addedWords} / -{wd.removedWords}w
                          </span>
                        </div>

                        {isOpen && (
                          <div className="flex items-center gap-1.5">
                            {bd.change !== "removed" && (
                              <button
                                type="button"
                                onClick={() => {
                                  setSteeringBlockId((cur) =>
                                    cur === bd.block_id ? null : bd.block_id
                                  );
                                  setCommentTargetBlockId(null);
                                }}
                                className="inline-flex items-center gap-1 rounded border border-violet-200 bg-violet-50 px-2 py-1 text-[11px] font-medium text-violet-700 hover:bg-violet-100"
                              >
                                <Sparkles className="h-3 w-3" />
                                Steer AI
                              </button>
                            )}
                            <button
                              type="button"
                              onClick={() => {
                                setCommentTargetBlockId((cur) =>
                                  cur === bd.block_id ? null : bd.block_id
                                );
                                setSteeringBlockId(null);
                              }}
                              className="inline-flex items-center gap-1 rounded border border-stone-200 bg-white px-2 py-1 text-[11px] font-medium text-stone-700 hover:bg-stone-100"
                            >
                              <MessageSquare className="h-3 w-3" />
                              Note ({blockComments.length})
                            </button>
                            <button
                              type="button"
                              disabled={rejectingId === bd.block_id}
                              onClick={() =>
                                void handleRejectHunk("block", bd.block_id, bd.page_id ?? page.id)
                              }
                              className="inline-flex items-center gap-1 rounded border border-red-200 bg-white px-2 py-1 text-[11px] font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
                            >
                              <RotateCcw className="h-3 w-3" />
                              {rejectingId === bd.block_id ? "Reverting..." : "Reject Hunk"}
                            </button>
                          </div>
                        )}
                      </div>

                      {rawDiffMode ? (
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
                      ) : (
                        <div className="bg-white px-4 py-3 text-sm leading-relaxed">
                          {wd.tokens.map((tok, i) =>
                            tok.kind === "equal" ? (
                              <span key={i} className="whitespace-pre-wrap text-stone-800">
                                {tok.text}
                              </span>
                            ) : tok.kind === "added" ? (
                              <span
                                key={i}
                                className="whitespace-pre-wrap rounded bg-emerald-100/90 px-0.5 text-emerald-950"
                              >
                                {tok.text}
                              </span>
                            ) : (
                              <span
                                key={i}
                                className="whitespace-pre-wrap rounded bg-rose-100/80 px-0.5 text-rose-800 line-through"
                              >
                                {tok.text}
                              </span>
                            )
                          )}
                        </div>
                      )}

                      {steeringBlockId === bd.block_id && (
                        <div className="border-t border-violet-100 bg-violet-50/60 px-3.5 py-2.5 flex items-center gap-2">
                          <input
                            value={steerInstruction}
                            onChange={(e) => setSteerInstruction(e.target.value)}
                            placeholder="Steer AI revision in-place (e.g. tighten wording and cite P99 SLO)..."
                            className="flex-1 rounded-lg border border-violet-200 bg-white px-2.5 py-1.5 text-xs outline-none focus:border-violet-400"
                          />
                          <button
                            type="button"
                            disabled={steering || !steerInstruction.trim()}
                            onClick={() => void handleSteerBlock(bd.block_id, bd.page_id)}
                            className="inline-flex items-center gap-1 rounded-lg bg-violet-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-violet-800 disabled:opacity-50"
                          >
                            <Sparkles className="h-3 w-3" />
                            {steering ? "Steering..." : "Revise In-Place"}
                          </button>
                        </div>
                      )}

                      {commentTargetBlockId === bd.block_id && (
                        <div className="border-t border-stone-100 bg-stone-50 px-3.5 py-2.5 flex items-center gap-2">
                          <input
                            value={blockCommentText}
                            onChange={(e) => setBlockCommentText(e.target.value)}
                            placeholder="Leave an anchored review note on this block..."
                            className="flex-1 rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs outline-none focus:border-stone-400"
                          />
                          <button
                            type="button"
                            disabled={postingComment || !blockCommentText.trim()}
                            onClick={() => void handlePostComment("block", bd.block_id)}
                            className="inline-flex items-center gap-1 rounded-lg bg-stone-900 px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50"
                          >
                            <Send className="h-3 w-3" />
                            Post
                          </button>
                        </div>
                      )}

                      {blockComments.length > 0 && (
                        <div className="border-t border-stone-100 bg-stone-50/60 px-3.5 py-2 space-y-1.5">
                          {blockComments.map((cmt) => {
                            const isAgent = typeof cmt.author_kind === "object";
                            return (
                              <div
                                key={cmt.id}
                                className={`rounded-lg border px-2.5 py-1.5 flex items-start justify-between gap-2 ${
                                  cmt.resolved_at
                                    ? "border-stone-200 bg-stone-100/70 opacity-75"
                                    : "border-stone-200 bg-white"
                                }`}
                              >
                                <div className="space-y-0.5">
                                  <div className="flex items-center gap-1.5 text-[11px] text-stone-500">
                                    {isAgent ? (
                                      <Bot className="h-3 w-3 text-violet-600" />
                                    ) : (
                                      <User className="h-3 w-3 text-stone-500" />
                                    )}
                                    <span className="font-mono font-medium text-stone-700">
                                      {cmt.author_handle}
                                    </span>
                                    {cmt.steer_requested && (
                                      <span className="rounded-full bg-violet-100 px-1.5 py-0 text-[10px] font-medium text-violet-800">
                                        Steer
                                      </span>
                                    )}
                                    {cmt.resolved_at && (
                                      <span className="inline-flex items-center gap-0.5 text-[10px] text-emerald-700">
                                        <CheckCircle2 className="h-2.5 w-2.5" />
                                        Resolved
                                      </span>
                                    )}
                                  </div>
                                  <p className="text-xs text-stone-800">{cmt.body_markdown}</p>
                                </div>
                                <button
                                  type="button"
                                  disabled={resolvingId === cmt.id}
                                  onClick={() => void handleResolveComment(cmt)}
                                  className="shrink-0 text-[11px] font-medium text-stone-500 hover:text-stone-900"
                                >
                                  {cmt.resolved_at ? "Reopen" : "Resolve"}
                                </button>
                              </div>
                            );
                          })}
                        </div>
                      )}
                    </div>
                  );
                })
              )}
            </div>

            {/* Proposal-level Review Comments */}
            <div className="rounded-xl border border-stone-200 bg-stone-50/60 p-3.5 space-y-2.5">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-stone-800">
                <MessageSquare className="h-3.5 w-3.5 text-stone-500" />
                Branch Review Notes ({proposalLevelComments.length})
              </div>
              {proposalLevelComments.length > 0 && (
                <div className="space-y-1.5">
                  {proposalLevelComments.map((cmt) => (
                    <div
                      key={cmt.id}
                      className="rounded-lg border border-stone-200 bg-white px-3 py-2 flex items-start justify-between gap-2 text-xs"
                    >
                      <div className="space-y-0.5">
                        <div className="flex items-center gap-1.5 text-[11px] text-stone-500">
                          <span className="font-mono font-medium text-stone-700">
                            {cmt.author_handle}
                          </span>
                          {cmt.resolved_at && (
                            <span className="text-emerald-700 font-medium">Resolved</span>
                          )}
                        </div>
                        <p className="text-stone-800">{cmt.body_markdown}</p>
                      </div>
                      <button
                        type="button"
                        disabled={resolvingId === cmt.id}
                        onClick={() => void handleResolveComment(cmt)}
                        className="shrink-0 text-[11px] font-medium text-stone-500 hover:text-stone-900"
                      >
                        {cmt.resolved_at ? "Reopen" : "Resolve"}
                      </button>
                    </div>
                  ))}
                </div>
              )}
              <div className="flex items-center gap-2">
                <input
                  value={proposalCommentText}
                  onChange={(e) => setProposalCommentText(e.target.value)}
                  placeholder="Add branch-level review note..."
                  className="flex-1 rounded-lg border border-stone-200 bg-white px-3 py-1.5 text-xs outline-none focus:border-stone-400"
                />
                <button
                  type="button"
                  disabled={postingComment || !proposalCommentText.trim()}
                  onClick={() => void handlePostComment("proposal", null)}
                  className="inline-flex items-center gap-1 rounded-lg bg-stone-900 px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50"
                >
                  <Send className="h-3 w-3" />
                  Comment
                </button>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
