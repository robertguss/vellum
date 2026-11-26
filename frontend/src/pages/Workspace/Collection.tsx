import { Link, router } from "@inertiajs/react";
import { Database as DbIcon, FilePlus, FileText, Plus, ShieldCheck } from "lucide-react";
import { useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type { Collection, DatabaseDef, Page } from "../../lib/types";

interface CollectionProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  collection: Collection;
  pages: Page[];
}

export default function CollectionView({
  collections = [],
  databases = [],
  collection,
  pages = [],
}: CollectionProps) {
  const [title, setTitle] = useState("");
  const [markdown, setMarkdown] = useState("# New Document\n\n");
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const colDatabases = databases.filter((d) => d.collection_id === collection.id);

  async function handleCreatePage(e: React.FormEvent) {
    e.preventDefault();
    if (!title.trim()) return;
    setCreating(true);
    setError(null);
    try {
      const res = await apiFetch<{ page: Page }>("/api/pages", {
        method: "POST",
        body: JSON.stringify({
          collection_id: collection.id,
          parent_page_id: null,
          title: title.trim(),
          markdown,
          icon: null,
          freshness_ttl_days: null,
          reason: `created page inside ${collection.slug}`,
        }),
      });
      router.visit(`/p/${res.page.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not create page");
    } finally {
      setCreating(false);
    }
  }

  return (
    <WorkspaceLayout
      title={collection.name}
      collections={collections}
      databases={databases}
      activeCollectionSlug={collection.slug}
      currentCollectionId={collection.id}
    >
      <div className="space-y-6">
        <div className="rounded-2xl border border-stone-200 bg-white p-6 flex flex-wrap items-start justify-between gap-4">
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-semibold text-stone-950">{collection.name}</h1>
              <span className="rounded-full bg-stone-100 px-2.5 py-0.5 text-[11px] font-mono text-stone-600">
                /{collection.slug}
              </span>
            </div>
            <p className="text-sm text-stone-500">
              {collection.description || "Vellum knowledge collection."}
            </p>
          </div>
          <div className="flex items-center gap-2 text-xs">
            <span className="rounded-full border border-stone-200 bg-stone-50 px-3 py-1 font-medium text-stone-700">
              Policy: {collection.write_policy}
            </span>
            {collection.freshness_ttl_days && (
              <span className="rounded-full border border-stone-200 bg-stone-50 px-3 py-1 text-stone-600">
                TTL: {collection.freshness_ttl_days}d
              </span>
            )}
          </div>
        </div>

        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}

        <form
          onSubmit={handleCreatePage}
          className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3"
        >
          <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
            <FilePlus className="h-4 w-4 text-blue-600" />
            Add Page to {collection.name}
          </div>
          <div className="flex flex-wrap gap-3">
            <input
              required
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Document title..."
              className="flex-1 min-w-[220px] rounded-lg border border-stone-200 px-3 py-2 text-sm outline-none focus:border-stone-500"
            />
            <button
              type="submit"
              disabled={creating || !title.trim()}
              className="inline-flex items-center gap-1.5 rounded-lg bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
            >
              <Plus className="h-3.5 w-3.5" />
              Create Page
            </button>
          </div>
          <textarea
            rows={2}
            value={markdown}
            onChange={(e) => setMarkdown(e.target.value)}
            className="w-full rounded-lg border border-stone-200 px-3 py-2 text-xs font-mono outline-none focus:border-stone-500"
          />
        </form>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-2.5">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-stone-500">
              Documents ({pages.length})
            </h2>
            <div className="rounded-2xl border border-stone-200 bg-white divide-y divide-stone-100">
              {pages.length === 0 && (
                <div className="p-6 text-sm text-stone-500">No documents in this collection yet.</div>
              )}
              {pages.map((p) => (
                <Link
                  key={p.id}
                  href={`/p/${p.id}`}
                  className="flex items-center justify-between px-5 py-3.5 hover:bg-stone-50 transition"
                >
                  <span className="flex items-center gap-2.5 text-sm font-medium text-stone-900">
                    <FileText className="h-4 w-4 text-stone-400" />
                    {p.title}
                  </span>
                  <span className="flex items-center gap-2 text-xs text-stone-400">
                    {p.verified_at && <ShieldCheck className="h-3.5 w-3.5 text-emerald-600" />}
                    <span className="font-mono">v{p.version}</span>
                  </span>
                </Link>
              ))}
            </div>
          </div>

          <div className="space-y-2.5">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-stone-500">
              Databases ({colDatabases.length})
            </h2>
            <div className="rounded-2xl border border-stone-200 bg-white divide-y divide-stone-100">
              {colDatabases.length === 0 && (
                <div className="p-5 text-xs text-stone-500">No databases in this collection.</div>
              )}
              {colDatabases.map((db) => (
                <Link
                  key={db.id}
                  href={`/d/${db.id}`}
                  className="flex items-center gap-2.5 px-4 py-3 text-sm font-medium text-blue-700 hover:bg-blue-50/60"
                >
                  <DbIcon className="h-4 w-4 shrink-0" />
                  <span className="truncate">{db.title}</span>
                </Link>
              ))}
            </div>
          </div>
        </div>
      </div>
    </WorkspaceLayout>
  );
}
