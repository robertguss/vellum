import { Link } from "@inertiajs/react";
import { ArrowUpRight, Bot, Database as DbIcon, FileText, MessageSquare, User, X } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  Block,
  BlockContextResponse,
  CellValue,
  DatabaseDef,
  DbViewDef,
  EnrichedRow,
  PrincipalSummary,
  RelationTargetOption,
} from "../../lib/types";
import InlineCellEditor, { getRowTitle } from "../database/InlineCellEditor";

export type InspectorTarget =
  | { kind: "block"; blockId: string }
  | { kind: "row"; databaseId: string; rowId: string; pageId: string }
  | null;

interface SlideOverInspectorProps {
  target: InspectorTarget;
  databases: DatabaseDef[];
  principals: PrincipalSummary[];
  relationTargets: Record<string, RelationTargetOption[]>;
  onClose: () => void;
  onRowUpdated?: () => void;
}

interface RowBundle {
  database: DatabaseDef;
  row: EnrichedRow;
  blocks: Block[];
  principals: PrincipalSummary[];
  relationTargets: Record<string, RelationTargetOption[]>;
}

export default function SlideOverInspector({
  target,
  databases,
  principals,
  relationTargets,
  onClose,
  onRowUpdated,
}: SlideOverInspectorProps) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [blockCtx, setBlockCtx] = useState<BlockContextResponse | null>(null);
  const [rowBundle, setRowBundle] = useState<RowBundle | null>(null);

  useEffect(() => {
    if (!target) return;
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [target, onClose]);

  const loadTarget = useCallback(async () => {
    if (!target) return;
    setLoading(true);
    setError(null);
    try {
      if (target.kind === "block") {
        setRowBundle(null);
        const ctx = await apiFetch<BlockContextResponse>(`/api/blocks/${target.blockId}`);
        setBlockCtx(ctx);
      } else {
        setBlockCtx(null);
        const [dbShow, pgShow] = await Promise.all([
          apiFetch<{
            database: DatabaseDef;
            views: DbViewDef[];
            rows: EnrichedRow[];
            principals: PrincipalSummary[];
            relation_targets: Record<string, RelationTargetOption[]>;
          }>(`/api/databases/${target.databaseId}`),
          apiFetch<{ blocks: Block[] }>(`/api/pages/${target.pageId}`),
        ]);
        const found = dbShow.rows.find((r) => r.row.id === target.rowId);
        if (!found) {
          throw new Error(`Row '${target.rowId}' not found`);
        }
        setRowBundle({
          database: dbShow.database,
          row: found,
          blocks: pgShow.blocks ?? [],
          principals: dbShow.principals ?? principals,
          relationTargets: dbShow.relation_targets ?? relationTargets,
        });
      }
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.message
          : err instanceof Error
            ? err.message
            : "Failed to load inspector context"
      );
    } finally {
      setLoading(false);
    }
  }, [target, principals, relationTargets]);

  useEffect(() => {
    void loadTarget();
  }, [loadTarget]);

  if (!target) return null;

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-stone-950/30 backdrop-blur-[1px]">
      <div className="flex-1" onClick={onClose} />
      <aside className="w-full max-w-lg bg-white border-l border-stone-200 shadow-2xl flex flex-col h-full">
        {/* Drawer Header */}
        <div className="flex items-center justify-between border-b border-stone-200 px-5 py-4 bg-stone-50/70">
          <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
            {target.kind === "block" ? (
              <>
                <FileText className="h-4 w-4 text-blue-600" />
                <span>Block Inspector</span>
                <span className="font-mono text-xs text-stone-500">{target.blockId}</span>
              </>
            ) : (
              <>
                <DbIcon className="h-4 w-4 text-indigo-600" />
                <span>Row Inspector</span>
                <span className="font-mono text-xs text-stone-500">{target.rowId}</span>
              </>
            )}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1.5 text-stone-500 hover:bg-stone-200/70 hover:text-stone-900"
            title="Close (Esc)"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        {/* Drawer Content */}
        <div className="flex-1 overflow-y-auto p-5 space-y-5">
          {loading && <div className="text-xs text-stone-500">Loading live context...</div>}
          {error && (
            <div className="rounded-xl border border-red-200 bg-red-50 px-3.5 py-2.5 text-xs text-red-800">
              {error}
            </div>
          )}

          {blockCtx && (
            <>
              <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-4 space-y-2">
                <div className="flex items-center justify-between gap-2 text-xs text-stone-500">
                  <span>
                    Page: <strong className="text-stone-900">{blockCtx.page.title}</strong>
                  </span>
                  <Link
                    href={`/p/${blockCtx.page.id}`}
                    className="inline-flex items-center gap-1 font-medium text-blue-700 hover:underline"
                  >
                    Open page <ArrowUpRight className="h-3 w-3" />
                  </Link>
                </div>
                <div className="flex flex-wrap items-center gap-2 text-[11px] text-stone-500">
                  <span className="rounded bg-white border border-stone-200 px-2 py-0.5 font-mono">
                    v{blockCtx.block.version}
                  </span>
                  <span className="inline-flex items-center gap-1 rounded bg-white border border-stone-200 px-2 py-0.5">
                    {blockCtx.block.provenance.author_kind === "human_author" ? (
                      <User className="h-3 w-3 text-emerald-700" />
                    ) : (
                      <Bot className="h-3 w-3 text-teal-700" />
                    )}
                    {blockCtx.block.provenance.author_id}
                  </span>
                  {blockCtx.block.provenance.proposal_id && (
                    <span className="rounded bg-teal-50 border border-teal-200 px-2 py-0.5 font-mono text-teal-800">
                      {blockCtx.block.provenance.proposal_id}
                    </span>
                  )}
                </div>
                {blockCtx.block.provenance.reason && (
                  <p className="text-xs text-stone-600 italic">
                    &ldquo;{blockCtx.block.provenance.reason}&rdquo;
                  </p>
                )}
              </div>

              {blockCtx.prev_block && (
                <div className="space-y-1">
                  <div className="text-[11px] font-semibold uppercase tracking-wider text-stone-400">
                    Previous Block
                  </div>
                  <div className="rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs text-stone-600">
                    {blockCtx.prev_block.markdown || "(non-text block)"}
                  </div>
                </div>
              )}

              <div className="space-y-1">
                <div className="text-[11px] font-semibold uppercase tracking-wider text-blue-700">
                  Referenced Block ({blockCtx.block.id})
                </div>
                <div className="rounded-xl border-2 border-blue-200 bg-blue-50/40 p-4 text-sm text-stone-900 whitespace-pre-wrap leading-relaxed">
                  {blockCtx.block.markdown || "(structural block)"}
                </div>
              </div>

              {blockCtx.next_block && (
                <div className="space-y-1">
                  <div className="text-[11px] font-semibold uppercase tracking-wider text-stone-400">
                    Next Block
                  </div>
                  <div className="rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs text-stone-600">
                    {blockCtx.next_block.markdown || "(non-text block)"}
                  </div>
                </div>
              )}

              <div className="space-y-2 pt-2 border-t border-stone-200">
                <div className="flex items-center gap-1.5 text-xs font-semibold text-stone-800">
                  <MessageSquare className="h-3.5 w-3.5 text-stone-500" />
                  Block Comments ({blockCtx.comments.length})
                </div>
                {blockCtx.comments.length === 0 ? (
                  <p className="text-xs text-stone-400">No comments attached directly to this block.</p>
                ) : (
                  blockCtx.comments.map((c) => (
                    <div key={c.id} className="rounded-lg border border-stone-200 bg-stone-50 p-3 text-xs">
                      <div className="flex justify-between text-[11px] text-stone-400">
                        <span className="font-mono">{c.author_id}</span>
                        <span>{c.created_at}</span>
                      </div>
                      <p className="mt-1 text-stone-800">{c.body_markdown}</p>
                    </div>
                  ))
                )}
              </div>
            </>
          )}

          {rowBundle && (
            <>
              <div className="flex items-center justify-between rounded-xl border border-stone-200 bg-stone-50/70 px-4 py-3">
                <div>
                  <div className="text-[11px] text-stone-500">{rowBundle.database.title}</div>
                  <div className="text-sm font-semibold text-stone-950">
                    {getRowTitle(rowBundle.row, rowBundle.database.properties)}
                  </div>
                </div>
                <Link
                  href={`/p/${rowBundle.row.row.page_id}`}
                  className="inline-flex items-center gap-1 rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs font-medium text-blue-700 hover:bg-blue-50"
                >
                  Open full page <ArrowUpRight className="h-3 w-3" />
                </Link>
              </div>

              <div className="space-y-2.5">
                <div className="text-[11px] font-semibold uppercase tracking-wider text-stone-400">
                  Row Properties
                </div>
                {rowBundle.database.properties.map((prop) => (
                  <div
                    key={prop.id}
                    className="rounded-lg border border-stone-200 bg-stone-50/50 px-3 py-2 flex items-center justify-between gap-3"
                  >
                    <span className="text-xs font-medium text-stone-600 shrink-0">{prop.name}</span>
                    <div className="min-w-0 flex-1 flex justify-end">
                      <InlineCellEditor
                        er={rowBundle.row}
                        prop={prop}
                        database={rowBundle.database}
                        databases={databases.length > 0 ? databases : [rowBundle.database]}
                        principals={rowBundle.principals}
                        relationTargets={rowBundle.relationTargets}
                        onCommit={async (cellValue: CellValue) => {
                          await apiFetch(
                            `/api/databases/${rowBundle.database.id}/rows/${rowBundle.row.row.id}`,
                            {
                              method: "PATCH",
                              body: JSON.stringify({
                                cells: { [prop.id]: cellValue },
                                expected_version: rowBundle.row.row.version,
                                reason: "Edited row via slide-over inspector",
                              }),
                            }
                          );
                          await loadTarget();
                          onRowUpdated?.();
                        }}
                      />
                    </div>
                  </div>
                ))}
              </div>

              <div className="space-y-2 pt-3 border-t border-stone-200">
                <div className="text-[11px] font-semibold uppercase tracking-wider text-stone-400">
                  Backing Document Blocks ({rowBundle.blocks.length})
                </div>
                {rowBundle.blocks.length === 0 ? (
                  <p className="text-xs text-stone-400">No body blocks on this row page yet.</p>
                ) : (
                  rowBundle.blocks.map((b) => (
                    <div
                      key={b.id}
                      className="rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs text-stone-800 whitespace-pre-wrap"
                    >
                      {b.markdown}
                    </div>
                  ))
                )}
              </div>
            </>
          )}
        </div>
      </aside>
    </div>
  );
}
