import { Link } from "@inertiajs/react";
import { EditorContent, useEditor } from "@tiptap/react";
import Placeholder from "@tiptap/extension-placeholder";
import TaskItem from "@tiptap/extension-task-item";
import TaskList from "@tiptap/extension-task-list";
import StarterKit from "@tiptap/starter-kit";
import { Bot, GitPullRequest, Plus, Save, Sparkles, Trash2, User } from "lucide-react";
import { useEffect, useState } from "react";
import { ApiError, apiFetch } from "../lib/api";
import type { Block, BlockKind, BlockOp, Page, ProposalMeta } from "../lib/types";

interface BlockEditorProps {
  page: Page;
  blocks: Block[];
  onBlocksUpdated: (nextBlocks: Block[], anchoredMarkdown: string) => void;
  onProposalCreated?: (proposal: ProposalMeta) => void;
}

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function blockKindLabel(kind: BlockKind): string {
  if (typeof kind === "string") {
    if (kind === "paragraph") return "Paragraph";
    if (kind === "bullet_list_item") return "Bullet";
    if (kind === "quote") return "Quote";
    if (kind === "divider") return "Divider";
    return kind;
  }
  if ("heading" in kind) return `H${kind.heading.level}`;
  if ("ordered_list_item" in kind) return `${kind.ordered_list_item.start}.`;
  if ("task_item" in kind) return kind.task_item.checked ? "Task [x]" : "Task [ ]";
  if ("callout" in kind) return `Callout (${kind.callout.tone})`;
  if ("code_block" in kind) return `Code (${kind.code_block.language || "text"})`;
  if ("image" in kind) return "Image";
  if ("file_embed" in kind) return "File";
  if ("page_link" in kind) return "PageLink";
  return "Block";
}

function blockKindOptionValue(kind: BlockKind): string {
  if (kind === "paragraph") return "paragraph";
  if (kind === "bullet_list_item") return "bullet_list_item";
  if (kind === "quote") return "quote";
  if (kind === "divider") return "divider";
  if (typeof kind === "object" && "heading" in kind) {
    return `h${kind.heading.level}`;
  }
  if (typeof kind === "object" && "code_block" in kind) return "code_block";
  if (typeof kind === "object" && "task_item" in kind) return "task_item";
  return "paragraph";
}

function optionValueToBlockKind(val: string): BlockKind {
  switch (val) {
    case "h1":
      return { heading: { level: 1 } };
    case "h2":
      return { heading: { level: 2 } };
    case "h3":
      return { heading: { level: 3 } };
    case "bullet_list_item":
      return "bullet_list_item";
    case "quote":
      return "quote";
    case "task_item":
      return { task_item: { checked: false } };
    case "code_block":
      return { code_block: { language: "mo" } };
    case "divider":
      return "divider";
    default:
      return "paragraph";
  }
}

function blockToHtml(kind: BlockKind, markdown: string): string {
  const safe = escapeHtml(markdown);
  if (typeof kind === "object" && "heading" in kind) {
    const lvl = Math.min(3, Math.max(1, kind.heading.level));
    return `<h${lvl}>${safe}</h${lvl}>`;
  }
  if (typeof kind === "object" && "code_block" in kind) {
    return `<pre><code>${safe}</code></pre>`;
  }
  if (kind === "quote") {
    return `<blockquote><p>${safe}</p></blockquote>`;
  }
  return `<p>${safe}</p>`;
}

interface TipTapInlineEditorProps {
  block: Block;
  onChangeText: (text: string) => void;
}

function TipTapInlineEditor({ block, onChangeText }: TipTapInlineEditorProps) {
  const editor = useEditor({
    extensions: [
      StarterKit,
      TaskList,
      TaskItem.configure({ nested: true }),
      Placeholder.configure({ placeholder: "Type block content..." }),
    ],
    content: blockToHtml(block.kind, block.markdown),
    onUpdate: ({ editor: ed }) => {
      onChangeText(ed.getText({ blockSeparator: "\n" }));
    },
  });

  return (
    <div className="rounded-lg border border-blue-200 bg-white px-3 py-2 text-sm shadow-2xs focus-within:ring-2 focus-within:ring-blue-500/20">
      <EditorContent editor={editor} />
    </div>
  );
}

export default function BlockEditor({
  page,
  blocks,
  onBlocksUpdated,
  onProposalCreated,
}: BlockEditorProps) {
  const [drafts, setDrafts] = useState<Record<string, { kind: BlockKind; markdown: string }>>({});
  const [activeBlockId, setActiveBlockId] = useState<string | null>(blocks[0]?.id ?? null);
  const [highlightedId, setHighlightedId] = useState<string | null>(null);
  const [rawMode, setRawMode] = useState(false);
  const [reason, setReason] = useState("inline editor update");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [statusMsg, setStatusMsg] = useState<string | null>(null);

  // Add new block inputs
  const [newMarkdown, setNewMarkdown] = useState("");
  const [newKindVal, setNewKindVal] = useState("paragraph");

  // AI Draft Proposal bar
  const [aiInst, setAiInst] = useState("");
  const [aiLoading, setAiLoading] = useState(false);
  const [createdProposal, setCreatedProposal] = useState<ProposalMeta | null>(null);

  useEffect(() => {
    const map: Record<string, { kind: BlockKind; markdown: string }> = {};
    for (const b of blocks) {
      map[b.id] = { kind: b.kind, markdown: b.markdown };
    }
    setDrafts(map);
  }, [blocks]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const h = window.location.hash.replace(/^#/, "");
    if (h) {
      setHighlightedId(h);
      const el = document.querySelector(`[data-block-id="${h}"]`);
      el?.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [blocks]);

  async function handleSaveBlock(b: Block) {
    const edited = drafts[b.id];
    if (!edited) return;
    setSaving(true);
    setError(null);
    setStatusMsg(null);
    try {
      const ops: BlockOp[] = [
        {
          replace_block: {
            block_id: b.id,
            expected_version: b.version,
            kind: edited.kind,
            markdown: edited.markdown,
          },
        },
      ];
      const res = await apiFetch<{ blocks: Block[]; anchored_markdown: string }>(
        `/api/pages/${page.id}/blocks`,
        {
          method: "PATCH",
          body: JSON.stringify({
            ops,
            expected_versions: { [b.id]: b.version },
            reason: reason.trim() || "editor update",
          }),
        }
      );
      onBlocksUpdated(res.blocks, res.anchored_markdown);
      setStatusMsg(`Saved block ${b.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save block");
    } finally {
      setSaving(false);
    }
  }

  async function handleInsertBlock(e: React.FormEvent) {
    e.preventDefault();
    if (!newMarkdown.trim()) return;
    setSaving(true);
    setError(null);
    setStatusMsg(null);
    try {
      const lastId = blocks.length > 0 ? blocks[blocks.length - 1].id : null;
      const ops: BlockOp[] = [
        {
          insert_block_after: {
            after_block_id: lastId,
            parent_block_id: null,
            kind: optionValueToBlockKind(newKindVal),
            markdown: newMarkdown.trim(),
          },
        },
      ];
      const res = await apiFetch<{ blocks: Block[]; anchored_markdown: string }>(
        `/api/pages/${page.id}/blocks`,
        {
          method: "PATCH",
          body: JSON.stringify({
            ops,
            expected_versions: {},
            reason: reason.trim() || "insert block",
          }),
        }
      );
      setNewMarkdown("");
      onBlocksUpdated(res.blocks, res.anchored_markdown);
      setStatusMsg("Inserted new block");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to insert block");
    } finally {
      setSaving(false);
    }
  }

  async function handleDeleteBlock(b: Block) {
    setSaving(true);
    setError(null);
    setStatusMsg(null);
    try {
      const ops: BlockOp[] = [
        {
          delete_block: {
            block_id: b.id,
            expected_version: b.version,
          },
        },
      ];
      const res = await apiFetch<{ blocks: Block[]; anchored_markdown: string }>(
        `/api/pages/${page.id}/blocks`,
        {
          method: "PATCH",
          body: JSON.stringify({
            ops,
            expected_versions: { [b.id]: b.version },
            reason: reason.trim() || "delete block",
          }),
        }
      );
      onBlocksUpdated(res.blocks, res.anchored_markdown);
      setStatusMsg(`Deleted block ${b.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to delete block");
    } finally {
      setSaving(false);
    }
  }

  async function handleAiDraft(e: React.FormEvent) {
    e.preventDefault();
    if (!aiInst.trim()) return;
    setAiLoading(true);
    setError(null);
    try {
      const res = await apiFetch<{
        draft_markdown: string;
        proposal: ProposalMeta;
        model: string;
      }>("/api/ai/draft", {
        method: "POST",
        body: JSON.stringify({
          page_id: page.id,
          instruction: aiInst.trim(),
          as_proposal: true,
        }),
      });
      setCreatedProposal(res.proposal);
      setAiInst("");
      onProposalCreated?.(res.proposal);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "AI draft failed (check VELLUM_AI_API_KEY)");
    } finally {
      setAiLoading(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-stone-200 bg-white px-4 py-2.5">
        <div className="flex items-center gap-2 text-xs text-stone-600">
          <span className="font-medium text-stone-800">Audit Reason:</span>
          <input
            type="text"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="rounded-md border border-stone-200 px-2.5 py-1 text-xs w-56 outline-none focus:border-stone-500"
          />
        </div>
        <div className="flex items-center gap-3 text-xs">
          {statusMsg && <span className="text-emerald-700 font-medium">{statusMsg}</span>}
          <button
            type="button"
            onClick={() => setRawMode((v) => !v)}
            className="rounded-md border border-stone-200 px-2.5 py-1 text-stone-600 hover:bg-stone-50"
          >
            {rawMode ? "TipTap Rich Mode" : "Raw Markdown Mode"}
          </button>
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-xs text-red-800">
          {error}
        </div>
      )}

      <div className="space-y-2.5">
        {blocks.map((b) => {
          const isAgent =
            typeof b.provenance.author_kind === "object" &&
            "agent_author" in b.provenance.author_kind;
          const draft = drafts[b.id] ?? { kind: b.kind, markdown: b.markdown };
          const dirty =
            draft.markdown !== b.markdown ||
            JSON.stringify(draft.kind) !== JSON.stringify(b.kind);
          const isActive = activeBlockId === b.id;
          const isHighlighted = highlightedId === b.id;

          return (
            <div
              key={b.id}
              data-block-id={b.id}
              onClick={() => setActiveBlockId(b.id)}
              className={`group rounded-xl border p-3.5 transition ${
                isHighlighted
                  ? "border-amber-400 bg-amber-50/40 ring-2 ring-amber-200"
                  : isActive
                    ? "border-stone-300 bg-white shadow-xs"
                    : "border-stone-200/80 bg-white/70 hover:border-stone-300"
              }`}
            >
              <div className="flex items-start gap-3">
                {/* Provenance Gutter */}
                <div className="w-28 shrink-0 pt-1 space-y-1">
                  <div
                    title={
                      b.provenance.reason
                        ? `Reason: ${b.provenance.reason}`
                        : `Author: ${b.provenance.author_id}`
                    }
                    className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-medium ${
                      isAgent
                        ? "bg-teal-50 text-teal-800 border border-teal-200"
                        : "bg-stone-100 text-stone-700"
                    }`}
                  >
                    {isAgent ? <Bot className="h-3 w-3" /> : <User className="h-3 w-3" />}
                    <span>{isAgent ? "Agent" : "Human"}</span>
                  </div>
                  <div className="text-[10px] font-mono text-stone-400 truncate">
                    {b.id} · v{b.version}
                  </div>
                  {b.provenance.reason && (
                    <div className="text-[10px] text-stone-500 truncate" title={b.provenance.reason}>
                      {b.provenance.reason}
                    </div>
                  )}
                </div>

                {/* Block Body */}
                <div className="flex-1 min-w-0 space-y-2">
                  <div className="flex items-center justify-between gap-2">
                    <select
                      value={blockKindOptionValue(draft.kind)}
                      onChange={(e) =>
                        setDrafts((prev) => ({
                          ...prev,
                          [b.id]: { ...draft, kind: optionValueToBlockKind(e.target.value) },
                        }))
                      }
                      className="rounded border border-stone-200 bg-stone-50 px-2 py-0.5 text-[11px] font-medium text-stone-600"
                    >
                      <option value="paragraph">Paragraph</option>
                      <option value="h1">Heading 1</option>
                      <option value="h2">Heading 2</option>
                      <option value="h3">Heading 3</option>
                      <option value="bullet_list_item">Bullet Item</option>
                      <option value="task_item">Task Item</option>
                      <option value="quote">Quote</option>
                      <option value="code_block">Code Block</option>
                      <option value="divider">Divider</option>
                    </select>

                    <div className="flex items-center gap-1.5">
                      {typeof b.kind === "object" && "page_link" in b.kind && (
                        <Link
                          href={`/p/${b.kind.page_link.target_page_id}`}
                          className="text-xs text-blue-600 hover:underline mr-2"
                        >
                          Open linked page →
                        </Link>
                      )}
                      {dirty && (
                        <button
                          type="button"
                          disabled={saving}
                          onClick={(e) => {
                            e.stopPropagation();
                            void handleSaveBlock(b);
                          }}
                          className="inline-flex items-center gap-1 rounded-md bg-blue-600 px-2.5 py-1 text-[11px] font-medium text-white hover:bg-blue-700"
                        >
                          <Save className="h-3 w-3" />
                          Save
                        </button>
                      )}
                      <button
                        type="button"
                        disabled={saving}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleDeleteBlock(b);
                        }}
                        title="Delete block"
                        className="rounded p-1 text-stone-400 hover:text-red-600 opacity-0 group-hover:opacity-100 transition"
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>

                  {isActive && !rawMode ? (
                    <TipTapInlineEditor
                      key={b.id}
                      block={b}
                      onChangeText={(txt) =>
                        setDrafts((prev) => ({
                          ...prev,
                          [b.id]: { ...draft, markdown: txt },
                        }))
                      }
                    />
                  ) : isActive && rawMode ? (
                    <textarea
                      rows={3}
                      value={draft.markdown}
                      onChange={(e) =>
                        setDrafts((prev) => ({
                          ...prev,
                          [b.id]: { ...draft, markdown: e.target.value },
                        }))
                      }
                      className="w-full rounded-lg border border-stone-300 px-3 py-2 text-sm font-mono outline-none focus:border-blue-500"
                    />
                  ) : (
                    <div className="text-sm text-stone-800 whitespace-pre-wrap py-0.5">
                      <span className="text-[11px] font-mono text-stone-400 mr-2">
                        [{blockKindLabel(b.kind)}]
                      </span>
                      {b.markdown}
                    </div>
                  )}

                  {b.provenance.citations.length > 0 && (
                    <div className="flex flex-wrap gap-1.5 pt-1">
                      {b.provenance.citations.map((cit, i) => (
                        <span
                          key={i}
                          className="inline-flex items-center rounded bg-blue-50 px-2 py-0.5 text-[11px] text-blue-700 border border-blue-100"
                        >
                          {cit.label} ({cit.source_ref})
                        </span>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {/* Insert New Block */}
      <form
        onSubmit={handleInsertBlock}
        className="rounded-xl border border-dashed border-stone-300 bg-stone-50/70 p-3 flex flex-wrap items-center gap-2"
      >
        <select
          value={newKindVal}
          onChange={(e) => setNewKindVal(e.target.value)}
          className="rounded-lg border border-stone-200 bg-white px-2.5 py-2 text-xs"
        >
          <option value="paragraph">Paragraph</option>
          <option value="h2">Heading 2</option>
          <option value="bullet_list_item">Bullet</option>
          <option value="task_item">Task Item</option>
          <option value="quote">Quote</option>
          <option value="code_block">Code Block</option>
        </select>
        <input
          type="text"
          value={newMarkdown}
          onChange={(e) => setNewMarkdown(e.target.value)}
          placeholder="Add a new canonical block..."
          className="flex-1 min-w-[200px] rounded-lg border border-stone-200 bg-white px-3 py-2 text-sm outline-none focus:border-stone-500"
        />
        <button
          type="submit"
          disabled={saving || !newMarkdown.trim()}
          className="inline-flex items-center gap-1.5 rounded-lg bg-stone-900 px-3.5 py-2 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
        >
          <Plus className="h-3.5 w-3.5" />
          Add Block
        </button>
      </form>

      {/* AI Draft as Speculative Proposal */}
      <form
        onSubmit={handleAiDraft}
        className="rounded-xl border border-teal-200 bg-teal-50/50 p-4 space-y-2.5"
      >
        <div className="flex items-center gap-2 text-xs font-semibold text-teal-900">
          <Sparkles className="h-3.5 w-3.5 text-teal-700" />
          Draft Section into Speculative Proposal (Modb.World)
        </div>
        <div className="flex flex-wrap gap-2">
          <input
            type="text"
            value={aiInst}
            onChange={(e) => setAiInst(e.target.value)}
            placeholder="e.g. Add an emergency escalation checklist..."
            className="flex-1 min-w-[240px] rounded-lg border border-teal-200 bg-white px-3 py-2 text-sm outline-none focus:border-teal-600"
          />
          <button
            type="submit"
            disabled={aiLoading || !aiInst.trim()}
            className="rounded-lg bg-teal-700 px-4 py-2 text-xs font-medium text-white hover:bg-teal-800 disabled:opacity-50"
          >
            {aiLoading ? "Drafting..." : "Draft Proposal"}
          </button>
        </div>
        {createdProposal && (
          <div className="flex items-center justify-between text-xs text-teal-900 bg-white rounded-lg border border-teal-200 px-3 py-2">
            <span>
              Created Proposal <strong className="font-mono">{createdProposal.id}</strong> (
              {createdProposal.status}) without touching the live page.
            </span>
            <Link
              href="/proposals"
              className="inline-flex items-center gap-1 font-medium text-teal-700 hover:underline"
            >
              <GitPullRequest className="h-3.5 w-3.5" />
              Review Diff →
            </Link>
          </div>
        )}
      </form>
    </div>
  );
}
