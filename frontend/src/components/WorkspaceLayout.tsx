import { Head, Link, router, usePage } from "@inertiajs/react";
import {
  Bot,
  BookOpen,
  ChevronRight,
  Database as DbIcon,
  FolderPlus,
  GitPullRequest,
  Home,
  LogOut,
  Search,
  Settings,
  Sparkles,
  X,
} from "lucide-react";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { ApiError, apiFetch, streamAskWorkspace } from "../lib/api";
import { useRealtimeEvents, type RealtimeScope } from "../lib/useRealtimeEvents";
import type {
  AiCitation,
  ClaimRecord,
  Collection,
  CollectionWritePolicy,
  DatabaseDef,
  SearchMode,
  SearchResponse,
  SearchResultItem,
  SharedPageProps,
} from "../lib/types";

interface WorkspaceLayoutProps {
  title: string;
  collections: Collection[];
  databases?: DatabaseDef[];
  activeCollectionSlug?: string;
  activeDatabaseId?: string;
  currentCollectionId?: string | null;
  realtimeScope?: RealtimeScope;
  onRealtimeEvent?: (eventName: string, data: Record<string, unknown>) => void;
  onClaimsChange?: (claims: ClaimRecord[]) => void;
  children: ReactNode;
}

export default function WorkspaceLayout({
  title,
  collections,
  databases = [],
  activeCollectionSlug,
  activeDatabaseId,
  currentCollectionId = null,
  realtimeScope,
  onRealtimeEvent,
  onClaimsChange,
  children,
}: WorkspaceLayoutProps) {
  const { auth, flash } = usePage<SharedPageProps>().props;
  const effectiveScope: RealtimeScope | undefined =
    realtimeScope ?? (currentCollectionId ? { collectionId: currentCollectionId } : undefined);
  const { connectionState, claims } = useRealtimeEvents({
    enabled: Boolean(auth),
    scope: effectiveScope,
    onEvent: onRealtimeEvent,
  });

  useEffect(() => {
    onClaimsChange?.(claims);
  }, [claims, onClaimsChange]);

  // Cmd+K Hybrid (BM25 + Modb.Vec) search modal
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchMode, setSearchMode] = useState<SearchMode>("hybrid");
  const [searchBackend, setSearchBackend] = useState<"neural" | "sketch" | "none" | null>(null);
  const [searchResults, setSearchResults] = useState<SearchResultItem[]>([]);
  const [searchLoading, setSearchLoading] = useState(false);

  // Ask Workspace AI SSE drawer
  const [aiOpen, setAiOpen] = useState(false);
  const [aiQuestion, setAiQuestion] = useState("");
  const [aiScoped, setAiScoped] = useState(false);
  const [aiAnswer, setAiAnswer] = useState("");
  const [aiModel, setAiModel] = useState("");
  const [aiCitations, setAiCitations] = useState<AiCitation[]>([]);
  const [aiError, setAiError] = useState<string | null>(null);
  const [aiStreaming, setAiStreaming] = useState(false);
  const aiAbortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    return () => {
      aiAbortRef.current?.abort();
    };
  }, []);

  function closeAiDrawer() {
    aiAbortRef.current?.abort();
    aiAbortRef.current = null;
    setAiOpen(false);
  }

  // Create collection modal
  const [newColOpen, setNewColOpen] = useState(false);
  const [colName, setColName] = useState("");
  const [colSlug, setColSlug] = useState("");
  const [colPolicy, setColPolicy] = useState<CollectionWritePolicy>("direct_with_audit");
  const [colTtl, setColTtl] = useState("90");
  const [colError, setColError] = useState<string | null>(null);
  const [colSaving, setColSaving] = useState(false);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setSearchOpen((prev) => !prev);
      }
      if (e.key === "Escape") {
        setSearchOpen(false);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    if (!searchOpen) return;
    const trimmed = searchQuery.trim();
    if (!trimmed) {
      setSearchResults([]);
      setSearchBackend(null);
      return;
    }
    const timer = window.setTimeout(async () => {
      setSearchLoading(true);
      try {
        const res = await apiFetch<SearchResponse>(
          `/api/search?q=${encodeURIComponent(trimmed)}&limit=15&mode=${searchMode}`
        );
        setSearchResults(res.results ?? []);
        setSearchBackend(res.vector_backend ?? null);
      } catch {
        setSearchResults([]);
        setSearchBackend(null);
      } finally {
        setSearchLoading(false);
      }
    }, 180);
    return () => window.clearTimeout(timer);
  }, [searchOpen, searchQuery, searchMode]);

  async function handleAskAi(e: React.FormEvent) {
    e.preventDefault();
    const q = aiQuestion.trim();
    if (!q || aiStreaming) return;
    aiAbortRef.current?.abort();
    const controller = new AbortController();
    aiAbortRef.current = controller;
    setAiStreaming(true);
    setAiAnswer("");
    setAiModel("");
    setAiCitations([]);
    setAiError(null);
    try {
      await streamAskWorkspace(
        {
          question: q,
          collection_id: aiScoped ? currentCollectionId : null,
          max_sources: 5,
        },
        {
          onCitation: (c) => setAiCitations((prev) => [...prev, c]),
          onToken: (delta) => setAiAnswer((prev) => prev + delta),
          onDone: (model) => setAiModel(model),
        },
        controller.signal
      );
    } catch (err) {
      if (err instanceof DOMException && err.name === "AbortError") {
        return;
      }
      setAiError(err instanceof ApiError ? err.message : "Failed to query Ask Workspace");
    } finally {
      if (aiAbortRef.current === controller) {
        aiAbortRef.current = null;
      }
      setAiStreaming(false);
    }
  }

  async function handleCreateCollection(e: React.FormEvent) {
    e.preventDefault();
    setColError(null);
    setColSaving(true);
    try {
      const slug =
        colSlug.trim() ||
        colName
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-|-$/g, "");
      const ttlNum = Number.parseInt(colTtl, 10);
      const created = await apiFetch<Collection>("/api/collections", {
        method: "POST",
        body: JSON.stringify({
          slug,
          name: colName.trim(),
          description: null,
          icon: null,
          write_policy: colPolicy,
          freshness_ttl_days: Number.isFinite(ttlNum) && ttlNum > 0 ? ttlNum : null,
        }),
      });
      setNewColOpen(false);
      setColName("");
      setColSlug("");
      router.visit(`/c/${created.slug}`);
    } catch (err) {
      setColError(err instanceof ApiError ? err.message : "Could not create collection");
    } finally {
      setColSaving(false);
    }
  }

  return (
    <>
      <Head title={`${title} — Vellum`} />
      <div className="min-h-screen flex bg-[#faf9f6] text-stone-900">
        {/* Sidebar */}
        <aside className="w-64 shrink-0 border-r border-stone-200 bg-[#f5f3ee] flex flex-col justify-between">
          <div className="p-4 space-y-6 overflow-y-auto">
            <div className="flex items-center justify-between px-1">
              <Link
                href="/"
                className="flex items-center gap-2 font-semibold text-base tracking-tight text-stone-950"
              >
                <span className="h-6 w-6 rounded-md bg-stone-900 text-white grid place-items-center text-xs font-bold">
                  V
                </span>
                Vellum
              </Link>
              <span className="text-[11px] font-mono uppercase tracking-wider text-stone-500">
                MoDB
              </span>
            </div>

            <nav className="space-y-1 text-sm">
              <Link
                href="/"
                className="flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-stone-700 hover:bg-stone-200/70 transition"
              >
                <Home className="h-4 w-4 text-stone-500" />
                Workspace
              </Link>
              <Link
                href="/proposals"
                className="flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-stone-700 hover:bg-stone-200/70 transition"
              >
                <GitPullRequest className="h-4 w-4 text-teal-700" />
                Change Proposals
              </Link>
              <Link
                href="/admin"
                className="flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-stone-700 hover:bg-stone-200/70 transition"
              >
                <Settings className="h-4 w-4 text-stone-500" />
                Agents &amp; Console
              </Link>
            </nav>

            <div>
              <div className="flex items-center justify-between px-2 mb-1.5">
                <span className="text-[11px] font-semibold uppercase tracking-wider text-stone-500">
                  Collections
                </span>
                <button
                  type="button"
                  onClick={() => setNewColOpen(true)}
                  title="New collection"
                  className="text-stone-500 hover:text-stone-900 p-0.5 rounded"
                >
                  <FolderPlus className="h-3.5 w-3.5" />
                </button>
              </div>
              <div className="space-y-0.5 text-sm">
                {collections.map((c) => {
                  const active = c.slug === activeCollectionSlug;
                  return (
                    <Link
                      key={c.id}
                      href={`/c/${c.slug}`}
                      className={`flex items-center justify-between rounded-lg px-2.5 py-1.5 transition ${
                        active
                          ? "bg-white text-stone-950 font-medium shadow-xs"
                          : "text-stone-700 hover:bg-stone-200/60"
                      }`}
                    >
                      <span className="flex items-center gap-2 truncate">
                        <BookOpen className="h-3.5 w-3.5 text-stone-400 shrink-0" />
                        <span className="truncate">{c.name}</span>
                      </span>
                      {c.write_policy !== "direct_with_audit" && (
                        <span
                          title={c.write_policy}
                          className="text-[10px] rounded bg-amber-100 text-amber-800 px-1.5 py-0.5 font-medium shrink-0"
                        >
                          PR
                        </span>
                      )}
                    </Link>
                  );
                })}
              </div>
            </div>

            {databases.length > 0 && (
              <div>
                <div className="px-2 mb-1.5">
                  <span className="text-[11px] font-semibold uppercase tracking-wider text-stone-500">
                    Databases
                  </span>
                </div>
                <div className="space-y-0.5 text-sm">
                  {databases.map((db) => {
                    const active = db.id === activeDatabaseId;
                    return (
                      <Link
                        key={db.id}
                        href={`/d/${db.id}`}
                        className={`flex items-center gap-2 rounded-lg px-2.5 py-1.5 transition ${
                          active
                            ? "bg-white text-stone-950 font-medium shadow-xs"
                            : "text-stone-700 hover:bg-stone-200/60"
                        }`}
                      >
                        <DbIcon className="h-3.5 w-3.5 text-blue-600 shrink-0" />
                        <span className="truncate">{db.title}</span>
                      </Link>
                    );
                  })}
                </div>
              </div>
            )}
          </div>

          {auth && (
            <div className="border-t border-stone-200 p-3 flex items-center justify-between gap-2 bg-[#efede6]">
              <div className="min-w-0">
                <div className="text-xs font-medium text-stone-900 truncate">
                  {auth.display_name}
                </div>
                <div className="text-[11px] text-stone-500 truncate">
                  {auth.handle} · {auth.role}
                </div>
              </div>
              <button
                type="button"
                onClick={() => router.post("/logout")}
                title="Sign out"
                className="rounded-lg p-1.5 text-stone-500 hover:text-stone-900 hover:bg-stone-200/70 transition"
              >
                <LogOut className="h-4 w-4" />
              </button>
            </div>
          )}
        </aside>

        {/* Main area */}
        <div className="flex-1 flex flex-col min-w-0">
          <header className="h-14 border-b border-stone-200 bg-white/80 backdrop-blur px-6 flex items-center justify-between gap-4 sticky top-0 z-20">
            <div className="flex items-center gap-2 text-sm text-stone-500 min-w-0">
              <span className="font-medium text-stone-900 truncate">{title}</span>
            </div>
            <div className="flex items-center gap-2">
              {auth && (
                <span
                  data-testid="sse-status"
                  title={
                    connectionState === "live"
                      ? "Streaming live updates via Mo SSE"
                      : "Reconnecting to live SSE stream"
                  }
                  className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium ${
                    connectionState === "live"
                      ? "border-emerald-200 bg-emerald-50 text-emerald-700"
                      : "border-amber-200 bg-amber-50 text-amber-700"
                  }`}
                >
                  <span
                    className={`h-1.5 w-1.5 rounded-full ${
                      connectionState === "live" ? "bg-emerald-500" : "bg-amber-500 animate-pulse"
                    }`}
                  />
                  {connectionState === "live" ? "Live" : "Syncing"}
                </span>
              )}
              <button
                type="button"
                onClick={() => setSearchOpen(true)}
                className="inline-flex items-center gap-2 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-xs text-stone-600 hover:bg-stone-100 transition"
              >
                <Search className="h-3.5 w-3.5" />
                <span>Search</span>
                <kbd className="rounded bg-white border border-stone-200 px-1 py-0.5 font-mono text-[10px] text-stone-400">
                  ⌘K
                </kbd>
              </button>
              <button
                type="button"
                onClick={() => setAiOpen(true)}
                className="inline-flex items-center gap-1.5 rounded-lg bg-teal-700 px-3 py-1.5 text-xs font-medium text-white hover:bg-teal-800 transition"
              >
                <Sparkles className="h-3.5 w-3.5" />
                Ask AI
              </button>
            </div>
          </header>

          {(flash?.notice || flash?.alert || flash?.error) && (
            <div className="px-6 pt-4">
              {(flash.alert || flash.error) && (
                <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
                  {flash.alert || flash.error}
                </div>
              )}
              {flash.notice && (
                <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-sm text-emerald-800">
                  {flash.notice}
                </div>
              )}
            </div>
          )}

          <main className="flex-1 p-6 max-w-6xl w-full mx-auto">{children}</main>
        </div>
      </div>

      {/* Cmd+K Search Modal */}
      {searchOpen && (
        <div className="fixed inset-0 z-50 bg-stone-950/40 backdrop-blur-xs flex items-start justify-center pt-24 px-4">
          <div className="w-full max-w-xl rounded-2xl border border-stone-200 bg-white shadow-xl overflow-hidden">
            <div className="flex items-center gap-3 border-b border-stone-200 px-4 py-3">
              <Search className="h-4 w-4 text-stone-400" />
              <input
                autoFocus
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search pages & database rows (Hybrid RRF + BM25)..."
                className="flex-1 text-sm outline-none bg-transparent"
              />
              <button
                type="button"
                onClick={() => setSearchOpen(false)}
                className="text-stone-400 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <div className="flex items-center justify-between gap-2 border-b border-stone-100 bg-stone-50/70 px-4 py-2">
              <div className="inline-flex items-center rounded-lg border border-stone-200 bg-white p-0.5 text-[11px] font-medium">
                {(
                  [
                    ["hybrid", "Hybrid"],
                    ["bm25", "Keyword"],
                    ["semantic", "Semantic"],
                  ] as const
                ).map(([modeVal, label]) => (
                  <button
                    key={modeVal}
                    type="button"
                    onClick={() => setSearchMode(modeVal)}
                    className={`rounded-md px-2.5 py-0.5 transition ${
                      searchMode === modeVal
                        ? "bg-stone-900 text-white"
                        : "text-stone-600 hover:text-stone-900"
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </div>
              {searchBackend && (
                <span className="rounded-full border border-stone-200 bg-white px-2 py-0.5 font-mono text-[10px] text-stone-500">
                  {searchBackend === "neural"
                    ? "Neural Vec"
                    : searchBackend === "sketch"
                      ? "Sketch Vec"
                      : "BM25 Only"}
                </span>
              )}
            </div>
            <div className="max-h-80 overflow-y-auto divide-y divide-stone-100">
              {searchLoading && (
                <div className="px-4 py-6 text-center text-xs text-stone-400">
                  Searching MoDB index...
                </div>
              )}
              {!searchLoading && searchQuery.trim() && searchResults.length === 0 && (
                <div className="px-4 py-6 text-center text-xs text-stone-500">
                  No permitted workspace matches found.
                </div>
              )}
              {searchResults.map((hit) => {
                const hasFts = hit.fts_rank !== null && hit.fts_rank !== undefined;
                const hasVec = hit.vec_rank !== null && hit.vec_rank !== undefined;
                const matchBadge =
                  hasFts && hasVec
                    ? { label: "Hybrid", cls: "bg-teal-50 text-teal-800 border-teal-200" }
                    : hasVec
                      ? { label: "Semantic", cls: "bg-indigo-50 text-indigo-800 border-indigo-200" }
                      : { label: "BM25", cls: "bg-stone-100 text-stone-700 border-stone-200" };
                return (
                  <button
                    key={hit.page_id}
                    type="button"
                    onClick={() => {
                      setSearchOpen(false);
                      router.visit(`/p/${hit.page_id}`);
                    }}
                    className="w-full text-left px-4 py-3 hover:bg-stone-50 flex items-center justify-between gap-4 transition"
                  >
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="text-sm font-medium text-stone-900 truncate">
                          {hit.title}
                        </span>
                        <span
                          className={`shrink-0 rounded border px-1.5 py-0.5 text-[10px] font-medium ${matchBadge.cls}`}
                        >
                          {matchBadge.label}
                        </span>
                      </div>
                      <div className="text-xs text-stone-500 mt-0.5 flex flex-wrap items-center gap-x-2">
                        {hit.matched_terms.length > 0 && (
                          <span>
                            Matched: {hit.matched_terms.join(", ")} · {hit.matched_fields.join(", ")}
                          </span>
                        )}
                        {hit.matched_terms.length === 0 && hasVec && (
                          <span>Semantic similarity match</span>
                        )}
                        {typeof hit.vec_score === "number" && (
                          <span className="font-mono text-[11px] text-stone-400">
                            cos {hit.vec_score.toFixed(2)}
                          </span>
                        )}
                      </div>
                    </div>
                    <ChevronRight className="h-4 w-4 text-stone-400 shrink-0" />
                  </button>
                );
              })}
            </div>
          </div>
        </div>
      )}

      {/* Ask Workspace AI Drawer */}
      {aiOpen && (
        <div className="fixed inset-y-0 right-0 z-50 w-full max-w-md border-l border-stone-200 bg-white shadow-2xl flex flex-col">
          <div className="flex items-center justify-between border-b border-stone-200 px-5 py-4">
            <div className="flex items-center gap-2 font-semibold text-sm text-stone-900">
              <Bot className="h-4 w-4 text-teal-700" />
              Ask Workspace (Grant-Filtered RAG)
            </div>
            <button
              type="button"
              onClick={closeAiDrawer}
              className="text-stone-400 hover:text-stone-700"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
          <div className="flex-1 overflow-y-auto p-5 space-y-4">
            <form onSubmit={handleAskAi} className="space-y-3">
              <textarea
                rows={3}
                value={aiQuestion}
                onChange={(e) => setAiQuestion(e.target.value)}
                placeholder="Ask a question answered strictly from pages you can access..."
                className="w-full rounded-xl border border-stone-200 p-3 text-sm focus:border-teal-600 outline-none"
              />
              <div className="flex items-center justify-between gap-2">
                {currentCollectionId ? (
                  <label className="flex items-center gap-2 text-xs text-stone-600">
                    <input
                      type="checkbox"
                      checked={aiScoped}
                      onChange={(e) => setAiScoped(e.target.checked)}
                    />
                    Current collection only
                  </label>
                ) : (
                  <span className="text-xs text-stone-400">Across permitted collections</span>
                )}
                <div className="flex items-center gap-2">
                  {aiStreaming && (
                    <button
                      type="button"
                      onClick={() => aiAbortRef.current?.abort()}
                      className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-600 hover:bg-stone-50 transition"
                    >
                      Stop
                    </button>
                  )}
                  <button
                    type="submit"
                    disabled={aiStreaming || !aiQuestion.trim()}
                    className="rounded-lg bg-teal-700 px-3.5 py-1.5 text-xs font-medium text-white disabled:opacity-50 hover:bg-teal-800 transition"
                  >
                    {aiStreaming ? "Streaming..." : "Ask"}
                  </button>
                </div>
              </div>
            </form>

            {aiError && (
              <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
                {aiError}
              </div>
            )}

            {(aiAnswer || aiCitations.length > 0) && (
              <div className="space-y-4 pt-2 border-t border-stone-100">
                {aiAnswer && (
                  <div className="rounded-xl bg-stone-50 border border-stone-200 p-4 text-sm leading-relaxed text-stone-800 whitespace-pre-wrap">
                    {aiAnswer}
                    {aiModel && (
                      <div className="mt-2 text-[11px] text-stone-400 font-mono">
                        Model: {aiModel}
                      </div>
                    )}
                  </div>
                )}
                {aiCitations.length > 0 && (
                  <div className="space-y-2">
                    <div className="text-xs font-semibold uppercase tracking-wider text-stone-500">
                      Cited Sources
                    </div>
                    {aiCitations.map((c, idx) => (
                      <Link
                        key={`${c.page_id}-${c.block_id}-${idx}`}
                        href={`/p/${c.page_id}#${c.block_id}`}
                        onClick={() => setAiOpen(false)}
                        className="block rounded-lg border border-stone-200 p-2.5 hover:bg-stone-50 transition"
                      >
                        <div className="text-xs font-medium text-blue-700">
                          [{c.title} §{c.block_id}]
                        </div>
                        <div className="text-xs text-stone-500 mt-1 line-clamp-2">
                          {c.excerpt}
                        </div>
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      )}

      {/* New Collection Modal */}
      {newColOpen && (
        <div className="fixed inset-0 z-50 bg-stone-950/40 backdrop-blur-xs flex items-center justify-center p-4">
          <form
            onSubmit={handleCreateCollection}
            className="w-full max-w-md rounded-2xl border border-stone-200 bg-white p-6 shadow-xl space-y-4"
          >
            <div className="flex items-center justify-between">
              <h2 className="text-base font-semibold text-stone-900">New Collection</h2>
              <button
                type="button"
                onClick={() => setNewColOpen(false)}
                className="text-stone-400 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            {colError && (
              <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
                {colError}
              </div>
            )}
            <div className="space-y-1">
              <label className="text-xs font-medium text-stone-700">Name</label>
              <input
                required
                value={colName}
                onChange={(e) => setColName(e.target.value)}
                placeholder="Engineering Runbooks"
                className="w-full rounded-lg border border-stone-200 px-3 py-2 text-sm outline-none focus:border-stone-500"
              />
            </div>
            <div className="space-y-1">
              <label className="text-xs font-medium text-stone-700">URL Slug</label>
              <input
                value={colSlug}
                onChange={(e) => setColSlug(e.target.value)}
                placeholder="eng-runbooks (auto-generated if blank)"
                className="w-full rounded-lg border border-stone-200 px-3 py-2 text-sm font-mono outline-none focus:border-stone-500"
              />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <label className="text-xs font-medium text-stone-700">Write Policy</label>
                <select
                  value={colPolicy}
                  onChange={(e) => setColPolicy(e.target.value as CollectionWritePolicy)}
                  className="w-full rounded-lg border border-stone-200 px-2.5 py-2 text-xs bg-white"
                >
                  <option value="direct_with_audit">Direct + Audit</option>
                  <option value="proposals_required_for_agents">Proposals for Agents</option>
                  <option value="proposals_required_for_all">Proposals for All</option>
                </select>
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-stone-700">Freshness TTL (days)</label>
                <input
                  type="number"
                  min={1}
                  value={colTtl}
                  onChange={(e) => setColTtl(e.target.value)}
                  className="w-full rounded-lg border border-stone-200 px-3 py-2 text-xs"
                />
              </div>
            </div>
            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setNewColOpen(false)}
                className="rounded-lg border border-stone-200 px-3.5 py-2 text-xs font-medium text-stone-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={colSaving}
                className="rounded-lg bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
              >
                {colSaving ? "Creating..." : "Create"}
              </button>
            </div>
          </form>
        </div>
      )}
    </>
  );
}
