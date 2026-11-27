import { useEffect, useRef, useState } from "react";
import type { ClaimRecord } from "./types";

export type RealtimeConnectionState = "connecting" | "live" | "reconnecting";

export interface RealtimeScope {
  pageId?: string;
  databaseId?: string;
  collectionId?: string;
  channelId?: string;
}

export interface UseRealtimeEventsOptions {
  enabled: boolean;
  scope?: RealtimeScope;
  onEvent?: (eventName: string, data: Record<string, unknown>) => void;
}

const STREAM_EVENT_NAMES = [
  "page.created",
  "page.blocks_updated",
  "page.verified",
  "comment.created",
  "proposal.opened",
  "proposal.accepted",
  "proposal.rejected",
  "db.row_created",
  "db.row_updated",
  "db.row_deleted",
  "chat.message_created",
  "chat.message_updated",
  "chat.message_deleted",
  "chat.reaction_updated",
  "chat.inbox_updated",
  "resync_required",
] as const;

export function buildEventsUrl(scope?: RealtimeScope): string {
  const params = new URLSearchParams();
  if (scope?.channelId) {
    params.set("channel_id", scope.channelId);
    return `/api/v1/events?${params.toString()}`;
  }
  if (scope?.pageId) {
    params.set("page_id", scope.pageId);
  } else if (scope?.databaseId) {
    params.set("database_id", scope.databaseId);
  } else if (scope?.collectionId) {
    params.set("collection_id", scope.collectionId);
  }
  const qs = params.toString();
  return qs ? `/api/events?${qs}` : "/api/events";
}

function parseJsonData(raw: string): Record<string, unknown> {
  if (!raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

export function useRealtimeEvents({ enabled, scope, onEvent }: UseRealtimeEventsOptions) {
  const [connectionState, setConnectionState] = useState<RealtimeConnectionState>("connecting");
  const [claims, setClaims] = useState<ClaimRecord[]>([]);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  const pageId = scope?.pageId ?? "";
  const databaseId = scope?.databaseId ?? "";
  const collectionId = scope?.collectionId ?? "";
  const channelId = scope?.channelId ?? "";

  useEffect(() => {
    if (!enabled || typeof window === "undefined" || typeof EventSource === "undefined") {
      return;
    }

    const url = buildEventsUrl({
      pageId: pageId || undefined,
      databaseId: databaseId || undefined,
      collectionId: collectionId || undefined,
      channelId: channelId || undefined,
    });
    setConnectionState("connecting");
    const es = new EventSource(url, { withCredentials: true });

    const handleConnected = () => {
      setConnectionState("live");
    };

    const handleClaimsSnapshot = (e: MessageEvent<string>) => {
      setConnectionState("live");
      const data = parseJsonData(e.data);
      if (Array.isArray(data.claims)) {
        setClaims(data.claims as ClaimRecord[]);
      }
    };

    const handleClaimAcquired = (e: MessageEvent<string>) => {
      const data = parseJsonData(e.data);
      const claim = data.claim as ClaimRecord | undefined;
      if (claim && typeof claim.resource === "string") {
        setClaims((prev) => [
          ...prev.filter((c) => c.resource !== claim.resource),
          claim,
        ]);
      }
      onEventRef.current?.("claim.acquired", data);
    };

    const handleClaimHeartbeat = (e: MessageEvent<string>) => {
      const data = parseJsonData(e.data);
      const claim = data.claim as ClaimRecord | undefined;
      if (claim && typeof claim.resource === "string") {
        setClaims((prev) =>
          prev.map((c) => (c.resource === claim.resource ? claim : c))
        );
      }
      onEventRef.current?.("claim.heartbeat", data);
    };

    const handleClaimReleased = (e: MessageEvent<string>) => {
      const data = parseJsonData(e.data);
      const resource = typeof data.resource === "string" ? data.resource : "";
      if (resource) {
        setClaims((prev) => prev.filter((c) => c.resource !== resource));
      }
      onEventRef.current?.("claim.released", data);
    };

    es.onopen = () => setConnectionState("live");
    es.onerror = () => setConnectionState("reconnecting");

    es.addEventListener("connected", handleConnected);
    es.addEventListener("claims.snapshot", handleClaimsSnapshot as EventListener);
    es.addEventListener("claim.acquired", handleClaimAcquired as EventListener);
    es.addEventListener("claim.heartbeat", handleClaimHeartbeat as EventListener);
    es.addEventListener("claim.released", handleClaimReleased as EventListener);

    const listeners: Array<[string, EventListener]> = [];
    for (const evName of STREAM_EVENT_NAMES) {
      const fn: EventListener = (evt) => {
        const msg = evt as MessageEvent<string>;
        onEventRef.current?.(evName, parseJsonData(msg.data));
      };
      es.addEventListener(evName, fn);
      listeners.push([evName, fn]);
    }

    return () => {
      es.removeEventListener("connected", handleConnected);
      es.removeEventListener("claims.snapshot", handleClaimsSnapshot as EventListener);
      es.removeEventListener("claim.acquired", handleClaimAcquired as EventListener);
      es.removeEventListener("claim.heartbeat", handleClaimHeartbeat as EventListener);
      es.removeEventListener("claim.released", handleClaimReleased as EventListener);
      for (const [evName, fn] of listeners) {
        es.removeEventListener(evName, fn);
      }
      es.close();
    };
  }, [enabled, pageId, databaseId, collectionId, channelId]);

  return { connectionState, claims };
}
