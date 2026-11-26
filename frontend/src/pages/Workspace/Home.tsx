import { Link, router } from "@inertiajs/react";
import { BookOpen, Clock, Database as DbIcon, FilePlus, Plus, ShieldCheck } from "lucide-react";
import { useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type { AuditFeedItem, Collection, DatabaseDef, Page } from "../../lib/types";

interface HomeProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  pages: Page[];
  audit_feed: AuditFeedItem[];
}

export default function Home({
  collections = [],
  databases = [],
  pages = [],
  audit_feed = [],
}: HomeProps) {
  const [title, setTitle] = useState("");
  const [colId, setColId] = useState(collections[0]?.id ?? "col_general");
  const [markdown, setMarkdown] = useState("# Overview\n\nStart documenting here.");
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [dbTitle, setDbTitle] = useState("");
  const [creatingDb, setCreatingDb] = useState(false);

  async function handleCreatePage(e: React.FormEvent) {
    e.preventDefault();
    if (!title.trim()) return;
    setCreating(true);
    setError(null);
    try {
      const res = await apiFetch<{ page: Page }>("/api/pages", {
        method: "POST",
        body: JSON.stringify({
          collection_id: colId || collections[0]?.id || "col_general",
          parent_page_id: null,
          title: title.trim(),
          markdown,
          icon: null,
          freshness_ttl_days: null,
          reason: "created from workspace home",
        }),
      });
      router.visit(`/p/${res.page.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create page");
    } finally {
      setCreating(false);
    }
  }

  async function handleQuickDatabase(e: React.FormEvent) {
    e.preventDefault();
    if (!dbTitle.trim()) return;
    setCreatingDb(true);
    setError(null);
    try {
      const res = await apiFetch<{ database: DatabaseDef }>("/api/databases", {
        method: "POST",
        body: JSON.stringify({
          collection_id: colId || collections[0]?.id || "col_general",
          parent_page_id: null,
          title: dbTitle.trim(),
          description: "Relational MoDB workspace database",
          properties: [
            { id: "title", name: "Title", kind: "title", required: true, sort_order: "i" },
            {
              id: "status",
              name: "Status",
              kind: {
                select: {
                  options: [
                    { id: "todo", label: "To Do", color: "gray" },
                    { id: "doing", label: "In Progress", color: "blue" },
                    { id: "done", label: "Done", color: "green" },
                  ],
                },
              },
              required: false,
              sort_order: "j",
            },
            {
              id: "due_date",
              name: "Due Date",
              kind: { date_prop: { include_time: false } },
              required: false,
              sort_order: "k",
            },
          ],
        }),
      });
      router.visit(`/d/${res.database.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create database");
    } finally {
      setCreatingDb(false);
    }
  }

  return (
    <WorkspaceLayout title="Workspace Overview" collections={collections} databases={databases}>
      <div className="space-y-8">
        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}

        {/* Quick Create Cards */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <form
            onSubmit={handleCreatePage}
            className="lg:col-span-2 rounded-2xl border border-stone-200 bg-white p-5 shadow-2xs space-y-3"
          >
            <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
              <FilePlus className="h-4 w-4 text-blue-600" />
              New Document Page
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <input
                required
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="Page title..."
                className="sm:col-span-2 rounded-lg border border-stone-200 px-3 py-2 text-sm outline-none focus:border-stone-500"
              />
              <select
                value={colId}
                onChange={(e) => setColId(e.target.value)}
                className="rounded-lg border border-stone-200 px-2.5 py-2 text-xs bg-white"
              >
                {collections.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            </div>
            <textarea
              rows={2}
              value={markdown}
              onChange={(e) => setMarkdown(e.target.value)}
              className="w-full rounded-lg border border-stone-200 px-3 py-2 text-xs font-mono outline-none focus:border-stone-500"
            />
            <div className="flex justify-end">
              <button
                type="submit"
                disabled={creating || !title.trim()}
                className="inline-flex items-center gap-1.5 rounded-lg bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
              >
                <Plus className="h-3.5 w-3.5" />
                {creating ? "Creating..." : "Create Page"}
              </button>
            </div>
          </form>

          <form
            onSubmit={handleQuickDatabase}
            className="rounded-2xl border border-stone-200 bg-white p-5 shadow-2xs flex flex-col justify-between space-y-3"
          >
            <div className="space-y-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <DbIcon className="h-4 w-4 text-teal-700" />
                New Relational Database
              </div>
              <p className="text-xs text-stone-500">
                Provisions a typed Table, Kanban Board, and Calendar database inside MoDB.
              </p>
              <input
                required
                value={dbTitle}
                onChange={(e) => setDbTitle(e.target.value)}
                placeholder="e.g. Incident Tracker"
                className="w-full rounded-lg border border-stone-200 px-3 py-2 text-sm outline-none focus:border-stone-500"
              />
            </div>
            <button
              type="submit"
              disabled={creatingDb || !dbTitle.trim()}
              className="w-full rounded-lg border border-stone-300 bg-stone-50 px-3 py-2 text-xs font-medium text-stone-900 hover:bg-stone-100 disabled:opacity-50"
            >
              {creatingDb ? "Creating DB..." : "Create Database"}
            </button>
          </form>
        </div>

        {/* Pages + Databases */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-3">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-stone-500">
              Recent Pages ({pages.length})
            </h2>
            <div className="rounded-2xl border border-stone-200 bg-white divide-y divide-stone-100">
              {pages.length === 0 && (
                <div className="p-6 text-sm text-stone-500">
                  No pages yet. Create one above or import a Notion workspace from Agents &amp; Console.
                </div>
              )}
              {pages.map((p) => (
                <Link
                  key={p.id}
                  href={`/p/${p.id}`}
                  className="flex items-center justify-between px-5 py-3.5 hover:bg-stone-50 transition"
                >
                  <div className="min-w-0">
                    <div className="text-sm font-medium text-stone-900 truncate">{p.title}</div>
                    <div className="text-xs text-stone-400 mt-0.5 flex items-center gap-2">
                      <span className="font-mono">{p.id}</span>
                      <span>·</span>
                      <span>v{p.version}</span>
                    </div>
                  </div>
                  <div className="flex items-center gap-2 shrink-0 text-xs">
                    {p.verified_at ? (
                      <span className="inline-flex items-center gap-1 rounded-full bg-emerald-50 px-2.5 py-0.5 text-emerald-700 font-medium">
                        <ShieldCheck className="h-3 w-3" />
                        Verified
                      </span>
                    ) : (
                      <span className="inline-flex items-center gap-1 rounded-full bg-stone-100 px-2.5 py-0.5 text-stone-500">
                        <Clock className="h-3 w-3" />
                        Unverified
                      </span>
                    )}
                  </div>
                </Link>
              ))}
            </div>
          </div>

          {/* Ledger Audit Feed */}
          <div className="space-y-3">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-stone-500">
              Hash-Chained Audit Tail
            </h2>
            <div className="rounded-2xl border border-stone-200 bg-white divide-y divide-stone-100 max-h-[420px] overflow-y-auto">
              {audit_feed.length === 0 && (
                <div className="p-5 text-xs text-stone-500">No ledger transactions yet.</div>
              )}
              {audit_feed.map((ev) => (
                <div key={ev.seq} className="px-4 py-3 space-y-1">
                  <div className="flex items-center justify-between text-xs">
                    <span className="font-medium text-stone-900">{ev.actor_name}</span>
                    <span className="font-mono text-[10px] text-stone-400">#{ev.seq}</span>
                  </div>
                  <div className="text-xs text-stone-600">{ev.summary}</div>
                  <div className="text-[11px] text-stone-400 truncate" title={ev.reason}>
                    {ev.action} — {ev.reason}
                  </div>
                </div>
              ))}
            </div>

            {databases.length > 0 && (
              <div className="rounded-2xl border border-stone-200 bg-white p-4 space-y-2">
                <div className="flex items-center gap-2 text-xs font-semibold text-stone-700">
                  <BookOpen className="h-3.5 w-3.5" />
                  Quick Databases
                </div>
                <div className="space-y-1">
                  {databases.map((db) => (
                    <Link
                      key={db.id}
                      href={`/d/${db.id}`}
                      className="block rounded-lg px-2.5 py-1.5 text-xs text-blue-700 hover:bg-blue-50"
                    >
                      {db.title} ({db.properties.length} columns)
                    </Link>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </WorkspaceLayout>
  );
}
