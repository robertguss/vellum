import { Link, router } from "@inertiajs/react";
import {
  ArrowUpRight,
  CheckCircle2,
  Clock,
  Download,
  Eye,
  FileText,
  Flame,
  GitBranch,
  GitPullRequest,
  Link2,
  MessageSquare,
  Paperclip,
  PenTool,
  RefreshCw,
  Save,
  Send,
  ShieldAlert,
  Sparkles,
  Upload,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import BlockEditor from "../../components/BlockEditor";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import BlueprintBar from "../../components/editor/BlueprintBar";
import PatchworkLens from "../../components/editor/PatchworkLens";
import SlideOverInspector, { type InspectorTarget } from "../../components/editor/SlideOverInspector";
import XRayLens from "../../components/editor/XRayLens";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  Attachment,
  AuditFeedItem,
  Block,
  BlueprintDef,
  ClaimRecord,
  Collection,
  Comment,
  DatabaseDef,
  EditorLens,
  ExplicitBacklink,
  GardenCitationDrift,
  Page,
  PageBlueprintMeta,
  PageTaintProvenance,
  PrincipalSummary,
  ProposalMeta,
  PurgeSecretResponse,
  RelationTargetOption,
  ResolvedMetric,
  SecretHint,
  SemanticBacklink,
} from "../../lib/types";

interface PageProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  collection: Collection;
  page: Page;
  blocks: Block[];
  anchored_markdown: string;
  yaml_frontmatter?: string;
  comments: Comment[];
  attachments: Attachment[];
  blueprints?: BlueprintDef[];
  page_blueprint?: BlueprintDef | null;
  page_meta?: PageBlueprintMeta | null;
  page_proposals?: ProposalMeta[];
  principals?: PrincipalSummary[];
  relation_targets?: Record<string, RelationTargetOption[]>;
  resolved_metrics?: Record<string, ResolvedMetric>;
  open_scenarios?: ProposalMeta[];
  page_audit?: AuditFeedItem[];
  citation_drifts?: GardenCitationDrift[];
  explicit_backlinks?: ExplicitBacklink[];
  semantic_backlinks?: SemanticBacklink[];
  taint_provenance?: PageTaintProvenance | null;
  secret_hints?: SecretHint[];
}

async function sha256Hex(file: File): Promise<string> {
  const buf = await file.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function collectMetricTokens(blks: Block[]): string[] {
  const re = /\{\{metric:[^}\n]+\}\}/g;
  const seen = new Set<string>();
  const out: string[] = [];
  for (const b of blks) {
    const matches = b.markdown.match(re) ?? [];
    for (const m of matches) {
      if (!seen.has(m)) {
        seen.add(m);
        out.push(m);
      }
    }
  }
  return out;
}

const LENS_ORDER: EditorLens[] = ["studio", "markdown", "patchwork", "xray"];

export default function PageView({
  collections = [],
  databases = [],
  collection,
  page: initialPage,
  blocks: initialBlocks = [],
  anchored_markdown: initialAnchored = "",
  yaml_frontmatter: initialYaml = "",
  comments: initialComments = [],
  attachments: initialAttachments = [],
  blueprints: initialBlueprints = [],
  page_blueprint: initialPageBlueprint = null,
  page_meta: initialPageMeta = null,
  page_proposals: initialProposals = [],
  principals = [],
  relation_targets = {},
  resolved_metrics: initialResolvedMetrics = {},
  open_scenarios: initialScenarios = [],
  page_audit = [],
  citation_drifts = [],
  explicit_backlinks = [],
  semantic_backlinks = [],
  taint_provenance = null,
  secret_hints = [],
}: PageProps) {
  const [page, setPage] = useState<Page>(initialPage);
  const [stagingDriftId, setStagingDriftId] = useState<string | null>(null);
  const [blocks, setBlocks] = useState<Block[]>(initialBlocks);
  const [anchoredMd, setAnchoredMd] = useState<string>(initialAnchored);
  const [yamlFm, setYamlFm] = useState<string>(initialYaml || initialAnchored);
  const [blueprints, setBlueprints] = useState<BlueprintDef[]>(initialBlueprints);
  const [pageBlueprint, setPageBlueprint] = useState<BlueprintDef | null>(initialPageBlueprint);
  const [pageMeta, setPageMeta] = useState<PageBlueprintMeta | null>(initialPageMeta);
  const [pageProposals, setPageProposals] = useState<ProposalMeta[]>(initialProposals);
  const [openScenarios, setOpenScenarios] = useState<ProposalMeta[]>(initialScenarios);
  const [metricsMap, setMetricsMap] =
    useState<Record<string, ResolvedMetric>>(initialResolvedMetrics);
  const [activeScenarioId, setActiveScenarioId] = useState<string | null>(null);

  const [comments, setComments] = useState<Comment[]>(initialComments);
  const [attachments, setAttachments] = useState<Attachment[]>(initialAttachments);
  const [activeClaims, setActiveClaims] = useState<ClaimRecord[]>([]);
  const [liveNotice, setLiveNotice] = useState<string | null>(null);

  const [lens, setLens] = useState<EditorLens>("studio");
  const [mdDraft, setMdDraft] = useState<string>(initialAnchored);
  const [mdSaving, setMdSaving] = useState(false);
  const [mdConflict, setMdConflict] = useState<string | null>(null);
  const [inspectorTarget, setInspectorTarget] = useState<InspectorTarget>(null);

  const [verifying, setVerifying] = useState(false);
  const [commentBody, setCommentBody] = useState("");
  const [commentSaving, setCommentSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [purgingSecrets, setPurgingSecrets] = useState(false);
  const [purgeReceipt, setPurgeReceipt] = useState<PurgeSecretResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setPage(initialPage);
  }, [initialPage]);
  useEffect(() => {
    setBlocks(initialBlocks);
  }, [initialBlocks]);
  useEffect(() => {
    setAnchoredMd(initialAnchored);
    setMdDraft(initialAnchored);
  }, [initialAnchored]);
  useEffect(() => {
    setYamlFm(initialYaml || initialAnchored);
  }, [initialYaml, initialAnchored]);
  useEffect(() => {
    setBlueprints(initialBlueprints);
  }, [initialBlueprints]);
  useEffect(() => {
    setPageBlueprint(initialPageBlueprint);
  }, [initialPageBlueprint]);
  useEffect(() => {
    setPageMeta(initialPageMeta);
  }, [initialPageMeta]);
  useEffect(() => {
    setPageProposals(initialProposals);
  }, [initialProposals]);
  useEffect(() => {
    setOpenScenarios(initialScenarios);
  }, [initialScenarios]);
  useEffect(() => {
    setMetricsMap(initialResolvedMetrics);
  }, [initialResolvedMetrics]);
  useEffect(() => {
    setComments(initialComments);
  }, [initialComments]);
  useEffect(() => {
    setAttachments(initialAttachments);
  }, [initialAttachments]);

  // ⌘⇧L / Ctrl+Shift+L Lens Switcher Shortcut
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "l") {
        e.preventDefault();
        setLens((cur) => LENS_ORDER[(LENS_ORDER.indexOf(cur) + 1) % LENS_ORDER.length]);
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const refreshMetrics = useCallback(
    async (blks: Block[], scenId: string | null) => {
      const tokens = collectMetricTokens(blks);
      if (tokens.length === 0) {
        setMetricsMap({});
        return;
      }
      try {
        const res = await apiFetch<{ metrics: Record<string, ResolvedMetric> }>(
          "/api/metrics/resolve",
          {
            method: "POST",
            body: JSON.stringify({ tokens, scenario_id: scenId }),
          }
        );
        setMetricsMap(res.metrics ?? {});
      } catch {
        // Keep existing metrics snapshot on transient errors
      }
    },
    []
  );

  useEffect(() => {
    void refreshMetrics(blocks, activeScenarioId);
  }, [blocks, activeScenarioId, refreshMetrics]);

  const handleSaveMarkdown = useCallback(async () => {
    setMdSaving(true);
    setMdConflict(null);
    setError(null);
    try {
      const res = await apiFetch<{
        page: Page;
        blocks: Block[];
        anchored_markdown: string;
        yaml_frontmatter: string;
      }>(`/api/pages/${page.id}/markdown`, {
        method: "PUT",
        body: JSON.stringify({
          markdown: mdDraft,
          expected_page_version: page.version,
          reason: "Synced directly from Markdown Lens",
        }),
      });
      setPage(res.page);
      setBlocks(res.blocks);
      setAnchoredMd(res.anchored_markdown);
      setMdDraft(res.anchored_markdown);
      setYamlFm(res.yaml_frontmatter);
      router.reload({ only: ["page", "blocks", "anchored_markdown", "yaml_frontmatter", "page_audit"] });
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) {
        setMdConflict(err.message);
      } else {
        setError(err instanceof ApiError ? err.message : "Failed to save Markdown");
      }
    } finally {
      setMdSaving(false);
    }
  }, [mdDraft, page.id, page.version]);

  // ⌘S / Ctrl+S Save inside Markdown Lens
  useEffect(() => {
    if (lens !== "markdown") return;
    function onKeyDown(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        void handleSaveMarkdown();
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [lens, handleSaveMarkdown]);

  const blockIds = useMemo(() => new Set(blocks.map((b) => `block:${b.id}`)), [blocks]);
  const pageLeases = activeClaims.filter(
    (c) => c.resource === `page:${page.id}` || blockIds.has(c.resource)
  );
  const openProposalsCount = pageProposals.filter((p) => p.status === "open").length;
  const mdDirty = mdDraft !== anchoredMd;

  const handleRealtimeEvent = useCallback((eventName: string, data: Record<string, unknown>) => {
    const actor = typeof data.actor === "string" ? data.actor : "collaborator";
    if (
      eventName === "page.blocks_updated" ||
      eventName === "page.meta_updated" ||
      eventName === "page.verified" ||
      eventName === "comment.created" ||
      eventName === "proposal.accepted" ||
      eventName === "resync_required"
    ) {
      setLiveNotice(
        eventName === "resync_required"
          ? "Re-synced page snapshot from server"
          : `Updated live by ${actor} (${eventName})`
      );
      router.reload({
        only: [
          "page",
          "blocks",
          "anchored_markdown",
          "yaml_frontmatter",
          "comments",
          "page_blueprint",
          "page_meta",
          "page_proposals",
          "resolved_metrics",
          "open_scenarios",
          "page_audit",
        ],
      });
    }
  }, []);

  async function handleVerify() {
    setVerifying(true);
    setError(null);
    try {
      const updated = await apiFetch<Page>(`/api/pages/${page.id}/verify`, {
        method: "POST",
        body: JSON.stringify({ freshness_ttl_days: page.freshness_ttl_days }),
      });
      setPage(updated);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to verify page");
    } finally {
      setVerifying(false);
    }
  }

  async function handleCommentSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!commentBody.trim()) return;
    setCommentSaving(true);
    setError(null);
    try {
      const created = await apiFetch<Comment>(`/api/pages/${page.id}/comments`, {
        method: "POST",
        body: JSON.stringify({
          block_id: null,
          parent_comment_id: null,
          body_markdown: commentBody.trim(),
        }),
      });
      setComments((prev) => [...prev, created]);
      setCommentBody("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to post comment");
    } finally {
      setCommentSaving(false);
    }
  }

  async function handleFileUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploading(true);
    setError(null);
    try {
      const sha = await sha256Hex(file);
      const presigned = await apiFetch<{
        attachment: Attachment;
        upload_url: string;
        method: string;
        required_headers: Array<{ name: string; value: string }>;
      }>("/api/attachments/presign", {
        method: "POST",
        body: JSON.stringify({
          page_id: page.id,
          filename: file.name,
          content_type: file.type || "application/octet-stream",
          size_bytes: file.size,
          sha256_hex: sha,
        }),
      });
      const headers = new Headers();
      for (const h of presigned.required_headers ?? []) {
        headers.set(h.name, h.value);
      }
      const putRes = await fetch(presigned.upload_url, {
        method: presigned.method || "PUT",
        headers,
        body: file,
      });
      if (!putRes.ok) {
        throw new Error(`S3 upload failed with HTTP ${putRes.status}`);
      }
      const committed = await apiFetch<Attachment>(
        `/api/attachments/${presigned.attachment.id}/commit`,
        {
          method: "POST",
          body: JSON.stringify({}),
        }
      );
      setAttachments((prev) => [...prev, committed]);
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.message
          : err instanceof Error
            ? err.message
            : "Attachment upload failed"
      );
    } finally {
      setUploading(false);
      e.target.value = "";
    }
  }

  return (
    <WorkspaceLayout
      title={page.title}
      collections={collections}
      databases={databases}
      activeCollectionSlug={collection.slug}
      currentCollectionId={collection.id}
      realtimeScope={{ pageId: page.id }}
      onRealtimeEvent={handleRealtimeEvent}
      onClaimsChange={setActiveClaims}
    >
      <div className="space-y-6">
        {pageLeases.length > 0 && (
          <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-2.5 text-xs text-amber-900 flex flex-wrap items-center justify-between gap-2">
            <span>
              Active advisory lease{pageLeases.length > 1 ? "s" : ""}:{" "}
              {pageLeases.map((c) => `${c.holder} on ${c.resource} (${c.reason})`).join(" · ")}
            </span>
          </div>
        )}
        {liveNotice && (
          <div className="rounded-xl border border-teal-200 bg-teal-50 px-4 py-2 text-xs text-teal-900 flex items-center justify-between">
            <span>{liveNotice}</span>
            <button
              type="button"
              onClick={() => setLiveNotice(null)}
              className="text-teal-700 hover:underline"
            >
              Dismiss
            </button>
          </div>
        )}

        {/* Breadcrumb + Freshness + 4-Lens Switcher */}
        <div className="rounded-2xl border border-stone-200 bg-white p-6 space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div>
              <div className="flex items-center gap-2 text-xs text-stone-500">
                <Link href={`/c/${collection.slug}`} className="hover:underline">
                  {collection.name}
                </Link>
                <span>/</span>
                <span className="font-mono">{page.id}</span>
                <span>· v{page.version}</span>
              </div>
              <h1 className="mt-1 text-2xl font-semibold tracking-tight text-stone-950">
                {page.title}
              </h1>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {page.database_id && (
                <Link
                  href={`/d/${page.database_id}`}
                  className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-blue-700 hover:bg-blue-50"
                >
                  Open Database →
                </Link>
              )}
              <button
                type="button"
                onClick={() => void handleVerify()}
                disabled={verifying}
                className="inline-flex items-center gap-1.5 rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-xs font-medium text-emerald-800 hover:bg-emerald-100 disabled:opacity-50"
              >
                <CheckCircle2 className="h-3.5 w-3.5" />
                {verifying ? "Verifying..." : "Verify Freshness"}
              </button>
            </div>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-stone-100 pt-3 text-xs text-stone-500">
            <div className="flex items-center gap-2">
              <Clock className="h-3.5 w-3.5" />
              {page.verified_at ? (
                <span>
                  Verified at <strong className="text-stone-700">{page.verified_at}</strong>
                </span>
              ) : (
                <span>Not yet manually verified</span>
              )}
            </div>

            {/* 4 Lenses Switcher */}
            <div
              className="flex flex-wrap items-center rounded-lg border border-stone-200 p-0.5 bg-stone-50"
              title="Switch Lenses (⌘⇧L)"
            >
              <button
                type="button"
                onClick={() => setLens("studio")}
                className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition ${
                  lens === "studio" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <PenTool className="h-3 w-3" />
                Studio
              </button>
              <button
                type="button"
                onClick={() => setLens("markdown")}
                className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition ${
                  lens === "markdown" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <FileText className="h-3 w-3" />
                Markdown
              </button>
              <button
                type="button"
                onClick={() => setLens("patchwork")}
                className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition ${
                  lens === "patchwork" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <GitPullRequest className="h-3 w-3" />
                Patchwork
                {openProposalsCount > 0 && (
                  <span className="rounded-full bg-teal-600 px-1.5 py-0 text-[10px] font-semibold text-white">
                    {openProposalsCount}
                  </span>
                )}
              </button>
              <button
                type="button"
                onClick={() => setLens("xray")}
                className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition ${
                  lens === "xray" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <Eye className="h-3 w-3" />
                X-Ray
              </button>
            </div>
          </div>
        </div>

        {/* Modb.Taint Untrusted Provenance Banner */}
        {taint_provenance &&
          (taint_provenance.trust === "untrusted" ||
            taint_provenance.untrusted_block_ids.length > 0) && (
            <div className="rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 flex flex-wrap items-center justify-between gap-3 text-xs text-amber-950">
              <div className="flex items-start gap-2.5">
                <ShieldAlert className="h-4 w-4 text-amber-700 shrink-0 mt-0.5" />
                <div>
                  <span className="font-semibold">
                    Modb.Taint Untrusted External Provenance
                  </span>
                  {taint_provenance.page?.writer ? (
                    <span> · Source: <code className="font-mono">{taint_provenance.page.writer}</code></span>
                  ) : null}
                  {taint_provenance.untrusted_block_ids.length > 0 ? (
                    <span> · {taint_provenance.untrusted_block_ids.length} untrusted block(s)</span>
                  ) : null}
                  <p className="text-[11px] text-amber-800 mt-0.5">
                    Agent sessions reading this content become tainted monotonically; Lethal
                    Trifecta policy blocks direct writes and webhook exfiltration until an Admin
                    clears the session.
                  </p>
                </div>
              </div>
              <Link
                href="/admin"
                className="rounded-lg border border-amber-300 bg-white px-2.5 py-1 font-medium text-amber-900 hover:bg-amber-100 shrink-0"
              >
                Inspect in Taint &amp; Safety →
              </Link>
            </div>
          )}

        {/* Modb.Erasure Secret Exposure Warning & One-Click Purge */}
        {(secret_hints.length > 0 || purgeReceipt) && (
          <div className="rounded-xl border border-rose-300 bg-rose-50 px-4 py-3 flex flex-wrap items-center justify-between gap-3 text-xs text-rose-950">
            <div className="flex items-start gap-2.5">
              <Flame className="h-4 w-4 text-rose-700 shrink-0 mt-0.5" />
              <div className="space-y-1">
                {secret_hints.length > 0 ? (
                  <>
                    <div className="font-semibold">
                      Detected {secret_hints.length} Exposed Secret(s) in This Page
                    </div>
                    <div className="flex flex-wrap gap-1.5">
                      {secret_hints.map((h, i) => (
                        <span
                          key={`${h.match_sha256}-${i}`}
                          className="rounded bg-white border border-rose-200 px-2 py-0.5 font-mono text-[11px] text-rose-900"
                        >
                          {h.label}: {h.masked_preview}
                        </span>
                      ))}
                    </div>
                  </>
                ) : (
                  purgeReceipt && (
                    <div className="font-semibold text-emerald-900">
                      Purged secrets via Modb.Erasure receipt{" "}
                      <code className="font-mono">{purgeReceipt.receipt.id}</code> (
                      {purgeReceipt.blocks_redacted} blocks redacted, compacted:{" "}
                      {String(purgeReceipt.receipt.compacted)})
                    </div>
                  )
                )}
              </div>
            </div>
            <div className="flex flex-wrap items-center gap-2 shrink-0">
              {secret_hints.length > 0 && (
                <button
                  type="button"
                  disabled={purgingSecrets}
                  onClick={async () => {
                    setPurgingSecrets(true);
                    setError(null);
                    try {
                      const res = await apiFetch<PurgeSecretResponse>("/api/admin/erasure/purge", {
                        method: "POST",
                        body: JSON.stringify({
                          page_id: page.id,
                          mode: "redact",
                          compact: true,
                          reason: `One-click secret purge from page ${page.id}`,
                        }),
                      });
                      setPurgeReceipt(res);
                      router.reload({
                        only: [
                          "page",
                          "blocks",
                          "anchored_markdown",
                          "yaml_frontmatter",
                          "comments",
                          "page_audit",
                          "secret_hints",
                        ],
                      });
                    } catch (err) {
                      setError(
                        err instanceof ApiError
                          ? err.message
                          : "Only Owner/Admin can purge secrets"
                      );
                    } finally {
                      setPurgingSecrets(false);
                    }
                  }}
                  className="inline-flex items-center gap-1.5 rounded-lg bg-rose-700 px-3 py-1.5 font-medium text-white hover:bg-rose-800 disabled:opacity-50"
                >
                  <Flame className="h-3.5 w-3.5" />
                  {purgingSecrets ? "Purging..." : "Purge Secrets Now"}
                </button>
              )}
              {purgeReceipt && (
                <a
                  href={`/api/admin/erasure/receipts/${encodeURIComponent(purgeReceipt.receipt.id)}/download`}
                  className="inline-flex items-center gap-1 rounded-lg border border-rose-300 bg-white px-2.5 py-1.5 font-medium text-rose-900 hover:bg-rose-100"
                >
                  <Download className="h-3.5 w-3.5" />
                  Receipt JSON
                </a>
              )}
              <Link
                href="/admin"
                className="rounded-lg border border-rose-300 bg-white px-2.5 py-1.5 font-medium text-rose-900 hover:bg-rose-100"
              >
                Secret Purge Console →
              </Link>
            </div>
          </div>
        )}

        {/* Scenario Comparison Strip */}
        {openScenarios.length > 0 && (
          <div className="rounded-xl border border-indigo-200 bg-indigo-50/60 px-4 py-2.5 flex flex-wrap items-center justify-between gap-2 text-xs">
            <div className="flex items-center gap-2 font-medium text-indigo-950">
              <GitBranch className="h-3.5 w-3.5 text-indigo-700" />
              <span>Scenario Lens Overlay:</span>
              <select
                value={activeScenarioId ?? ""}
                onChange={(e) => setActiveScenarioId(e.target.value || null)}
                className="rounded-lg border border-indigo-200 bg-white px-2.5 py-1 text-xs text-indigo-950"
              >
                <option value="">Live Workspace State</option>
                {openScenarios.map((sc) => (
                  <option key={sc.id} value={sc.id}>
                    What-If: {sc.title} ({sc.author_handle})
                  </option>
                ))}
              </select>
            </div>
            {activeScenarioId && (
              <button
                type="button"
                onClick={() => setActiveScenarioId(null)}
                className="text-indigo-700 hover:underline font-medium"
              >
                Reset to Live
              </button>
            )}
          </div>
        )}

        {/* Statamic-Style Blueprint Metadata Bar */}
        <BlueprintBar
          page={page}
          blueprints={blueprints}
          pageBlueprint={pageBlueprint}
          pageMeta={pageMeta}
          yamlFrontmatter={yamlFm}
          databases={databases}
          principals={principals}
          relationTargets={relation_targets}
          onBlueprintCreated={(createdBp) => setBlueprints((prev) => [...prev, createdBp])}
          onMetaSaved={(res) => {
            setPage(res.page);
            setBlocks(res.blocks);
            setAnchoredMd(res.anchored_markdown);
            setMdDraft(res.anchored_markdown);
            setYamlFm(res.yaml_frontmatter);
            setPageBlueprint(res.page_blueprint);
            setPageMeta(res.page_meta);
            router.reload({
              only: [
                "page",
                "blocks",
                "anchored_markdown",
                "yaml_frontmatter",
                "page_blueprint",
                "page_meta",
                "page_audit",
              ],
            });
          }}
        />

        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}

        {/* Lens Content */}
        {lens === "studio" && (
          <BlockEditor
            page={page}
            blocks={blocks}
            databases={databases}
            principals={principals}
            relationTargets={relation_targets}
            resolvedMetrics={metricsMap}
            activeScenarioId={activeScenarioId}
            onBlocksUpdated={(nextBlocks, nextAnchored) => {
              setBlocks(nextBlocks);
              setAnchoredMd(nextAnchored);
              setMdDraft(nextAnchored);
              router.reload({ only: ["page", "yaml_frontmatter", "resolved_metrics", "page_audit"] });
            }}
            onProposalCreated={(p) => setPageProposals((prev) => [p, ...prev])}
            onInspectBlock={(blockId) => setInspectorTarget({ kind: "block", blockId })}
            onInspectRow={(databaseId, rowId, pageId) =>
              setInspectorTarget({ kind: "row", databaseId, rowId, pageId })
            }
            onMetricInvalidated={() => void refreshMetrics(blocks, activeScenarioId)}
          />
        )}

        {lens === "markdown" && (
          <div className="rounded-2xl border border-stone-200 bg-white overflow-hidden">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-stone-200 bg-stone-50 px-4 py-2.5 text-xs">
              <div className="flex items-center gap-2 text-stone-600">
                <FileText className="h-3.5 w-3.5 text-stone-500" />
                <span>
                  Anchored Markdown Source · <strong className="font-mono">v{page.version}</strong>
                </span>
                {mdDirty && (
                  <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-800">
                    Unsaved (⌘S)
                  </span>
                )}
              </div>
              <button
                type="button"
                disabled={mdSaving || !mdDirty}
                onClick={() => void handleSaveMarkdown()}
                className="inline-flex items-center gap-1.5 rounded-lg bg-stone-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
              >
                <Save className="h-3.5 w-3.5" />
                {mdSaving ? "Reconciling..." : "Sync Markdown"}
              </button>
            </div>

            {mdConflict && (
              <div className="border-b border-red-200 bg-red-50 px-4 py-2.5 flex items-center justify-between gap-3 text-xs text-red-900">
                <span>Version conflict: {mdConflict}</span>
                <button
                  type="button"
                  onClick={() => {
                    setMdConflict(null);
                    router.reload();
                  }}
                  className="inline-flex items-center gap-1 rounded-md border border-red-300 bg-white px-2.5 py-1 font-medium text-red-800 hover:bg-red-100"
                >
                  <RefreshCw className="h-3 w-3" />
                  Reload Latest
                </button>
              </div>
            )}

            <textarea
              rows={20}
              value={mdDraft}
              onChange={(e) => setMdDraft(e.target.value)}
              spellCheck={false}
              className="w-full bg-stone-950 text-stone-100 p-5 font-mono text-xs leading-relaxed outline-none resize-y"
            />
          </div>
        )}

        {lens === "patchwork" && (
          <PatchworkLens
            page={page}
            proposals={pageProposals}
            onResolved={() =>
              router.reload({
                only: [
                  "page",
                  "blocks",
                  "anchored_markdown",
                  "yaml_frontmatter",
                  "page_proposals",
                  "resolved_metrics",
                  "open_scenarios",
                  "page_audit",
                ],
              })
            }
          />
        )}

        {lens === "xray" && (
          <XRayLens
            page={page}
            blocks={blocks}
            resolvedMetrics={metricsMap}
            yamlFrontmatter={yamlFm}
            pageAudit={page_audit}
            citationDrifts={citation_drifts}
            taintProvenance={taint_provenance}
            stagingDriftId={stagingDriftId}
            onStageDriftProposal={async (d) => {
              const driftKey = `${d.dependent_block_id}->${d.cited_block_id}`;
              setStagingDriftId(driftKey);
              setError(null);
              try {
                const res = await apiFetch<{ proposal: { id: string } }>(
                  "/api/admin/garden/propose",
                  {
                    method: "POST",
                    body: JSON.stringify({
                      kind: "citation_drift",
                      target_page_id: d.dependent_page_id,
                      target_block_id: d.dependent_block_id,
                      related_page_id: d.cited_page_id,
                      related_block_id: d.cited_block_id,
                      reason: d.summary,
                    }),
                  }
                );
                setLiveNotice(`Staged refresh proposal ${res.proposal.id} in Change Proposals.`);
              } catch (err) {
                setError(err instanceof ApiError ? err.message : "Failed to stage drift proposal");
              } finally {
                setStagingDriftId(null);
              }
            }}
            onInspectBlock={(blockId) => setInspectorTarget({ kind: "block", blockId })}
          />
        )}

        {/* Comments + Attachments */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
            <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
              <MessageSquare className="h-4 w-4 text-stone-500" />
              Comments ({comments.length})
            </div>
            <div className="space-y-2.5 max-h-60 overflow-y-auto">
              {comments.length === 0 && (
                <p className="text-xs text-stone-400">No comments on this document yet.</p>
              )}
              {comments.map((c) => (
                <div key={c.id} className="rounded-lg border border-stone-100 bg-stone-50 p-3">
                  <div className="flex items-center justify-between text-[11px] text-stone-400">
                    <span className="font-mono">{c.author_id}</span>
                    <span>{c.created_at}</span>
                  </div>
                  <p className="mt-1 text-sm text-stone-800">{c.body_markdown}</p>
                </div>
              ))}
            </div>
            <form onSubmit={(e) => void handleCommentSubmit(e)} className="flex gap-2">
              <input
                value={commentBody}
                onChange={(e) => setCommentBody(e.target.value)}
                placeholder="Write a comment (supports @agent mentions)..."
                className="flex-1 rounded-lg border border-stone-200 px-3 py-2 text-xs outline-none focus:border-stone-500"
              />
              <button
                type="submit"
                disabled={commentSaving || !commentBody.trim()}
                className="inline-flex items-center gap-1 rounded-lg bg-stone-900 px-3 py-2 text-xs font-medium text-white disabled:opacity-50"
              >
                <Send className="h-3.5 w-3.5" />
                Post
              </button>
            </form>
          </section>

          <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <Paperclip className="h-4 w-4 text-stone-500" />
                S3 Attachments ({attachments.length})
              </div>
              <label className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-100 cursor-pointer">
                <Upload className="h-3.5 w-3.5" />
                {uploading ? "Uploading..." : "Upload File"}
                <input
                  type="file"
                  className="hidden"
                  disabled={uploading}
                  onChange={(e) => void handleFileUpload(e)}
                />
              </label>
            </div>
            <div className="space-y-2">
              {attachments.length === 0 && (
                <p className="text-xs text-stone-400">
                  Zero binary bytes stored in MoDB; files stream directly via SigV4 presigned S3
                  URLs.
                </p>
              )}
              {attachments.map((att) => (
                <div
                  key={att.id}
                  className="flex items-center justify-between rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs"
                >
                  <div className="min-w-0">
                    <div className="font-medium text-stone-900 truncate">{att.filename}</div>
                    <div className="text-[11px] text-stone-400 font-mono">
                      {att.size_bytes} B · {att.status}
                    </div>
                  </div>
                  <a
                    href={`/api/attachments/${att.id}/download`}
                    className="text-blue-600 hover:underline shrink-0 ml-3"
                  >
                    Download
                  </a>
                </div>
              ))}
            </div>
          </section>
        </div>

        {/* Backlinks & Modb.Vec Semantic Connections */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <Link2 className="h-4 w-4 text-teal-700" />
                Incoming Backlinks &amp; Citations ({explicit_backlinks.length})
              </div>
              <span className="text-[11px] font-mono text-stone-400">ACL-filtered</span>
            </div>
            {explicit_backlinks.length === 0 ? (
              <p className="text-xs text-stone-400">
                No other accessible pages link to or cite this page yet.
              </p>
            ) : (
              <div className="space-y-2 max-h-60 overflow-y-auto">
                {explicit_backlinks.map((bl) => (
                  <Link
                    key={`${bl.source_page_id}-${bl.block_id}`}
                    href={`/p/${bl.source_page_id}#${bl.block_id}`}
                    className="block rounded-lg border border-stone-100 bg-stone-50 p-3 hover:border-teal-300 transition"
                  >
                    <div className="flex items-center justify-between gap-2 text-xs">
                      <span className="font-medium text-stone-900 flex items-center gap-1">
                        {bl.source_title}
                        <ArrowUpRight className="h-3 w-3 text-stone-400" />
                      </span>
                      <span className="rounded-full bg-teal-50 border border-teal-200 px-2 py-0.5 font-mono text-[10px] text-teal-800">
                        {bl.kind}
                      </span>
                    </div>
                    {bl.excerpt && (
                      <p className="mt-1 text-xs text-stone-600 line-clamp-2">{bl.excerpt}</p>
                    )}
                  </Link>
                ))}
              </div>
            )}
          </section>

          <section className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <Sparkles className="h-4 w-4 text-indigo-600" />
                Semantic Backlinks ({semantic_backlinks.length})
              </div>
              <span className="text-[11px] font-mono text-stone-400">Modb.Vec</span>
            </div>
            {semantic_backlinks.length === 0 ? (
              <p className="text-xs text-stone-400">
                Add content to surface semantically related pages via{" "}
                <code className="font-mono">Modb.Vec</code>.
              </p>
            ) : (
              <div className="space-y-2 max-h-60 overflow-y-auto">
                {semantic_backlinks.map((sb) => (
                  <Link
                    key={sb.page_id}
                    href={`/p/${sb.page_id}`}
                    className="block rounded-lg border border-stone-100 bg-stone-50 p-3 hover:border-indigo-300 transition"
                  >
                    <div className="flex items-center justify-between gap-2 text-xs">
                      <span className="font-medium text-stone-900 truncate">{sb.title}</span>
                      <span className="shrink-0 rounded-full bg-indigo-50 border border-indigo-200 px-2 py-0.5 font-mono text-[10px] text-indigo-800">
                        {(sb.similarity * 100).toFixed(0)}% · {sb.vector_backend}
                      </span>
                    </div>
                    {sb.summary && (
                      <p className="mt-1 text-xs text-stone-600 line-clamp-2">{sb.summary}</p>
                    )}
                  </Link>
                ))}
              </div>
            )}
          </section>
        </div>
      </div>

      {/* Right Slide-Over Inspector Drawer */}
      <SlideOverInspector
        target={inspectorTarget}
        databases={databases}
        principals={principals}
        relationTargets={relation_targets}
        onClose={() => setInspectorTarget(null)}
        onRowUpdated={() => {
          void refreshMetrics(blocks, activeScenarioId);
          router.reload({ only: ["resolved_metrics"] });
        }}
      />
    </WorkspaceLayout>
  );
}
