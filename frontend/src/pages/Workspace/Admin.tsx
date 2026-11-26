import { Link } from "@inertiajs/react";
import {
  AlertTriangle,
  Bot,
  History,
  KeyRound,
  Leaf,
  Lock,
  RotateCcw,
  Upload,
  Webhook,
} from "lucide-react";
import { useEffect, useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  AuditFeedItem,
  ClaimRecord,
  Collection,
  DatabaseDef,
  GardenReport,
  WebhookSubPublic,
} from "../../lib/types";

interface AdminProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  audit_feed: AuditFeedItem[];
  webhooks: WebhookSubPublic[];
}

export default function AdminConsole({
  collections = [],
  databases = [],
  audit_feed = [],
  webhooks: initialWebhooks = [],
}: AdminProps) {
  const [tab, setTab] = useState<"agents" | "garden" | "importer" | "replay" | "webhooks">(
    "agents"
  );
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  // Agents, Grants & Claims
  const [agentHandle, setAgentHandle] = useState("docs-gardener");
  const [agentName, setAgentName] = useState("Docs Gardener Bot");
  const [agentModel, setAgentModel] = useState("claude-sonnet-4-6");
  const [agentActions, setAgentActions] = useState("read,propose,comment");
  const [agentColScope, setAgentColScope] = useState("");
  const [mintedToken, setMintedToken] = useState<{
    raw_token: string;
    grant_id: string;
  } | null>(null);
  const [revokeGrantId, setRevokeGrantId] = useState("");
  const [claims, setClaims] = useState<ClaimRecord[]>([]);

  // Knowledge Gardening
  const [garden, setGarden] = useState<GardenReport | null>(null);
  const [gardenLoading, setGardenLoading] = useState(false);

  // Notion Importer
  const [impColId, setImpColId] = useState(collections[0]?.id ?? "col_general");
  const [impPath, setImpPath] = useState("export/Engineering%20Handbook%200123456789abcdef0123456789abcdef.md");
  const [impMd, setImpMd] = useState("# Welcome\n\nImported from Notion export.");
  const [impCsvTitle, setImpCsvTitle] = useState("");
  const [impCsvText, setImpCsvText] = useState("");
  const [impResult, setImpResult] = useState<string | null>(null);

  // Selective Undo (Modb.Replay)
  const [replayFilterKind, setReplayFilterKind] = useState<"exclude_principal" | "exclude_grant">(
    "exclude_principal"
  );
  const [replayTarget, setReplayTarget] = useState("@docs-gardener");
  const [replayDesc, setReplayDesc] = useState("Rollback specific agent edits");
  const [replaySim, setReplaySim] = useState<{
    proposal_id: string;
    summary: unknown;
    bucket_diffs: unknown;
    status: unknown;
  } | null>(null);

  // Webhooks
  const [webhooks, setWebhooks] = useState<WebhookSubPublic[]>(initialWebhooks);
  const [whUrl, setWhUrl] = useState("");
  const [whEvents, setWhEvents] = useState("proposal.opened,proposal.accepted,page.updated");
  const [whSecret, setWhSecret] = useState<string | null>(null);

  useEffect(() => {
    void loadClaims();
  }, []);

  async function loadClaims() {
    try {
      const res = await apiFetch<{ claims: ClaimRecord[] }>("/api/claims");
      setClaims(res.claims ?? []);
    } catch {
      // ignore on mount
    }
  }

  async function handleMintAgent(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setNotice(null);
    try {
      const actions = agentActions
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      const res = await apiFetch<{
        raw_token: string;
        grant: { id: string };
      }>("/api/admin/agents", {
        method: "POST",
        body: JSON.stringify({
          handle: agentHandle.trim(),
          display_name: agentName.trim(),
          model_id: agentModel.trim() || null,
          label: "ui-minted",
          allowed_actions: actions,
          allowed_collections: agentColScope ? [agentColScope] : null,
          max_calls: 250,
          ttl_days: 30,
        }),
      });
      setMintedToken({ raw_token: res.raw_token, grant_id: res.grant.id });
      setNotice(`Minted agent token with grant ${res.grant.id}`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to mint agent token");
    }
  }

  async function handleRevokeGrant(e: React.FormEvent) {
    e.preventDefault();
    if (!revokeGrantId.trim()) return;
    setError(null);
    setNotice(null);
    try {
      await apiFetch(`/api/admin/grants/${encodeURIComponent(revokeGrantId.trim())}/revoke`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setNotice(`Revoked grant tree ${revokeGrantId.trim()}`);
      setRevokeGrantId("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to revoke grant");
    }
  }

  async function handleReleaseClaim(resource: string) {
    setError(null);
    try {
      await apiFetch("/api/claims/release", {
        method: "POST",
        body: JSON.stringify({ resource }),
      });
      await loadClaims();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to release claim");
    }
  }

  async function handleRunGarden() {
    setGardenLoading(true);
    setError(null);
    try {
      const rep = await apiFetch<GardenReport>("/api/admin/garden");
      setGarden(rep);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Garden scan failed");
    } finally {
      setGardenLoading(false);
    }
  }

  async function handleNotionImport(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setImpResult(null);
    try {
      const pages = impPath.trim()
        ? [{ path: impPath.trim(), title: null, markdown: impMd }]
        : [];
      const databasesPayload =
        impCsvTitle.trim() && impCsvText.trim()
          ? [{ title: impCsvTitle.trim(), csv_text: impCsvText }]
          : [];
      const res = await apiFetch<{
        page_count: number;
        database_count: number;
        row_count: number;
      }>("/api/import/notion", {
        method: "POST",
        body: JSON.stringify({
          collection_id: impColId || collections[0]?.id || "col_general",
          pages,
          databases: databasesPayload,
        }),
      });
      setImpResult(
        `Imported ${res.page_count} page(s), ${res.database_count} database(s), and ${res.row_count} row(s).`
      );
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Notion import failed");
    }
  }

  async function handleSimulateReplay(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setNotice(null);
    try {
      await apiFetch("/api/admin/replay/baseline", {
        method: "POST",
        body: JSON.stringify({}),
      });
      const sim = await apiFetch<{
        proposal_id: string;
        summary: unknown;
        bucket_diffs: unknown;
        status: unknown;
      }>("/api/admin/replay/simulate", {
        method: "POST",
        body: JSON.stringify({
          filter_kind: replayFilterKind,
          target: replayTarget.trim(),
          seq: null,
          description: replayDesc.trim() || "selective undo",
        }),
      });
      setReplaySim(sim);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Replay simulation failed");
    }
  }

  async function handleAcceptReplay() {
    if (!replaySim) return;
    setError(null);
    try {
      await apiFetch(`/api/admin/replay/${replaySim.proposal_id}/accept`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setNotice(`Applied selective rollback ${replaySim.proposal_id}`);
      setReplaySim(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not accept rollback");
    }
  }

  async function handleDiscardReplay() {
    if (!replaySim) return;
    setError(null);
    try {
      await apiFetch(`/api/admin/replay/${replaySim.proposal_id}/discard`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setNotice(`Discarded simulation ${replaySim.proposal_id}`);
      setReplaySim(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not discard simulation");
    }
  }

  async function handleCreateWebhook(e: React.FormEvent) {
    e.preventDefault();
    if (!whUrl.trim()) return;
    setError(null);
    setWhSecret(null);
    try {
      const events = whEvents
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      const res = await apiFetch<{
        id: string;
        url: string;
        events: string[];
        collection_id: string | null;
        secret: string;
      }>("/api/webhooks", {
        method: "POST",
        body: JSON.stringify({
          collection_id: null,
          url: whUrl.trim(),
          events,
        }),
      });
      setWhSecret(res.secret);
      setWebhooks((prev) => [
        ...prev,
        {
          id: res.id,
          workspace_id: "ws_default",
          collection_id: res.collection_id,
          url: res.url,
          events: res.events,
          enabled: true,
          created_at: new Date().toISOString(),
        },
      ]);
      setWhUrl("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not register webhook");
    }
  }

  return (
    <WorkspaceLayout title="Agents, Grants & Console" collections={collections} databases={databases}>
      <div className="space-y-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-stone-950">Agents &amp; Console</h1>
            <p className="text-sm text-stone-500 mt-0.5">
              Capability tokens, live MoDB claims, Knowledge Gardening, Notion Importer, Selective
              Undo, and signed webhooks.
            </p>
          </div>
          <div className="inline-flex flex-wrap rounded-xl border border-stone-200 bg-white p-1 text-xs">
            {(
              [
                ["agents", "Agents & Claims", Bot],
                ["garden", "Gardening", Leaf],
                ["importer", "Notion Importer", Upload],
                ["replay", "Selective Undo", RotateCcw],
                ["webhooks", "Webhooks", Webhook],
              ] as const
            ).map(([key, label, Icon]) => (
              <button
                key={key}
                type="button"
                onClick={() => setTab(key)}
                className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 font-medium ${
                  tab === key ? "bg-stone-900 text-white" : "text-stone-600"
                }`}
              >
                <Icon className="h-3.5 w-3.5" />
                {label}
              </button>
            ))}
          </div>
        </div>

        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-2.5 text-sm text-red-800">
            {error}
          </div>
        )}
        {notice && (
          <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-sm text-emerald-800">
            {notice}
          </div>
        )}

        {/* TAB 1: AGENTS, GRANTS & CLAIMS */}
        {tab === "agents" && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <form
              onSubmit={handleMintAgent}
              className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3"
            >
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <KeyRound className="h-4 w-4 text-blue-600" />
                Mint Scoped Agent Token (vlm_ag_...)
              </div>
              <div className="grid grid-cols-2 gap-3 text-xs">
                <div>
                  <label className="font-medium text-stone-700">Handle</label>
                  <input
                    value={agentHandle}
                    onChange={(e) => setAgentHandle(e.target.value)}
                    className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                  />
                </div>
                <div>
                  <label className="font-medium text-stone-700">Display Name</label>
                  <input
                    value={agentName}
                    onChange={(e) => setAgentName(e.target.value)}
                    className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2"
                  />
                </div>
                <div>
                  <label className="font-medium text-stone-700">Model ID</label>
                  <input
                    value={agentModel}
                    onChange={(e) => setAgentModel(e.target.value)}
                    className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                  />
                </div>
                <div>
                  <label className="font-medium text-stone-700">Collection Scope</label>
                  <select
                    value={agentColScope}
                    onChange={(e) => setAgentColScope(e.target.value)}
                    className="mt-1 w-full rounded-lg border border-stone-200 px-2.5 py-2 bg-white"
                  >
                    <option value="">All workspace collections</option>
                    {collections.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.name} ({c.id})
                      </option>
                    ))}
                  </select>
                </div>
              </div>
              <div className="text-xs">
                <label className="font-medium text-stone-700">Allowed Actions (CSV)</label>
                <input
                  value={agentActions}
                  onChange={(e) => setAgentActions(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                />
              </div>
              <button
                type="submit"
                className="rounded-lg bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800"
              >
                Mint Scoped Token
              </button>

              {mintedToken && (
                <div className="rounded-xl border border-amber-300 bg-amber-50 p-3.5 text-xs space-y-1">
                  <div className="font-semibold text-amber-950">
                    Copy now (stored SHA-256 hashed only — never shown again):
                  </div>
                  <div className="font-mono break-all bg-white border border-amber-200 rounded p-2 select-all">
                    {mintedToken.raw_token}
                  </div>
                  <div className="text-amber-800 font-mono">Grant: {mintedToken.grant_id}</div>
                </div>
              )}
            </form>

            <div className="space-y-6">
              <form
                onSubmit={handleRevokeGrant}
                className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3"
              >
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  <Lock className="h-4 w-4 text-red-600" />
                  Cascading Grant Revocation
                </div>
                <div className="flex gap-2">
                  <input
                    value={revokeGrantId}
                    onChange={(e) => setRevokeGrantId(e.target.value)}
                    placeholder="gr_..."
                    className="flex-1 rounded-lg border border-stone-200 px-3 py-2 text-xs font-mono"
                  />
                  <button
                    type="submit"
                    className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2 text-xs font-medium text-red-700 hover:bg-red-100"
                  >
                    Revoke Tree
                  </button>
                </div>
              </form>

              <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm font-semibold text-stone-900">
                    Active Block/Row Leases ({claims.length})
                  </span>
                  <button
                    type="button"
                    onClick={() => void loadClaims()}
                    className="text-xs text-blue-600 hover:underline"
                  >
                    Refresh
                  </button>
                </div>
                {claims.length === 0 ? (
                  <p className="text-xs text-stone-400">No active Modb.Claims leases.</p>
                ) : (
                  <div className="space-y-2">
                    {claims.map((c) => (
                      <div
                        key={c.resource}
                        className="flex items-center justify-between rounded-lg border border-stone-100 bg-stone-50 px-3 py-2 text-xs"
                      >
                        <div>
                          <div className="font-mono font-medium text-stone-900">{c.resource}</div>
                          <div className="text-stone-500">
                            {c.holder} · expires {c.expires_at}
                          </div>
                        </div>
                        <button
                          type="button"
                          onClick={() => void handleReleaseClaim(c.resource)}
                          className="text-red-600 hover:underline"
                        >
                          Force Release
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>
        )}

        {/* TAB 2: KNOWLEDGE GARDENING */}
        {tab === "garden" && (
          <div className="rounded-2xl border border-stone-200 bg-white p-6 space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h2 className="text-base font-semibold text-stone-900">
                  Knowledge Gardening Scan
                </h2>
                <p className="text-xs text-stone-500">
                  Detects pages exceeding freshness TTL (page → collection → workspace) and broken{" "}
                  <code className="font-mono">[[page_id]]</code> links.
                </p>
              </div>
              <button
                type="button"
                disabled={gardenLoading}
                onClick={() => void handleRunGarden()}
                className="inline-flex items-center gap-1.5 rounded-lg bg-teal-700 px-4 py-2 text-xs font-medium text-white hover:bg-teal-800 disabled:opacity-50"
              >
                <Leaf className="h-3.5 w-3.5" />
                {gardenLoading ? "Scanning..." : "Run Garden Audit"}
              </button>
            </div>

            {garden && (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4 pt-2">
                <div className="rounded-xl border border-stone-200 p-4 space-y-2">
                  <div className="text-xs font-semibold text-stone-700">
                    Stale Pages ({garden.stale_pages.length} / {garden.checked_pages} checked)
                  </div>
                  {garden.stale_pages.map((sp) => (
                    <Link
                      key={sp.page_id}
                      href={`/p/${sp.page_id}`}
                      className="block rounded-lg bg-amber-50 border border-amber-200 p-2.5 text-xs"
                    >
                      <div className="font-medium text-amber-950">{sp.title}</div>
                      <div className="text-amber-800">
                        {sp.days_since_verified}d since verified (TTL {sp.ttl_days}d)
                      </div>
                    </Link>
                  ))}
                  {garden.stale_pages.length === 0 && (
                    <p className="text-xs text-stone-400">All checked pages are fresh.</p>
                  )}
                </div>

                <div className="rounded-xl border border-stone-200 p-4 space-y-2">
                  <div className="text-xs font-semibold text-stone-700 flex items-center gap-1.5">
                    <AlertTriangle className="h-3.5 w-3.5 text-red-600" />
                    Broken Links ({garden.broken_links.length})
                  </div>
                  {garden.broken_links.map((bl, idx) => (
                    <Link
                      key={`${bl.block_id}-${idx}`}
                      href={`/p/${bl.source_page_id}#${bl.block_id}`}
                      className="block rounded-lg bg-red-50 border border-red-200 p-2.5 text-xs"
                    >
                      <div className="font-medium text-red-950">{bl.source_title}</div>
                      <div className="font-mono text-red-800">
                        Missing target: {bl.target_page_id} ({bl.label})
                      </div>
                    </Link>
                  ))}
                  {garden.broken_links.length === 0 && (
                    <p className="text-xs text-stone-400">Zero broken PageLinks detected.</p>
                  )}
                </div>
              </div>
            )}
          </div>
        )}

        {/* TAB 3: NOTION IMPORTER */}
        {tab === "importer" && (
          <form
            onSubmit={handleNotionImport}
            className="rounded-2xl border border-stone-200 bg-white p-6 space-y-4"
          >
            <h2 className="text-base font-semibold text-stone-900">
              Notion Markdown &amp; CSV Importer
            </h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-xs">
              <div>
                <label className="font-medium text-stone-700">Target Collection</label>
                <select
                  value={impColId}
                  onChange={(e) => setImpColId(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 bg-white"
                >
                  {collections.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className="font-medium text-stone-700">Notion Page Path</label>
                <input
                  value={impPath}
                  onChange={(e) => setImpPath(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                />
              </div>
            </div>
            <div className="text-xs">
              <label className="font-medium text-stone-700">Page Markdown Content</label>
              <textarea
                rows={4}
                value={impMd}
                onChange={(e) => setImpMd(e.target.value)}
                className="mt-1 w-full rounded-lg border border-stone-200 p-3 font-mono"
              />
            </div>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 text-xs">
              <div>
                <label className="font-medium text-stone-700">Optional CSV Filename</label>
                <input
                  value={impCsvTitle}
                  onChange={(e) => setImpCsvTitle(e.target.value)}
                  placeholder="Incidents 0123456789abcdef0123456789abcdef.csv"
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                />
              </div>
              <div className="md:col-span-2">
                <label className="font-medium text-stone-700">Optional CSV Rows</label>
                <textarea
                  rows={2}
                  value={impCsvText}
                  onChange={(e) => setImpCsvText(e.target.value)}
                  placeholder="Title,Status,Cost&#10;Auth 502,Open,12.50"
                  className="mt-1 w-full rounded-lg border border-stone-200 p-2 font-mono"
                />
              </div>
            </div>
            <button
              type="submit"
              className="rounded-lg bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800"
            >
              Run Notion Import into MoDB
            </button>
            {impResult && (
              <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3.5 py-2 text-xs text-emerald-800">
                {impResult}
              </div>
            )}
          </form>
        )}

        {/* TAB 4: SELECTIVE UNDO */}
        {tab === "replay" && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <form
              onSubmit={handleSimulateReplay}
              className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3 text-xs"
            >
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <History className="h-4 w-4 text-amber-700" />
                Simulate Selective Rollback (Modb.Replay)
              </div>
              <div>
                <label className="font-medium text-stone-700">Filter Mode</label>
                <select
                  value={replayFilterKind}
                  onChange={(e) =>
                    setReplayFilterKind(e.target.value as "exclude_principal" | "exclude_grant")
                  }
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 bg-white"
                >
                  <option value="exclude_principal">Exclude Principal Handle</option>
                  <option value="exclude_grant">Exclude Grant Subtree</option>
                </select>
              </div>
              <div>
                <label className="font-medium text-stone-700">Target Principal / Grant ID</label>
                <input
                  value={replayTarget}
                  onChange={(e) => setReplayTarget(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                />
              </div>
              <div>
                <label className="font-medium text-stone-700">Description</label>
                <input
                  value={replayDesc}
                  onChange={(e) => setReplayDesc(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2"
                />
              </div>
              <button
                type="submit"
                className="rounded-lg bg-amber-700 px-4 py-2 font-medium text-white hover:bg-amber-800"
              >
                Pin Baseline &amp; Simulate
              </button>

              {replaySim && (
                <div className="space-y-3 pt-2 border-t border-stone-100">
                  <div className="font-mono text-stone-800">
                    Simulation: <strong>{replaySim.proposal_id}</strong>
                  </div>
                  <pre className="rounded-lg bg-stone-950 text-stone-100 p-3 overflow-x-auto max-h-48">
                    {JSON.stringify(replaySim.bucket_diffs, null, 2)}
                  </pre>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      onClick={() => void handleAcceptReplay()}
                      className="rounded-lg bg-emerald-700 px-3 py-1.5 font-medium text-white"
                    >
                      Apply Selective Undo
                    </button>
                    <button
                      type="button"
                      onClick={() => void handleDiscardReplay()}
                      className="rounded-lg border border-stone-200 px-3 py-1.5 text-stone-700"
                    >
                      Discard
                    </button>
                  </div>
                </div>
              )}
            </form>

            <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-2 max-h-96 overflow-y-auto">
              <div className="text-sm font-semibold text-stone-900">
                Recent Ledger Transactions ({audit_feed.length})
              </div>
              {audit_feed.map((ev) => (
                <div key={ev.seq} className="border-b border-stone-100 py-2 text-xs">
                  <div className="flex justify-between font-mono text-stone-500">
                    <span>
                      #{ev.seq} · {ev.actor_name}
                    </span>
                    <span>{ev.action}</span>
                  </div>
                  <div className="text-stone-800 mt-0.5">{ev.reason}</div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* TAB 5: WEBHOOKS */}
        {tab === "webhooks" && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <form
              onSubmit={handleCreateWebhook}
              className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3 text-xs"
            >
              <div className="text-sm font-semibold text-stone-900">Register Signed Webhook</div>
              <div>
                <label className="font-medium text-stone-700">Endpoint URL</label>
                <input
                  required
                  type="url"
                  value={whUrl}
                  onChange={(e) => setWhUrl(e.target.value)}
                  placeholder="https://agent.example.com/webhooks/vellum"
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                />
              </div>
              <div>
                <label className="font-medium text-stone-700">Events (CSV)</label>
                <input
                  value={whEvents}
                  onChange={(e) => setWhEvents(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                />
              </div>
              <button
                type="submit"
                className="rounded-lg bg-stone-900 px-4 py-2 font-medium text-white"
              >
                Create Webhook
              </button>
              {whSecret && (
                <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 font-mono break-all">
                  Signing Secret (X-Vellum-Signature-256): {whSecret}
                </div>
              )}
            </form>

            <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-2">
              <div className="text-sm font-semibold text-stone-900">
                Active Subscriptions ({webhooks.length})
              </div>
              {webhooks.length === 0 && (
                <p className="text-xs text-stone-400">No webhooks configured.</p>
              )}
              {webhooks.map((w) => (
                <div
                  key={w.id}
                  className="rounded-lg border border-stone-100 bg-stone-50 p-3 text-xs space-y-1"
                >
                  <div className="font-mono font-medium text-stone-900 break-all">{w.url}</div>
                  <div className="text-stone-500">
                    Events: {w.events.join(", ")} · {w.enabled ? "enabled" : "disabled"}
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </WorkspaceLayout>
  );
}
