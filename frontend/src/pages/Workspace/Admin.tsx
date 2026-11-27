import { Link } from "@inertiajs/react";
import {
  AlertTriangle,
  Bot,
  GitCompare,
  GitPullRequest,
  History,
  KeyRound,
  Leaf,
  Link2,
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
  ReplayProposalSummary,
  ReplayStatusResponse,
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
  const [gardenProposingKey, setGardenProposingKey] = useState<string | null>(null);

  // Notion Importer
  const [impColId, setImpColId] = useState(collections[0]?.id ?? "col_general");
  const [impPath, setImpPath] = useState("export/Engineering%20Handbook%200123456789abcdef0123456789abcdef.md");
  const [impMd, setImpMd] = useState("# Welcome\n\nImported from Notion export.");
  const [impCsvTitle, setImpCsvTitle] = useState("");
  const [impCsvText, setImpCsvText] = useState("");
  const [impResult, setImpResult] = useState<string | null>(null);

  // Selective Undo (Modb.Replay)
  const [replayFilterKind, setReplayFilterKind] = useState<
    "exclude_principal" | "exclude_grant" | "exclude_world" | "stop_before_seq"
  >("exclude_principal");
  const [replayTarget, setReplayTarget] = useState("@docs-gardener");
  const [replayStopSeq, setReplayStopSeq] = useState(1);
  const [replayDesc, setReplayDesc] = useState("Rollback specific agent edits");
  const [replayStatus, setReplayStatus] = useState<ReplayStatusResponse | null>(null);
  const [replayBusy, setReplayBusy] = useState(false);
  const [replaySim, setReplaySim] = useState<ReplayProposalSummary | null>(null);

  // Webhooks
  const [webhooks, setWebhooks] = useState<WebhookSubPublic[]>(initialWebhooks);
  const [whUrl, setWhUrl] = useState("");
  const [whEvents, setWhEvents] = useState("proposal.opened,proposal.accepted,page.updated");
  const [whSecret, setWhSecret] = useState<string | null>(null);

  useEffect(() => {
    void loadClaims();
  }, []);

  useEffect(() => {
    if (tab === "replay") {
      void loadReplayStatus();
    }
  }, [tab]);

  async function loadReplayStatus() {
    try {
      const st = await apiFetch<ReplayStatusResponse>("/api/admin/replay/status");
      setReplayStatus(st);
      if (st.call_count > 0) {
        setReplayStopSeq(st.call_count);
      }
      if (!replaySim && st.proposals.length > 0) {
        setReplaySim(st.proposals[0]);
      }
    } catch {
      // ignore initial replay status fetch failure
    }
  }

  async function handlePinBaseline() {
    setReplayBusy(true);
    setError(null);
    setNotice(null);
    try {
      await apiFetch("/api/admin/replay/baseline", {
        method: "POST",
        body: JSON.stringify({}),
      });
      setNotice("Pinned Modb.Replay CoW baseline snapshot.");
      await loadReplayStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not pin replay baseline");
    } finally {
      setReplayBusy(false);
    }
  }

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

  async function handleProposeGardenFix(
    key: string,
    payload: {
      kind: "stale_refresh" | "duplicate_contradiction" | "citation_drift";
      target_page_id: string;
      target_block_id?: string | null;
      related_page_id?: string | null;
      related_block_id?: string | null;
      reason: string;
    }
  ) {
    setGardenProposingKey(key);
    setError(null);
    setNotice(null);
    try {
      const res = await apiFetch<{ proposal: { id: string; title: string } }>(
        "/api/admin/garden/propose",
        {
          method: "POST",
          body: JSON.stringify(payload),
        }
      );
      setNotice(
        `Staged Proposals-Only Gardener PR ${res.proposal.id} (${res.proposal.title}). Review in Change Proposals.`
      );
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to stage gardener proposal");
    } finally {
      setGardenProposingKey(null);
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
    setReplayBusy(true);
    setError(null);
    setNotice(null);
    try {
      const sim = await apiFetch<{
        proposal_id: string;
        description: string;
        filter: unknown;
        base_call_seq: number;
        summary: ReplayProposalSummary["summary"];
        outcomes: unknown[];
        bucket_diffs: ReplayProposalSummary["bucket_diffs"];
        status: unknown;
      }>("/api/admin/replay/simulate", {
        method: "POST",
        body: JSON.stringify({
          filter_kind: replayFilterKind,
          target: replayFilterKind === "stop_before_seq" ? null : replayTarget.trim(),
          seq: replayFilterKind === "stop_before_seq" ? replayStopSeq : null,
          description: replayDesc.trim() || `Selective simulation (${replayFilterKind})`,
        }),
      });
      setReplaySim({
        id: sim.proposal_id,
        description: sim.description,
        filter: sim.filter,
        base_call_seq: sim.base_call_seq,
        created_by: "you",
        created_at: new Date().toISOString(),
        status: sim.status,
        summary: sim.summary,
        outcomes: sim.outcomes ?? [],
        bucket_diffs: sim.bucket_diffs ?? [],
      });
      await loadReplayStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Replay simulation failed");
    } finally {
      setReplayBusy(false);
    }
  }

  async function handleAcceptReplay(propId?: string) {
    const targetId = propId ?? replaySim?.id;
    if (!targetId) return;
    setReplayBusy(true);
    setError(null);
    try {
      await apiFetch(`/api/admin/replay/${targetId}/accept`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setNotice(`Applied selective rollback ${targetId}`);
      if (replaySim?.id === targetId) setReplaySim(null);
      await loadReplayStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not accept rollback");
    } finally {
      setReplayBusy(false);
    }
  }

  async function handleDiscardReplay(propId?: string) {
    const targetId = propId ?? replaySim?.id;
    if (!targetId) return;
    setReplayBusy(true);
    setError(null);
    try {
      await apiFetch(`/api/admin/replay/${targetId}/discard`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setNotice(`Discarded simulation ${targetId}`);
      if (replaySim?.id === targetId) setReplaySim(null);
      await loadReplayStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not discard simulation");
    } finally {
      setReplayBusy(false);
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
                  Detects stale pages, broken <code className="font-mono">[[page_id]]</code> links,{" "}
                  <code className="font-mono">Modb.Vec</code> semantic near-duplicates/contradictions,
                  and cited-dependency drift. All fixes stage strictly as Proposals-Only PRs.
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
                    <div
                      key={sp.page_id}
                      className="rounded-lg bg-amber-50 border border-amber-200 p-2.5 text-xs space-y-1.5"
                    >
                      <div className="flex items-start justify-between gap-2">
                        <Link
                          href={`/p/${sp.page_id}`}
                          className="font-medium text-amber-950 hover:underline"
                        >
                          {sp.title}
                        </Link>
                        <button
                          type="button"
                          disabled={gardenProposingKey === `stale:${sp.page_id}`}
                          onClick={() =>
                            void handleProposeGardenFix(`stale:${sp.page_id}`, {
                              kind: "stale_refresh",
                              target_page_id: sp.page_id,
                              reason: `Page stale (${sp.days_since_verified}d vs ${sp.ttl_days}d TTL)`,
                            })
                          }
                          className="shrink-0 rounded border border-amber-300 bg-white px-2 py-0.5 text-[11px] font-medium text-amber-900 hover:bg-amber-100 disabled:opacity-50"
                        >
                          {gardenProposingKey === `stale:${sp.page_id}`
                            ? "Staging..."
                            : "Stage Proposal"}
                        </button>
                      </div>
                      <div className="text-amber-800">
                        {sp.days_since_verified}d since verified (TTL {sp.ttl_days}d)
                      </div>
                    </div>
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

                <div className="rounded-xl border border-stone-200 p-4 space-y-2">
                  <div className="text-xs font-semibold text-stone-700 flex items-center gap-1.5">
                    <GitCompare className="h-3.5 w-3.5 text-violet-600" />
                    Near-Duplicates &amp; Contradictions ({garden.duplicate_pairs?.length ?? 0})
                  </div>
                  {(garden.duplicate_pairs ?? []).map((dp, idx) => {
                    const pkey = `dup:${dp.page_a_id}:${dp.page_b_id}`;
                    return (
                      <div
                        key={`${pkey}-${idx}`}
                        className="rounded-lg bg-violet-50 border border-violet-200 p-2.5 text-xs space-y-1.5"
                      >
                        <div className="flex items-start justify-between gap-2">
                          <div className="space-y-0.5">
                            <div className="font-medium text-violet-950">
                              <Link href={`/p/${dp.page_a_id}`} className="hover:underline">
                                {dp.page_a_title}
                              </Link>{" "}
                              ↔{" "}
                              <Link href={`/p/${dp.page_b_id}`} className="hover:underline">
                                {dp.page_b_title}
                              </Link>
                            </div>
                            <div className="text-[11px] text-violet-800">
                              Cosine {(dp.similarity * 100).toFixed(0)}%
                              {dp.possible_contradiction ? " · Potential contradiction" : " · High overlap"}
                            </div>
                          </div>
                          <button
                            type="button"
                            disabled={gardenProposingKey === pkey}
                            onClick={() =>
                              void handleProposeGardenFix(pkey, {
                                kind: "duplicate_contradiction",
                                target_page_id: dp.page_a_id,
                                related_page_id: dp.page_b_id,
                                reason:
                                  dp.contradiction_reason ??
                                  `Semantic overlap ${(dp.similarity * 100).toFixed(0)}% with ${dp.page_b_title}`,
                              })
                            }
                            className="shrink-0 rounded border border-violet-300 bg-white px-2 py-0.5 text-[11px] font-medium text-violet-900 hover:bg-violet-100 disabled:opacity-50"
                          >
                            {gardenProposingKey === pkey ? "Staging..." : "Stage Proposal"}
                          </button>
                        </div>
                        {dp.contradiction_reason && (
                          <div className="text-[11px] text-rose-700 font-medium">
                            {dp.contradiction_reason}
                          </div>
                        )}
                      </div>
                    );
                  })}
                  {(garden.duplicate_pairs?.length ?? 0) === 0 && (
                    <p className="text-xs text-stone-400">
                      No semantic duplicates or contradictions flagged.
                    </p>
                  )}
                </div>

                <div className="rounded-xl border border-stone-200 p-4 space-y-2">
                  <div className="text-xs font-semibold text-stone-700 flex items-center gap-1.5">
                    <Link2 className="h-3.5 w-3.5 text-amber-600" />
                    Cited-Dependency Drift ({garden.citation_drifts?.length ?? 0})
                  </div>
                  {(garden.citation_drifts ?? []).map((cd, idx) => {
                    const pkey = `drift:${cd.dependent_block_id}:${cd.cited_block_id}`;
                    return (
                      <div
                        key={`${pkey}-${idx}`}
                        className="rounded-lg bg-amber-50 border border-amber-200 p-2.5 text-xs space-y-1.5"
                      >
                        <div className="flex items-start justify-between gap-2">
                          <div>
                            <Link
                              href={`/p/${cd.dependent_page_id}#${cd.dependent_block_id}`}
                              className="font-medium text-amber-950 hover:underline"
                            >
                              {cd.dependent_page_title}
                            </Link>
                            <div className="text-[11px] text-amber-800">
                              Cites{" "}
                              <Link
                                href={`/p/${cd.cited_page_id}#${cd.cited_block_id}`}
                                className="underline"
                              >
                                {cd.cited_page_title} §{cd.cited_block_id} (v{cd.cited_block_version})
                              </Link>
                            </div>
                          </div>
                          <button
                            type="button"
                            disabled={gardenProposingKey === pkey}
                            onClick={() =>
                              void handleProposeGardenFix(pkey, {
                                kind: "citation_drift",
                                target_page_id: cd.dependent_page_id,
                                target_block_id: cd.dependent_block_id,
                                related_page_id: cd.cited_page_id,
                                related_block_id: cd.cited_block_id,
                                reason: cd.summary,
                              })
                            }
                            className="shrink-0 rounded border border-amber-300 bg-white px-2 py-0.5 text-[11px] font-medium text-amber-900 hover:bg-amber-100 disabled:opacity-50"
                          >
                            {gardenProposingKey === pkey ? "Staging..." : "Stage Proposal"}
                          </button>
                        </div>
                        <div className="text-[11px] text-amber-900">{cd.summary}</div>
                      </div>
                    );
                  })}
                  {(garden.citation_drifts?.length ?? 0) === 0 && (
                    <p className="text-xs text-stone-400">All cited block dependencies are in sync.</p>
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

        {/* TAB 4: SELECTIVE UNDO / VISUAL MODB.REPLAY */}
        {tab === "replay" && (
          <div className="space-y-6">
            {/* CoW Baseline Banner */}
            <div className="rounded-2xl border border-stone-200 bg-white p-5 flex flex-wrap items-center justify-between gap-4">
              <div className="space-y-1">
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  <History className="h-4 w-4 text-amber-700" />
                  Modb.Replay Time-Travel &amp; Selective Undo
                </div>
                {replayStatus?.baseline ? (
                  <p className="text-xs text-stone-600">
                    CoW baseline pinned at{" "}
                    <span className="font-mono text-stone-900">txid #{replayStatus.baseline.txid}</span>{" "}
                    (schema v{replayStatus.baseline.schema_version}, {replayStatus.baseline.pinned_at}) ·{" "}
                    <strong>{replayStatus.call_count}</strong> replayable calls recorded.
                  </p>
                ) : (
                  <p className="text-xs text-stone-500">
                    No CoW replay baseline pinned yet. Pin before recording replay calls to enable offline counterfactual simulation and point-in-time scrubbing.
                  </p>
                )}
              </div>
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  disabled={replayBusy}
                  onClick={() => void loadReplayStatus()}
                  className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50"
                >
                  Refresh
                </button>
                {!replayStatus?.baseline && (
                  <button
                    type="button"
                    disabled={replayBusy || (replayStatus?.call_count ?? 0) > 0}
                    onClick={() => void handlePinBaseline()}
                    className="rounded-lg bg-stone-900 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
                  >
                    Pin CoW Baseline
                  </button>
                )}
              </div>
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              {/* Left: Simulation Builder & Visual Diff Preview */}
              <div className="space-y-4">
                <form
                  onSubmit={handleSimulateReplay}
                  className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3 text-xs"
                >
                  <div className="text-sm font-semibold text-stone-900">
                    Counterfactual Replay Simulation
                  </div>
                  <div>
                    <label className="font-medium text-stone-700">Filter Mode</label>
                    <select
                      value={replayFilterKind}
                      onChange={(e) =>
                        setReplayFilterKind(
                          e.target.value as
                            | "exclude_principal"
                            | "exclude_grant"
                            | "exclude_world"
                            | "stop_before_seq"
                        )
                      }
                      className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 bg-white"
                    >
                      <option value="exclude_principal">Exclude Principal Handle</option>
                      <option value="exclude_grant">Exclude Grant Subtree</option>
                      <option value="exclude_world">Exclude Single World / Proposal</option>
                      <option value="stop_before_seq">Rewind Before Sequence #</option>
                    </select>
                  </div>

                  {replayFilterKind === "stop_before_seq" ? (
                    <div className="space-y-1.5">
                      <div className="flex items-center justify-between font-medium text-stone-700">
                        <span>Stop Before Replay Call #</span>
                        <span className="font-mono text-amber-800">seq &lt; {replayStopSeq}</span>
                      </div>
                      <input
                        type="range"
                        min={1}
                        max={Math.max(1, (replayStatus?.call_count ?? 1) + 1)}
                        value={replayStopSeq}
                        onChange={(e) => setReplayStopSeq(Number(e.target.value))}
                        className="w-full accent-amber-700"
                      />
                    </div>
                  ) : (
                    <div>
                      <label className="font-medium text-stone-700">
                        {replayFilterKind === "exclude_world"
                          ? "Target World ID"
                          : replayFilterKind === "exclude_grant"
                            ? "Target Grant ID"
                            : "Target Principal Handle / ID"}
                      </label>
                      <input
                        value={replayTarget}
                        onChange={(e) => setReplayTarget(e.target.value)}
                        className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                      />
                    </div>
                  )}

                  <div>
                    <label className="font-medium text-stone-700">Simulation Reason</label>
                    <input
                      value={replayDesc}
                      onChange={(e) => setReplayDesc(e.target.value)}
                      className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2"
                    />
                  </div>
                  <button
                    type="submit"
                    disabled={replayBusy}
                    className="rounded-lg bg-amber-700 px-4 py-2 font-medium text-white hover:bg-amber-800 disabled:opacity-50"
                  >
                    {replayBusy ? "Simulating..." : "Simulate Counterfactual History"}
                  </button>
                </form>

                {replaySim && (
                  <div className="rounded-2xl border border-amber-200 bg-white p-5 space-y-4 text-xs">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div>
                        <div className="font-mono font-semibold text-stone-900">
                          {replaySim.id}
                        </div>
                        <div className="text-stone-500">{replaySim.description}</div>
                      </div>
                      <span className="rounded-full bg-amber-50 border border-amber-200 px-2.5 py-0.5 font-mono text-[11px] text-amber-900">
                        {typeof replaySim.status === "string"
                          ? replaySim.status
                          : Object.keys((replaySim.status as Record<string, unknown>) ?? {})[0] ?? "pending"}
                      </span>
                    </div>

                    {/* Structured Summary Metrics */}
                    <div className="grid grid-cols-3 gap-2">
                      <div className="rounded-lg bg-stone-50 p-2">
                        <div className="text-[10px] text-stone-500">Excluded Calls</div>
                        <div className="font-mono text-sm font-semibold text-amber-800">
                          {replaySim.summary.excluded} / {replaySim.summary.total_calls}
                        </div>
                      </div>
                      <div className="rounded-lg bg-stone-50 p-2">
                        <div className="text-[10px] text-stone-500">Now Refused / Blocked</div>
                        <div className="font-mono text-sm font-semibold text-red-700">
                          {replaySim.summary.now_refused + replaySim.summary.now_invariant_blocked}
                        </div>
                      </div>
                      <div className="rounded-lg bg-stone-50 p-2">
                        <div className="text-[10px] text-stone-500">Unchanged / Changed</div>
                        <div className="font-mono text-sm font-semibold text-emerald-700">
                          {replaySim.summary.unchanged} / {replaySim.summary.reply_changed}
                        </div>
                      </div>
                    </div>

                    {/* Bucket Diff Summary */}
                    <div className="space-y-1.5">
                      <div className="font-semibold text-stone-700">
                        Affected MoDB Buckets ({replaySim.bucket_diffs.length})
                      </div>
                      {replaySim.bucket_diffs.length === 0 ? (
                        <p className="text-stone-400">Zero storage differences vs Live.</p>
                      ) : (
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-1.5">
                          {replaySim.bucket_diffs.map((bd) => (
                            <div
                              key={bd.bucket}
                              className="flex items-center justify-between rounded-lg border border-stone-100 bg-stone-50 px-2.5 py-1.5 font-mono text-[11px]"
                            >
                              <span className="text-stone-800">{bd.bucket}</span>
                              <span>
                                <span className="text-emerald-700">+{bd.added}</span>{" "}
                                <span className="text-amber-700">~{bd.modified}</span>{" "}
                                <span className="text-red-700">-{bd.removed}</span>
                              </span>
                            </div>
                          ))}
                        </div>
                      )}
                    </div>

                    {/* Call-by-Call Outcomes */}
                    {replaySim.outcomes.length > 0 && (
                      <div className="space-y-1.5">
                        <div className="font-semibold text-stone-700">
                          Replayed Call Outcomes ({replaySim.outcomes.length})
                        </div>
                        <div className="max-h-40 overflow-y-auto space-y-1">
                          {replaySim.outcomes.map((raw, i) => {
                            const obj = (raw as Record<string, Record<string, unknown>>) ?? {};
                            const kind = Object.keys(obj)[0] ?? "outcome";
                            const inner = obj[kind] ?? {};
                            const tone =
                              kind === "excluded"
                                ? "bg-amber-50 text-amber-900 border-amber-200"
                                : kind === "now_refused" || kind === "now_invariant_blocked"
                                  ? "bg-red-50 text-red-900 border-red-200"
                                  : "bg-stone-50 text-stone-700 border-stone-200";
                            return (
                              <div
                                key={i}
                                className={`flex items-center justify-between rounded border px-2 py-1 font-mono text-[11px] ${tone}`}
                              >
                                <span>
                                  #{String(inner.seq ?? i + 1)} · {String(inner.principal ?? "")} ·{" "}
                                  {String(inner.action ?? "")}
                                </span>
                                <span className="font-semibold uppercase">{kind}</span>
                              </div>
                            );
                          })}
                        </div>
                      </div>
                    )}

                    {replaySim.status === "pending" && (
                      <div className="flex gap-2 pt-1">
                        <button
                          type="button"
                          disabled={replayBusy}
                          onClick={() => void handleAcceptReplay(replaySim.id)}
                          className="rounded-lg bg-emerald-700 px-3 py-1.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-50"
                        >
                          Apply Selective Undo
                        </button>
                        <button
                          type="button"
                          disabled={replayBusy}
                          onClick={() => void handleDiscardReplay(replaySim.id)}
                          className="rounded-lg border border-stone-200 px-3 py-1.5 text-stone-700 hover:bg-stone-50 disabled:opacity-50"
                        >
                          Discard
                        </button>
                      </div>
                    )}
                  </div>
                )}
              </div>

              {/* Right: Recorded Replay Calls & Recent Ledger */}
              <div className="space-y-4">
                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-2.5 max-h-96 overflow-y-auto text-xs">
                  <div className="text-sm font-semibold text-stone-900">
                    Recorded Modb.Replay Call Log ({replayStatus?.calls.length ?? 0})
                  </div>
                  {(replayStatus?.calls.length ?? 0) === 0 ? (
                    <p className="text-stone-400">
                      No Modb.World proposals accepted under replay logging yet.
                    </p>
                  ) : (
                    (replayStatus?.calls ?? []).map((c) => (
                      <div
                        key={c.seq}
                        className="rounded-lg border border-stone-100 bg-stone-50 p-2.5 space-y-1.5"
                      >
                        <div className="flex items-center justify-between font-mono text-[11px] text-stone-600">
                          <span>
                            #{c.seq} · {c.principal} · {c.action}
                          </span>
                          <span>{c.page_id ?? c.database_id ?? c.world_id ?? ""}</span>
                        </div>
                        <div className="text-stone-800">{c.reason}</div>
                        <div className="flex flex-wrap gap-1.5 pt-0.5">
                          {c.world_id && (
                            <button
                              type="button"
                              onClick={() => {
                                setReplayFilterKind("exclude_world");
                                setReplayTarget(c.world_id ?? "");
                                setReplayDesc(`Undo World ${c.world_id} (${c.principal})`);
                              }}
                              className="rounded border border-stone-200 bg-white px-2 py-0.5 text-[10px] text-stone-700 hover:bg-stone-100"
                            >
                              Exclude World
                            </button>
                          )}
                          <button
                            type="button"
                            onClick={() => {
                              setReplayFilterKind("exclude_principal");
                              setReplayTarget(c.principal);
                              setReplayDesc(`Exclude actor ${c.principal}`);
                            }}
                            className="rounded border border-stone-200 bg-white px-2 py-0.5 text-[10px] text-stone-700 hover:bg-stone-100"
                          >
                            Exclude Actor
                          </button>
                          <button
                            type="button"
                            onClick={() => {
                              setReplayFilterKind("stop_before_seq");
                              setReplayStopSeq(c.seq);
                              setReplayDesc(`Rewind before call #${c.seq}`);
                            }}
                            className="rounded border border-stone-200 bg-white px-2 py-0.5 text-[10px] text-stone-700 hover:bg-stone-100"
                          >
                            Rewind Before #{c.seq}
                          </button>
                        </div>
                      </div>
                    ))
                  )}
                </div>

                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-2 max-h-72 overflow-y-auto">
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

            <div className="lg:col-span-2 rounded-2xl border border-stone-200 bg-white p-5 space-y-2 text-xs">
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <GitPullRequest className="h-4 w-4 text-teal-700" />
                Inbound GitHub PR-to-Runbook Bridge
              </div>
              <p className="text-stone-600">
                Signed <code className="font-mono">pull_request</code> webhooks sent to{" "}
                <code className="font-mono">POST /api/webhooks/github</code> (verified via{" "}
                <code className="font-mono">X-Hub-Signature-256</code> against{" "}
                <code className="font-mono">VELLUM_GITHUB_WEBHOOK_SECRET</code>) run under{" "}
                <code className="font-mono">@github-pr-bridge</code> (<code className="font-mono">read</code> +{" "}
                <code className="font-mono">propose</code> only), match affected docs with{" "}
                <code className="font-mono">Db.search_pages_hybrid</code>, and open inspectable{" "}
                <code className="font-mono">Modb.World</code> Change Proposals without ever writing live content.
              </p>
            </div>
          </div>
        )}
      </div>
    </WorkspaceLayout>
  );
}
