import { Link, usePage } from "@inertiajs/react";
import {
  AtSign,
  Award,
  Check,
  CheckCheck,
  CheckSquare,
  Edit3,
  FileText,
  GitPullRequest,
  Hash,
  Inbox,
  Link2,
  Lock,
  MessageSquare,
  Paperclip,
  Plus,
  Search,
  Send,
  ShieldAlert,
  SmilePlus,
  Trash2,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import WorkspaceLayout from "../../components/WorkspaceLayout";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  ChatAttachmentSummary,
  ChatChannel,
  ChatInboxItem,
  ChatLinkableEntity,
  ChatMessage,
  ChatPrincipalSummary,
  ChatSearchHit,
  Collection,
  DatabaseDef,
  SharedPageProps,
} from "../../lib/types";

interface ChatProps {
  collections: Collection[];
  databases?: DatabaseDef[];
  channels: ChatChannel[];
  principals: ChatPrincipalSummary[];
  inbox_unread_count: number;
  initial_channel_id?: string | null;
  initial_message_id?: string | null;
}

const REACTION_CHOICES = ["👍", "👀", "✅", "🎉"] as const;

function formatClock(iso?: string | null): string {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleString([], {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

export default function Chat({
  collections = [],
  databases = [],
  channels: initialChannels = [],
  principals = [],
  inbox_unread_count: initialInboxUnread = 0,
  initial_channel_id = null,
  initial_message_id = null,
}: ChatProps) {
  const { auth } = usePage<SharedPageProps>().props;
  const [channels, setChannels] = useState<ChatChannel[]>(initialChannels);
  const [activeChannelId, setActiveChannelId] = useState<string>(() => {
    if (initial_channel_id && initialChannels.some((c) => c.id === initial_channel_id)) {
      return initial_channel_id;
    }
    return initialChannels[0]?.id ?? "";
  });

  const activeChannel = useMemo(
    () => channels.find((c) => c.id === activeChannelId) ?? null,
    [channels, activeChannelId]
  );

  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [nextBeforeCursor, setNextBeforeCursor] = useState<string | null>(null);
  const [loadingMsgs, setLoadingMsgs] = useState(false);
  const [decisionsOnly, setDecisionsOnly] = useState(false);

  const [threadRoot, setThreadRoot] = useState<ChatMessage | null>(null);
  const [threadReplies, setThreadReplies] = useState<ChatMessage[]>([]);
  const [threadText, setThreadText] = useState("");
  const [threadSending, setThreadSending] = useState(false);

  const [inboxOpen, setInboxOpen] = useState(false);
  const [inboxItems, setInboxItems] = useState<ChatInboxItem[]>([]);
  const [inboxUnread, setInboxUnread] = useState<number>(initialInboxUnread);

  const [searchText, setSearchText] = useState("");
  const [searchHits, setSearchHits] = useState<ChatSearchHit[] | null>(null);

  const [composer, setComposer] = useState("");
  const [markDecision, setMarkDecision] = useState(false);
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [pendingAtts, setPendingAtts] = useState<ChatAttachmentSummary[]>([]);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [editingId, setEditingId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");
  const [reactionPickerFor, setReactionPickerFor] = useState<string | null>(null);

  const [newModalOpen, setNewModalOpen] = useState(false);
  const [newKind, setNewKind] = useState<"public" | "private" | "dm">("public");
  const [newColId, setNewColId] = useState<string>(collections[0]?.id ?? "");
  const [newName, setNewName] = useState("");
  const [newTopic, setNewTopic] = useState("");
  const [newMemberIds, setNewMemberIds] = useState<string[]>([]);
  const [creatingCh, setCreatingCh] = useState(false);

  // Chat Moat: Create Task modal, Draft Doc Proposal modal & Entity Ref picker
  const [taskModalMsg, setTaskModalMsg] = useState<ChatMessage | null>(null);
  const [taskDbId, setTaskDbId] = useState<string>(databases[0]?.id ?? "");
  const [taskTitle, setTaskTitle] = useState("");
  const [taskSubmitting, setTaskSubmitting] = useState(false);

  const [propModalMsg, setPropModalMsg] = useState<ChatMessage | null>(null);
  const [propTargetPageId, setPropTargetPageId] = useState("");
  const [propTitle, setPropTitle] = useState("");
  const [propReason, setPropReason] = useState("");
  const [propPages, setPropPages] = useState<ChatLinkableEntity[]>([]);
  const [propSubmitting, setPropSubmitting] = useState(false);

  const [entityPickerOpen, setEntityPickerOpen] = useState(false);
  const [entityQuery, setEntityQuery] = useState("");
  const [entityResults, setEntityResults] = useState<ChatLinkableEntity[]>([]);

  const [error, setError] = useState<string | null>(null);
  const [highlightMsgId] = useState<string | null>(initial_message_id ?? null);

  const loadChannels = useCallback(async () => {
    try {
      const res = await apiFetch<{
        channels: ChatChannel[];
        inbox_unread_count: number;
      }>("/api/v1/chat/channels");
      setChannels(res.channels ?? []);
      setInboxUnread(res.inbox_unread_count ?? 0);
      setActiveChannelId((prev) => {
        if (prev && (res.channels ?? []).some((c) => c.id === prev)) return prev;
        return res.channels?.[0]?.id ?? "";
      });
    } catch {
      // keep existing state on transient reload failure
    }
  }, []);

  const loadMessages = useCallback(
    async (channelId: string, opts: { before?: string; appendOlder?: boolean } = {}) => {
      if (!channelId) {
        setMessages([]);
        setHasMore(false);
        setNextBeforeCursor(null);
        return;
      }
      setLoadingMsgs(true);
      setError(null);
      try {
        const params = new URLSearchParams({ limit: "50" });
        if (opts.before) params.set("before", opts.before);
        if (decisionsOnly) params.set("decisions_only", "1");
        const res = await apiFetch<{
          messages: ChatMessage[];
          has_more: boolean;
          next_before_cursor: string | null;
        }>(`/api/v1/chat/channels/${encodeURIComponent(channelId)}/messages?${params.toString()}`);
        if (opts.appendOlder) {
          setMessages((prev) => {
            const seen = new Set(prev.map((m) => m.id));
            const older = (res.messages ?? []).filter((m) => !seen.has(m.id));
            return [...older, ...prev];
          });
        } else {
          setMessages(res.messages ?? []);
        }
        setHasMore(Boolean(res.has_more));
        setNextBeforeCursor(res.next_before_cursor ?? null);
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Failed to load channel messages");
      } finally {
        setLoadingMsgs(false);
      }
    },
    [decisionsOnly]
  );

  const loadThread = useCallback(async (channelId: string, root: ChatMessage) => {
    setThreadRoot(root);
    try {
      const res = await apiFetch<{ messages: ChatMessage[] }>(
        `/api/v1/chat/channels/${encodeURIComponent(channelId)}/messages?parent_message_id=${encodeURIComponent(
          root.id
        )}&limit=100`
      );
      setThreadReplies(res.messages ?? []);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load thread replies");
    }
  }, []);

  const loadInbox = useCallback(async () => {
    try {
      const res = await apiFetch<{ items: ChatInboxItem[]; unread_count: number }>(
        "/api/v1/chat/inbox?limit=50"
      );
      setInboxItems(res.items ?? []);
      setInboxUnread(res.unread_count ?? 0);
    } catch {
      // ignore transient error
    }
  }, []);

  useEffect(() => {
    setThreadRoot(null);
    setThreadReplies([]);
    if (activeChannelId) {
      void loadMessages(activeChannelId);
    } else {
      setMessages([]);
    }
  }, [activeChannelId, loadMessages]);

  useEffect(() => {
    if (inboxOpen) {
      void loadInbox();
    }
  }, [inboxOpen, loadInbox]);

  const handleRealtimeEvent = useCallback(
    (eventName: string, data: Record<string, unknown>) => {
      if (eventName === "chat.message_created") {
        const msg = data.message as ChatMessage | undefined;
        if (!msg || !msg.id) return;
        if (msg.channel_id === activeChannelId) {
          if (msg.parent_message_id) {
            setMessages((prev) =>
              prev.map((m) =>
                m.id === msg.parent_message_id
                  ? { ...m, reply_count: (m.reply_count ?? 0) + 1 }
                  : m
              )
            );
            setThreadReplies((prev) => {
              if (!threadRoot || threadRoot.id !== msg.parent_message_id) return prev;
              if (prev.some((r) => r.id === msg.id)) return prev;
              return [...prev, msg];
            });
            if (msg.needs_enrichment && threadRoot && threadRoot.id === msg.parent_message_id) {
              void loadThread(activeChannelId, threadRoot);
            }
          } else {
            setMessages((prev) => (prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]));
            if (msg.needs_enrichment) {
              void loadMessages(activeChannelId);
            }
          }
        } else if (!msg.parent_message_id && msg.author_id !== auth?.id) {
          setChannels((prev) =>
            prev.map((c) =>
              c.id === msg.channel_id ? { ...c, unread_count: (c.unread_count ?? 0) + 1 } : c
            )
          );
        }
      } else if (eventName === "chat.message_updated") {
        const msg = data.message as ChatMessage | undefined;
        if (!msg || !msg.id) return;
        setMessages((prev) => prev.map((m) => (m.id === msg.id ? { ...m, ...msg } : m)));
        setThreadReplies((prev) => prev.map((r) => (r.id === msg.id ? { ...r, ...msg } : r)));
        setThreadRoot((prev) => (prev && prev.id === msg.id ? { ...prev, ...msg } : prev));
        if (msg.needs_enrichment && activeChannelId && msg.channel_id === activeChannelId) {
          void loadMessages(activeChannelId);
          if (threadRoot && (msg.parent_message_id === threadRoot.id || msg.id === threadRoot.id)) {
            void loadThread(activeChannelId, threadRoot);
          }
        }
      } else if (eventName === "chat.message_deleted") {
        const msgId = typeof data.message_id === "string" ? data.message_id : "";
        if (!msgId) return;
        const tombstone = (m: ChatMessage): ChatMessage =>
          m.id === msgId
            ? { ...m, deleted_at: new Date().toISOString(), body_markdown: "", attachments: [] }
            : m;
        setMessages((prev) => prev.map(tombstone));
        setThreadReplies((prev) => prev.map(tombstone));
        setThreadRoot((prev) => (prev ? tombstone(prev) : prev));
      } else if (eventName === "chat.reaction_updated") {
        const msgId = typeof data.message_id === "string" ? data.message_id : "";
        const reactions = (data.reactions as Record<string, string[]>) ?? {};
        if (!msgId) return;
        const applyReactions = (m: ChatMessage): ChatMessage =>
          m.id === msgId ? { ...m, reactions } : m;
        setMessages((prev) => prev.map(applyReactions));
        setThreadReplies((prev) => prev.map(applyReactions));
        setThreadRoot((prev) => (prev ? applyReactions(prev) : prev));
      } else if (eventName === "chat.inbox_updated") {
        setInboxUnread((prev) => prev + 1);
        if (inboxOpen) {
          void loadInbox();
        }
      }
    },
    [activeChannelId, auth?.id, inboxOpen, loadInbox, loadMessages, loadThread, threadRoot]
  );

  function statusBadgeClasses(color?: string | null): string {
    switch (color) {
      case "green":
        return "border-emerald-200 bg-emerald-50 text-emerald-800";
      case "blue":
        return "border-sky-200 bg-sky-50 text-sky-800";
      case "amber":
        return "border-amber-200 bg-amber-50 text-amber-800";
      case "red":
        return "border-rose-200 bg-rose-50 text-rose-800";
      case "purple":
        return "border-purple-200 bg-purple-50 text-purple-800";
      default:
        return "border-stone-200 bg-stone-100 text-stone-700";
    }
  }

  const loadLinkableEntities = useCallback(async (q: string, kind?: string) => {
    try {
      const params = new URLSearchParams({ limit: "25" });
      if (q.trim()) params.set("q", q.trim());
      if (kind) params.set("kind", kind);
      const res = await apiFetch<{ entities: ChatLinkableEntity[] }>(
        `/api/v1/chat/entities?${params.toString()}`
      );
      if (kind === "page") setPropPages(res.entities ?? []);
      else setEntityResults(res.entities ?? []);
    } catch {
      // ignore picker load failure
    }
  }, []);

  function openCreateTaskModal(msg: ChatMessage) {
    setTaskModalMsg(msg);
    setTaskDbId(databases[0]?.id ?? "");
    const firstLine = (msg.body_markdown || "").split("\n")[0]?.trim() || "";
    setTaskTitle(firstLine.slice(0, 80) || "Follow-up task");
  }

  async function handleCreateTaskFromMsg(e: React.FormEvent) {
    e.preventDefault();
    if (!activeChannelId || !taskModalMsg || !taskDbId || taskSubmitting) return;
    setTaskSubmitting(true);
    setError(null);
    try {
      const res = await apiFetch<{ message: ChatMessage }>(
        `/api/v1/chat/channels/${encodeURIComponent(
          activeChannelId
        )}/messages/${encodeURIComponent(taskModalMsg.id)}/create-task`,
        {
          method: "POST",
          body: JSON.stringify({
            database_id: taskDbId,
            title: taskTitle.trim() || undefined,
          }),
        }
      );
      const mergeUpdated = (m: ChatMessage): ChatMessage =>
        m.id === res.message.id ? { ...m, ...res.message } : m;
      setMessages((prev) => prev.map(mergeUpdated));
      setThreadReplies((prev) => prev.map(mergeUpdated));
      setThreadRoot((prev) => (prev && prev.id === res.message.id ? mergeUpdated(prev) : prev));
      setTaskModalMsg(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create task from message");
    } finally {
      setTaskSubmitting(false);
    }
  }

  function openDraftPropModal(msg: ChatMessage) {
    setPropModalMsg(msg);
    setPropTargetPageId("");
    const firstLine = (msg.body_markdown || "").split("\n")[0]?.trim() || "";
    setPropTitle(`Decision: ${firstLine.slice(0, 72) || "Doc update"}`);
    setPropReason("Promoted chat decision into living documentation");
    void loadLinkableEntities("", "page");
  }

  async function handleDraftProposalFromMsg(e: React.FormEvent) {
    e.preventDefault();
    if (!activeChannelId || !propModalMsg || !propTargetPageId || propSubmitting) return;
    setPropSubmitting(true);
    setError(null);
    try {
      const res = await apiFetch<{ message: ChatMessage }>(
        `/api/v1/chat/channels/${encodeURIComponent(
          activeChannelId
        )}/messages/${encodeURIComponent(propModalMsg.id)}/draft-proposal`,
        {
          method: "POST",
          body: JSON.stringify({
            target_page_id: propTargetPageId,
            title: propTitle.trim() || undefined,
            reason: propReason.trim() || undefined,
          }),
        }
      );
      const mergeUpdated = (m: ChatMessage): ChatMessage =>
        m.id === res.message.id ? { ...m, ...res.message } : m;
      setMessages((prev) => prev.map(mergeUpdated));
      setThreadReplies((prev) => prev.map(mergeUpdated));
      setThreadRoot((prev) => (prev && prev.id === res.message.id ? mergeUpdated(prev) : prev));
      setPropModalMsg(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to draft doc proposal");
    } finally {
      setPropSubmitting(false);
    }
  }

  async function handleSendMessage(e: React.FormEvent) {
    e.preventDefault();
    if (!activeChannelId || sending) return;
    if (!composer.trim() && pendingAtts.length === 0) return;
    setSending(true);
    setError(null);
    const clientMsgId =
      typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
        ? `cli_${crypto.randomUUID()}`
        : `cli_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    try {
      const res = await apiFetch<{ message: ChatMessage }>(
        `/api/v1/chat/channels/${encodeURIComponent(activeChannelId)}/messages`,
        {
          method: "POST",
          body: JSON.stringify({
            body_markdown: composer.trim(),
            attachment_ids: pendingAtts.map((a) => a.id),
            is_decision: markDecision,
            client_msg_id: clientMsgId,
          }),
        }
      );
      setComposer("");
      setMarkDecision(false);
      setPendingAtts([]);
      setMessages((prev) =>
        prev.some((m) => m.id === res.message.id) ? prev : [...prev, res.message]
      );
      setChannels((prev) =>
        prev.map((c) => (c.id === activeChannelId ? { ...c, unread_count: 0 } : c))
      );
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to send message");
    } finally {
      setSending(false);
    }
  }

  async function handleSendThreadReply(e: React.FormEvent) {
    e.preventDefault();
    if (!activeChannelId || !threadRoot || !threadText.trim() || threadSending) return;
    setThreadSending(true);
    setError(null);
    const clientMsgId =
      typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
        ? `cli_${crypto.randomUUID()}`
        : `cli_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    try {
      const res = await apiFetch<{ message: ChatMessage }>(
        `/api/v1/chat/channels/${encodeURIComponent(activeChannelId)}/messages`,
        {
          method: "POST",
          body: JSON.stringify({
            body_markdown: threadText.trim(),
            parent_message_id: threadRoot.id,
            client_msg_id: clientMsgId,
          }),
        }
      );
      setThreadText("");
      setThreadReplies((prev) =>
        prev.some((m) => m.id === res.message.id) ? prev : [...prev, res.message]
      );
      setMessages((prev) =>
        prev.map((m) =>
          m.id === threadRoot.id ? { ...m, reply_count: (m.reply_count ?? 0) + 1 } : m
        )
      );
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to post thread reply");
    } finally {
      setThreadSending(false);
    }
  }

  async function handleUploadFile(file: File) {
    if (!activeChannelId) return;
    setUploading(true);
    setError(null);
    try {
      const presign = await apiFetch<{
        attachment: { id: string; filename: string; content_type: string; size_bytes: number };
        upload_url: string;
        method: string;
        required_headers: Array<{ name: string; value: string }>;
      }>("/api/attachments/presign", {
        method: "POST",
        body: JSON.stringify({
          page_id: activeChannelId,
          filename: file.name,
          content_type: file.type || "application/octet-stream",
          size_bytes: file.size || 1,
          sha256_hex: null,
        }),
      });
      const headers = new Headers();
      for (const h of presign.required_headers ?? []) {
        headers.set(h.name, h.value);
      }
      const putRes = await fetch(presign.upload_url, {
        method: presign.method || "PUT",
        headers,
        body: file,
      });
      if (!putRes.ok) {
        throw new Error(`Upload failed (${putRes.status})`);
      }
      await apiFetch(`/api/attachments/${encodeURIComponent(presign.attachment.id)}/commit`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setPendingAtts((prev) => [
        ...prev,
        {
          id: presign.attachment.id,
          filename: presign.attachment.filename,
          content_type: presign.attachment.content_type,
          size_bytes: presign.attachment.size_bytes,
          download_url: `/api/attachments/${presign.attachment.id}/download`,
        },
      ]);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Attachment upload failed");
    } finally {
      setUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  }

  async function handleToggleReaction(msgId: string, emoji: string) {
    if (!activeChannelId) return;
    setReactionPickerFor(null);
    try {
      const res = await apiFetch<{ reactions: Record<string, string[]> }>(
        `/api/v1/chat/channels/${encodeURIComponent(
          activeChannelId
        )}/messages/${encodeURIComponent(msgId)}/reactions`,
        {
          method: "POST",
          body: JSON.stringify({ emoji }),
        }
      );
      const upd = (m: ChatMessage): ChatMessage =>
        m.id === msgId ? { ...m, reactions: res.reactions ?? {} } : m;
      setMessages((prev) => prev.map(upd));
      setThreadReplies((prev) => prev.map(upd));
      setThreadRoot((prev) => (prev ? upd(prev) : prev));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to toggle reaction");
    }
  }

  async function handleToggleDecision(msg: ChatMessage) {
    if (!activeChannelId) return;
    try {
      const res = await apiFetch<{ message: ChatMessage }>(
        `/api/v1/chat/channels/${encodeURIComponent(
          activeChannelId
        )}/messages/${encodeURIComponent(msg.id)}`,
        {
          method: "PATCH",
          body: JSON.stringify({ is_decision: !msg.is_decision }),
        }
      );
      setMessages((prev) => prev.map((m) => (m.id === msg.id ? { ...m, ...res.message } : m)));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update decision flag");
    }
  }

  async function handleSaveEdit(msgId: string) {
    if (!activeChannelId || !editDraft.trim()) return;
    try {
      const res = await apiFetch<{ message: ChatMessage }>(
        `/api/v1/chat/channels/${encodeURIComponent(
          activeChannelId
        )}/messages/${encodeURIComponent(msgId)}`,
        {
          method: "PATCH",
          body: JSON.stringify({ body_markdown: editDraft.trim() }),
        }
      );
      setMessages((prev) => prev.map((m) => (m.id === msgId ? { ...m, ...res.message } : m)));
      setThreadReplies((prev) => prev.map((r) => (r.id === msgId ? { ...r, ...res.message } : r)));
      setEditingId(null);
      setEditDraft("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to edit message");
    }
  }

  async function handleDeleteMessage(msgId: string) {
    if (!activeChannelId) return;
    try {
      await apiFetch(
        `/api/v1/chat/channels/${encodeURIComponent(
          activeChannelId
        )}/messages/${encodeURIComponent(msgId)}`,
        { method: "DELETE", body: JSON.stringify({}) }
      );
      const tombstone = (m: ChatMessage): ChatMessage =>
        m.id === msgId
          ? { ...m, deleted_at: new Date().toISOString(), body_markdown: "", attachments: [] }
          : m;
      setMessages((prev) => prev.map(tombstone));
      setThreadReplies((prev) => prev.map(tombstone));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to delete message");
    }
  }

  async function handleMarkRead() {
    if (!activeChannelId) return;
    try {
      await apiFetch(`/api/v1/chat/channels/${encodeURIComponent(activeChannelId)}/read`, {
        method: "POST",
        body: JSON.stringify({}),
      });
      setChannels((prev) =>
        prev.map((c) => (c.id === activeChannelId ? { ...c, unread_count: 0 } : c))
      );
    } catch {
      // ignore
    }
  }

  async function handleAckInbox(notificationId?: string) {
    try {
      const res = await apiFetch<{ unread_count: number }>("/api/v1/chat/inbox/ack", {
        method: "POST",
        body: JSON.stringify(notificationId ? { notification_id: notificationId } : { all: true }),
      });
      setInboxUnread(res.unread_count ?? 0);
      await loadInbox();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to acknowledge inbox");
    }
  }

  async function handleRunChannelSearch(e: React.FormEvent) {
    e.preventDefault();
    const q = searchText.trim();
    if (!q) {
      setSearchHits(null);
      return;
    }
    try {
      const params = new URLSearchParams({ q, limit: "25" });
      if (activeChannelId) params.set("channel_id", activeChannelId);
      const res = await apiFetch<{ results: ChatSearchHit[] }>(
        `/api/v1/chat/search?${params.toString()}`
      );
      setSearchHits(res.results ?? []);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Chat search failed");
    }
  }

  async function handleCreateChannel(e: React.FormEvent) {
    e.preventDefault();
    if (creatingCh) return;
    setCreatingCh(true);
    setError(null);
    try {
      const res = await apiFetch<{ channel: ChatChannel }>("/api/v1/chat/channels", {
        method: "POST",
        body: JSON.stringify({
          kind: newKind,
          collection_id: newKind === "dm" ? null : newColId || collections[0]?.id || null,
          name: newName.trim(),
          topic: newTopic.trim(),
          member_principal_ids: newKind === "public" ? [] : newMemberIds,
        }),
      });
      setNewModalOpen(false);
      setNewName("");
      setNewTopic("");
      setNewMemberIds([]);
      await loadChannels();
      setActiveChannelId(res.channel.id);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create channel");
    } finally {
      setCreatingCh(false);
    }
  }

  const publicPrivateChannels = channels.filter((c) => c.kind !== "dm");
  const dmChannels = channels.filter((c) => c.kind === "dm");

  function renderMessageCard(msg: ChatMessage, inThread = false) {
    const deleted = Boolean(msg.deleted_at);
    const mine = auth?.id === msg.author_id || auth?.role === "owner" || auth?.role === "admin";
    const highlighted = highlightMsgId === msg.id;
    const reactionEntries = Object.entries(msg.reactions ?? {}).filter(
      ([, pids]) => pids && pids.length > 0
    );

    return (
      <div
        key={msg.id}
        className={`group rounded-xl border px-4 py-3 transition ${
          highlighted
            ? "border-sky-300 bg-sky-50/40"
            : msg.is_decision && !deleted
              ? "border-amber-200 bg-amber-50/30"
              : "border-stone-200/80 bg-white hover:border-stone-300"
        }`}
      >
        <div className="flex items-start justify-between gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <span className="text-xs font-semibold text-stone-900 truncate">
              {msg.author_display_name || msg.author_handle}
            </span>
            <span className="font-mono text-[11px] text-stone-400 truncate">
              {msg.author_handle.startsWith("@") ? msg.author_handle : `@${msg.author_handle}`}
            </span>
            <span className="text-[11px] text-stone-400">{formatClock(msg.created_at)}</span>
            {msg.edited_at && !deleted && (
              <span className="text-[10px] text-stone-400">(edited)</span>
            )}
            {msg.is_decision && !deleted && (
              <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold text-amber-900">
                <Award className="h-3 w-3" />
                Decision
              </span>
            )}
          </div>
          {!deleted && (
            <div className="flex items-center gap-1 opacity-80 group-hover:opacity-100">
              <div className="relative">
                <button
                  type="button"
                  onClick={() =>
                    setReactionPickerFor((prev) => (prev === msg.id ? null : msg.id))
                  }
                  title="React"
                  className="rounded p-1 text-stone-400 hover:bg-stone-100 hover:text-stone-700"
                >
                  <SmilePlus className="h-3.5 w-3.5" />
                </button>
                {reactionPickerFor === msg.id && (
                  <div className="absolute right-0 top-7 z-20 flex items-center gap-1 rounded-lg border border-stone-200 bg-white p-1 shadow-lg">
                    {REACTION_CHOICES.map((em) => (
                      <button
                        key={em}
                        type="button"
                        onClick={() => void handleToggleReaction(msg.id, em)}
                        className="rounded px-1.5 py-0.5 text-sm hover:bg-stone-100"
                      >
                        {em}
                      </button>
                    ))}
                  </div>
                )}
              </div>
              {!inThread && (
                <button
                  type="button"
                  onClick={() => activeChannel && void loadThread(activeChannel.id, msg)}
                  title="Reply in thread"
                  className="rounded p-1 text-stone-400 hover:bg-stone-100 hover:text-stone-700"
                >
                  <MessageSquare className="h-3.5 w-3.5" />
                </button>
              )}
              <button
                type="button"
                onClick={() => openCreateTaskModal(msg)}
                title="Create Database Task"
                className="rounded p-1 text-stone-400 hover:bg-emerald-50 hover:text-emerald-700"
              >
                <CheckSquare className="h-3.5 w-3.5" />
              </button>
              <button
                type="button"
                onClick={() => openDraftPropModal(msg)}
                title="Draft Doc Update Proposal"
                className="rounded p-1 text-stone-400 hover:bg-indigo-50 hover:text-indigo-700"
              >
                <GitPullRequest className="h-3.5 w-3.5" />
              </button>
              {mine && !inThread && (
                <button
                  type="button"
                  onClick={() => void handleToggleDecision(msg)}
                  title={msg.is_decision ? "Unmark Decision" : "Mark Decision"}
                  className={`rounded p-1 hover:bg-stone-100 ${
                    msg.is_decision ? "text-amber-700" : "text-stone-400 hover:text-stone-700"
                  }`}
                >
                  <Award className="h-3.5 w-3.5" />
                </button>
              )}
              {mine && (
                <>
                  <button
                    type="button"
                    onClick={() => {
                      setEditingId(msg.id);
                      setEditDraft(msg.body_markdown);
                    }}
                    title="Edit"
                    className="rounded p-1 text-stone-400 hover:bg-stone-100 hover:text-stone-700"
                  >
                    <Edit3 className="h-3.5 w-3.5" />
                  </button>
                  <button
                    type="button"
                    onClick={() => void handleDeleteMessage(msg.id)}
                    title="Delete"
                    className="rounded p-1 text-stone-400 hover:bg-red-50 hover:text-red-600"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                </>
              )}
            </div>
          )}
        </div>

        {deleted ? (
          <div className="mt-1.5 text-xs italic text-stone-400">[Message deleted]</div>
        ) : editingId === msg.id ? (
          <div className="mt-2 space-y-2">
            <textarea
              rows={2}
              value={editDraft}
              onChange={(e) => setEditDraft(e.target.value)}
              className="w-full rounded-lg border border-stone-300 px-3 py-1.5 text-sm outline-none focus:border-stone-900"
            />
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={() => void handleSaveEdit(msg.id)}
                className="rounded-md bg-stone-900 px-2.5 py-1 text-xs font-medium text-white"
              >
                Save
              </button>
              <button
                type="button"
                onClick={() => setEditingId(null)}
                className="rounded-md border border-stone-200 px-2.5 py-1 text-xs text-stone-600"
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          <div className="mt-1.5 text-sm leading-relaxed text-stone-800 whitespace-pre-wrap break-words">
            {msg.body_markdown}
          </div>
        )}

        {!deleted && msg.attachments && msg.attachments.length > 0 && (
          <div className="mt-2 flex flex-wrap gap-2">
            {msg.attachments.map((att) => (
              <a
                key={att.id}
                href={att.download_url}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2.5 py-1 text-xs font-medium text-stone-700 hover:bg-stone-100"
              >
                <Paperclip className="h-3 w-3 text-stone-500" />
                {att.filename}
              </a>
            ))}
          </div>
        )}

        {!deleted && msg.inline_refs && msg.inline_refs.length > 0 && (
          <div className="mt-2 flex flex-wrap gap-1.5">
            {msg.inline_refs.map((ref) =>
              ref.accessible && ref.url ? (
                <Link
                  key={`${ref.kind}-${ref.id}`}
                  href={ref.url}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2.5 py-1 text-xs text-stone-800 hover:border-sky-300 hover:bg-sky-50/60"
                >
                  <FileText className="h-3 w-3 text-stone-500" />
                  <span className="font-medium truncate max-w-[180px]">{ref.title}</span>
                  <span className="text-[10px] text-stone-400">{ref.subtitle}</span>
                  {ref.status_label && (
                    <span
                      className={`rounded-full border px-1.5 py-0 text-[10px] font-medium ${statusBadgeClasses(
                        ref.status_color
                      )}`}
                    >
                      {ref.status_label}
                    </span>
                  )}
                </Link>
              ) : (
                <span
                  key={`${ref.kind}-${ref.id}`}
                  className="inline-flex items-center gap-1 rounded-lg border border-amber-200 bg-amber-50/70 px-2 py-1 text-[11px] font-medium text-amber-900"
                >
                  <Lock className="h-3 w-3 text-amber-700" />
                  {ref.title}
                </span>
              )
            )}
          </div>
        )}

        {!deleted &&
          ((msg.linked_rows && msg.linked_rows.length > 0) ||
            (msg.linked_proposals && msg.linked_proposals.length > 0)) && (
            <div className="mt-2 flex flex-wrap gap-1.5">
              {(msg.linked_rows ?? []).map((lr) => (
                <Link
                  key={lr.row_id}
                  href={`/p/${lr.page_id}`}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-emerald-200 bg-emerald-50/60 px-2.5 py-1 text-xs text-stone-900 hover:bg-emerald-50"
                >
                  <CheckSquare className="h-3 w-3 text-emerald-700" />
                  <span className="font-medium truncate max-w-[180px]">{lr.title}</span>
                  <span className="text-[10px] text-stone-500">{lr.database_title}</span>
                  {lr.status_label && (
                    <span
                      className={`rounded-full border px-1.5 py-0 text-[10px] font-semibold ${statusBadgeClasses(
                        lr.status_color
                      )}`}
                    >
                      {lr.status_label}
                    </span>
                  )}
                </Link>
              ))}
              {(msg.linked_proposals ?? []).map((lp) => (
                <Link
                  key={lp.proposal_id}
                  href={`/p/${lp.target_page_id}`}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-indigo-200 bg-indigo-50/60 px-2.5 py-1 text-xs text-stone-900 hover:bg-indigo-50"
                >
                  <GitPullRequest className="h-3 w-3 text-indigo-700" />
                  <span className="font-medium truncate max-w-[180px]">{lp.title}</span>
                  <span className="rounded-full bg-white border border-indigo-200 px-1.5 py-0 text-[10px] font-mono uppercase text-indigo-800">
                    {lp.status}
                  </span>
                </Link>
              ))}
            </div>
          )}

        {!deleted && (reactionEntries.length > 0 || (!inThread && (msg.reply_count ?? 0) > 0)) && (
          <div className="mt-2.5 flex flex-wrap items-center gap-2">
            {reactionEntries.map(([emoji, pids]) => {
              const reacted = Boolean(auth?.id && pids.includes(auth.id));
              return (
                <button
                  key={emoji}
                  type="button"
                  onClick={() => void handleToggleReaction(msg.id, emoji)}
                  className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs transition ${
                    reacted
                      ? "border-sky-300 bg-sky-50 text-sky-900 font-medium"
                      : "border-stone-200 bg-stone-50 text-stone-700 hover:bg-stone-100"
                  }`}
                >
                  <span>{emoji}</span>
                  <span>{pids.length}</span>
                </button>
              );
            })}
            {!inThread && (msg.reply_count ?? 0) > 0 && (
              <button
                type="button"
                onClick={() => activeChannel && void loadThread(activeChannel.id, msg)}
                className="inline-flex items-center gap-1 rounded-full border border-stone-200 bg-white px-2.5 py-0.5 text-xs font-medium text-sky-700 hover:bg-sky-50"
              >
                <MessageSquare className="h-3 w-3" />
                {msg.reply_count} {msg.reply_count === 1 ? "reply" : "replies"}
              </button>
            )}
          </div>
        )}
      </div>
    );
  }

  return (
    <WorkspaceLayout
      title={
        activeChannel
          ? activeChannel.kind === "dm"
            ? activeChannel.name
            : `#${activeChannel.name}`
          : "Workspace Chat"
      }
      collections={collections}
      databases={databases}
      realtimeScope={activeChannel ? { channelId: activeChannel.id } : undefined}
      onRealtimeEvent={handleRealtimeEvent}
    >
      <div className="flex flex-col lg:flex-row gap-4 min-h-[calc(100vh-8.5rem)]">
        {/* Left rail: Channels, DMs & Calm Inbox */}
        <aside className="w-full lg:w-64 shrink-0 rounded-2xl border border-stone-200 bg-white p-3.5 flex flex-col gap-4">
          <div className="flex items-center justify-between gap-2">
            <button
              type="button"
              onClick={() => setInboxOpen((prev) => !prev)}
              className={`flex-1 inline-flex items-center justify-between gap-2 rounded-lg px-2.5 py-1.5 text-xs font-medium border transition ${
                inboxOpen
                  ? "border-stone-900 bg-stone-900 text-white"
                  : "border-stone-200 bg-stone-50 text-stone-700 hover:bg-stone-100"
              }`}
            >
              <span className="inline-flex items-center gap-1.5">
                <Inbox className="h-3.5 w-3.5" />
                Calm Inbox
              </span>
              {inboxUnread > 0 && (
                <span className="rounded-full bg-amber-500 px-1.5 py-0.5 text-[10px] font-bold text-white">
                  {inboxUnread}
                </span>
              )}
            </button>
            <button
              type="button"
              onClick={() => setNewModalOpen(true)}
              title="New Channel or DM"
              className="rounded-lg border border-stone-200 bg-white p-1.5 text-stone-600 hover:bg-stone-100 hover:text-stone-900"
            >
              <Plus className="h-4 w-4" />
            </button>
          </div>

          <div>
            <div className="px-1.5 mb-1 text-[11px] font-semibold uppercase tracking-wider text-stone-400">
              Channels
            </div>
            <div className="space-y-0.5">
              {publicPrivateChannels.length === 0 && (
                <div className="px-2 py-2 text-xs text-stone-400">No channels yet.</div>
              )}
              {publicPrivateChannels.map((c) => {
                const active = !inboxOpen && c.id === activeChannelId;
                return (
                  <button
                    key={c.id}
                    type="button"
                    onClick={() => {
                      setInboxOpen(false);
                      setSearchHits(null);
                      setActiveChannelId(c.id);
                    }}
                    className={`w-full flex items-center justify-between gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs transition ${
                      active
                        ? "bg-stone-900 text-white font-medium"
                        : "text-stone-700 hover:bg-stone-100"
                    }`}
                  >
                    <span className="flex items-center gap-1.5 min-w-0 truncate">
                      {c.kind === "private" ? (
                        <Lock className="h-3.5 w-3.5 shrink-0 opacity-75" />
                      ) : (
                        <Hash className="h-3.5 w-3.5 shrink-0 opacity-75" />
                      )}
                      <span className="truncate">{c.name}</span>
                      {c.ferpa_restricted && (
                        <ShieldAlert
                          className={`h-3.5 w-3.5 shrink-0 ${
                            active ? "text-amber-300" : "text-amber-600"
                          }`}
                        />
                      )}
                    </span>
                    {(c.unread_count ?? 0) > 0 && (
                      <span className="shrink-0 rounded-full bg-sky-600 px-1.5 py-0.5 text-[10px] font-bold text-white">
                        {c.unread_count}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>

          <div>
            <div className="px-1.5 mb-1 text-[11px] font-semibold uppercase tracking-wider text-stone-400">
              Direct Messages
            </div>
            <div className="space-y-0.5">
              {dmChannels.length === 0 && (
                <div className="px-2 py-1 text-xs text-stone-400">No direct messages.</div>
              )}
              {dmChannels.map((c) => {
                const active = !inboxOpen && c.id === activeChannelId;
                return (
                  <button
                    key={c.id}
                    type="button"
                    onClick={() => {
                      setInboxOpen(false);
                      setSearchHits(null);
                      setActiveChannelId(c.id);
                    }}
                    className={`w-full flex items-center justify-between gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs transition ${
                      active
                        ? "bg-stone-900 text-white font-medium"
                        : "text-stone-700 hover:bg-stone-100"
                    }`}
                  >
                    <span className="flex items-center gap-1.5 min-w-0 truncate">
                      <AtSign className="h-3.5 w-3.5 shrink-0 opacity-75" />
                      <span className="truncate">{c.name}</span>
                    </span>
                    {(c.unread_count ?? 0) > 0 && (
                      <span className="shrink-0 rounded-full bg-sky-600 px-1.5 py-0.5 text-[10px] font-bold text-white">
                        {c.unread_count}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
        </aside>

        {/* Center panel: Calm Inbox OR Channel Stream */}
        <section className="flex-1 min-w-0 rounded-2xl border border-stone-200 bg-white flex flex-col overflow-hidden">
          {error && (
            <div className="border-b border-red-200 bg-red-50 px-4 py-2 text-xs text-red-800 flex items-center justify-between">
              <span>{error}</span>
              <button type="button" onClick={() => setError(null)}>
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          )}

          {inboxOpen ? (
            <div className="flex-1 flex flex-col">
              <div className="border-b border-stone-200 px-5 py-3.5 flex items-center justify-between">
                <div>
                  <h2 className="text-sm font-semibold text-stone-900">
                    Calm Inbox (Mentions, Threads &amp; DMs)
                  </h2>
                  <p className="text-xs text-stone-500">
                    High-signal notifications only; regular channel chatter stays out of your way.
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => void handleAckInbox()}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 px-3 py-1.5 text-xs font-medium text-stone-700 hover:bg-stone-50"
                >
                  <CheckCheck className="h-3.5 w-3.5" />
                  Mark all read
                </button>
              </div>
              <div className="flex-1 overflow-y-auto p-4 space-y-2">
                {inboxItems.length === 0 ? (
                  <div className="py-12 text-center text-xs text-stone-500">
                    Inbox is clear.
                  </div>
                ) : (
                  inboxItems.map((it) => (
                    <div
                      key={it.id}
                      className={`rounded-xl border p-3.5 flex items-start justify-between gap-3 ${
                        it.read_at
                          ? "border-stone-200 bg-stone-50/50 text-stone-500"
                          : "border-amber-200 bg-amber-50/40 text-stone-900"
                      }`}
                    >
                      <button
                        type="button"
                        onClick={() => {
                          setInboxOpen(false);
                          setActiveChannelId(it.channel_id);
                        }}
                        className="text-left flex-1 min-w-0"
                      >
                        <div className="flex items-center gap-2 text-xs">
                          <span className="rounded bg-stone-200/80 px-1.5 py-0.5 font-mono text-[10px] uppercase text-stone-700">
                            {it.kind}
                          </span>
                          <span className="font-semibold">@{it.actor_handle}</span>
                          <span className="text-stone-400">{formatClock(it.created_at)}</span>
                        </div>
                        <div className="mt-1 text-sm truncate">{it.preview}</div>
                      </button>
                      {!it.read_at && (
                        <button
                          type="button"
                          onClick={() => void handleAckInbox(it.id)}
                          title="Acknowledge"
                          className="rounded-lg border border-stone-200 bg-white p-1.5 text-stone-600 hover:bg-stone-100"
                        >
                          <Check className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </div>
                  ))
                )}
              </div>
            </div>
          ) : activeChannel ? (
            <>
              <div className="border-b border-stone-200 px-5 py-3 flex flex-wrap items-center justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <h2 className="text-sm font-semibold text-stone-900 truncate">
                      {activeChannel.kind === "dm" ? activeChannel.name : `#${activeChannel.name}`}
                    </h2>
                    {activeChannel.ferpa_restricted && (
                      <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold text-amber-900">
                        <ShieldAlert className="h-3 w-3" />
                        FERPA Vault Audited
                      </span>
                    )}
                    {activeChannel.read_only && (
                      <span className="inline-flex items-center gap-1 rounded-full bg-stone-100 border border-stone-200 px-2 py-0.5 text-[10px] font-semibold text-stone-700">
                        <Lock className="h-3 w-3" />
                        Read-only archive
                      </span>
                    )}
                  </div>
                  {activeChannel.topic && (
                    <p className="text-xs text-stone-500 truncate mt-0.5">{activeChannel.topic}</p>
                  )}
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  <form onSubmit={handleRunChannelSearch} className="relative">
                    <Search className="h-3.5 w-3.5 text-stone-400 absolute left-2.5 top-2" />
                    <input
                      type="text"
                      value={searchText}
                      onChange={(e) => {
                        setSearchText(e.target.value);
                        if (!e.target.value.trim()) setSearchHits(null);
                      }}
                      placeholder="Search channel..."
                      className="rounded-lg border border-stone-200 pl-8 pr-3 py-1 text-xs outline-none focus:border-stone-900"
                    />
                  </form>
                  <button
                    type="button"
                    onClick={() => setDecisionsOnly((p) => !p)}
                    className={`inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium ${
                      decisionsOnly
                        ? "border-amber-400 bg-amber-50 text-amber-900"
                        : "border-stone-200 text-stone-600 hover:bg-stone-50"
                    }`}
                  >
                    <Award className="h-3.5 w-3.5" />
                    Decisions
                  </button>
                  <button
                    type="button"
                    onClick={() => void handleMarkRead()}
                    className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1 text-xs text-stone-600 hover:bg-stone-50"
                  >
                    <CheckCheck className="h-3.5 w-3.5" />
                    Mark read
                  </button>
                </div>
              </div>

              {searchHits !== null && (
                <div className="border-b border-stone-200 bg-stone-50 px-5 py-3 space-y-1.5">
                  <div className="flex items-center justify-between text-xs font-medium text-stone-700">
                    <span>Channel search hits ({searchHits.length})</span>
                    <button
                      type="button"
                      onClick={() => {
                        setSearchHits(null);
                        setSearchText("");
                      }}
                      className="text-stone-400 hover:text-stone-700"
                    >
                      Clear
                    </button>
                  </div>
                  {searchHits.map((h) => (
                    <div
                      key={h.message_id}
                      className="rounded-lg border border-stone-200 bg-white px-3 py-2 text-xs"
                    >
                      <span className="font-semibold">@{h.author_handle}: </span>
                      <span className="text-stone-600">{h.snippet}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="flex-1 overflow-y-auto p-4 space-y-2.5 bg-[#fafaf8]">
                {hasMore && nextBeforeCursor && (
                  <div className="text-center pb-2">
                    <button
                      type="button"
                      onClick={() =>
                        void loadMessages(activeChannel.id, {
                          before: nextBeforeCursor,
                          appendOlder: true,
                        })
                      }
                      className="rounded-full border border-stone-200 bg-white px-3 py-1 text-xs font-medium text-stone-600 hover:bg-stone-50"
                    >
                      Load older messages
                    </button>
                  </div>
                )}
                {loadingMsgs && messages.length === 0 ? (
                  <div className="py-10 text-center text-xs text-stone-400">
                    Loading messages...
                  </div>
                ) : messages.length === 0 ? (
                  <div className="py-12 text-center text-xs text-stone-500">
                    No messages in this channel yet. Start a discussion below.
                  </div>
                ) : (
                  messages.map((m) => renderMessageCard(m, false))
                )}
              </div>

              {activeChannel.read_only ? (
                <div className="border-t border-stone-200 px-4 py-3 bg-stone-50 text-xs text-stone-600 flex items-center gap-2">
                  <Lock className="h-3.5 w-3.5 text-stone-500 shrink-0" />
                  Read-only archive imported from Slack — posting, edits, and deletions are disabled.
                </div>
              ) : (
                <form onSubmit={handleSendMessage} className="relative border-t border-stone-200 p-3.5 bg-white">
                  {entityPickerOpen && (
                    <div className="mb-2.5 rounded-xl border border-stone-200 bg-stone-50 p-2.5 space-y-2">
                      <div className="flex items-center justify-between gap-2">
                        <input
                          type="text"
                          value={entityQuery}
                          onChange={(e) => {
                            const val = e.target.value;
                            setEntityQuery(val);
                            void loadLinkableEntities(val);
                          }}
                          placeholder="Search pages, tasks, proposals to cite (@/#)..."
                          className="flex-1 rounded-lg border border-stone-200 bg-white px-2.5 py-1 text-xs outline-none focus:border-stone-900"
                        />
                        <button
                          type="button"
                          onClick={() => setEntityPickerOpen(false)}
                          className="rounded p-1 text-stone-400 hover:text-stone-700"
                        >
                          <X className="h-3.5 w-3.5" />
                        </button>
                      </div>
                      <div className="max-h-36 overflow-y-auto space-y-1">
                        {entityResults.length === 0 ? (
                          <div className="text-[11px] text-stone-400 px-1 py-1">No matching entities.</div>
                        ) : (
                          entityResults.map((ent) => (
                            <button
                              key={`${ent.kind}-${ent.id}`}
                              type="button"
                              onClick={() => {
                                setComposer((prev) =>
                                  prev ? `${prev.trimEnd()} ${ent.insert_token} ` : `${ent.insert_token} `
                                );
                                setEntityPickerOpen(false);
                              }}
                              className="w-full flex items-center justify-between gap-2 rounded-lg bg-white border border-stone-200 px-2.5 py-1 text-left text-xs hover:border-sky-300 hover:bg-sky-50/40"
                            >
                              <span className="font-medium text-stone-900 truncate">{ent.title}</span>
                              <span className="shrink-0 font-mono text-[10px] text-stone-500">
                                {ent.subtitle}
                              </span>
                            </button>
                          ))
                        )}
                      </div>
                    </div>
                  )}
                  {pendingAtts.length > 0 && (
                    <div className="mb-2 flex flex-wrap gap-2">
                      {pendingAtts.map((a) => (
                        <span
                          key={a.id}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 bg-stone-50 px-2.5 py-1 text-xs text-stone-700"
                        >
                          <Paperclip className="h-3 w-3" />
                          {a.filename}
                          <button
                            type="button"
                            onClick={() =>
                              setPendingAtts((prev) => prev.filter((x) => x.id !== a.id))
                            }
                          >
                            <X className="h-3 w-3 text-stone-400 hover:text-stone-800" />
                          </button>
                        </span>
                      ))}
                    </div>
                  )}
                  <div className="flex items-end gap-2">
                    <input
                      ref={fileInputRef}
                      type="file"
                      className="hidden"
                      onChange={(e) => {
                        const f = e.target.files?.[0];
                        if (f) void handleUploadFile(f);
                      }}
                    />
                    <button
                      type="button"
                      disabled={uploading}
                      onClick={() => fileInputRef.current?.click()}
                      title="Attach file"
                      className="rounded-lg border border-stone-200 p-2 text-stone-500 hover:bg-stone-100 hover:text-stone-800 disabled:opacity-50"
                    >
                      <Paperclip className="h-4 w-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        const next = !entityPickerOpen;
                        setEntityPickerOpen(next);
                        if (next) void loadLinkableEntities(entityQuery);
                      }}
                      title="Insert @page / @task / @proposal citation"
                      className={`rounded-lg border p-2 transition ${
                        entityPickerOpen
                          ? "border-sky-400 bg-sky-50 text-sky-800"
                          : "border-stone-200 text-stone-500 hover:bg-stone-100"
                      }`}
                    >
                      <Link2 className="h-4 w-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() => setMarkDecision((p) => !p)}
                      title="Flag message as Decision"
                      className={`rounded-lg border p-2 transition ${
                        markDecision
                          ? "border-amber-400 bg-amber-50 text-amber-800"
                          : "border-stone-200 text-stone-500 hover:bg-stone-100"
                      }`}
                    >
                      <Award className="h-4 w-4" />
                    </button>
                    <textarea
                      rows={2}
                      value={composer}
                      onChange={(e) => setComposer(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.shiftKey) {
                          e.preventDefault();
                          void handleSendMessage(e);
                        }
                      }}
                      placeholder={`Message ${
                        activeChannel.kind === "dm" ? activeChannel.name : `#${activeChannel.name}`
                      } (@mention teammates or @page:/[[row:...]] refs)...`}
                      className="flex-1 resize-none rounded-xl border border-stone-200 px-3 py-2 text-sm outline-none focus:border-stone-900"
                    />
                    <button
                      type="submit"
                      disabled={sending || (!composer.trim() && pendingAtts.length === 0)}
                      className="inline-flex items-center gap-1.5 rounded-xl bg-stone-900 px-4 py-2 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
                    >
                      <Send className="h-3.5 w-3.5" />
                      Send
                    </button>
                  </div>
                </form>
              )}
            </>
          ) : (
            <div className="flex-1 flex flex-col items-center justify-center p-8 text-center">
              <MessageSquare className="h-8 w-8 text-stone-300 mb-2" />
              <div className="text-sm font-medium text-stone-800">No visible channels yet</div>
              <p className="text-xs text-stone-500 mt-1">
                Create a channel inside one of your Collections or start a Direct Message.
              </p>
              <button
                type="button"
                onClick={() => setNewModalOpen(true)}
                className="mt-4 inline-flex items-center gap-1.5 rounded-lg bg-stone-900 px-3.5 py-2 text-xs font-medium text-white"
              >
                <Plus className="h-3.5 w-3.5" />
                Create Channel / DM
              </button>
            </div>
          )}
        </section>

        {/* Right expandable Thread Drawer */}
        {threadRoot && activeChannel && (
          <aside className="w-full lg:w-88 shrink-0 rounded-2xl border border-stone-200 bg-white flex flex-col overflow-hidden">
            <div className="border-b border-stone-200 px-4 py-3 flex items-center justify-between">
              <div className="text-xs font-semibold text-stone-900">Thread</div>
              <button
                type="button"
                onClick={() => {
                  setThreadRoot(null);
                  setThreadReplies([]);
                }}
                className="rounded p-1 text-stone-400 hover:bg-stone-100 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <div className="flex-1 overflow-y-auto p-3 space-y-2.5 bg-[#fafaf8]">
              {renderMessageCard(threadRoot, true)}
              <div className="px-1 text-[10px] font-semibold uppercase tracking-wider text-stone-400">
                Replies ({threadReplies.length})
              </div>
              {threadReplies.map((r) => renderMessageCard(r, true))}
            </div>
            <form onSubmit={handleSendThreadReply} className="border-t border-stone-200 p-3 bg-white">
              <div className="flex items-end gap-2">
                <textarea
                  rows={2}
                  value={threadText}
                  onChange={(e) => setThreadText(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      void handleSendThreadReply(e);
                    }
                  }}
                  placeholder="Reply in thread..."
                  className="flex-1 resize-none rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs outline-none focus:border-stone-900"
                />
                <button
                  type="submit"
                  disabled={threadSending || !threadText.trim()}
                  className="rounded-lg bg-stone-900 p-2 text-white hover:bg-stone-800 disabled:opacity-50"
                >
                  <Send className="h-3.5 w-3.5" />
                </button>
              </div>
            </form>
          </aside>
        )}
      </div>

      {/* Create Channel / DM Modal */}
      {newModalOpen && (
        <div className="fixed inset-0 z-50 bg-stone-950/40 backdrop-blur-xs flex items-center justify-center p-4">
          <form
            onSubmit={handleCreateChannel}
            className="w-full max-w-md rounded-2xl border border-stone-200 bg-white p-6 shadow-xl space-y-4"
          >
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-stone-900">New Channel or DM</h3>
              <button
                type="button"
                onClick={() => setNewModalOpen(false)}
                className="text-stone-400 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <div className="grid grid-cols-3 gap-1.5 rounded-lg border border-stone-200 p-1 bg-stone-50 text-xs font-medium">
              {(["public", "private", "dm"] as const).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => setNewKind(k)}
                  className={`rounded-md py-1.5 capitalize ${
                    newKind === k ? "bg-white shadow-xs text-stone-950" : "text-stone-500"
                  }`}
                >
                  {k === "dm" ? "Direct Msg" : k}
                </button>
              ))}
            </div>
            {newKind !== "dm" && (
              <div>
                <label className="block text-xs font-medium text-stone-700 mb-1">
                  Collection Scope
                </label>
                <select
                  value={newColId}
                  onChange={(e) => setNewColId(e.target.value)}
                  className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm"
                >
                  {collections.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </div>
            )}
            <div>
              <label className="block text-xs font-medium text-stone-700 mb-1">
                {newKind === "dm" ? "Optional DM Title" : "Channel Name"}
              </label>
              <input
                type="text"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                required={newKind !== "dm"}
                placeholder={newKind === "dm" ? "Auto-named from members" : "engineering-ops"}
                className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm"
              />
            </div>
            {newKind !== "dm" && (
              <div>
                <label className="block text-xs font-medium text-stone-700 mb-1">Topic</label>
                <input
                  type="text"
                  value={newTopic}
                  onChange={(e) => setNewTopic(e.target.value)}
                  placeholder="Optional channel topic"
                  className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm"
                />
              </div>
            )}
            {newKind !== "public" && (
              <div>
                <label className="block text-xs font-medium text-stone-700 mb-1">
                  Members
                </label>
                <div className="max-h-32 overflow-y-auto rounded-lg border border-stone-200 p-2 space-y-1">
                  {principals
                    .filter((p) => p.id !== auth?.id)
                    .map((p) => {
                      const checked = newMemberIds.includes(p.id);
                      return (
                        <label
                          key={p.id}
                          className="flex items-center gap-2 text-xs text-stone-700 cursor-pointer"
                        >
                          <input
                            type="checkbox"
                            checked={checked}
                            onChange={(e) =>
                              setNewMemberIds((prev) =>
                                e.target.checked
                                  ? [...prev, p.id]
                                  : prev.filter((x) => x !== p.id)
                              )
                            }
                          />
                          <span>
                            {p.display_name} ({p.handle})
                          </span>
                        </label>
                      );
                    })}
                </div>
              </div>
            )}
            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setNewModalOpen(false)}
                className="rounded-lg border border-stone-200 px-3.5 py-1.5 text-xs font-medium text-stone-600"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={creatingCh}
                className="rounded-lg bg-stone-900 px-4 py-1.5 text-xs font-medium text-white disabled:opacity-50"
              >
                {creatingCh ? "Creating..." : "Create"}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Create Database Task Modal */}
      {taskModalMsg && (
        <div className="fixed inset-0 z-50 bg-stone-950/40 backdrop-blur-xs flex items-center justify-center p-4">
          <form
            onSubmit={handleCreateTaskFromMsg}
            className="w-full max-w-md rounded-2xl border border-stone-200 bg-white p-6 shadow-xl space-y-4"
          >
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-stone-900">Create Database Task from Chat</h3>
              <button
                type="button"
                onClick={() => setTaskModalMsg(null)}
                className="text-stone-400 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <div>
              <label className="block text-xs font-medium text-stone-700 mb-1">
                Target Database
              </label>
              <select
                value={taskDbId}
                onChange={(e) => setTaskDbId(e.target.value)}
                required
                className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm bg-white"
              >
                {databases.map((db) => (
                  <option key={db.id} value={db.id}>
                    {db.title}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs font-medium text-stone-700 mb-1">Task Title</label>
              <input
                type="text"
                value={taskTitle}
                onChange={(e) => setTaskTitle(e.target.value)}
                required
                placeholder="Action item title"
                className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm"
              />
            </div>
            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setTaskModalMsg(null)}
                className="rounded-lg border border-stone-200 px-3.5 py-1.5 text-xs font-medium text-stone-600"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={taskSubmitting || !taskDbId}
                className="rounded-lg bg-stone-900 px-4 py-1.5 text-xs font-medium text-white disabled:opacity-50"
              >
                {taskSubmitting ? "Creating..." : "Create Task"}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Draft Living Doc Change Proposal Modal */}
      {propModalMsg && (
        <div className="fixed inset-0 z-50 bg-stone-950/40 backdrop-blur-xs flex items-center justify-center p-4">
          <form
            onSubmit={handleDraftProposalFromMsg}
            className="w-full max-w-md rounded-2xl border border-stone-200 bg-white p-6 shadow-xl space-y-4"
          >
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-stone-900">Draft Living Doc Update</h3>
              <button
                type="button"
                onClick={() => setPropModalMsg(null)}
                className="text-stone-400 hover:text-stone-700"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
            <div>
              <label className="block text-xs font-medium text-stone-700 mb-1">Target Page</label>
              <select
                value={propTargetPageId}
                onChange={(e) => setPropTargetPageId(e.target.value)}
                required
                className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm bg-white"
              >
                <option value="">Select a visible page...</option>
                {propPages.map((pg) => (
                  <option key={pg.id} value={pg.id}>
                    {pg.title}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs font-medium text-stone-700 mb-1">
                Proposal Title
              </label>
              <input
                type="text"
                value={propTitle}
                onChange={(e) => setPropTitle(e.target.value)}
                required
                className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-stone-700 mb-1">Reason</label>
              <input
                type="text"
                value={propReason}
                onChange={(e) => setPropReason(e.target.value)}
                className="w-full rounded-lg border border-stone-200 px-3 py-1.5 text-sm"
              />
            </div>
            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setPropModalMsg(null)}
                className="rounded-lg border border-stone-200 px-3.5 py-1.5 text-xs font-medium text-stone-600"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={propSubmitting || !propTargetPageId}
                className="rounded-lg bg-stone-900 px-4 py-1.5 text-xs font-medium text-white disabled:opacity-50"
              >
                {propSubmitting ? "Drafting..." : "Draft Proposal"}
              </button>
            </div>
          </form>
        </div>
      )}
    </WorkspaceLayout>
  );
}
