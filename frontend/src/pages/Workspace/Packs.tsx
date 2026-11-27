import { Link } from "@inertiajs/react";
import {
  Check,
  Copy,
  Database as DbIcon,
  ExternalLink,
  FileText,
  Layers,
  Plus,
  RefreshCw,
  Save,
  Sparkles,
  Trash2,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  Collection,
  CompiledPackResult,
  ContextPack,
  DatabaseDef,
  LivingSummary,
} from "../../lib/types";

interface PacksPageProps {
  collections: Collection[];
  databases: DatabaseDef[];
  summaries: LivingSummary[];
  packs: ContextPack[];
  llms_txt: string;
}

function slugifyName(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 64);
}

export default function Packs({
  collections,
  databases,
  summaries,
  packs: initialPacks,
  llms_txt: initialLlmsTxt,
}: PacksPageProps) {
  const [packs, setPacks] = useState<ContextPack[]>(initialPacks);
  const [selectedPackId, setSelectedPackId] = useState<string | null>(
    initialPacks[0]?.id ?? null
  );
  const [rightTab, setRightTab] = useState<"compiled" | "llms" | "summaries">("compiled");

  // Pack form state (null selectedPackId => creating new pack)
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugTouched, setSlugTouched] = useState(false);
  const [description, setDescription] = useState("");
  const [tokenBudget, setTokenBudget] = useState(4000);
  const [collectionIds, setCollectionIds] = useState<string[]>([]);
  const [pinnedPageIds, setPinnedPageIds] = useState<string[]>([]);
  const [databaseIds, setDatabaseIds] = useState<string[]>([]);
  const [queryHint, setQueryHint] = useState("");
  const [freshOnly, setFreshOnly] = useState(false);
  const [includeFullBlocks, setIncludeFullBlocks] = useState(true);

  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [formStatus, setFormStatus] = useState<string | null>(null);

  // Compiled pack preview state
  const [compiled, setCompiled] = useState<CompiledPackResult | null>(null);
  const [compileLoading, setCompileLoading] = useState(false);
  const [compileError, setCompileError] = useState<string | null>(null);
  const [previewQueryOverride, setPreviewQueryOverride] = useState("");
  const [copiedKey, setCopiedKey] = useState<string | null>(null);

  // Living summaries filter state
  const [summaryFilter, setSummaryFilter] = useState("");
  const [summaryKindFilter, setSummaryKindFilter] = useState<"all" | "page" | "database">("all");

  const selectedPack = useMemo(
    () => packs.find((p) => p.id === selectedPackId) ?? null,
    [packs, selectedPackId]
  );

  const pageSummaries = useMemo(
    () => summaries.filter((s) => s.entity_kind === "page"),
    [summaries]
  );

  const collectionMap = useMemo(() => {
    const m = new Map<string, Collection>();
    for (const c of collections) m.set(c.id, c);
    return m;
  }, [collections]);

  const loadPackIntoForm = useCallback((pk: ContextPack | null) => {
    setFormError(null);
    if (!pk) {
      setName("");
      setSlug("");
      setSlugTouched(false);
      setDescription("");
      setTokenBudget(4000);
      setCollectionIds([]);
      setPinnedPageIds([]);
      setDatabaseIds([]);
      setQueryHint("");
      setFreshOnly(false);
      setIncludeFullBlocks(true);
      return;
    }
    setName(pk.name);
    setSlug(pk.slug);
    setSlugTouched(true);
    setDescription(pk.description);
    setTokenBudget(pk.token_budget);
    setCollectionIds(pk.collection_ids);
    setPinnedPageIds(pk.pinned_page_ids);
    setDatabaseIds(pk.database_ids);
    setQueryHint(pk.query_hint ?? "");
    setFreshOnly(pk.fresh_only);
    setIncludeFullBlocks(pk.include_full_blocks);
  }, []);

  useEffect(() => {
    loadPackIntoForm(selectedPack);
  }, [selectedPack, loadPackIntoForm]);

  const compileSelectedPack = useCallback(
    async (packSlug: string, qOverride?: string) => {
      setCompileLoading(true);
      setCompileError(null);
      try {
        const q = (qOverride ?? "").trim();
        const url = q
          ? `/api/packs/${encodeURIComponent(packSlug)}?q=${encodeURIComponent(q)}`
          : `/api/packs/${encodeURIComponent(packSlug)}`;
        const res = await apiFetch<CompiledPackResult>(url);
        setCompiled(res);
      } catch (err) {
        setCompiled(null);
        setCompileError(
          err instanceof ApiError ? err.message : "Failed to compile Context Pack"
        );
      } finally {
        setCompileLoading(false);
      }
    },
    []
  );

  useEffect(() => {
    if (!selectedPack) {
      setCompiled(null);
      setCompileError(null);
      return;
    }
    void compileSelectedPack(selectedPack.slug, previewQueryOverride);
  }, [selectedPack, previewQueryOverride, compileSelectedPack]);

  function startNewPack() {
    setSelectedPackId(null);
    setFormStatus(null);
    setCompiled(null);
    loadPackIntoForm(null);
  }

  function toggleInList(list: string[], id: string, setter: (next: string[]) => void) {
    setter(list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
  }

  async function handleCopy(key: string, text: string) {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedKey(key);
      window.setTimeout(() => {
        setCopiedKey((prev) => (prev === key ? null : prev));
      }, 1600);
    } catch {
      // Clipboard API unavailable in non-HTTPS contexts
    }
  }

  async function handleSavePack(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    setFormStatus(null);
    const trimmedName = name.trim();
    const resolvedSlug = (slug.trim() || slugifyName(trimmedName)).toLowerCase();
    if (!trimmedName || !resolvedSlug) {
      setFormError("Pack name and slug are required.");
      return;
    }

    setSaving(true);
    try {
      if (selectedPack) {
        const updated = await apiFetch<ContextPack>(`/api/packs/${selectedPack.id}`, {
          method: "PUT",
          body: JSON.stringify({
            slug: resolvedSlug,
            name: trimmedName,
            description: description.trim(),
            collection_ids: collectionIds,
            pinned_page_ids: pinnedPageIds,
            database_ids: databaseIds,
            query_hint: queryHint.trim() || "",
            fresh_only: freshOnly,
            include_full_blocks: includeFullBlocks,
            token_budget: tokenBudget,
            expected_version: selectedPack.version,
          }),
        });
        setPacks((prev) => prev.map((p) => (p.id === updated.id ? updated : p)));
        setFormStatus(`Updated pack '${updated.slug}' (v${updated.version})`);
        setRightTab("compiled");
        await compileSelectedPack(updated.slug, previewQueryOverride);
      } else {
        const created = await apiFetch<ContextPack>("/api/packs", {
          method: "POST",
          body: JSON.stringify({
            slug: resolvedSlug,
            name: trimmedName,
            description: description.trim() || null,
            collection_ids: collectionIds,
            pinned_page_ids: pinnedPageIds,
            database_ids: databaseIds,
            query_hint: queryHint.trim() || null,
            fresh_only: freshOnly,
            include_full_blocks: includeFullBlocks,
            token_budget: tokenBudget,
          }),
        });
        setPacks((prev) => [...prev, created].sort((a, b) => a.slug.localeCompare(b.slug)));
        setSelectedPackId(created.id);
        setFormStatus(`Created pack '${created.slug}' (vellum://packs/${created.slug})`);
        setRightTab("compiled");
      }
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : "Failed to save Context Pack");
    } finally {
      setSaving(false);
    }
  }

  async function handleDeletePack(pk: ContextPack) {
    setDeleting(true);
    setFormError(null);
    setFormStatus(null);
    try {
      await apiFetch<{ deleted: boolean; id: string }>(`/api/packs/${pk.id}`, {
        method: "DELETE",
      });
      const next = packs.filter((p) => p.id !== pk.id);
      setPacks(next);
      if (selectedPackId === pk.id) {
        setSelectedPackId(next[0]?.id ?? null);
      }
      setFormStatus(`Deleted pack '${pk.slug}'`);
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : "Failed to delete Context Pack");
    } finally {
      setDeleting(false);
    }
  }

  const filteredSummaries = useMemo(() => {
    const q = summaryFilter.trim().toLowerCase();
    return summaries.filter((s) => {
      if (summaryKindFilter !== "all" && s.entity_kind !== summaryKindFilter) {
        return false;
      }
      if (!q) return true;
      return (
        s.title.toLowerCase().includes(q) ||
        s.structural_summary.toLowerCase().includes(q) ||
        (s.semantic_summary ?? "").toLowerCase().includes(q) ||
        s.entity_id.toLowerCase().includes(q)
      );
    });
  }, [summaries, summaryFilter, summaryKindFilter]);

  const budgetPct = compiled ? Math.min(100, Math.max(0, compiled.budget_utilization_pct)) : 0;
  const budgetBarCls =
    budgetPct >= 95
      ? "bg-amber-500"
      : budgetPct >= 75
        ? "bg-indigo-600"
        : "bg-emerald-600";

  return (
    <WorkspaceLayout title="Context Studio" collections={collections} databases={databases}>
      <div className="space-y-6">
        {/* Hero Header */}
        <div className="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-stone-200 bg-white p-5 shadow-xs">
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <span className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-indigo-50 text-indigo-700 border border-indigo-200">
                <Layers className="h-4 w-4" />
              </span>
              <h1 className="text-lg font-semibold tracking-tight text-stone-950">
                Context Studio &amp; Progressive Disclosure
              </h1>
            </div>
            <p className="text-xs text-stone-600">
              Compile grant-filtered, token-budgeted <code className="font-mono">vellum://packs/&lt;slug&gt;</code> bundles from auto-maintained Living Summaries (<code className="font-mono">/llms.txt</code> Layer 1).
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <a
              href="/llms.txt"
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 font-mono text-stone-700 hover:bg-stone-100 transition"
            >
              <span>/llms.txt</span>
              <ExternalLink className="h-3 w-3 text-stone-400" />
            </a>
            <button
              type="button"
              onClick={startNewPack}
              className="inline-flex items-center gap-1.5 rounded-lg bg-stone-900 px-3.5 py-1.5 font-medium text-white hover:bg-stone-800 transition"
            >
              <Plus className="h-3.5 w-3.5" />
              New Context Pack
            </button>
          </div>
        </div>

        {/* Two-column Context Studio */}
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
          {/* Left Column: Pack List + Pack Editor Form */}
          <div className="lg:col-span-5 space-y-5">
            {/* Existing Packs Selector */}
            <div className="rounded-2xl border border-stone-200 bg-white p-4 space-y-3">
              <div className="flex items-center justify-between">
                <h2 className="text-xs font-semibold uppercase tracking-wider text-stone-500">
                  Saved Context Packs ({packs.length})
                </h2>
                <button
                  type="button"
                  onClick={startNewPack}
                  className="text-xs font-medium text-indigo-700 hover:underline"
                >
                  + Create new
                </button>
              </div>
              {packs.length === 0 ? (
                <div className="rounded-xl border border-dashed border-stone-200 bg-stone-50 px-4 py-5 text-center text-xs text-stone-500">
                  No Context Packs yet. Configure your first token-budgeted pack below.
                </div>
              ) : (
                <div className="space-y-1.5">
                  {packs.map((pk) => {
                    const active = pk.id === selectedPackId;
                    return (
                      <div
                        key={pk.id}
                        className={`flex items-center justify-between gap-2 rounded-xl border px-3 py-2.5 transition ${
                          active
                            ? "border-indigo-300 bg-indigo-50/70"
                            : "border-stone-200 bg-stone-50/50 hover:bg-stone-100/70"
                        }`}
                      >
                        <button
                          type="button"
                          onClick={() => setSelectedPackId(pk.id)}
                          className="flex-1 text-left min-w-0"
                        >
                          <div className="flex items-center gap-2">
                            <span className="text-sm font-medium text-stone-900 truncate">
                              {pk.name}
                            </span>
                            <span className="rounded bg-white border border-stone-200 px-1.5 py-0.5 font-mono text-[10px] text-stone-600 shrink-0">
                              {pk.token_budget} tok
                            </span>
                          </div>
                          <div className="font-mono text-[11px] text-indigo-700 truncate mt-0.5">
                            vellum://packs/{pk.slug}
                          </div>
                        </button>
                        <button
                          type="button"
                          disabled={deleting}
                          onClick={() => void handleDeletePack(pk)}
                          title={`Delete ${pk.slug}`}
                          className="rounded-lg p-1.5 text-stone-400 hover:bg-red-50 hover:text-red-600 transition shrink-0"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>

            {/* Pack Editor Form */}
            <form
              onSubmit={(e) => void handleSavePack(e)}
              className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4"
            >
              <div className="flex items-center justify-between border-b border-stone-100 pb-3">
                <h2 className="text-sm font-semibold text-stone-950">
                  {selectedPack ? `Edit Pack: ${selectedPack.slug}` : "New Context Pack"}
                </h2>
                {selectedPack && (
                  <span className="font-mono text-[11px] text-stone-400">
                    v{selectedPack.version}
                  </span>
                )}
              </div>

              {formError && (
                <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
                  {formError}
                </div>
              )}
              {formStatus && (
                <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-800">
                  {formStatus}
                </div>
              )}

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-medium text-stone-700">Name</label>
                  <input
                    required
                    type="text"
                    value={name}
                    onChange={(e) => {
                      const val = e.target.value;
                      setName(val);
                      if (!slugTouched) setSlug(slugifyName(val));
                    }}
                    placeholder="Incident Ops Brief"
                    className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm outline-none focus:border-indigo-500"
                  />
                </div>
                <div className="space-y-1">
                  <label className="text-xs font-medium text-stone-700">Pack Slug</label>
                  <input
                    required
                    type="text"
                    value={slug}
                    onChange={(e) => {
                      setSlugTouched(true);
                      setSlug(e.target.value.toLowerCase());
                    }}
                    placeholder="ops-brief"
                    className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm font-mono outline-none focus:border-indigo-500"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-stone-700">Description</label>
                <input
                  type="text"
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  placeholder="On-call runbooks, incident spend ledger & live escalations"
                  className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-xs outline-none focus:border-indigo-500"
                />
              </div>

              {/* Token Budget Slider + Numeric Input */}
              <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-3 space-y-2">
                <div className="flex items-center justify-between">
                  <label className="text-xs font-medium text-stone-800">
                    Hard Token Budget
                  </label>
                  <div className="flex items-center gap-1.5">
                    <input
                      type="number"
                      min={256}
                      max={32000}
                      step={64}
                      value={tokenBudget}
                      onChange={(e) => {
                        const n = Number.parseInt(e.target.value, 10);
                        if (Number.isFinite(n)) setTokenBudget(Math.min(64000, Math.max(256, n)));
                      }}
                      className="w-24 rounded-md border border-stone-200 bg-white px-2 py-1 text-right font-mono text-xs"
                    />
                    <span className="text-[11px] font-mono text-stone-500">tokens</span>
                  </div>
                </div>
                <input
                  type="range"
                  min={256}
                  max={32000}
                  step={128}
                  value={Math.min(32000, Math.max(256, tokenBudget))}
                  onChange={(e) => setTokenBudget(Number.parseInt(e.target.value, 10))}
                  className="w-full accent-indigo-600"
                />
                <div className="flex justify-between text-[10px] font-mono text-stone-400">
                  <span>256 tok</span>
                  <span>8k</span>
                  <span>16k</span>
                  <span>32k tok</span>
                </div>
              </div>

              {/* Collections Multi-select */}
              <div className="space-y-1.5">
                <label className="text-xs font-medium text-stone-700">
                  Collections Scope <span className="text-stone-400">(blank = all permitted)</span>
                </label>
                <div className="max-h-28 overflow-y-auto rounded-lg border border-stone-200 p-2 space-y-1 bg-stone-50/40">
                  {collections.map((c) => (
                    <label
                      key={c.id}
                      className="flex items-center gap-2 text-xs text-stone-700 cursor-pointer hover:text-stone-950"
                    >
                      <input
                        type="checkbox"
                        checked={collectionIds.includes(c.id)}
                        onChange={() => toggleInList(collectionIds, c.id, setCollectionIds)}
                      />
                      <span className="truncate">{c.name}</span>
                      <span className="font-mono text-[10px] text-stone-400 ml-auto">
                        {c.slug}
                      </span>
                    </label>
                  ))}
                </div>
              </div>

              {/* Pinned Pages Picker */}
              {pageSummaries.length > 0 && (
                <div className="space-y-1.5">
                  <label className="text-xs font-medium text-stone-700">
                    Pinned Pages <span className="text-stone-400">(always prioritized)</span>
                  </label>
                  <div className="max-h-32 overflow-y-auto rounded-lg border border-stone-200 p-2 space-y-1 bg-stone-50/40">
                    {pageSummaries.map((s) => (
                      <label
                        key={s.entity_id}
                        className="flex items-center gap-2 text-xs text-stone-700 cursor-pointer hover:text-stone-950"
                      >
                        <input
                          type="checkbox"
                          checked={pinnedPageIds.includes(s.entity_id)}
                          onChange={() => toggleInList(pinnedPageIds, s.entity_id, setPinnedPageIds)}
                        />
                        <span className="truncate">{s.title}</span>
                        <span className="font-mono text-[10px] text-stone-400 ml-auto shrink-0">
                          ~{s.estimated_tokens}t
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              )}

              {/* Databases Picker */}
              {databases.length > 0 && (
                <div className="space-y-1.5">
                  <label className="text-xs font-medium text-stone-700">
                    Databases <span className="text-stone-400">(blank = scoped collections)</span>
                  </label>
                  <div className="max-h-28 overflow-y-auto rounded-lg border border-stone-200 p-2 space-y-1 bg-stone-50/40">
                    {databases.map((db) => (
                      <label
                        key={db.id}
                        className="flex items-center gap-2 text-xs text-stone-700 cursor-pointer hover:text-stone-950"
                      >
                        <input
                          type="checkbox"
                          checked={databaseIds.includes(db.id)}
                          onChange={() => toggleInList(databaseIds, db.id, setDatabaseIds)}
                        />
                        <span className="truncate">{db.title}</span>
                      </label>
                    ))}
                  </div>
                </div>
              )}

              <div className="space-y-1">
                <label className="text-xs font-medium text-stone-700">Query Hint</label>
                <input
                  type="text"
                  value={queryHint}
                  onChange={(e) => setQueryHint(e.target.value)}
                  placeholder="Optional focus keyword (boosts matching docs)"
                  className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-xs outline-none focus:border-indigo-500"
                />
              </div>

              <div className="flex flex-col gap-2 pt-1 text-xs text-stone-700">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={freshOnly}
                    onChange={(e) => setFreshOnly(e.target.checked)}
                  />
                  <span>Fresh only (skip pages past their verification TTL)</span>
                </label>
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={includeFullBlocks}
                    onChange={(e) => setIncludeFullBlocks(e.target.checked)}
                  />
                  <span>Include full blocks when budget allows (otherwise Living Summaries)</span>
                </label>
              </div>

              <div className="flex justify-end gap-2 pt-2 border-t border-stone-100">
                <button
                  type="submit"
                  disabled={saving}
                  className="inline-flex items-center gap-1.5 rounded-lg bg-indigo-700 px-4 py-2 text-xs font-medium text-white hover:bg-indigo-800 disabled:opacity-50 transition"
                >
                  <Save className="h-3.5 w-3.5" />
                  {saving ? "Saving..." : selectedPack ? "Update Pack" : "Create Pack"}
                </button>
              </div>
            </form>
          </div>

          {/* Right Column: Live Compiled Preview, /llms.txt Index, & Living Summaries */}
          <div className="lg:col-span-7 space-y-4">
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-stone-200 bg-white p-2">
              <div className="flex items-center gap-1 text-xs font-medium">
                <button
                  type="button"
                  onClick={() => setRightTab("compiled")}
                  className={`rounded-lg px-3 py-1.5 transition ${
                    rightTab === "compiled"
                      ? "bg-stone-900 text-white"
                      : "text-stone-600 hover:bg-stone-100"
                  }`}
                >
                  Compiled Pack Preview
                </button>
                <button
                  type="button"
                  onClick={() => setRightTab("llms")}
                  className={`rounded-lg px-3 py-1.5 font-mono transition ${
                    rightTab === "llms"
                      ? "bg-stone-900 text-white"
                      : "text-stone-600 hover:bg-stone-100"
                  }`}
                >
                  /llms.txt
                </button>
                <button
                  type="button"
                  onClick={() => setRightTab("summaries")}
                  className={`rounded-lg px-3 py-1.5 transition ${
                    rightTab === "summaries"
                      ? "bg-stone-900 text-white"
                      : "text-stone-600 hover:bg-stone-100"
                  }`}
                >
                  Living Summaries ({summaries.length})
                </button>
              </div>
            </div>

            {/* Tab 1: Compiled Context Pack */}
            {rightTab === "compiled" && (
              <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                {!selectedPack ? (
                  <div className="py-12 text-center text-xs text-stone-500">
                    Select a Context Pack on the left or create one to inspect its compiled token-budgeted output.
                  </div>
                ) : (
                  <>
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div>
                        <div className="text-sm font-semibold text-stone-950">
                          {selectedPack.name}
                        </div>
                        <div className="font-mono text-[11px] text-indigo-700">
                          vellum://packs/{selectedPack.slug}
                        </div>
                      </div>
                      <div className="flex flex-wrap items-center gap-2 text-xs">
                        <button
                          type="button"
                          onClick={() =>
                            void handleCopy("uri", `vellum://packs/${selectedPack.slug}`)
                          }
                          className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-stone-700 hover:bg-stone-50"
                        >
                          {copiedKey === "uri" ? (
                            <Check className="h-3.5 w-3.5 text-emerald-600" />
                          ) : (
                            <Copy className="h-3.5 w-3.5" />
                          )}
                          Copy URI
                        </button>
                        {compiled && (
                          <button
                            type="button"
                            onClick={() => void handleCopy("md", compiled.markdown)}
                            className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-stone-700 hover:bg-stone-50"
                          >
                            {copiedKey === "md" ? (
                              <Check className="h-3.5 w-3.5 text-emerald-600" />
                            ) : (
                              <Copy className="h-3.5 w-3.5" />
                            )}
                            Copy Markdown
                          </button>
                        )}
                        <a
                          href={`/api/packs/${encodeURIComponent(selectedPack.slug)}/markdown`}
                          target="_blank"
                          rel="noreferrer"
                          className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-stone-700 hover:bg-stone-50"
                        >
                          Raw <ExternalLink className="h-3 w-3" />
                        </a>
                      </div>
                    </div>

                    {/* Ad-hoc Query Override */}
                    <div className="flex items-center gap-2">
                      <input
                        type="text"
                        value={previewQueryOverride}
                        onChange={(e) => setPreviewQueryOverride(e.target.value)}
                        placeholder="Optional ad-hoc ?q= relevance boost override..."
                        className="flex-1 rounded-lg border border-stone-200 px-3 py-1.5 text-xs outline-none focus:border-indigo-500"
                      />
                      <button
                        type="button"
                        disabled={compileLoading}
                        onClick={() =>
                          void compileSelectedPack(selectedPack.slug, previewQueryOverride)
                        }
                        className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-100"
                      >
                        <RefreshCw
                          className={`h-3.5 w-3.5 ${compileLoading ? "animate-spin" : ""}`}
                        />
                        Recompile
                      </button>
                    </div>

                    {compileError && (
                      <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
                        {compileError}
                      </div>
                    )}

                    {compiled && (
                      <>
                        {/* Token Budget Meter */}
                        <div className="rounded-xl border border-stone-200 bg-stone-50/70 p-3.5 space-y-2">
                          <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
                            <span className="font-medium text-stone-800">
                              Token Budget Utilization
                            </span>
                            <span className="font-mono font-semibold text-stone-900">
                              {compiled.tokens_used} / {compiled.token_budget} tok (
                              {compiled.budget_utilization_pct}%)
                            </span>
                          </div>
                          <div className="h-2.5 w-full overflow-hidden rounded-full bg-stone-200">
                            <div
                              className={`h-full transition-all ${budgetBarCls}`}
                              style={{ width: `${budgetPct}%` }}
                            />
                          </div>
                          <div className="flex flex-wrap gap-3 text-[11px] text-stone-600">
                            <span>{compiled.included_items.length} included</span>
                            <span>{compiled.omitted_count} omitted by budget</span>
                            <span>{compiled.skipped_stale_count} stale skipped</span>
                          </div>
                        </div>

                        {/* Included Items Chips */}
                        {compiled.included_items.length > 0 && (
                          <div className="flex flex-wrap gap-1.5">
                            {compiled.included_items.map((item) => (
                              <Link
                                key={`${item.entity_kind}-${item.entity_id}`}
                                href={
                                  item.entity_kind === "database"
                                    ? `/d/${item.entity_id}`
                                    : `/p/${item.entity_id}`
                                }
                                className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2.5 py-1 text-[11px] hover:bg-stone-100 transition"
                              >
                                {item.entity_kind === "database" ? (
                                  <DbIcon className="h-3 w-3 text-blue-600" />
                                ) : (
                                  <FileText className="h-3 w-3 text-stone-500" />
                                )}
                                <span className="font-medium text-stone-800">{item.title}</span>
                                <span className="rounded bg-white border border-stone-200 px-1 py-0 font-mono text-[10px] text-stone-500">
                                  {item.inclusion_mode} · {item.tokens_used}t
                                </span>
                                {item.pinned && (
                                  <span className="rounded bg-indigo-100 text-indigo-800 px-1 font-medium text-[10px]">
                                    pin
                                  </span>
                                )}
                              </Link>
                            ))}
                          </div>
                        )}

                        {/* Compiled Markdown */}
                        <pre className="max-h-[480px] overflow-auto rounded-xl border border-stone-800 bg-stone-950 p-4 font-mono text-xs leading-relaxed text-stone-100 whitespace-pre-wrap">
                          {compiled.markdown}
                        </pre>
                      </>
                    )}
                  </>
                )}
              </div>
            )}

            {/* Tab 2: /llms.txt Index */}
            {rightTab === "llms" && (
              <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <h2 className="text-sm font-semibold text-stone-950">
                      Layer 1 Progressive Disclosure Index (<code className="font-mono">/llms.txt</code>)
                    </h2>
                    <p className="text-xs text-stone-500">
                      Grant-filtered overview served at <code className="font-mono">GET /llms.txt</code> and MCP <code className="font-mono">vellum://index</code>.
                    </p>
                  </div>
                  <div className="flex items-center gap-2 text-xs">
                    <button
                      type="button"
                      onClick={() => void handleCopy("llms", initialLlmsTxt)}
                      className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-stone-700 hover:bg-stone-50"
                    >
                      {copiedKey === "llms" ? (
                        <Check className="h-3.5 w-3.5 text-emerald-600" />
                      ) : (
                        <Copy className="h-3.5 w-3.5" />
                      )}
                      Copy Index
                    </button>
                    <a
                      href="/llms.txt"
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-stone-700 hover:bg-stone-50"
                    >
                      Open <ExternalLink className="h-3 w-3" />
                    </a>
                  </div>
                </div>
                <pre className="max-h-[540px] overflow-auto rounded-xl border border-stone-800 bg-stone-950 p-4 font-mono text-xs leading-relaxed text-stone-100 whitespace-pre-wrap">
                  {initialLlmsTxt}
                </pre>
              </div>
            )}

            {/* Tab 3: Living Summaries Explorer */}
            {rightTab === "summaries" && (
              <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                <div className="flex flex-wrap items-center gap-2">
                  <input
                    type="text"
                    value={summaryFilter}
                    onChange={(e) => setSummaryFilter(e.target.value)}
                    placeholder="Filter summaries by title, digest, or ID..."
                    className="flex-1 min-w-[200px] rounded-lg border border-stone-200 px-3 py-1.5 text-xs outline-none focus:border-indigo-500"
                  />
                  <div className="inline-flex rounded-lg border border-stone-200 bg-stone-50 p-0.5 text-xs">
                    {(["all", "page", "database"] as const).map((k) => (
                      <button
                        key={k}
                        type="button"
                        onClick={() => setSummaryKindFilter(k)}
                        className={`rounded-md px-2.5 py-1 capitalize transition ${
                          summaryKindFilter === k
                            ? "bg-stone-900 text-white"
                            : "text-stone-600 hover:text-stone-900"
                        }`}
                      >
                        {k}
                      </button>
                    ))}
                  </div>
                </div>

                {filteredSummaries.length === 0 ? (
                  <div className="py-10 text-center text-xs text-stone-500">
                    No matching Living Summaries found.
                  </div>
                ) : (
                  <div className="space-y-2.5 max-h-[540px] overflow-y-auto pr-1">
                    {filteredSummaries.map((s) => {
                      const col = collectionMap.get(s.collection_id);
                      const isDb = s.entity_kind === "database";
                      return (
                        <div
                          key={s.id}
                          className="rounded-xl border border-stone-200 bg-stone-50/50 p-3.5 space-y-1.5"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="flex items-center gap-2 min-w-0">
                              <span
                                className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase ${
                                  isDb
                                    ? "bg-blue-50 text-blue-800 border border-blue-200"
                                    : "bg-stone-200/80 text-stone-800"
                                }`}
                              >
                                {isDb ? "DB" : "Page"}
                              </span>
                              <Link
                                href={isDb ? `/d/${s.entity_id}` : `/p/${s.entity_id}`}
                                className="text-sm font-semibold text-stone-900 hover:text-indigo-700 truncate"
                              >
                                {s.title}
                              </Link>
                              {col && (
                                <span className="font-mono text-[10px] text-stone-400">
                                  #{col.slug}
                                </span>
                              )}
                            </div>
                            <span className="font-mono text-[11px] text-stone-500">
                              ~{s.estimated_tokens} tok
                            </span>
                          </div>
                          <div className="text-xs text-stone-700">{s.structural_summary}</div>
                          {s.semantic_summary && (
                            <div className="flex items-start gap-1.5 rounded-lg border border-indigo-200 bg-indigo-50/70 px-2.5 py-1.5 text-xs text-indigo-950">
                              <Sparkles className="h-3.5 w-3.5 text-indigo-700 shrink-0 mt-0.5" />
                              <span>{s.semantic_summary}</span>
                            </div>
                          )}
                          <div className="flex flex-wrap items-center gap-3 text-[11px] text-stone-500 font-mono">
                            {isDb ? (
                              <span>{s.row_count} rows</span>
                            ) : (
                              <>
                                <span>{s.word_count} words</span>
                                {(s.open_tasks > 0 || s.done_tasks > 0) && (
                                  <span>
                                    tasks {s.done_tasks}/{s.open_tasks + s.done_tasks}
                                  </span>
                                )}
                              </>
                            )}
                            {s.blueprint_slug && <span>bp:{s.blueprint_slug}</span>}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      </div>
    </WorkspaceLayout>
  );
}
