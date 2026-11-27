## Shared Vellum Stage 1 domain types, error enum, and JSON-serializable payloads.
module Domain.Types
expose PrincipalKind(..),
WorkspaceRole(..),
Principal(..),
AgentToken(..),
AuthContext(..),
CollectionWritePolicy(..),
Workspace(..),
Collection(..),
PageKind(..),
Page(..),
AuthorKind(..),
Citation(..),
Provenance(..),
BlockKind(..),
Block(..),
BlockOp(..),
Comment(..),
Attachment(..),
SearchResultItem(..),
AuditFeedItem(..),
AppError(..),
to_text
use Arvo.Session

## Whether a workspace member is an OIDC-authenticated human or an agent principal.
enum PrincipalKind
  Human
  Agent
end

## Coarse workspace capability tier assigned to a `Principal`.
enum WorkspaceRole
  Owner
  Admin
  Member
  Guest
  Bot
end

## Unified identity for both humans (OIDC) and agents (token + grant) across all tables and audits.
struct Principal
  id: Text
  kind: PrincipalKind
  handle: Text
  display_name: Text
  email: Option(Text)
  avatar_url: Option(Text)
  role: WorkspaceRole
  model_id: Option(Text)
  root_grant_id: Text
  suspended: Bool
  created_at: Time
  last_seen_at: Option(Time)
end

## Revocable SHA-256-hashed Bearer credential bound to an Agent principal and attenuated `Modb.Grants.Grant`.
struct AgentToken
  id: Text
  principal_id: Text
  grant_id: Text
  label: Text
  prefix: Text
  token_hash: Text
  created_by: Text
  expires_at: Option(Time)
  revoked_at: Option(Time)
  last_used_at: Option(Time)
end

## Authenticated request context resolved by `Routes.Auth.authenticate`.
struct AuthContext
  principal: Principal
  grant_id: Text
  session: Option(Session.Session)
  allowed_collections: Option(List(Text))
  allowed_actions: List(Text)
end

## Per-collection rule controlling whether writes land directly or require Change Proposals.
enum CollectionWritePolicy
  DirectWithAudit
  ProposalsRequiredForAgents
  ProposalsRequiredForAll
end

## Top-level workspace configuration record.
struct Workspace
  id: Text
  slug: Text
  name: Text
  allowed_domains: List(Text)
  default_write_policy: CollectionWritePolicy
  default_freshness_ttl_days: Int
  updated_at: Time
end

## Hierarchical knowledge collection grouping pages and nested documents.
struct Collection
  id: Text
  workspace_id: Text
  slug: Text
  name: Text
  description: Text
  icon: Option(Text)
  write_policy: CollectionWritePolicy
  freshness_ttl_days: Option(Int)
  sort_order: Text
  archived_at: Option(Time)
end

## Distinguishes regular wiki documents from database rows (coming in Stage 2).
enum PageKind
  Document
  DatabaseRow(database_id: Text, row_id: Text)
end

## Metadata record for a document page inside a `Collection`.
struct Page
  id: Text
  collection_id: Text
  parent_page_id: Option(Text)
  title: Text
  icon: Option(Text)
  cover_attachment_id: Option(Text)
  kind: PageKind
  sort_order: Text
  database_id: Option(Text)
  freshness_ttl_days: Option(Int)
  verified_at: Option(Time)
  verified_by: Option(Text)
  created_by: Text
  created_at: Time
  updated_at: Time
  archived_at: Option(Time)
  version: Int
end

## Distinguishes human-authored vs AI/agent-authored blocks.
enum AuthorKind
  HumanAuthor
  AgentAuthor(model: Option(Text))
end

## Source reference attached to a block or proposal for verifiable knowledge provenance.
struct Citation
  source_kind: Text
  source_ref: Text
  label: Text
  excerpt: Option(Text)
end

## Authorship, grant, reason, and citation metadata stored directly on every `Block`.
struct Provenance
  author_id: Text
  author_kind: AuthorKind
  grant_id: Option(Text)
  proposal_id: Option(Text)
  reason: Option(Text)
  citations: List(Citation)
  updated_at: Time
end

## Canonical block variants shared between the TipTap editor and anchored Markdown projection.
enum BlockKind
  Paragraph
  Heading(level: Int)
  BulletListItem
  OrderedListItem(start: Int)
  TaskItem(checked: Bool)
  Quote
  Callout(tone: Text, icon: Option(Text))
  CodeBlock(language: Text)
  Divider
  Image(attachment_id: Text, caption: Text)
  FileEmbed(attachment_id: Text, filename: Text)
  PageLink(target_page_id: Text)
  DatabaseViewEmbed(database_id: Text, view_id: Option(Text))
end

## Ordered, stable-ID content unit belonging to a `Page`.
struct Block
  id: Text
  page_id: Text
  parent_block_id: Option(Text)
  rank: Text
  kind: BlockKind
  markdown: Text
  provenance: Provenance
  version: Int
end

## Surgical mutation operations applied cleanly by both the TipTap editor and AI agents.
enum BlockOp
  ReplaceBlock(block_id: Text, expected_version: Int, kind: Option(BlockKind), markdown: Text)
  InsertBlockAfter(
    after_block_id: Option(Text),
    parent_block_id: Option(Text),
    kind: BlockKind,
    markdown: Text
  )
  DeleteBlock(block_id: Text, expected_version: Int)
  MoveBlock(block_id: Text, new_parent_id: Option(Text), after_block_id: Option(Text))
  AttachCitations(block_id: Text, citations: List(Citation))
end

## Page-level or block-anchored discussion comment.
struct Comment
  id: Text
  page_id: Text
  block_id: Option(Text)
  parent_comment_id: Option(Text)
  author_id: Text
  body_markdown: Text
  resolved_at: Option(Time)
  created_at: Time
end

## S3-backed attachment metadata stored in MoDB (never raw binary blobs).
struct Attachment
  id: Text
  workspace_id: Text
  page_id: Text
  uploaded_by: Text
  filename: Text
  content_type: Text
  size_bytes: Int
  sha256_hex: Text
  s3_bucket: Text
  s3_key: Text
  status: Text
  created_at: Time
end

## Grant-filtered search hit returned by `/api/search` and `/mcp` (`vellum.search`).
struct SearchResultItem
  page_id: Text
  collection_id: Text
  title: Text
  score: Float
  matched_terms: List(Text)
  matched_fields: List(Text)
  fts_rank: Option(Int)
  vec_rank: Option(Int)
  vec_score: Option(Float)
end

## UI-ready summary of a `Modb.Ledger.AuditEntry` (`actor_name` avoids Mo's `actor` keyword).
struct AuditFeedItem
  seq: Int
  txid: Int
  actor_name: Text
  action: Text
  reason: Text
  summary: Text
  at: Time
end

## Domain errors mapped exhaustively to HTTP status codes in `Main`'s `api` block.
enum AppError
  Unauthenticated
  Forbidden(reason: Text)
  Missing(entity: Text, id: Text)
  Conflict(reason: Text)
  BadInput(reason: Text)
  ServerFailed(reason: Text)
end

## Formats an `AppError` as a human-readable message.
fn to_text(err: AppError) : Text
  case err
    Unauthenticated: "authentication required"
    Forbidden(reason: r): "forbidden: #{r}"
    Missing(entity: e, id: i): "#{e} '#{i}' not found"
    Conflict(reason: r): "conflict: #{r}"
    BadInput(reason: r): "invalid input: #{r}"
    ServerFailed(reason: r): "internal error: #{r}"
  end
end
