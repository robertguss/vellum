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

function dispatchAskSseFrame(frame: string, handlers: AskWorkspaceStreamHandlers): void {
  if (!frame.trim()) return;
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
  if (dataLines.length === 0) return;
  const rawData = dataLines.join("\n");
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(rawData) as Record<string, unknown>;
  } catch {
    return;
  }
  if (eventName === "ai.citation") {
    handlers.onCitation?.(parsed as unknown as AiCitation);
  } else if (eventName === "ai.token") {
    const delta = typeof parsed.delta === "string" ? parsed.delta : "";
    if (delta) {
      handlers.onToken?.(delta);
    }
  } else if (eventName === "ai.done") {
    const model = typeof parsed.model === "string" ? parsed.model : "";
    handlers.onDone?.(model);
  } else if (eventName === "ai.error") {
    const status = typeof parsed.status === "number" ? parsed.status : 502;
    const msg =
      typeof parsed.detail === "string" && parsed.detail
        ? parsed.detail
        : typeof parsed.error === "string" && parsed.error
          ? parsed.error
          : "LLM streaming error";
    throw new ApiError(status >= 400 ? status : 502, msg);
  }
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

  if (!res.body) {
    const bodyText = await res.text();
    for (const frame of bodyText.split(/\r?\n\r?\n/)) {
      dispatchAskSseFrame(frame, handlers);
    }
    return;
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (value) {
        buffer += decoder.decode(value, { stream: !done });
        const frames = buffer.split(/\r?\n\r?\n/);
        buffer = frames.pop() ?? "";
        for (const frame of frames) {
          dispatchAskSseFrame(frame, handlers);
        }
      }
      if (done) {
        buffer += decoder.decode();
        for (const frame of buffer.split(/\r?\n\r?\n/)) {
          dispatchAskSseFrame(frame, handlers);
        }
        break;
      }
    }
  } finally {
    reader.releaseLock();
  }
}
