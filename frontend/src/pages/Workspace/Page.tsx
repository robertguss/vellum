import { Link, router } from "@inertiajs/react";
import {
  CheckCircle2,
  Clock,
  FileText,
  MessageSquare,
  Paperclip,
  Send,
  Upload,
} from "lucide-react";
import { useState } from "react";
import BlockEditor from "../../components/BlockEditor";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  Attachment,
  Block,
  Collection,
  Comment,
  DatabaseDef,
  Page,
} from "../../lib/types";

interface PageProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  collection: Collection;
  page: Page;
  blocks: Block[];
  anchored_markdown: string;
  comments: Comment[];
  attachments: Attachment[];
}

async function sha256Hex(file: File): Promise<string> {
  const buf = await file.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export default function PageView({
  collections = [],
  databases = [],
  collection,
  page: initialPage,
  blocks: initialBlocks = [],
  anchored_markdown: initialAnchored = "",
  comments: initialComments = [],
  attachments: initialAttachments = [],
}: PageProps) {
  const [page, setPage] = useState<Page>(initialPage);
  const [blocks, setBlocks] = useState<Block[]>(initialBlocks);
  const [anchoredMd, setAnchoredMd] = useState<string>(initialAnchored);
  const [comments, setComments] = useState<Comment[]>(initialComments);
  const [attachments, setAttachments] = useState<Attachment[]>(initialAttachments);
  const [tab, setTab] = useState<"editor" | "markdown">("editor");
  const [verifying, setVerifying] = useState(false);
  const [commentBody, setCommentBody] = useState("");
  const [commentSaving, setCommentSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
    >
      <div className="space-y-6">
        {/* Breadcrumb + Freshness Banner */}
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
              <h1 className="mt-1 text-2xl font-semibold text-stone-950">{page.title}</h1>
            </div>

            <div className="flex items-center gap-2">
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

            <div className="flex items-center rounded-lg border border-stone-200 p-0.5 bg-stone-50">
              <button
                type="button"
                onClick={() => setTab("editor")}
                className={`rounded-md px-3 py-1 text-xs font-medium transition ${
                  tab === "editor" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                Blocks &amp; TipTap
              </button>
              <button
                type="button"
                onClick={() => setTab("markdown")}
                className={`inline-flex items-center gap-1 rounded-md px-3 py-1 text-xs font-medium transition ${
                  tab === "markdown" ? "bg-white text-stone-900 shadow-2xs" : "text-stone-500"
                }`}
              >
                <FileText className="h-3 w-3" />
                Anchored Markdown
              </button>
            </div>
          </div>
        </div>

        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}

        {tab === "editor" ? (
          <BlockEditor
            page={page}
            blocks={blocks}
            onBlocksUpdated={(nextBlocks, nextAnchored) => {
              setBlocks(nextBlocks);
              setAnchoredMd(nextAnchored);
              router.reload({ only: ["page"] });
            }}
          />
        ) : (
          <div className="rounded-2xl border border-stone-200 bg-stone-950 text-stone-100 p-5 overflow-x-auto">
            <pre className="text-xs font-mono leading-relaxed whitespace-pre-wrap">
              {anchoredMd}
            </pre>
          </div>
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
            <form onSubmit={handleCommentSubmit} className="flex gap-2">
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
      </div>
    </WorkspaceLayout>
  );
}
