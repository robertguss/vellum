import type { AiCitation } from "./types";

export class ApiError extends Error {
  status: number;
  code?: string;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function getXsrfToken(): string | null {
  if (typeof document === "undefined") return null;
  const parts = document.cookie ? document.cookie.split("; ") : [];
  for (const part of parts) {
    if (part.startsWith("XSRF-TOKEN=")) {
      const raw = part.slice("XSRF-TOKEN=".length);
      try {
        return decodeURIComponent(raw);
      } catch {
        return raw;
      }
    }
  }
  return null;
}

export async function apiFetch<T>(url: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? "GET").toUpperCase();
  const headers = new Headers(init.headers);
  if (!headers.has("Accept")) {
    headers.set("Accept", "application/json");
  }
  if (init.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  if (!["GET", "HEAD", "OPTIONS"].includes(method)) {
    const xsrf = getXsrfToken();
    if (xsrf) {
      headers.set("X-XSRF-TOKEN", xsrf);
    }
  }

  const res = await fetch(url, {
    ...init,
    method,
    headers,
    credentials: "same-origin",
  });

  const text = await res.text();
  let parsed: Record<string, unknown> | null = null;
  if (text.trim().length > 0) {
    try {
      parsed = JSON.parse(text) as Record<string, unknown>;
    } catch {
      parsed = null;
    }
  }

  if (!res.ok) {
    const errMsg =
      (parsed && typeof parsed.error === "string" && parsed.error) ||
      (parsed && typeof parsed.message === "string" && parsed.message) ||
      text ||
      `HTTP ${res.status}`;
    throw new ApiError(res.status, errMsg);
  }

  return (parsed ?? {}) as T;
}

export interface AskWorkspaceStreamHandlers {
  onCitation?: (citation: AiCitation) => void;
  onToken?: (delta: string) => void;
  onDone?: (model: string) => void;
}

export async function streamAskWorkspace(
  payload: {
    question: string;
    collection_id: string | null;
    max_sources?: number;
  },
  handlers: AskWorkspaceStreamHandlers,
  signal?: AbortSignal
): Promise<void> {
  const headers = new Headers({
    Accept: "text/event-stream",
    "Content-Type": "application/json",
  });
  const xsrf = getXsrfToken();
  if (xsrf) {
    headers.set("X-XSRF-TOKEN", xsrf);
  }

  const res = await fetch("/api/ai/ask", {
    method: "POST",
    headers,
    credentials: "same-origin",
    signal,
    body: JSON.stringify({
      question: payload.question,
      collection_id: payload.collection_id,
      max_sources: payload.max_sources ?? 5,
      stream: true,
    }),
  });

  if (!res.ok) {
    const raw = await res.text();
    let msg = raw || `HTTP ${res.status}`;
    try {
      const j = JSON.parse(raw) as { error?: string };
      if (j.error) msg = j.error;
    } catch {
      // plain text fallback
    }
    throw new ApiError(res.status, msg);
  }

  const bodyText = await res.text();
  const frames = bodyText.split(/\r?\n\r?\n/);
  for (const frame of frames) {
    if (!frame.trim()) continue;
    let eventName = "message";
    const dataLines: string[] = [];
    for (const line of frame.split(/\r?\n/)) {
      if (line.startsWith(":")) continue;
      if (line.startsWith("event:")) {
        eventName = line.slice("event:".length).trim();
      } else if (line.startsWith("data:")) {
        dataLines.push(line.slice("data:".length).trimStart());
      }
    }
    if (dataLines.length === 0) continue;
    const rawData = dataLines.join("\n");
    try {
      const parsed = JSON.parse(rawData) as Record<string, unknown>;
      if (eventName === "ai.citation") {
        handlers.onCitation?.(parsed as unknown as AiCitation);
      } else if (eventName === "ai.token") {
        const delta = typeof parsed.delta === "string" ? parsed.delta : "";
        handlers.onToken?.(delta);
      } else if (eventName === "ai.done") {
        const model = typeof parsed.model === "string" ? parsed.model : "";
        handlers.onDone?.(model);
      }
    } catch {
      // ignore non-JSON frame
    }
  }
}
