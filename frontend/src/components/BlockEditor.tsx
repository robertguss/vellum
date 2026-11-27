import { Link } from "@inertiajs/react";
import { EditorContent, useEditor } from "@tiptap/react";
import Placeholder from "@tiptap/extension-placeholder";
import TaskItem from "@tiptap/extension-task-item";
import TaskList from "@tiptap/extension-task-list";
import StarterKit from "@tiptap/starter-kit";
import {
  AlertTriangle,
  Bold,
  Bot,
  Calculator,
  Check,
  Code,
  Database as DbIcon,
  FileText,
  GitPullRequest,
  GripVertical,
  Info,
  Italic,
  Lightbulb,
  Lock,
  Plus,
  RefreshCw,
  Save,
  ShieldAlert,
  Sparkles,
  Trash2,
  User,
} from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { ApiError, apiFetch } from "../lib/api";
import type {
  Block,
  BlockKind,
  BlockOp,
  DatabaseDef,
  DbViewDef,
  Page,
  PrincipalSummary,
  ProposalMeta,
  RelationTargetOption,
  ResolvedMetric,
} from "../lib/types";
import { formatNumberCell, formatSignedDecimal } from "./database/InlineCellEditor";
import EmbeddedDatabase from "./EmbeddedDatabase";

interface BlockEditorProps {
  page: Page;
  blocks: Block[];
  databases?: DatabaseDef[];
  principals?: PrincipalSummary[];
  relationTargets?: Record<string, RelationTargetOption[]>;
  resolvedMetrics?: Record<string, ResolvedMetric>;
  activeScenarioId?: string | null;
  onBlocksUpdated: (nextBlocks: Block[], anchoredMarkdown: string) => void;
  onProposalCreated?: (proposal: ProposalMeta) => void;
  onInspectBlock?: (blockId: string) => void;
  onInspectRow?: (databaseId: string, rowId: string, pageId: string) => void;
  onMetricInvalidated?: () => void;
}

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function blockKindOptionValue(kind: BlockKind): string {
  if (kind === "paragraph") return "paragraph";
  if (kind === "bullet_list_item") return "bullet_list_item";
  if (kind === "quote") return "quote";
  if (kind === "divider") return "divider";
  if (typeof kind === "object" && "heading" in kind) {
    return `h${kind.heading.level}`;
  }
  if (typeof kind === "object" && "callout" in kind) return "callout";
  if (typeof kind === "object" && "code_block" in kind) return "code_block";
  if (typeof kind === "object" && "task_item" in kind) return "task_item";
  if (typeof kind === "object" && "database_view_embed" in kind) return "database_view_embed";
  if (typeof kind === "object" && "ai_brief" in kind) return "ai_brief";
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
    case "callout":
      return { callout: { tone: "info", icon: null } };
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

function isSafeLinkHref(href: string): boolean {
  return /^https?:\/\//i.test(href) || (href.startsWith("/") && !href.startsWith("//"));
}

function renderMetricPill(
  rawTok: string,
  metric: ResolvedMetric | undefined,
  key: number
): ReactNode {
  if (!metric) {
    return (
      <span
        key={key}
        className="inline-flex items-center gap-1 rounded-md border border-dashed border-stone-300 bg-stone-50 px-1.5 py-0.5 font-mono text-[11px] text-stone-600 align-baseline"
      >
        <Calculator className="h-3 w-3 text-stone-400" />
        {rawTok}
      </span>
    );
  }
  if (metric.status === "forbidden") {
    return (
      <span
        key={key}
        title="You do not have access to the source collection for this metric"
        className="inline-flex items-center gap-1 rounded-md border border-amber-200 bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-800 align-baseline"
      >
        <Lock className="h-3 w-3" />
        Restricted metric
      </span>
    );
  }
  if (metric.status !== "ok" || metric.value === null) {
    return (
      <span
        key={key}
        title={`${metric.status}: ${rawTok}`}
        className="inline-flex items-center gap-1 rounded-md border border-stone-200 bg-stone-100 px-2 py-0.5 font-mono text-[11px] text-stone-600 align-baseline"
      >
        {rawTok} ({metric.status})
      </span>
    );
  }

  const formattedVal = formatNumberCell(metric.value, metric.format) || metric.value;
  const hasDelta = metric.delta !== null && metric.delta !== "0";
  const tip = `${metric.database_title ?? metric.database_id} · ${
    metric.property_name ?? metric.property_id
  } (${metric.agg}, ${metric.row_count} rows)`;

  return (
    <Link
      key={key}
      href={`/d/${metric.database_id}`}
      onClick={(e) => e.stopPropagation()}
      title={tip}
      className="inline-flex items-center gap-1.5 rounded-md border border-emerald-200 bg-emerald-50/90 px-2 py-0.5 font-mono text-[0.88em] font-semibold text-emerald-950 hover:bg-emerald-100 transition align-baseline"
    >
      <Calculator className="h-3 w-3 text-emerald-700" />
      <span className="tabular-nums">{formattedVal}</span>
      {hasDelta && metric.delta && (
        <span className="rounded bg-indigo-600 px-1 py-0 text-[10px] font-semibold text-white tabular-nums">
          {formatSignedDecimal(metric.delta, metric.format)}
        </span>
      )}
    </Link>
  );
}

function renderInlineMarkdown(
  text: string,
  resolvedMetrics: Record<string, ResolvedMetric> = {},
  onInspectBlock?: (blockId: string) => void
): ReactNode[] {
  const tokenRe =
    /(\{\{metric:[^}\n]+\}\}|\[?blk_[A-Za-z0-9_]+\]?|`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|\[[^\]\n]+\]\([^)\s]+\))/g;
  const out: ReactNode[] = [];
  let lastIdx = 0;
  let match: RegExpExecArray | null;
  let keyIdx = 0;
  while ((match = tokenRe.exec(text)) !== null) {
    if (match.index > lastIdx) {
      out.push(text.slice(lastIdx, match.index));
    }
    const tok = match[0];
    if (tok.startsWith("{{metric:") && tok.endsWith("}}")) {
      out.push(renderMetricPill(tok, resolvedMetrics[tok], keyIdx++));
    } else if (/^\[?blk_[A-Za-z0-9_]+\]?$/.test(tok)) {
      const cleanId = tok.replace(/^\[|\]$/g, "");
      out.push(
        <button
          key={keyIdx++}
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onInspectBlock?.(cleanId);
          }}
          className="inline-flex items-center gap-1 rounded border border-blue-200 bg-blue-50 px-1.5 py-0 font-mono text-[11px] font-medium text-blue-700 hover:bg-blue-100 align-baseline"
        >
          {cleanId}
        </button>
      );
    } else if (tok.startsWith("`") && tok.endsWith("`")) {
      out.push(
        <code
          key={keyIdx++}
          className="rounded bg-stone-100 px-1.5 py-0.5 font-mono text-[0.85em] text-stone-800 border border-stone-200/80"
        >
          {tok.slice(1, -1)}
        </code>
      );
    } else if (tok.startsWith("**") && tok.endsWith("**")) {
      out.push(
        <strong key={keyIdx++} className="font-semibold text-stone-950">
          {tok.slice(2, -2)}
        </strong>
      );
    } else if (tok.startsWith("*") && tok.endsWith("*")) {
      out.push(
        <em key={keyIdx++} className="italic">
          {tok.slice(1, -1)}
        </em>
      );
    } else if (tok.startsWith("[")) {
      const m = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(tok);
      if (m && isSafeLinkHref(m[2])) {
        const [, label, href] = m;
        if (href.startsWith("/")) {
          out.push(
            <Link
              key={keyIdx++}
              href={href}
              onClick={(e) => e.stopPropagation()}
              className="text-blue-600 underline decoration-blue-300 hover:text-blue-800"
            >
              {label}
            </Link>
          );
        } else {
          out.push(
            <a
              key={keyIdx++}
              href={href}
              target="_blank"
              rel="noreferrer"
              onClick={(e) => e.stopPropagation()}
              className="text-blue-600 underline decoration-blue-300 hover:text-blue-800"
            >
              {label}
            </a>
          );
        }
      } else {
        out.push(tok);
      }
    } else {
      out.push(tok);
    }
    lastIdx = match.index + tok.length;
  }
  if (lastIdx < text.length) {
    out.push(text.slice(lastIdx));
  }
  return out;
}

function getCalloutPalette(toneRaw: string) {
  const tone = toneRaw.trim().toLowerCase();
  if (tone === "warning" || tone === "warn" || tone === "amber" || tone === "important") {
    return {
      container: "border-l-4 border-amber-500 bg-amber-50/75 text-amber-950",
      title: "text-amber-900",
      Icon: AlertTriangle,
    };
  }
  if (tone === "caution" || tone === "danger" || tone === "error" || tone === "red") {
    return {
      container: "border-l-4 border-red-500 bg-red-50/75 text-red-950",
      title: "text-red-900",
      Icon: ShieldAlert,
    };
  }
  if (tone === "tip" || tone === "success" || tone === "green") {
    return {
      container: "border-l-4 border-emerald-500 bg-emerald-50/75 text-emerald-950",
      title: "text-emerald-900",
      Icon: Lightbulb,
    };
  }
  return {
    container: "border-l-4 border-blue-500 bg-blue-50/75 text-blue-950",
    title: "text-blue-900",
    Icon: Info,
  };
}

function CalloutBox({
  tone,
  title,
  body,
  resolvedMetrics,
  onInspectBlock,
}: {
  tone: string;
  title?: string;
  body: string;
  resolvedMetrics: Record<string, ResolvedMetric>;
  onInspectBlock?: (blockId: string) => void;
}) {
  const palette = getCalloutPalette(tone);
  const Icon = palette.Icon;
  return (
    <div className={`rounded-r-xl px-4 py-3 text-sm space-y-1 ${palette.container}`}>
      <div
        className={`flex items-center gap-2 font-semibold text-xs uppercase tracking-wide ${palette.title}`}
      >
        <Icon className="h-3.5 w-3.5 shrink-0" />
        <span>{title || tone || "Note"}</span>
      </div>
      {body && (
        <div className="leading-relaxed whitespace-pre-wrap">
          {renderInlineMarkdown(body, resolvedMetrics, onInspectBlock)}
        </div>
      )}
    </div>
  );
}

function RenderedBlockBody({
  block,
  saving,
  databases,
  principals,
  relationTargets,
  resolvedMetrics,
  activeScenarioId,
  onToggleTask,
  onInspectBlock,
  onInspectRow,
  onMetricInvalidated,
}: {
  block: Block;
  saving: boolean;
  databases: DatabaseDef[];
  principals: PrincipalSummary[];
  relationTargets: Record<string, RelationTargetOption[]>;
  resolvedMetrics: Record<string, ResolvedMetric>;
  activeScenarioId: string | null;
  onToggleTask: (b: Block) => void;
  onInspectBlock?: (blockId: string) => void;
  onInspectRow?: (databaseId: string, rowId: string, pageId: string) => void;
  onMetricInvalidated?: () => void;
}) {
  const { kind, markdown } = block;

  if (typeof kind === "object" && "database_view_embed" in kind) {
    return (
      <EmbeddedDatabase
        databaseId={kind.database_view_embed.database_id}
        viewId={kind.database_view_embed.view_id}
        databases={databases}
        principals={principals}
        relationTargets={relationTargets}
        activeScenarioId={activeScenarioId}
        onInspectRow={onInspectRow}
        onMetricInvalidated={onMetricInvalidated}
      />
    );
  }

  if (typeof kind === "object" && "ai_brief" in kind) {
    const brief = kind.ai_brief;
    return (
      <div className="rounded-xl border border-violet-200 bg-violet-50/60 p-4 space-y-2.5">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2 text-xs font-semibold text-violet-950">
            <Sparkles className="h-3.5 w-3.5 text-violet-700" />
            <span>{brief.prompt}</span>
          </div>
          <div className="flex items-center gap-2 text-[11px]">
            {brief.source_scope && (
              <span className="rounded-md bg-white border border-violet-200 px-2 py-0.5 font-mono text-violet-700">
                scope: {brief.source_scope}
              </span>
            )}
            <span className="font-mono text-violet-700/80">
              {brief.refreshed_at ? `Refreshed ${brief.refreshed_at}` : "Never refreshed"}
            </span>
          </div>
        </div>
        <div className="text-sm leading-relaxed text-stone-800 whitespace-pre-wrap">
          {markdown.trim()
            ? renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)
            : "No synthesized brief content yet."}
        </div>
      </div>
    );
  }

  if (typeof kind === "object" && "heading" in kind) {
    const lvl = Math.min(3, Math.max(1, kind.heading.level));
    const cls =
      lvl === 1
        ? "text-2xl font-bold tracking-tight text-stone-950 pt-1"
        : lvl === 2
          ? "text-lg font-semibold tracking-tight text-stone-950 pt-0.5"
          : "text-base font-semibold text-stone-900";
    if (lvl === 1) {
      return <h1 className={cls}>{renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}</h1>;
    }
    if (lvl === 2) {
      return <h2 className={cls}>{renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}</h2>;
    }
    return <h3 className={cls}>{renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}</h3>;
  }

  if (kind === "bullet_list_item") {
    return (
      <div className="flex items-start gap-2.5 text-[15px] leading-relaxed text-stone-800 py-0.5">
        <span className="mt-2.5 h-1.5 w-1.5 rounded-full bg-stone-500 shrink-0" />
        <div className="flex-1 whitespace-pre-wrap">
          {renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}
        </div>
      </div>
    );
  }

  if (typeof kind === "object" && "ordered_list_item" in kind) {
    return (
      <div className="flex items-start gap-2.5 text-[15px] leading-relaxed text-stone-800 py-0.5">
        <span className="font-mono text-xs font-semibold text-stone-500 mt-1 shrink-0">
          {kind.ordered_list_item.start}.
        </span>
        <div className="flex-1 whitespace-pre-wrap">
          {renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}
        </div>
      </div>
    );
  }

  if (typeof kind === "object" && "task_item" in kind) {
    const checked = kind.task_item.checked;
    return (
      <div className="flex items-start gap-2.5 text-[15px] py-0.5">
        <button
          type="button"
          disabled={saving}
          aria-label={checked ? "Mark task incomplete" : "Mark task complete"}
          onClick={(e) => {
            e.stopPropagation();
            onToggleTask(block);
          }}
          className={`mt-1 h-4 w-4 rounded border flex items-center justify-center shrink-0 transition ${
            checked
              ? "border-emerald-600 bg-emerald-600 text-white"
              : "border-stone-300 bg-white hover:border-stone-500"
          }`}
        >
          {checked && <Check className="h-3 w-3 stroke-[2.5]" />}
        </button>
        <div
          className={`flex-1 leading-relaxed whitespace-pre-wrap ${
            checked ? "line-through text-stone-400" : "text-stone-800"
          }`}
        >
          {renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}
        </div>
      </div>
    );
  }

  if (typeof kind === "object" && "callout" in kind) {
    const lines = markdown.split("\n");
    const first = lines[0] ?? "";
    const rest = lines.slice(1).join("\n").trim();
    return (
      <CalloutBox
        tone={kind.callout.tone}
        title={rest ? first : kind.callout.tone}
        body={rest || first}
        resolvedMetrics={resolvedMetrics}
        onInspectBlock={onInspectBlock}
      />
    );
  }

  if (kind === "quote") {
    const lines = markdown.split("\n");
    const alertMatch = /^\[!(WARNING|CAUTION|IMPORTANT|TIP|NOTE|INFO)\]\s*(.*)$/i.exec(
      (lines[0] ?? "").trim()
    );
    if (alertMatch) {
      const tone = alertMatch[1];
      const heading = alertMatch[2].trim();
      const body = lines.slice(1).join("\n").trim();
      return (
        <CalloutBox
          tone={tone}
          title={heading || tone}
          body={body}
          resolvedMetrics={resolvedMetrics}
          onInspectBlock={onInspectBlock}
        />
      );
    }
    return (
      <blockquote className="border-l-3 border-stone-300 pl-3.5 py-0.5 text-[15px] italic leading-relaxed text-stone-600 whitespace-pre-wrap">
        {renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}
      </blockquote>
    );
  }

  if (typeof kind === "object" && "code_block" in kind) {
    return (
      <div className="rounded-xl border border-stone-800 bg-stone-950 text-stone-100 overflow-hidden">
        <div className="flex items-center justify-between border-b border-stone-800 px-3.5 py-1.5 text-[10px] font-mono uppercase tracking-wider text-stone-400">
          <span>{kind.code_block.language || "text"}</span>
        </div>
        <pre className="p-3.5 text-xs font-mono leading-relaxed overflow-x-auto">
          <code>{markdown}</code>
        </pre>
      </div>
    );
  }

  if (kind === "divider") {
    return <hr className="my-2 border-stone-200" />;
  }

  if (typeof kind === "object" && "page_link" in kind) {
    return (
      <Link
        href={`/p/${kind.page_link.target_page_id}`}
        onClick={(e) => e.stopPropagation()}
        className="inline-flex items-center gap-2 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-sm font-medium text-blue-700 hover:bg-stone-100"
      >
        <FileText className="h-3.5 w-3.5" />
        <span>{markdown || kind.page_link.target_page_id}</span>
      </Link>
    );
  }

  if (typeof kind === "object" && ("image" in kind || "file_embed" in kind)) {
    const label =
      "image" in kind ? kind.image.caption || kind.image.attachment_id : kind.file_embed.filename;
    return (
      <div className="inline-flex items-center gap-2 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-xs text-stone-700">
        <FileText className="h-3.5 w-3.5 text-stone-500" />
        <span>{label}</span>
      </div>
    );
  }

  return (
    <div className="text-[15px] leading-relaxed text-stone-800 whitespace-pre-wrap py-0.5">
      {renderInlineMarkdown(markdown, resolvedMetrics, onInspectBlock)}
    </div>
  );
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
  onSlashTrigger: () => void;
}

function TipTapInlineEditor({ block, onChangeText, onSlashTrigger }: TipTapInlineEditorProps) {
  const editor = useEditor({
    extensions: [
      StarterKit,
      TaskList,
      TaskItem.configure({ nested: true }),
      Placeholder.configure({ placeholder: "Write freely or type '/' for Sets..." }),
    ],
    content: blockToHtml(block.kind, block.markdown),
    onUpdate: ({ editor: ed }) => {
      const txt = ed.getText({ blockSeparator: "\n" });
      if (txt.trim() === "/") {
        onSlashTrigger();
      }
      onChangeText(txt);
    },
  });

  return (
    <div className="rounded-lg border border-blue-200 bg-white px-3 py-2 text-[15px] shadow-2xs focus-within:ring-2 focus-within:ring-blue-500/20">
      {editor && (
        <div className="flex flex-wrap items-center gap-1 pb-1.5 mb-1.5 border-b border-stone-100">
          <button
            type="button"
            onClick={() => editor.chain().focus().toggleBold().run()}
            className="rounded p-1 text-stone-500 hover:bg-stone-100 hover:text-stone-900"
            title="Bold"
          >
            <Bold className="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            onClick={() => editor.chain().focus().toggleItalic().run()}
            className="rounded p-1 text-stone-500 hover:bg-stone-100 hover:text-stone-900"
            title="Italic"
          >
            <Italic className="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            onClick={() => editor.chain().focus().toggleCode().run()}
            className="rounded p-1 text-stone-500 hover:bg-stone-100 hover:text-stone-900"
            title="Code"
          >
            <Code className="h-3.5 w-3.5" />
          </button>
          <span className="text-[11px] text-stone-400 ml-auto">
            Type <code className="font-mono">/</code> for Sets &amp; Embeds
          </span>
        </div>
      )}
      <EditorContent editor={editor} />
    </div>
  );
}

export default function BlockEditor({
  page,
  blocks,
  databases = [],
  principals = [],
  relationTargets = {},
  resolvedMetrics = {},
  activeScenarioId = null,
  onBlocksUpdated,
  onProposalCreated,
  onInspectBlock,
  onInspectRow,
  onMetricInvalidated,
}: BlockEditorProps) {
  const [drafts, setDrafts] = useState<Record<string, { kind: BlockKind; markdown: string }>>({});
  const [activeBlockId, setActiveBlockId] = useState<string | null>(blocks[0]?.id ?? null);
  const [highlightedId, setHighlightedId] = useState<string | null>(null);
  const [rawMode, setRawMode] = useState(false);
  const [reason, setReason] = useState("inline editor update");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [statusMsg, setStatusMsg] = useState<string | null>(null);

  // Drag & Drop state
  const [draggedId, setDraggedId] = useState<string | null>(null);
  const [dragOverId, setDragOverId] = useState<string | null>(null);

  // Sets (Slash) Command Palette
  const [showSetsMenu, setShowSetsMenu] = useState(false);
  const [setsMode, setSetsMode] = useState<"main" | "db_embed" | "metric_pill" | "ai_brief">(
    "main"
  );
  const [insertAfterId, setInsertAfterId] = useState<string | null>(null);

  const [embedDbId, setEmbedDbId] = useState<string>(databases[0]?.id ?? "");
  const [embedDbViews, setEmbedDbViews] = useState<DbViewDef[]>([]);
  const [embedViewId, setEmbedViewId] = useState<string>("");

  const [metricDbId, setMetricDbId] = useState<string>(databases[0]?.id ?? "");
  const [metricPropId, setMetricPropId] = useState<string>("");
  const [metricAgg, setMetricAgg] = useState<string>("sum");

  const [briefPrompt, setBriefPrompt] = useState("");
  const [briefScope, setBriefScope] = useState("");
  const [refreshingBlockId, setRefreshingBlockId] = useState<string | null>(null);

  // Quick Add new block bar
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
    if (!embedDbId && databases[0]) setEmbedDbId(databases[0].id);
    if (!metricDbId && databases[0]) setMetricDbId(databases[0].id);
  }, [databases, embedDbId, metricDbId]);

  useEffect(() => {
    if (setsMode !== "db_embed" || !embedDbId) return;
    apiFetch<{ views: DbViewDef[] }>(`/api/databases/${embedDbId}`)
      .then((res) => {
        setEmbedDbViews(res.views ?? []);
        setEmbedViewId(res.views?.[0]?.id ?? "");
      })
      .catch(() => {
        setEmbedDbViews([]);
        setEmbedViewId("");
      });
  }, [setsMode, embedDbId]);

  useEffect(() => {
    const db = databases.find((d) => d.id === metricDbId);
    if (!db) return;
    const numProps = db.properties.filter(
      (p) =>
        (typeof p.kind === "object" &&
          ("number" in p.kind ||
            "rollup" in p.kind ||
            ("ai_derived" in p.kind &&
              typeof p.kind.ai_derived.output_kind === "object" &&
              "ai_number" in p.kind.ai_derived.output_kind))) ||
        metricAgg === "count" ||
        metricAgg === "count_values"
    );
    const first = numProps[0] ?? db.properties[0];
    if (first && !db.properties.some((p) => p.id === metricPropId)) {
      setMetricPropId(first.id);
    }
  }, [metricDbId, databases, metricPropId, metricAgg]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const h = window.location.hash.replace(/^#/, "");
    if (h) {
      setHighlightedId(h);
      const el = document.querySelector(`[data-block-id="${h}"]`);
      el?.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [blocks]);

  async function patchOps(ops: BlockOp[], expectedVersions: Record<string, number>, msg: string, opReason: string) {
    setSaving(true);
    setError(null);
    setStatusMsg(null);
    try {
      const res = await apiFetch<{ blocks: Block[]; anchored_markdown: string }>(
        `/api/pages/${page.id}/blocks`,
        {
          method: "PATCH",
          body: JSON.stringify({
            ops,
            expected_versions: expectedVersions,
            reason: opReason,
          }),
        }
      );
      onBlocksUpdated(res.blocks, res.anchored_markdown);
      setStatusMsg(msg);
      onMetricInvalidated?.();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save block changes");
    } finally {
      setSaving(false);
    }
  }

  async function handleSaveBlock(b: Block) {
    const edited = drafts[b.id];
    if (!edited) return;
    await patchOps(
      [
        {
          replace_block: {
            block_id: b.id,
            expected_version: b.version,
            kind: edited.kind,
            markdown: edited.markdown,
          },
        },
      ],
      { [b.id]: b.version },
      `Saved block ${b.id}`,
      reason.trim() || "editor update"
    );
  }

  async function handleToggleTaskCheckbox(b: Block) {
    if (typeof b.kind !== "object" || !("task_item" in b.kind)) return;
    const nextChecked = !b.kind.task_item.checked;
    await patchOps(
      [
        {
          replace_block: {
            block_id: b.id,
            expected_version: b.version,
            kind: { task_item: { checked: nextChecked } },
            markdown: b.markdown,
          },
        },
      ],
      { [b.id]: b.version },
      nextChecked ? `Completed task ${b.id}` : `Reopened task ${b.id}`,
      nextChecked ? `checked task ${b.id}` : `unchecked task ${b.id}`
    );
  }

  async function handleInsertBlock(e: React.FormEvent) {
    e.preventDefault();
    if (!newMarkdown.trim() && newKindVal !== "divider") return;
    const lastId = blocks.length > 0 ? blocks[blocks.length - 1].id : null;
    await patchOps(
      [
        {
          insert_block_after: {
            after_block_id: lastId,
            parent_block_id: null,
            kind: optionValueToBlockKind(newKindVal),
            markdown: newMarkdown.trim(),
          },
        },
      ],
      {},
      "Inserted new block",
      reason.trim() || "insert block"
    );
    setNewMarkdown("");
  }

  async function handleInsertSetKind(kind: BlockKind, md: string) {
    const afterId =
      insertAfterId ?? (blocks.length > 0 ? blocks[blocks.length - 1].id : null);
    setShowSetsMenu(false);
    setSetsMode("main");
    await patchOps(
      [
        {
          insert_block_after: {
            after_block_id: afterId,
            parent_block_id: null,
            kind,
            markdown: md,
          },
        },
      ],
      {},
      "Inserted set block",
      reason.trim() || "insert set"
    );
  }

  async function handleMoveBlock(sourceId: string, targetId: string) {
    if (sourceId === targetId) return;
    const targetIdx = blocks.findIndex((b) => b.id === targetId);
    const sourceIdx = blocks.findIndex((b) => b.id === sourceId);
    if (targetIdx < 0 || sourceIdx < 0) return;

    const remaining = blocks.filter((b) => b.id !== sourceId);
    const newTargetIdx = remaining.findIndex((b) => b.id === targetId);
    const insertIdx = sourceIdx < targetIdx ? newTargetIdx + 1 : newTargetIdx;
    const afterBlockId = insertIdx > 0 ? remaining[insertIdx - 1].id : null;

    await patchOps(
      [
        {
          move_block: {
            block_id: sourceId,
            new_parent_id: null,
            after_block_id: afterBlockId,
          },
        },
      ],
      {},
      `Moved ${sourceId}`,
      reason.trim() || `reorder block ${sourceId}`
    );
  }

  async function handleDeleteBlock(b: Block) {
    await patchOps(
      [
        {
          delete_block: {
            block_id: b.id,
            expected_version: b.version,
          },
        },
      ],
      { [b.id]: b.version },
      `Deleted block ${b.id}`,
      reason.trim() || "delete block"
    );
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

  async function handleRefreshAiBrief(b: Block) {
    setRefreshingBlockId(b.id);
    setError(null);
    setStatusMsg(null);
    try {
      const res = await apiFetch<{
        proposal: ProposalMeta;
        draft_markdown: string;
        block_id: string;
        model: string;
      }>("/api/ai/brief/refresh", {
        method: "POST",
        body: JSON.stringify({
          page_id: page.id,
          block_id: b.id,
          deterministic_fallback: true,
        }),
      });
      setCreatedProposal(res.proposal);
      setStatusMsg(
        `Staged Living Brief refresh in Proposal ${res.proposal.id} (${res.model})`
      );
      onProposalCreated?.(res.proposal);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to refresh AI Brief");
    } finally {
      setRefreshingBlockId(null);
    }
  }

  const selectedMetricDb = databases.find((d) => d.id === metricDbId);

  return (
    <div className="max-w-4xl mx-auto space-y-5">
      {/* Studio Controls Header */}
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-stone-200 bg-white px-4 py-2.5">
        <div className="flex items-center gap-2 text-xs text-stone-600">
          <span className="font-medium text-stone-800">Audit Reason:</span>
          <input
            type="text"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="rounded-md border border-stone-200 px-2.5 py-1 text-xs w-52 outline-none focus:border-stone-500"
          />
        </div>
        <div className="flex flex-wrap items-center gap-2 text-xs">
          {statusMsg && <span className="text-emerald-700 font-medium">{statusMsg}</span>}
          <button
            type="button"
            onClick={() => {
              setInsertAfterId(blocks.length > 0 ? blocks[blocks.length - 1].id : null);
              setSetsMode("main");
              setShowSetsMenu((v) => !v);
            }}
            className="inline-flex items-center gap-1 rounded-md border border-stone-200 bg-stone-50 px-2.5 py-1 font-medium text-stone-700 hover:bg-stone-100"
          >
            <Plus className="h-3.5 w-3.5" />
            Add Set ( / )
          </button>
          <button
            type="button"
            onClick={() => setRawMode((v) => !v)}
            className="rounded-md border border-stone-200 px-2.5 py-1 text-stone-600 hover:bg-stone-50"
          >
            {rawMode ? "TipTap Rich Mode" : "Raw Block Mode"}
          </button>
        </div>
      </div>

      {/* Statamic-Style Sets Palette */}
      {showSetsMenu && (
        <div className="rounded-2xl border border-stone-300 bg-white p-4 shadow-lg space-y-3">
          <div className="flex items-center justify-between border-b border-stone-100 pb-2">
            <div className="text-xs font-semibold text-stone-900">
              {setsMode === "main"
                ? "Insert Content Set"
                : setsMode === "db_embed"
                  ? "Embed Live Database View"
                  : setsMode === "ai_brief"
                    ? "Insert Living AI Brief Card"
                    : "Insert Live Metric Pill"}
            </div>
            <button
              type="button"
              onClick={() => {
                setShowSetsMenu(false);
                setSetsMode("main");
              }}
              className="text-xs text-stone-500 hover:text-stone-900"
            >
              Close
            </button>
          </div>

          {setsMode === "main" && (
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
              <button
                type="button"
                onClick={() => void handleInsertSetKind("paragraph", "New paragraph...")}
                className="rounded-lg border border-stone-200 px-3 py-2 text-left hover:bg-stone-50"
              >
                <div className="font-semibold text-stone-900">Paragraph</div>
                <div className="text-[11px] text-stone-400">Plain editorial prose</div>
              </button>
              <button
                type="button"
                onClick={() => void handleInsertSetKind({ heading: { level: 2 } }, "Section Heading")}
                className="rounded-lg border border-stone-200 px-3 py-2 text-left hover:bg-stone-50"
              >
                <div className="font-semibold text-stone-900">Heading 2</div>
                <div className="text-[11px] text-stone-400">Section divider title</div>
              </button>
              <button
                type="button"
                onClick={() => void handleInsertSetKind({ task_item: { checked: false } }, "Action item")}
                className="rounded-lg border border-stone-200 px-3 py-2 text-left hover:bg-stone-50"
              >
                <div className="font-semibold text-stone-900">Checklist</div>
                <div className="text-[11px] text-stone-400">Interactive task box</div>
              </button>
              <button
                type="button"
                onClick={() =>
                  void handleInsertSetKind({ callout: { tone: "info", icon: null } }, "Key takeaway")
                }
                className="rounded-lg border border-stone-200 px-3 py-2 text-left hover:bg-stone-50"
              >
                <div className="font-semibold text-stone-900">Callout</div>
                <div className="text-[11px] text-stone-400">Highlighted banner</div>
              </button>
              <button
                type="button"
                onClick={() => void handleInsertSetKind({ code_block: { language: "mo" } }, "// code")}
                className="rounded-lg border border-stone-200 px-3 py-2 text-left hover:bg-stone-50"
              >
                <div className="font-semibold text-stone-900">Code Block</div>
                <div className="text-[11px] text-stone-400">Syntax formatted snippet</div>
              </button>
              <button
                type="button"
                onClick={() => void handleInsertSetKind("divider", "")}
                className="rounded-lg border border-stone-200 px-3 py-2 text-left hover:bg-stone-50"
              >
                <div className="font-semibold text-stone-900">Divider</div>
                <div className="text-[11px] text-stone-400">Horizontal separator</div>
              </button>
              <button
                type="button"
                onClick={() => setSetsMode("db_embed")}
                className="rounded-lg border border-blue-200 bg-blue-50/70 px-3 py-2 text-left hover:bg-blue-100/70"
              >
                <div className="flex items-center gap-1 font-semibold text-blue-900">
                  <DbIcon className="h-3.5 w-3.5" />
                  Live DB View
                </div>
                <div className="text-[11px] text-blue-700">Interactive table/board</div>
              </button>
              <button
                type="button"
                onClick={() => setSetsMode("metric_pill")}
                className="rounded-lg border border-emerald-200 bg-emerald-50/70 px-3 py-2 text-left hover:bg-emerald-100/70"
              >
                <div className="flex items-center gap-1 font-semibold text-emerald-900">
                  <Calculator className="h-3.5 w-3.5" />
                  Live Metric Pill
                </div>
                <div className="text-[11px] text-emerald-700">Decimal DB aggregation</div>
              </button>
              <button
                type="button"
                onClick={() => setSetsMode("ai_brief")}
                className="rounded-lg border border-violet-200 bg-violet-50/70 px-3 py-2 text-left hover:bg-violet-100/70"
              >
                <div className="flex items-center gap-1 font-semibold text-violet-900">
                  <Sparkles className="h-3.5 w-3.5" />
                  Living AI Brief
                </div>
                <div className="text-[11px] text-violet-700">Auto summary brief card</div>
              </button>
            </div>
          )}

          {setsMode === "db_embed" && (
            <div className="space-y-3 text-xs">
              {databases.length === 0 ? (
                <p className="text-stone-500">Create a Database first to embed live views here.</p>
              ) : (
                <div className="flex flex-wrap items-center gap-2">
                  <select
                    value={embedDbId}
                    onChange={(e) => setEmbedDbId(e.target.value)}
                    className="rounded-lg border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    {databases.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.title}
                      </option>
                    ))}
                  </select>
                  <select
                    value={embedViewId}
                    onChange={(e) => setEmbedViewId(e.target.value)}
                    className="rounded-lg border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    <option value="">Default View</option>
                    {embedDbViews.map((v) => (
                      <option key={v.id} value={v.id}>
                        {v.name}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={() =>
                      void handleInsertSetKind(
                        {
                          database_view_embed: {
                            database_id: embedDbId,
                            view_id: embedViewId || null,
                          },
                        },
                        ""
                      )
                    }
                    className="rounded-lg bg-stone-900 px-3.5 py-1.5 font-medium text-white hover:bg-stone-800"
                  >
                    Insert Live Embed
                  </button>
                </div>
              )}
            </div>
          )}

          {setsMode === "metric_pill" && (
            <div className="space-y-3 text-xs">
              {databases.length === 0 ? (
                <p className="text-stone-500">Create a Database first to reference metrics.</p>
              ) : (
                <div className="flex flex-wrap items-center gap-2">
                  <select
                    value={metricDbId}
                    onChange={(e) => setMetricDbId(e.target.value)}
                    className="rounded-lg border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    {databases.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.title}
                      </option>
                    ))}
                  </select>
                  <select
                    value={metricPropId}
                    onChange={(e) => setMetricPropId(e.target.value)}
                    className="rounded-lg border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    {(selectedMetricDb?.properties ?? []).map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.name} ({p.id})
                      </option>
                    ))}
                  </select>
                  <select
                    value={metricAgg}
                    onChange={(e) => setMetricAgg(e.target.value)}
                    className="rounded-lg border border-stone-200 bg-white px-2.5 py-1.5"
                  >
                    <option value="sum">sum</option>
                    <option value="count">count</option>
                    <option value="count_values">count_values</option>
                    <option value="avg">avg</option>
                    <option value="min">min</option>
                    <option value="max">max</option>
                  </select>
                  <button
                    type="button"
                    disabled={!metricDbId || !metricPropId}
                    onClick={() => {
                      const tok = `{{metric:${metricDbId}.${metricPropId}:${metricAgg}}}`;
                      const propName =
                        selectedMetricDb?.properties.find((p) => p.id === metricPropId)?.name ??
                        metricPropId;
                      void handleInsertSetKind("paragraph", `Live ${propName} (${metricAgg}): ${tok}`);
                    }}
                    className="rounded-lg bg-emerald-700 px-3.5 py-1.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-50"
                  >
                    Insert Metric Block
                  </button>
                </div>
              )}
            </div>
          )}

          {setsMode === "ai_brief" && (
            <div className="space-y-3 text-xs">
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
                <input
                  type="text"
                  value={briefPrompt}
                  onChange={(e) => setBriefPrompt(e.target.value)}
                  placeholder="Brief goal (e.g. Summarize Q4 operational status)"
                  className="sm:col-span-2 rounded-lg border border-stone-200 bg-white px-3 py-1.5 outline-none focus:border-violet-500"
                />
                <input
                  type="text"
                  value={briefScope}
                  onChange={(e) => setBriefScope(e.target.value)}
                  placeholder="Scope collection ID (blank = current)"
                  className="rounded-lg border border-stone-200 bg-white px-3 py-1.5 font-mono outline-none focus:border-violet-500"
                />
              </div>
              <div className="flex items-center justify-end gap-2">
                <button
                  type="button"
                  disabled={!briefPrompt.trim()}
                  onClick={() => {
                    const p = briefPrompt.trim();
                    const s = briefScope.trim() || null;
                    setBriefPrompt("");
                    setBriefScope("");
                    void handleInsertSetKind(
                      {
                        ai_brief: {
                          prompt: p,
                          source_scope: s,
                          refreshed_at: null,
                        },
                      },
                      "_Click Refresh into Proposal to synthesize from permitted workspace summaries._"
                    );
                  }}
                  className="rounded-lg bg-violet-700 px-3.5 py-1.5 font-medium text-white hover:bg-violet-800 disabled:opacity-50"
                >
                  Insert Living Brief Card
                </button>
              </div>
            </div>
          )}
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-xs text-red-800">
          {error}
        </div>
      )}

      {/* Editorial Canvas */}
      <div className="space-y-3">
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
          const isEmbed = typeof b.kind === "object" && "database_view_embed" in b.kind;
          const isAiBrief = typeof b.kind === "object" && "ai_brief" in b.kind;

          return (
            <div
              key={b.id}
              data-block-id={b.id}
              onClick={() => setActiveBlockId(b.id)}
              onDragOver={(e) => {
                e.preventDefault();
                if (draggedId && draggedId !== b.id) setDragOverId(b.id);
              }}
              onDragLeave={() => {
                if (dragOverId === b.id) setDragOverId(null);
              }}
              onDrop={(e) => {
                e.preventDefault();
                setDragOverId(null);
                if (draggedId && draggedId !== b.id) {
                  void handleMoveBlock(draggedId, b.id);
                }
                setDraggedId(null);
              }}
              className={`group rounded-2xl border p-4 transition ${
                dragOverId === b.id
                  ? "border-blue-400 ring-2 ring-blue-100 bg-blue-50/20"
                  : isHighlighted
                    ? "border-amber-400 bg-amber-50/40 ring-2 ring-amber-200"
                    : isActive
                      ? "border-stone-300 bg-white shadow-xs"
                      : "border-stone-200/75 bg-white/85 hover:border-stone-300"
              }`}
            >
              <div className="flex items-start gap-3">
                {/* Drag Handle + Provenance Gutter */}
                <div className="w-32 shrink-0 pt-1 space-y-1">
                  <div className="flex items-center gap-1">
                    <span
                      draggable
                      onDragStart={() => setDraggedId(b.id)}
                      onDragEnd={() => {
                        setDraggedId(null);
                        setDragOverId(null);
                      }}
                      title="Drag to reorder block"
                      className="cursor-grab text-stone-300 hover:text-stone-600 opacity-0 group-hover:opacity-100 transition"
                    >
                      <GripVertical className="h-4 w-4" />
                    </span>
                    <button
                      type="button"
                      onClick={(e) => {
                        e.stopPropagation();
                        onInspectBlock?.(b.id);
                      }}
                      title={
                        b.provenance.reason
                          ? `Inspect ${b.id} (${b.provenance.reason})`
                          : `Inspect ${b.id}`
                      }
                      className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-medium transition ${
                        isAgent
                          ? "bg-teal-50 text-teal-800 border border-teal-200 hover:bg-teal-100"
                          : "bg-stone-100 text-stone-700 hover:bg-stone-200"
                      }`}
                    >
                      {isAgent ? <Bot className="h-3 w-3" /> : <User className="h-3 w-3" />}
                      <span>{isAgent ? "Agent" : "Human"}</span>
                    </button>
                  </div>
                  <div className="text-[10px] font-mono text-stone-400 truncate pl-5">
                    {b.id} · v{b.version}
                  </div>
                  {b.provenance.reason && (
                    <div
                      className="text-[10px] text-stone-400 truncate pl-5"
                      title={b.provenance.reason}
                    >
                      {b.provenance.reason}
                    </div>
                  )}
                </div>

                {/* Block Body */}
                <div className="flex-1 min-w-0 space-y-2">
                  <div className="flex items-center justify-between gap-2">
                    {isEmbed ? (
                      <span className="inline-flex items-center gap-1 rounded-md bg-blue-50 border border-blue-200 px-2 py-0.5 text-[11px] font-medium text-blue-800">
                        <DbIcon className="h-3 w-3" />
                        Embedded Database View
                      </span>
                    ) : isAiBrief ? (
                      <div className="flex items-center gap-2">
                        <span className="inline-flex items-center gap-1 rounded-md bg-violet-50 border border-violet-200 px-2 py-0.5 text-[11px] font-medium text-violet-800">
                          <Sparkles className="h-3 w-3" />
                          Living AI Brief
                        </span>
                        <button
                          type="button"
                          disabled={refreshingBlockId === b.id}
                          onClick={(e) => {
                            e.stopPropagation();
                            void handleRefreshAiBrief(b);
                          }}
                          className="inline-flex items-center gap-1 rounded-md border border-violet-200 bg-white px-2.5 py-0.5 text-[11px] font-medium text-violet-800 hover:bg-violet-50 disabled:opacity-50"
                        >
                          <RefreshCw
                            className={`h-3 w-3 ${refreshingBlockId === b.id ? "animate-spin" : ""}`}
                          />
                          {refreshingBlockId === b.id ? "Refreshing..." : "Refresh into Proposal"}
                        </button>
                      </div>
                    ) : (
                      <select
                        value={blockKindOptionValue(draft.kind)}
                        onChange={(e) => {
                          const val = e.target.value;
                          const nextKind =
                            val === "callout" &&
                            typeof draft.kind === "object" &&
                            "callout" in draft.kind
                              ? draft.kind
                              : optionValueToBlockKind(val);
                          setDrafts((prev) => ({
                            ...prev,
                            [b.id]: { ...draft, kind: nextKind },
                          }));
                        }}
                        className={`rounded border border-stone-200 bg-stone-50 px-2 py-0.5 text-[11px] font-medium text-stone-600 transition ${
                          isActive ? "opacity-100" : "opacity-0 group-hover:opacity-100"
                        }`}
                      >
                        <option value="paragraph">Paragraph</option>
                        <option value="h1">Heading 1</option>
                        <option value="h2">Heading 2</option>
                        <option value="h3">Heading 3</option>
                        <option value="bullet_list_item">Bullet Item</option>
                        <option value="task_item">Task Item</option>
                        <option value="callout">Callout</option>
                        <option value="quote">Quote</option>
                        <option value="code_block">Code Block</option>
                        <option value="divider">Divider</option>
                      </select>
                    )}

                    <div className="flex items-center gap-1.5">
                      <button
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation();
                          setInsertAfterId(b.id);
                          setSetsMode("main");
                          setShowSetsMenu(true);
                        }}
                        title="Insert Set below this block"
                        className="rounded p-1 text-stone-400 hover:bg-stone-100 hover:text-stone-700 opacity-0 group-hover:opacity-100 transition"
                      >
                        <Plus className="h-3.5 w-3.5" />
                      </button>
                      {typeof b.kind === "object" && "page_link" in b.kind && (
                        <Link
                          href={`/p/${b.kind.page_link.target_page_id}`}
                          className="text-xs text-blue-600 hover:underline mr-2"
                        >
                          Open linked page →
                        </Link>
                      )}
                      {dirty && !isEmbed && (
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

                  {(isEmbed || (isAiBrief && !rawMode)) ? (
                    <RenderedBlockBody
                      block={b}
                      saving={saving}
                      databases={databases}
                      principals={principals}
                      relationTargets={relationTargets}
                      resolvedMetrics={resolvedMetrics}
                      activeScenarioId={activeScenarioId}
                      onToggleTask={(blk) => void handleToggleTaskCheckbox(blk)}
                      onInspectBlock={onInspectBlock}
                      onInspectRow={onInspectRow}
                      onMetricInvalidated={onMetricInvalidated}
                    />
                  ) : isActive && !rawMode ? (
                    <TipTapInlineEditor
                      key={b.id}
                      block={b}
                      onSlashTrigger={() => {
                        setInsertAfterId(b.id);
                        setSetsMode("main");
                        setShowSetsMenu(true);
                      }}
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
                    <RenderedBlockBody
                      block={b}
                      saving={saving}
                      databases={databases}
                      principals={principals}
                      relationTargets={relationTargets}
                      resolvedMetrics={resolvedMetrics}
                      activeScenarioId={activeScenarioId}
                      onToggleTask={(blk) => void handleToggleTaskCheckbox(blk)}
                      onInspectBlock={onInspectBlock}
                      onInspectRow={onInspectRow}
                      onMetricInvalidated={onMetricInvalidated}
                    />
                  )}

                  {b.provenance.citations.length > 0 && (
                    <div className="flex flex-wrap gap-1.5 pt-1">
                      {b.provenance.citations.map((cit, i) => {
                        const citBlkMatch = /^blk_[A-Za-z0-9_]+$/.test(cit.source_ref);
                        return citBlkMatch && onInspectBlock ? (
                          <button
                            key={i}
                            type="button"
                            onClick={(e) => {
                              e.stopPropagation();
                              onInspectBlock(cit.source_ref);
                            }}
                            className="inline-flex items-center rounded bg-blue-50 px-2 py-0.5 text-[11px] text-blue-700 border border-blue-200 hover:bg-blue-100"
                          >
                            {cit.label} ({cit.source_ref})
                          </button>
                        ) : (
                          <span
                            key={i}
                            className="inline-flex items-center rounded bg-blue-50 px-2 py-0.5 text-[11px] text-blue-700 border border-blue-100"
                          >
                            {cit.label} ({cit.source_ref})
                          </span>
                        );
                      })}
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
        onSubmit={(e) => void handleInsertBlock(e)}
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
          <option value="callout">Callout</option>
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
        onSubmit={(e) => void handleAiDraft(e)}
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
