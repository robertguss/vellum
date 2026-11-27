import { Link } from "@inertiajs/react";
import {
  Activity,
  AlertTriangle,
  Bot,
  Download,
  Flame,
  GitBranch,
  GitCompare,
  GitPullRequest,
  History,
  KeyRound,
  Leaf,
  Link2,
  Lock,
  RotateCcw,
  ShieldAlert,
  ShieldCheck,
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
  DeptGroup,
  ErasureStatusResponse,
  FerpaAuditEntry,
  GardenReport,
  GrantTreeResponse,
  KillAllGrantsResponse,
  PurgeSecretResponse,
  ReplayProposalSummary,
  ReplayStatusResponse,
  TaintStatusResponse,
  VaultPolicy,
  VaultStatusResponse,
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
  const [tab, setTab] = useState<
    | "agents"
    | "delegation"
    | "garden"
    | "importer"
    | "replay"
    | "taint"
    | "erasure"
    | "vault"
    | "webhooks"
  >("agents");
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

  // Modb.Taint & Lethal Trifecta Control Plane
  const [taintStatus, setTaintStatus] = useState<TaintStatusResponse | null>(null);
  const [taintLoading, setTaintLoading] = useState(false);
  const [clearingSid, setClearingSid] = useState<string | null>(null);
  const [clearReason, setClearReason] = useState(
    "Admin reviewed untrusted provenance and approved taint reset"
  );

  // One-Click Modb.Erasure Secret Purge
  const [erasureStatus, setErasureStatus] = useState<ErasureStatusResponse | null>(null);
  const [erasureLoading, setErasureLoading] = useState(false);
  const [purgingKey, setPurgingKey] = useState<string | null>(null);
  const [customSubjectId, setCustomSubjectId] = useState("");
  const [customTokens, setCustomTokens] = useState("");
  const [customReason, setCustomReason] = useState("Incident response secret crypto-purge");
  const [purgeCompact, setPurgeCompact] = useState(true);

  // Sub-Delegation Control Plane (Modb.Grants Hierarchy + Live SSE + Kill Switch)
  const [grantTree, setGrantTree] = useState<GrantTreeResponse | null>(null);
  const [grantTreeLoading, setGrantTreeLoading] = useState(false);
  const [revokingTreeGrantId, setRevokingTreeGrantId] = useState<string | null>(null);
  const [killAllArmed, setKillAllArmed] = useState(false);
  const [killAllBusy, setKillAllBusy] = useState(false);
  const [grantsSseLive, setGrantsSseLive] = useState(false);
  const [grantEvents, setGrantEvents] = useState<
    Array<{ id: string; event: string; detail: string; at: string }>
  >([]);

  // FERPA / Restricted Vault & Department Groups
  const [vaultStatus, setVaultStatus] = useState<VaultStatusResponse | null>(null);
  const [vaultLoading, setVaultLoading] = useState(false);
  const [vaultBusy, setVaultBusy] = useState(false);
  const [newGroupName, setNewGroupName] = useState("");
  const [newGroupSlug, setNewGroupSlug] = useState("");
  const [newGroupDesc, setNewGroupDesc] = useState("");
  const [newGroupMembers, setNewGroupMembers] = useState<string[]>([]);
  const [selectedVaultColId, setSelectedVaultColId] = useState<string>("");
  const [policyTier, setPolicyTier] = useState<"standard" | "ferpa_restricted">("standard");
  const [policyGroupIds, setPolicyGroupIds] = useState<string[]>([]);
  const [policyPrincipalIds, setPolicyPrincipalIds] = useState<string[]>([]);
  const [policyAllowLocalAi, setPolicyAllowLocalAi] = useState(false);
  const [policyReason, setPolicyReason] = useState("Configure collection security tier");
  const [vaultAudit, setVaultAudit] = useState<FerpaAuditEntry[]>([]);
  const [vaultAuditColFilter, setVaultAuditColFilter] = useState("");
  const [vaultAuditActFilter, setVaultAuditActFilter] = useState("");

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
    } else if (tab === "taint") {
      void loadTaintStatus();
    } else if (tab === "erasure") {
      void loadErasureStatus();
    } else if (tab === "vault") {
      void loadVaultStatus();
    } else if (tab === "delegation") {
      void loadGrantTree();
      const es = new EventSource("/api/events?scope=grants");
      const pushEvent = (event: string, detail: string) => {
        setGrantEvents((prev) =>
          [
            {
              id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
              event,
              detail,
              at: new Date().toLocaleTimeString(),
            },
            ...prev,
          ].slice(0, 25)
        );
      };
      es.addEventListener("connected", () => {
        setGrantsSseLive(true);
        pushEvent("connected", "Subscribed to claims + grants SSE stream");
      });
      es.addEventListener("grants.snapshot", (ev) => {
        setGrantsSseLive(true);
        pushEvent("grants.snapshot", (ev as MessageEvent<string>).data);
      });
      for (const name of ["grant.minted", "grant.delegated", "grant.revoked", "grants.kill_all"]) {
        es.addEventListener(name, (ev) => {
          pushEvent(name, (ev as MessageEvent<string>).data);
          void loadGrantTree();
        });
      }
      es.onerror = () => {
        setGrantsSseLive(false);
      };
      return () => {
        es.close();
        setGrantsSseLive(false);
      };
    }
  }, [tab]);

  async function loadGrantTree() {
    setGrantTreeLoading(true);
    try {
      const res = await apiFetch<GrantTreeResponse>("/api/admin/grants/tree");
      setGrantTree(res);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not load Modb.Grants tree");
    } finally {
      setGrantTreeLoading(false);
    }
  }

  function applyPolicyForm(colId: string, status: VaultStatusResponse | null) {
    setSelectedVaultColId(colId);
    const pol: VaultPolicy | undefined = status?.policies.find((p) => p.collection_id === colId);
    setPolicyTier(pol?.security_tier === "ferpa_restricted" ? "ferpa_restricted" : "standard");
    setPolicyGroupIds(pol?.allowed_group_ids ?? []);
    setPolicyPrincipalIds(pol?.allowed_principal_ids ?? []);
    setPolicyAllowLocalAi(Boolean(pol?.allow_local_ai));
  }

  async function loadVaultStatus(preferredColId?: string) {
    setVaultLoading(true);
    try {
      const res = await apiFetch<VaultStatusResponse>("/api/admin/vault/status");
      setVaultStatus(res);
      setVaultAudit(res.recent_audit ?? []);
      const targetCol =
        preferredColId ||
        (res.collections.some((c) => c.id === selectedVaultColId)
          ? selectedVaultColId
          : res.collections[0]?.id ?? "");
      if (targetCol) {
        applyPolicyForm(targetCol, res);
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not load FERPA Vault status");
    } finally {
      setVaultLoading(false);
    }
  }

  async function loadFerpaAudit(colFilter = vaultAuditColFilter, actFilter = vaultAuditActFilter) {
    setVaultLoading(true);
    try {
      const params = new URLSearchParams();
      if (colFilter.trim()) params.set("collection_id", colFilter.trim());
      if (actFilter.trim()) params.set("action", actFilter.trim());
      params.set("limit", "100");
      const res = await apiFetch<{ entries: FerpaAuditEntry[] }>(
        `/api/admin/ferpa/audit?${params.toString()}`
      );
      setVaultAudit(res.entries ?? []);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not load FERPA read audit logs");
    } finally {
      setVaultLoading(false);
    }
  }

  async function handleCreateGroup(e: React.FormEvent) {
    e.preventDefault();
    if (!newGroupName.trim()) return;
    setVaultBusy(true);
    setError(null);
    setNotice(null);
    try {
      const res = await apiFetch<{ group: DeptGroup }>("/api/admin/groups", {
        method: "POST",
        body: JSON.stringify({
          name: newGroupName.trim(),
          slug: newGroupSlug.trim() || null,
          description: newGroupDesc.trim() || null,
          member_principal_ids: newGroupMembers,
        }),
      });
      setNotice(`Created Department Group "${res.group.name}" (${res.group.id})`);
      setNewGroupName("");
      setNewGroupSlug("");
      setNewGroupDesc("");
      setNewGroupMembers([]);
      await loadVaultStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not create Department Group");
    } finally {
      setVaultBusy(false);
    }
  }

  async function handleDeleteGroup(groupId: string) {
    setVaultBusy(true);
    setError(null);
    setNotice(null);
    try {
      await apiFetch<{ deleted: boolean; id: string }>(
        `/api/admin/groups/${encodeURIComponent(groupId)}`,
        { method: "DELETE" }
      );
      setNotice(`Deleted Department Group ${groupId}`);
      await loadVaultStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not delete Department Group");
    } finally {
      setVaultBusy(false);
    }
  }

  async function handleSaveCollectionSecurity(e: React.FormEvent) {
    e.preventDefault();
    if (!selectedVaultColId) return;
    setVaultBusy(true);
    setError(null);
    setNotice(null);
    try {
      const res = await apiFetch<{ policy: VaultPolicy }>(
        `/api/collections/${encodeURIComponent(selectedVaultColId)}/security`,
        {
          method: "PATCH",
          body: JSON.stringify({
            security_tier: policyTier,
            allowed_group_ids: policyGroupIds,
            allowed_principal_ids: policyPrincipalIds,
            allow_local_ai: policyAllowLocalAi,
            reason: policyReason.trim() || null,
          }),
        }
      );
      setNotice(
        `Saved security tier "${res.policy.security_tier}" on collection ${res.policy.collection_id}`
      );
      await loadVaultStatus(selectedVaultColId);
    } catch (err) {
      setError(
        err instanceof ApiError ? err.message : "Could not update collection security policy"
      );
    } finally {
      setVaultBusy(false);
    }
  }

  function toggleId(list: string[], id: string, setList: (next: string[]) => void) {
    setList(list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
  }

  async function handleRevokeTreeGrant(grantId: string) {
    setRevokingTreeGrantId(grantId);
    setError(null);
    setNotice(null);
    try {
      const res = await apiFetch<{ revoked_grant_id: string; cascaded_count?: number }>(
        `/api/admin/grants/${encodeURIComponent(grantId)}/revoke`,
        { method: "POST", body: JSON.stringify({}) }
      );
      setNotice(
        `Revoked grant subtree ${res.revoked_grant_id} (${res.cascaded_count ?? 1} grant(s) disabled).`
      );
      await loadGrantTree();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not revoke grant subtree");
    } finally {
      setRevokingTreeGrantId(null);
    }
  }

  async function handleKillAllAgents() {
    setKillAllBusy(true);
    setError(null);
    setNotice(null);
    try {
      const res = await apiFetch<KillAllGrantsResponse>("/api/admin/grants/kill-all", {
        method: "POST",
        body: JSON.stringify({ reason: "Admin Console emergency kill switch" }),
      });
      setKillAllArmed(false);
      setNotice(
        `Emergency Kill Switch executed: revoked ${res.revoked_count} active agent grant(s).`
      );
      await loadGrantTree();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Emergency kill switch failed");
    } finally {
      setKillAllBusy(false);
    }
  }

  async function loadErasureStatus() {
    setErasureLoading(true);
    try {
      const st = await apiFetch<ErasureStatusResponse>("/api/admin/erasure/status");
      setErasureStatus(st);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not load Modb.Erasure status");
    } finally {
      setErasureLoading(false);
    }
  }

  async function handlePurgeSecret(opts: {
    key: string;
    page_id?: string | null;
    block_id?: string | null;
    comment_id?: string | null;
    mode: "redact" | "delete_page";
    subject_id?: string;
    match_tokens?: string[];
    reason?: string;
  }) {
    setPurgingKey(opts.key);
    setError(null);
    setNotice(null);
    try {
      const res = await apiFetch<PurgeSecretResponse>("/api/admin/erasure/purge", {
        method: "POST",
        body: JSON.stringify({
          page_id: opts.page_id ?? null,
          block_id: opts.block_id ?? null,
          comment_id: opts.comment_id ?? null,
          mode: opts.mode,
          subject_id: opts.subject_id ?? null,
          match_tokens: opts.match_tokens ?? [],
          compact: purgeCompact,
          reason: opts.reason ?? customReason,
        }),
      });
      setNotice(
        `Modb.Erasure receipt ${res.receipt.id} completed (${res.blocks_redacted} blocks, ${res.receipt.audit_entries_redacted} audit entries scrubbed, compacted=${res.receipt.compacted}).`
      );
      await loadErasureStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Modb.Erasure purge failed");
    } finally {
      setPurgingKey(null);
    }
  }

  async function loadTaintStatus() {
    setTaintLoading(true);
    try {
      const st = await apiFetch<TaintStatusResponse>("/api/admin/taint/status");
      setTaintStatus(st);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not load Modb.Taint status");
    } finally {
      setTaintLoading(false);
    }
  }

  async function handleClearTaint(sessionId: string) {
    setClearingSid(sessionId);
    setError(null);
    setNotice(null);
    try {
      await apiFetch(`/api/admin/taint/sessions/${encodeURIComponent(sessionId)}/clear`, {
        method: "POST",
        body: JSON.stringify({ reason: clearReason }),
      });
      setNotice(`Cleared Modb.Taint session ${sessionId}`);
      await loadTaintStatus();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to clear taint session");
    } finally {
      setClearingSid(null);
    }
  }

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
        nested_page_count?: number;
        database_count: number;
        skipped_duplicate_databases?: number;
        row_count: number;
      }>("/api/import/notion", {
        method: "POST",
        body: JSON.stringify({
          collection_id: impColId || collections[0]?.id || "col_general",
          pages,
          databases: databasesPayload,
        }),
      });
      const extraParts: string[] = [];
      if ((res.nested_page_count ?? 0) > 0) {
        extraParts.push(`${res.nested_page_count} nested`);
      }
      if ((res.skipped_duplicate_databases ?? 0) > 0) {
        extraParts.push(`${res.skipped_duplicate_databases} duplicate CSV view(s) skipped`);
      }
      const extraSuffix = extraParts.length > 0 ? ` (${extraParts.join(", ")})` : "";
      setImpResult(
        `Imported ${res.page_count} page(s), ${res.database_count} database(s), and ${res.row_count} row(s)${extraSuffix}.`
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
                ["delegation", "Delegation Tree", GitBranch],
                ["garden", "Gardening", Leaf],
                ["importer", "Notion Importer", Upload],
                ["replay", "Selective Undo", RotateCcw],
                ["taint", "Taint & Safety", ShieldAlert],
                ["erasure", "Secret Purge", Flame],
                ["vault", "FERPA Vault", ShieldCheck],
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
          <div className="space-y-4">
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

            <div className="rounded-2xl border border-stone-200 bg-stone-50 p-6 space-y-2.5">
              <h3 className="text-sm font-semibold text-stone-900">
                Full Workspace Migration (API-First + Hybrid ZIP CLI)
              </h3>
              <p className="text-xs text-stone-600">
                For full institutional Notion workspaces with deep nesting, dual/self relations,
                rollups, formulas, covers, and large media attachments (up to 500 MiB chunked), run
                the resumable 3-pass migration engine:
              </p>
              <pre className="overflow-x-auto rounded-lg border border-stone-200 bg-white p-3 text-[11px] font-mono text-stone-800">
                {`node scripts/notion-migrate.mjs \\
  --api-token-file /path/to/notion.tok \\
  --zip /path/to/notion-export.zip \\
  --vellum-url http://127.0.0.1:8080 \\
  --state /tmp/vellum-migrate-state.json`}
              </pre>
              <p className="text-[11px] text-stone-500">
                Supports <code>--dry-run</code> validation, <code>--solo-login</code> or{" "}
                <code>--vellum-token</code> auth, and idempotent resumes via <code>--state</code>.
              </p>
            </div>
          </div>
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

        {/* TAB 6: MODB.TAINT & LETHAL TRIFECTA CONTROL PLANE */}
        {tab === "taint" && (
          <div className="space-y-6">
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-stone-200 bg-white p-5">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  <ShieldAlert className="h-4 w-4 text-amber-700" />
                  Modb.Taint Lethal Trifecta Defense
                </div>
                <p className="text-xs text-stone-500 mt-0.5">
                  Monotonic taint tracking across MCP, RLM child forks, imported Notion docs, and
                  GitHub PR proposals with two-way write-down &amp; exfiltration blocking.
                </p>
              </div>
              <button
                type="button"
                onClick={() => void loadTaintStatus()}
                disabled={taintLoading}
                className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50 disabled:opacity-50"
              >
                {taintLoading ? "Refreshing..." : "Refresh Status"}
              </button>
            </div>

            {taintStatus && (
              <>
                <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                  <div className="rounded-2xl border border-stone-200 bg-white p-4">
                    <div className="text-[11px] uppercase tracking-wider text-stone-500">
                      Total Sessions
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-stone-950">
                      {taintStatus.sessions.length}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-amber-200 bg-amber-50/50 p-4">
                    <div className="text-[11px] uppercase tracking-wider text-amber-800">
                      Active Tainted
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-amber-950">
                      {taintStatus.sessions.filter((s) => s.untrusted_tainted).length}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-red-200 bg-red-50/40 p-4">
                    <div className="text-[11px] uppercase tracking-wider text-red-700">
                      Lethal Trifecta Blocks
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-red-900">
                      {taintStatus.sessions.reduce((acc, s) => acc + s.blocked_attempts, 0)}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-stone-200 bg-white p-4">
                    <div className="text-[11px] uppercase tracking-wider text-stone-500">
                      Untrusted Markers
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-stone-950">
                      {taintStatus.untrusted.pages.length +
                        taintStatus.untrusted.blocks.length +
                        taintStatus.untrusted.proposals.length}
                    </div>
                  </div>
                </div>

                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3 text-xs">
                  <div className="text-sm font-semibold text-stone-900">Active Policy Rules</div>
                  <div className="flex flex-wrap gap-2">
                    <span className="rounded-full border border-stone-200 bg-stone-50 px-2.5 py-1 font-mono">
                      max_sensitivity_when_tainted={taintStatus.policy.max_sensitivity_when_tainted}
                    </span>
                    <span className="rounded-full border border-stone-200 bg-stone-50 px-2.5 py-1 font-mono">
                      block_write_down={String(taintStatus.policy.block_write_down)}
                    </span>
                    {taintStatus.policy.external_actions.map((act) => (
                      <span
                        key={act}
                        className="rounded-full border border-red-200 bg-red-50 px-2.5 py-1 font-mono text-red-800"
                      >
                        action:{act}
                      </span>
                    ))}
                    {taintStatus.policy.exfil_sinks.map((sink) => (
                      <span
                        key={sink}
                        className="rounded-full border border-amber-200 bg-amber-50 px-2.5 py-1 font-mono text-amber-900"
                      >
                        sink:{sink}
                      </span>
                    ))}
                  </div>
                </div>

                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div className="text-sm font-semibold text-stone-900">
                      Tracked Sessions &amp; Fork Lineage ({taintStatus.sessions.length})
                    </div>
                    <input
                      value={clearReason}
                      onChange={(e) => setClearReason(e.target.value)}
                      placeholder="Audit reason when clearing session taint"
                      className="w-full sm:w-96 rounded-lg border border-stone-200 px-3 py-1.5 text-xs"
                    />
                  </div>
                  {taintStatus.sessions.length === 0 ? (
                    <p className="text-xs text-stone-400">
                      No Modb.Taint sessions recorded yet. Run MCP search/read or Tier 2 RLM
                      queries to inspect live session state.
                    </p>
                  ) : (
                    <div className="overflow-x-auto">
                      <table className="w-full text-left text-xs">
                        <thead>
                          <tr className="border-b border-stone-200 text-stone-500">
                            <th className="py-2 pr-3 font-medium">Session ID</th>
                            <th className="py-2 pr-3 font-medium">Principal / Parent</th>
                            <th className="py-2 pr-3 font-medium">Status</th>
                            <th className="py-2 pr-3 font-medium">Untrusted Sources</th>
                            <th className="py-2 pr-3 font-medium">Blocks</th>
                            <th className="py-2 font-medium text-right">Action</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-stone-100">
                          {taintStatus.sessions.map((s) => (
                            <tr key={s.id}>
                              <td className="py-2.5 pr-3 font-mono font-medium text-stone-900">
                                {s.id}
                              </td>
                              <td className="py-2.5 pr-3 text-stone-600">
                                <div className="font-mono">{s.principal}</div>
                                {s.parent_session_id && (
                                  <div className="text-[11px] font-mono text-indigo-700">
                                    forked from {s.parent_session_id}
                                  </div>
                                )}
                              </td>
                              <td className="py-2.5 pr-3">
                                {s.untrusted_tainted ? (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold text-amber-900">
                                    <ShieldAlert className="h-3 w-3" />
                                    Tainted
                                  </span>
                                ) : (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-semibold text-emerald-800">
                                    <ShieldCheck className="h-3 w-3" />
                                    Clean{s.cleared_by ? ` (${s.cleared_by})` : ""}
                                  </span>
                                )}
                              </td>
                              <td className="py-2.5 pr-3 font-mono text-[11px] text-stone-600 max-w-xs truncate">
                                {s.untrusted_sources.length > 0
                                  ? s.untrusted_sources.join(", ")
                                  : "—"}
                              </td>
                              <td className="py-2.5 pr-3 font-mono">
                                {s.blocked_attempts > 0 ? (
                                  <span className="rounded bg-red-100 px-1.5 py-0.5 font-semibold text-red-800">
                                    {s.blocked_attempts}
                                  </span>
                                ) : (
                                  "0"
                                )}
                              </td>
                              <td className="py-2.5 text-right">
                                {s.untrusted_tainted ? (
                                  <button
                                    type="button"
                                    disabled={clearingSid === s.id}
                                    onClick={() => void handleClearTaint(s.id)}
                                    className="rounded-lg border border-amber-300 bg-amber-50 px-2.5 py-1 font-medium text-amber-900 hover:bg-amber-100 disabled:opacity-50"
                                  >
                                    {clearingSid === s.id ? "Clearing..." : "Clear Taint"}
                                  </button>
                                ) : (
                                  <span className="text-[11px] text-stone-400">Cleared</span>
                                )}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>

                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-2 text-xs">
                  <div className="text-sm font-semibold text-stone-900">
                    Untrusted Provenance Inventory
                  </div>
                  <div className="text-stone-600 font-mono">
                    Pages ({taintStatus.untrusted.pages.length}) · Blocks (
                    {taintStatus.untrusted.blocks.length}) · Proposals (
                    {taintStatus.untrusted.proposals.length})
                  </div>
                </div>
              </>
            )}
          </div>
        )}

        {/* TAB 7: ONE-CLICK MODB.ERASURE SECRET PURGE */}
        {tab === "erasure" && (
          <div className="space-y-6">
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-stone-200 bg-white p-5">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  <Flame className="h-4 w-4 text-rose-700" />
                  One-Click Modb.Erasure Secret Crypto-Purge
                </div>
                <p className="text-xs text-stone-500 mt-0.5">
                  Shreds AES-256-GCM subject keys, sanitizes blocks/comments/FTS/Vec, scrubs{" "}
                  <code className="font-mono">_modb_replay_calls</code> &amp; re-chains{" "}
                  <code className="font-mono">_modb_audit</code>, evicts dead B+Tree pages via{" "}
                  <code className="font-mono">compact_after_erasure</code>, and issues downloadable{" "}
                  <code className="font-mono">ErasureReceipt</code> proofs.
                </p>
              </div>
              <div className="flex items-center gap-3">
                <label className="inline-flex items-center gap-1.5 text-xs text-stone-700">
                  <input
                    type="checkbox"
                    checked={purgeCompact}
                    onChange={(e) => setPurgeCompact(e.target.checked)}
                    className="rounded border-stone-300"
                  />
                  Physical B+Tree Compaction
                </label>
                <button
                  type="button"
                  onClick={() => void loadErasureStatus()}
                  disabled={erasureLoading}
                  className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50 disabled:opacity-50"
                >
                  {erasureLoading ? "Scanning..." : "Scan Workspace"}
                </button>
              </div>
            </div>

            {erasureStatus && (
              <>
                <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                  <div className="rounded-2xl border border-rose-200 bg-rose-50/50 p-4">
                    <div className="text-[11px] uppercase tracking-wider text-rose-800">
                      Detected Secrets
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-rose-950">
                      {erasureStatus.findings.length}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-stone-200 bg-white p-4">
                    <div className="text-[11px] uppercase tracking-wider text-stone-500">
                      Erasure Receipts
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-stone-950">
                      {erasureStatus.receipts.length}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-stone-200 bg-white p-4">
                    <div className="text-[11px] uppercase tracking-wider text-stone-500">
                      Audit &amp; Replay Scrubbed
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-stone-950">
                      {erasureStatus.receipts.reduce(
                        (acc, r) => acc + r.audit_entries_redacted + r.replay_calls_scrubbed,
                        0
                      )}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-emerald-200 bg-emerald-50/40 p-4">
                    <div className="text-[11px] uppercase tracking-wider text-emerald-800">
                      Compacted Receipts
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-emerald-950">
                      {erasureStatus.receipts.filter((r) => r.compacted).length}
                    </div>
                  </div>
                </div>

                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
                  <div className="text-sm font-semibold text-stone-900">
                    Detected Secrets Across Active Pages &amp; Comments (
                    {erasureStatus.findings.length})
                  </div>
                  {erasureStatus.findings.length === 0 ? (
                    <p className="text-xs text-stone-400">
                      Clean scan: no exposed API keys, GitHub/Slack/AWS tokens, webhook secrets,
                      agent tokens, or PEM keys detected.
                    </p>
                  ) : (
                    <div className="divide-y divide-stone-100">
                      {erasureStatus.findings.map((f, idx) => {
                        const rowKey = `${f.page_id}-${f.match_sha256}-${idx}`;
                        return (
                          <div
                            key={rowKey}
                            className="py-3 flex flex-wrap items-center justify-between gap-3 text-xs"
                          >
                            <div className="space-y-1 min-w-0">
                              <div className="flex flex-wrap items-center gap-2">
                                <span className="rounded-full bg-rose-100 px-2 py-0.5 text-[10px] font-semibold uppercase text-rose-800">
                                  {f.severity}
                                </span>
                                <span className="font-semibold text-stone-900">{f.label}</span>
                                <span className="rounded bg-stone-100 px-2 py-0.5 font-mono text-[11px] text-stone-800">
                                  {f.masked_preview}
                                </span>
                              </div>
                              <div className="text-stone-500">
                                Page:{" "}
                                <Link
                                  href={`/p/${f.page_id}`}
                                  className="text-blue-700 hover:underline font-medium"
                                >
                                  {f.page_title}
                                </Link>{" "}
                                · {f.target_kind}
                                {f.block_id ? ` (${f.block_id})` : ""}
                                {f.comment_id ? ` (${f.comment_id})` : ""}
                              </div>
                            </div>
                            <div className="flex items-center gap-2 shrink-0">
                              <button
                                type="button"
                                disabled={purgingKey === `${rowKey}-redact`}
                                onClick={() =>
                                  void handlePurgeSecret({
                                    key: `${rowKey}-redact`,
                                    page_id: f.page_id,
                                    block_id: f.block_id,
                                    comment_id: f.comment_id,
                                    mode: "redact",
                                  })
                                }
                                className="rounded-lg bg-rose-700 px-3 py-1.5 font-medium text-white hover:bg-rose-800 disabled:opacity-50"
                              >
                                {purgingKey === `${rowKey}-redact`
                                  ? "Purging..."
                                  : "Purge & Redact"}
                              </button>
                              <button
                                type="button"
                                disabled={purgingKey === `${rowKey}-delete`}
                                onClick={() =>
                                  void handlePurgeSecret({
                                    key: `${rowKey}-delete`,
                                    page_id: f.page_id,
                                    mode: "delete_page",
                                  })
                                }
                                className="rounded-lg border border-rose-300 bg-white px-2.5 py-1.5 font-medium text-rose-800 hover:bg-rose-50 disabled:opacity-50"
                              >
                                Purge Page
                              </button>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>

                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    const toks = customTokens
                      .split(/\n|,/)
                      .map((s) => s.trim())
                      .filter(Boolean);
                    if (toks.length === 0) return;
                    void handlePurgeSecret({
                      key: "custom-purge",
                      mode: "redact",
                      subject_id: customSubjectId.trim() || undefined,
                      match_tokens: toks,
                      reason: customReason,
                    });
                  }}
                  className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3 text-xs"
                >
                  <div className="text-sm font-semibold text-stone-900">
                    Custom Token / Subject Crypto-Purge
                  </div>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <div>
                      <label className="font-medium text-stone-700">
                        Subject ID (optional)
                      </label>
                      <input
                        value={customSubjectId}
                        onChange={(e) => setCustomSubjectId(e.target.value)}
                        placeholder="e.g. customer:acme or leaked-key-2026"
                        className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2 font-mono"
                      />
                    </div>
                    <div>
                      <label className="font-medium text-stone-700">Audit Reason</label>
                      <input
                        value={customReason}
                        onChange={(e) => setCustomReason(e.target.value)}
                        className="mt-1 w-full rounded-lg border border-stone-200 px-3 py-2"
                      />
                    </div>
                  </div>
                  <div>
                    <label className="font-medium text-stone-700">
                      Exact Token(s) / PII Strings to Scrub (comma or newline separated)
                    </label>
                    <textarea
                      rows={2}
                      value={customTokens}
                      onChange={(e) => setCustomTokens(e.target.value)}
                      placeholder="Paste exact sensitive string to scrub from blocks, comments, FTS, Vec, Replay, and Audit"
                      className="mt-1 w-full rounded-lg border border-stone-200 p-2 font-mono"
                    />
                  </div>
                  <button
                    type="submit"
                    disabled={purgingKey === "custom-purge" || !customTokens.trim()}
                    className="rounded-lg bg-stone-900 px-4 py-2 font-medium text-white disabled:opacity-50"
                  >
                    {purgingKey === "custom-purge"
                      ? "Executing Purge..."
                      : "Execute Modb.Erasure Purge"}
                  </button>
                </form>

                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
                  <div className="text-sm font-semibold text-stone-900">
                    Verifiable Erasure Receipts ({erasureStatus.receipts.length})
                  </div>
                  {erasureStatus.receipts.length === 0 ? (
                    <p className="text-xs text-stone-400">
                      No Modb.Erasure receipts issued yet.
                    </p>
                  ) : (
                    <div className="space-y-2.5">
                      {erasureStatus.receipts.map((r) => (
                        <div
                          key={r.id}
                          className="rounded-xl border border-stone-200 bg-stone-50 p-3.5 text-xs space-y-1.5"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="flex flex-wrap items-center gap-2 font-mono">
                              <span className="font-semibold text-stone-900">{r.id}</span>
                              <span className="text-stone-500">by {r.erased_by}</span>
                              <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-800">
                                key_shredded={String(r.key_shredded)}
                              </span>
                              <span className="rounded bg-stone-200 px-1.5 py-0.5 text-[10px] font-semibold text-stone-800">
                                compacted={String(r.compacted)}
                              </span>
                            </div>
                            <a
                              href={`/api/admin/erasure/receipts/${encodeURIComponent(r.id)}/download`}
                              className="inline-flex items-center gap-1 rounded-lg border border-stone-300 bg-white px-2.5 py-1 font-medium text-stone-800 hover:bg-stone-100"
                            >
                              <Download className="h-3 w-3" />
                              Download Receipt
                            </a>
                          </div>
                          <div className="text-stone-600">
                            rows={r.rows_deleted} · fts={r.fts_docs_deleted} · vec=
                            {r.vec_docs_deleted} · audit={r.audit_entries_redacted} · replay=
                            {r.replay_calls_scrubbed}
                          </div>
                          <div className="font-mono text-[10px] text-stone-400 truncate">
                            subj_sha256={r.subject_id_sha256} · tip: {r.pre_erasure_tip_hash.slice(0, 12)} →{" "}
                            {r.post_erasure_tip_hash.slice(0, 12)}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        )}

        {/* TAB 8: SUB-DELEGATION CONTROL PLANE */}
        {tab === "delegation" && (
          <div className="space-y-6">
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-stone-200 bg-white p-5">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  <GitBranch className="h-4 w-4 text-indigo-700" />
                  Modb.Grants Sub-Delegation Control Plane
                </div>
                <p className="text-xs text-stone-500 mt-0.5">
                  Attenuated parent → child delegation chains, ancestor call-budget conservation
                  gauges, live SSE lifecycle stream, and cascading instant revocation.
                </p>
              </div>
              <div className="flex flex-wrap items-center gap-2 text-xs">
                <span
                  className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-medium ${
                    grantsSseLive
                      ? "bg-emerald-100 text-emerald-800"
                      : "bg-stone-100 text-stone-600"
                  }`}
                >
                  <Activity className="h-3 w-3" />
                  {grantsSseLive ? "Live SSE Connected" : "Connecting SSE..."}
                </span>
                <button
                  type="button"
                  onClick={() => void loadGrantTree()}
                  disabled={grantTreeLoading}
                  className="rounded-lg border border-stone-200 px-3 py-1.5 font-medium text-stone-700 hover:bg-stone-50 disabled:opacity-50"
                >
                  {grantTreeLoading ? "Refreshing..." : "Refresh Tree"}
                </button>
                {!killAllArmed ? (
                  <button
                    type="button"
                    onClick={() => setKillAllArmed(true)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-red-300 bg-red-50 px-3 py-1.5 font-medium text-red-800 hover:bg-red-100"
                  >
                    <Lock className="h-3.5 w-3.5" />
                    Arm Emergency Kill Switch
                  </button>
                ) : (
                  <div className="flex items-center gap-1.5">
                    <button
                      type="button"
                      disabled={killAllBusy}
                      onClick={() => void handleKillAllAgents()}
                      className="rounded-lg bg-red-700 px-3 py-1.5 font-semibold text-white hover:bg-red-800 disabled:opacity-50"
                    >
                      {killAllBusy ? "Revoking All..." : "Confirm Kill All Agents"}
                    </button>
                    <button
                      type="button"
                      onClick={() => setKillAllArmed(false)}
                      className="rounded-lg border border-stone-200 px-2.5 py-1.5 text-stone-600 hover:bg-stone-50"
                    >
                      Cancel
                    </button>
                  </div>
                )}
              </div>
            </div>

            {grantTree && (
              <>
                <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                  <div className="rounded-2xl border border-stone-200 bg-white p-4">
                    <div className="text-[11px] uppercase tracking-wider text-stone-500">
                      Active Grants (Agents)
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-stone-950">
                      {grantTree.summary.active_grants}{" "}
                      <span className="text-sm font-normal text-stone-500">
                        ({grantTree.summary.active_agent_grants})
                      </span>
                    </div>
                  </div>
                  <div className="rounded-2xl border border-indigo-200 bg-indigo-50/40 p-4">
                    <div className="text-[11px] uppercase tracking-wider text-indigo-800">
                      Delegated Sub-Grants
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-indigo-950">
                      {grantTree.summary.delegated_grants}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-stone-200 bg-white p-4">
                    <div className="text-[11px] uppercase tracking-wider text-stone-500">
                      Agent Call Budget Used
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-stone-950">
                      {grantTree.summary.total_calls_used} / {grantTree.summary.total_call_budget}
                    </div>
                  </div>
                  <div className="rounded-2xl border border-red-200 bg-red-50/40 p-4">
                    <div className="text-[11px] uppercase tracking-wider text-red-700">
                      Revoked / Exhausted
                    </div>
                    <div className="mt-1 text-2xl font-semibold text-red-900">
                      {grantTree.summary.revoked_grants} / {grantTree.summary.exhausted_grants}
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                  <div className="lg:col-span-2 rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
                    <div className="text-sm font-semibold text-stone-900">
                      Grant Hierarchy &amp; Budget Gauges ({grantTree.grants.length})
                    </div>
                    {grantTree.grants.length === 0 ? (
                      <p className="text-xs text-stone-400">No grants recorded yet.</p>
                    ) : (
                      <div className="space-y-2.5">
                        {grantTree.grants.map((g) => {
                          const isAgent = g.principal_kind === "agent";
                          const barColor =
                            g.utilization_pct >= 90
                              ? "bg-rose-600"
                              : g.utilization_pct >= 65
                                ? "bg-amber-500"
                                : "bg-emerald-600";
                          return (
                            <div
                              key={g.id}
                              style={{ marginLeft: `${Math.min(g.depth, 6) * 20}px` }}
                              className="rounded-xl border border-stone-200 bg-stone-50/70 p-3.5 text-xs space-y-2"
                            >
                              <div className="flex flex-wrap items-center justify-between gap-2">
                                <div className="flex flex-wrap items-center gap-2">
                                  {g.depth > 0 && (
                                    <span className="font-mono text-stone-400">└─</span>
                                  )}
                                  <span className="font-mono font-semibold text-stone-900">
                                    {g.principal_handle ?? g.principal_id}
                                  </span>
                                  <span className="rounded bg-stone-200/80 px-1.5 py-0.5 font-mono text-[10px] text-stone-700">
                                    {g.id}
                                  </span>
                                  <span
                                    className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase ${
                                      g.status === "active"
                                        ? "bg-emerald-100 text-emerald-800"
                                        : g.status === "revoked"
                                          ? "bg-red-100 text-red-800"
                                          : "bg-amber-100 text-amber-900"
                                    }`}
                                  >
                                    {g.status}
                                    {g.revoked_via && g.revoked_via !== g.id
                                      ? ` via ${g.revoked_via}`
                                      : ""}
                                  </span>
                                  {g.model_id && (
                                    <span className="font-mono text-[10px] text-stone-500">
                                      {g.model_id}
                                    </span>
                                  )}
                                </div>
                                {isAgent && g.status === "active" && (
                                  <button
                                    type="button"
                                    disabled={revokingTreeGrantId === g.id}
                                    onClick={() => void handleRevokeTreeGrant(g.id)}
                                    className="rounded-lg border border-red-300 bg-white px-2.5 py-1 font-medium text-red-700 hover:bg-red-50 disabled:opacity-50"
                                  >
                                    {revokingTreeGrantId === g.id
                                      ? "Revoking..."
                                      : `Revoke Tree (${g.descendant_count + 1})`}
                                  </button>
                                )}
                              </div>

                              <div className="flex flex-wrap items-center gap-3 text-[11px] text-stone-600">
                                <span>
                                  Actions:{" "}
                                  <code className="font-mono">
                                    {g.allowed_actions.join(", ")}
                                  </code>
                                </span>
                                {g.allowed_collections && (
                                  <span>
                                    Scopes:{" "}
                                    <code className="font-mono">
                                      {g.allowed_collections.join(", ")}
                                    </code>
                                  </span>
                                )}
                              </div>

                              <div className="space-y-1">
                                <div className="flex justify-between font-mono text-[11px] text-stone-600">
                                  <span>
                                    Call Budget: {g.used_calls} / {g.max_calls}
                                  </span>
                                  <span>{g.utilization_pct}%</span>
                                </div>
                                <div className="h-1.5 w-full rounded-full bg-stone-200 overflow-hidden">
                                  <div
                                    className={`h-full ${barColor}`}
                                    style={{ width: `${g.utilization_pct}%` }}
                                  />
                                </div>
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    )}
                  </div>

                  <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-3">
                    <div className="text-sm font-semibold text-stone-900">
                      Live Grants SSE Feed ({grantEvents.length})
                    </div>
                    {grantEvents.length === 0 ? (
                      <p className="text-xs text-stone-400">
                        Waiting for grant lifecycle events...
                      </p>
                    ) : (
                      <div className="space-y-2 max-h-96 overflow-y-auto">
                        {grantEvents.map((ev) => (
                          <div
                            key={ev.id}
                            className="rounded-lg border border-stone-100 bg-stone-50 p-2.5 text-xs space-y-0.5"
                          >
                            <div className="flex justify-between font-mono text-[11px] text-stone-700 font-semibold">
                              <span>{ev.event}</span>
                              <span className="text-stone-400 font-normal">{ev.at}</span>
                            </div>
                            <div className="font-mono text-[10px] text-stone-500 break-all">
                              {ev.detail}
                            </div>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                </div>
              </>
            )}
          </div>
        )}

        {/* TAB 9: FERPA / RESTRICTED VAULT, DEPARTMENT GROUPS & AUDIT */}
        {tab === "vault" && (
          <div className="space-y-6">
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-stone-200 bg-white p-5">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  <ShieldCheck className="h-4 w-4 text-rose-700" />
                  Opt-In FERPA / Restricted Vault &amp; Department Groups
                </div>
                <p className="text-xs text-stone-500 mt-0.5">
                  Enforces strict Department Group &amp; principal allowlists across pages, DBs,
                  search, backlinks, MCP, and sync; locks external AI, webhooks, and{" "}
                  <code className="font-mono">/llms.txt</code>; records hash-chained{" "}
                  <code className="font-mono">Modb.Ledger</code> read/export audit trails.
                </p>
              </div>
              <button
                type="button"
                disabled={vaultLoading}
                onClick={() => void loadVaultStatus()}
                className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-3 py-1.5 text-xs font-medium text-stone-800 hover:bg-stone-100 disabled:opacity-50"
              >
                <RotateCcw className="h-3.5 w-3.5" />
                {vaultLoading ? "Refreshing..." : "Refresh Vault"}
              </button>
            </div>

            {vaultStatus && (
              <>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                  {/* CARD 1: DEPARTMENT GROUPS */}
                  <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                    <div>
                      <h2 className="text-sm font-semibold text-stone-900">Department Groups</h2>
                      <p className="text-xs text-stone-500">
                        Manage reusable campus/department access groups referenced by Restricted
                        Vault collection allowlists.
                      </p>
                    </div>

                    {vaultStatus.groups.length === 0 ? (
                      <p className="text-xs text-stone-400">No Department Groups created yet.</p>
                    ) : (
                      <div className="space-y-2.5">
                        {vaultStatus.groups.map((grp) => (
                          <div
                            key={grp.id}
                            className="rounded-xl border border-stone-200 bg-stone-50/60 p-3 flex items-start justify-between gap-3"
                          >
                            <div className="space-y-1">
                              <div className="flex items-center gap-2">
                                <span className="text-xs font-semibold text-stone-900">
                                  {grp.name}
                                </span>
                                <span className="rounded bg-stone-200 px-1.5 py-0.5 font-mono text-[10px] text-stone-700">
                                  {grp.slug}
                                </span>
                                <span className="font-mono text-[10px] text-stone-400">
                                  {grp.id}
                                </span>
                              </div>
                              {grp.description && (
                                <p className="text-xs text-stone-600">{grp.description}</p>
                              )}
                              <div className="flex flex-wrap gap-1 pt-0.5">
                                {grp.member_principal_ids.length === 0 ? (
                                  <span className="text-[11px] text-stone-400">No members</span>
                                ) : (
                                  grp.member_principal_ids.map((pid) => {
                                    const pr = vaultStatus.principals.find((p) => p.id === pid);
                                    return (
                                      <span
                                        key={pid}
                                        className="rounded-full border border-stone-200 bg-white px-2 py-0.5 font-mono text-[10px] text-stone-700"
                                      >
                                        {pr ? `@${pr.handle}` : pid}
                                      </span>
                                    );
                                  })
                                )}
                              </div>
                            </div>
                            <button
                              type="button"
                              disabled={vaultBusy}
                              onClick={() => void handleDeleteGroup(grp.id)}
                              className="rounded-lg border border-red-200 bg-red-50 px-2.5 py-1 text-[11px] font-medium text-red-700 hover:bg-red-100 disabled:opacity-50"
                            >
                              Delete
                            </button>
                          </div>
                        ))}
                      </div>
                    )}

                    <form
                      onSubmit={handleCreateGroup}
                      className="border-t border-stone-100 pt-4 space-y-3"
                    >
                      <div className="text-xs font-semibold text-stone-800">
                        Create Department Group
                      </div>
                      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
                        <input
                          type="text"
                          required
                          value={newGroupName}
                          onChange={(e) => setNewGroupName(e.target.value)}
                          placeholder="Group name (e.g. Registrar)"
                          className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs text-stone-900"
                        />
                        <input
                          type="text"
                          value={newGroupSlug}
                          onChange={(e) => setNewGroupSlug(e.target.value)}
                          placeholder="Slug (optional)"
                          className="rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-mono text-stone-900"
                        />
                      </div>
                      <input
                        type="text"
                        value={newGroupDesc}
                        onChange={(e) => setNewGroupDesc(e.target.value)}
                        placeholder="Description (optional)"
                        className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-xs text-stone-900"
                      />
                      <div className="space-y-1.5">
                        <div className="text-[11px] font-medium text-stone-600">
                          Initial Members
                        </div>
                        <div className="flex flex-wrap gap-2 max-h-28 overflow-y-auto">
                          {vaultStatus.principals.map((pr) => (
                            <label
                              key={pr.id}
                              className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2 py-1 text-[11px] text-stone-700"
                            >
                              <input
                                type="checkbox"
                                checked={newGroupMembers.includes(pr.id)}
                                onChange={() =>
                                  toggleId(newGroupMembers, pr.id, setNewGroupMembers)
                                }
                              />
                              <span className="font-mono">@{pr.handle}</span>
                              <span className="text-stone-400">({pr.role})</span>
                            </label>
                          ))}
                        </div>
                      </div>
                      <button
                        type="submit"
                        disabled={vaultBusy || !newGroupName.trim()}
                        className="rounded-lg bg-stone-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
                      >
                        {vaultBusy ? "Saving..." : "Create Group"}
                      </button>
                    </form>
                  </div>

                  {/* CARD 2: COLLECTION SECURITY TIERS */}
                  <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                    <div>
                      <h2 className="text-sm font-semibold text-stone-900">
                        Collection Security Tiers
                      </h2>
                      <p className="text-xs text-stone-500">
                        Configure <code className="font-mono">standard</code> vs{" "}
                        <code className="font-mono">ferpa_restricted</code> Vault protection and
                        zero-exfiltration locks per collection.
                      </p>
                    </div>

                    <form onSubmit={handleSaveCollectionSecurity} className="space-y-3.5">
                      <div>
                        <label className="block text-[11px] font-medium text-stone-600 mb-1">
                          Collection
                        </label>
                        <select
                          value={selectedVaultColId}
                          onChange={(e) => applyPolicyForm(e.target.value, vaultStatus)}
                          className="w-full rounded-lg border border-stone-200 bg-white px-3 py-1.5 text-xs text-stone-900"
                        >
                          {vaultStatus.collections.map((c) => {
                            const pol = vaultStatus.policies.find((p) => p.collection_id === c.id);
                            const restricted = pol?.security_tier === "ferpa_restricted";
                            return (
                              <option key={c.id} value={c.id}>
                                {c.name} ({c.slug}){restricted ? " [FERPA Restricted]" : ""}
                              </option>
                            );
                          })}
                        </select>
                      </div>

                      <div>
                        <label className="block text-[11px] font-medium text-stone-600 mb-1">
                          Security Tier
                        </label>
                        <div className="grid grid-cols-2 gap-2">
                          <button
                            type="button"
                            onClick={() => setPolicyTier("standard")}
                            className={`rounded-xl border px-3 py-2 text-left text-xs ${
                              policyTier === "standard"
                                ? "border-stone-900 bg-stone-900 text-white"
                                : "border-stone-200 bg-white text-stone-700 hover:bg-stone-50"
                            }`}
                          >
                            <div className="font-semibold">Standard</div>
                            <div className="text-[11px] opacity-80">Normal workspace grants</div>
                          </button>
                          <button
                            type="button"
                            onClick={() => setPolicyTier("ferpa_restricted")}
                            className={`rounded-xl border px-3 py-2 text-left text-xs ${
                              policyTier === "ferpa_restricted"
                                ? "border-rose-700 bg-rose-700 text-white"
                                : "border-rose-200 bg-rose-50/50 text-rose-900 hover:bg-rose-50"
                            }`}
                          >
                            <div className="inline-flex items-center gap-1 font-semibold">
                              <Lock className="h-3 w-3" />
                              FERPA / Restricted Vault
                            </div>
                            <div className="text-[11px] opacity-80">
                              Allowlist + Zero-Exfil + Read Audit
                            </div>
                          </button>
                        </div>
                      </div>

                      <div className="space-y-1.5">
                        <div className="text-[11px] font-medium text-stone-600">
                          Allowed Department Groups
                        </div>
                        {vaultStatus.groups.length === 0 ? (
                          <p className="text-[11px] text-stone-400">
                            Create a Department Group first or allow specific principals below.
                          </p>
                        ) : (
                          <div className="flex flex-wrap gap-2">
                            {vaultStatus.groups.map((grp) => (
                              <label
                                key={grp.id}
                                className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2 py-1 text-[11px] text-stone-800"
                              >
                                <input
                                  type="checkbox"
                                  checked={policyGroupIds.includes(grp.id)}
                                  onChange={() =>
                                    toggleId(policyGroupIds, grp.id, setPolicyGroupIds)
                                  }
                                />
                                <span>{grp.name}</span>
                              </label>
                            ))}
                          </div>
                        )}
                      </div>

                      <div className="space-y-1.5">
                        <div className="text-[11px] font-medium text-stone-600">
                          Allowed Principals (Direct Exception)
                        </div>
                        <div className="flex flex-wrap gap-2 max-h-28 overflow-y-auto">
                          {vaultStatus.principals.map((pr) => (
                            <label
                              key={pr.id}
                              className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2 py-1 text-[11px] text-stone-800"
                            >
                              <input
                                type="checkbox"
                                checked={policyPrincipalIds.includes(pr.id)}
                                onChange={() =>
                                  toggleId(policyPrincipalIds, pr.id, setPolicyPrincipalIds)
                                }
                              />
                              <span className="font-mono">@{pr.handle}</span>
                            </label>
                          ))}
                        </div>
                      </div>

                      <label className="flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50/70 p-2.5 text-xs text-amber-950">
                        <input
                          type="checkbox"
                          className="mt-0.5"
                          checked={policyAllowLocalAi}
                          onChange={(e) => setPolicyAllowLocalAi(e.target.checked)}
                        />
                        <span>
                          <span className="font-medium">Allow approved local/campus AI only</span>{" "}
                          (<code className="font-mono">http://127.0.0.1</code> /{" "}
                          <code className="font-mono">localhost</code> /{" "}
                          <code className="font-mono">VELLUM_AI_LOCAL_ONLY=1</code>). External
                          cloud AI, outbound webhooks, and <code className="font-mono">/llms.txt</code>{" "}
                          stay hard-blocked.
                        </span>
                      </label>

                      <div className="flex flex-wrap items-center gap-2">
                        <input
                          type="text"
                          value={policyReason}
                          onChange={(e) => setPolicyReason(e.target.value)}
                          placeholder="Ledger audit reason"
                          className="flex-1 min-w-[180px] rounded-lg border border-stone-200 px-3 py-1.5 text-xs text-stone-900"
                        />
                        <button
                          type="submit"
                          disabled={vaultBusy || !selectedVaultColId}
                          className="rounded-lg bg-rose-700 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-rose-800 disabled:opacity-50"
                        >
                          {vaultBusy ? "Saving..." : "Save Security Policy"}
                        </button>
                      </div>
                    </form>
                  </div>
                </div>

                {/* CARD 3: MODB.LEDGER FERPA READ / EXPORT AUDIT */}
                <div className="rounded-2xl border border-stone-200 bg-white p-5 space-y-4">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div>
                      <h2 className="text-sm font-semibold text-stone-900">
                        Modb.Ledger FERPA Read &amp; Export Audit
                      </h2>
                      <p className="text-xs text-stone-500">
                        Hash-chained read, DB query, attachment download, and snapshot export events
                        on <code className="font-mono">ferpa_restricted</code> collections.
                      </p>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <select
                        value={vaultAuditColFilter}
                        onChange={(e) => {
                          setVaultAuditColFilter(e.target.value);
                          void loadFerpaAudit(e.target.value, vaultAuditActFilter);
                        }}
                        className="rounded-lg border border-stone-200 bg-white px-2.5 py-1 text-xs text-stone-800"
                      >
                        <option value="">All collections</option>
                        {vaultStatus.collections.map((c) => (
                          <option key={c.id} value={c.id}>
                            {c.name}
                          </option>
                        ))}
                      </select>
                      <select
                        value={vaultAuditActFilter}
                        onChange={(e) => {
                          setVaultAuditActFilter(e.target.value);
                          void loadFerpaAudit(vaultAuditColFilter, e.target.value);
                        }}
                        className="rounded-lg border border-stone-200 bg-white px-2.5 py-1 text-xs text-stone-800"
                      >
                        <option value="">All actions</option>
                        <option value="ferpa.page.viewed">ferpa.page.viewed</option>
                        <option value="ferpa.db_row.viewed">ferpa.db_row.viewed</option>
                        <option value="ferpa.attachment.downloaded">ferpa.attachment.downloaded</option>
                        <option value="ferpa.export.requested">ferpa.export.requested</option>
                      </select>
                      <button
                        type="button"
                        disabled={vaultLoading}
                        onClick={() => void loadFerpaAudit()}
                        className="rounded-lg border border-stone-200 bg-stone-50 px-2.5 py-1 text-xs font-medium text-stone-800 hover:bg-stone-100"
                      >
                        Filter
                      </button>
                    </div>
                  </div>

                  {vaultAudit.length === 0 ? (
                    <p className="text-xs text-stone-400">
                      No FERPA read/export events recorded yet.
                    </p>
                  ) : (
                    <div className="overflow-x-auto">
                      <table className="w-full text-left text-xs">
                        <thead>
                          <tr className="border-b border-stone-200 text-stone-500">
                            <th className="py-2 pr-3 font-medium">Timestamp</th>
                            <th className="py-2 pr-3 font-medium">Action</th>
                            <th className="py-2 pr-3 font-medium">Collection</th>
                            <th className="py-2 pr-3 font-medium">Resource</th>
                            <th className="py-2 pr-3 font-medium">Principal</th>
                            <th className="py-2 pr-3 font-medium">Grant</th>
                            <th className="py-2 font-medium">Reason</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-stone-100">
                          {vaultAudit.map((ev) => (
                            <tr key={ev.id}>
                              <td className="py-2 pr-3 font-mono text-[11px] text-stone-500 whitespace-nowrap">
                                {ev.at}
                              </td>
                              <td className="py-2 pr-3 font-mono text-[11px] font-medium text-rose-800 whitespace-nowrap">
                                {ev.action}
                              </td>
                              <td className="py-2 pr-3 font-mono text-[11px] text-stone-700">
                                {ev.collection_id}
                              </td>
                              <td className="py-2 pr-3 font-mono text-[11px] text-stone-700">
                                {ev.resource_kind}:{ev.resource_id}
                              </td>
                              <td className="py-2 pr-3 font-mono text-[11px] text-stone-800">
                                @{ev.principal_handle}
                              </td>
                              <td className="py-2 pr-3 font-mono text-[11px] text-stone-500">
                                {ev.grant_id}
                              </td>
                              <td className="py-2 text-stone-600">{ev.reason}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </WorkspaceLayout>
  );
}
