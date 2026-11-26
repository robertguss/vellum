export type CollectionWritePolicy =
  | "direct_with_audit"
  | "proposals_required_for_agents"
  | "proposals_required_for_all";

export type PrincipalKind = "human" | "agent";
export type WorkspaceRole = "owner" | "admin" | "member" | "guest" | "bot";

export interface AuthUser {
  id: string;
  kind: PrincipalKind;
  handle: string;
  display_name: string;
  email: string | null;
  avatar_url: string | null;
  role: WorkspaceRole;
  model_id?: string | null;
  root_grant_id?: string;
}

export interface FlashMessages {
  notice?: string | null;
  error?: string | null;
  [key: string]: string | null | undefined;
}

export interface SharedPageProps {
  auth: AuthUser | null;
  flash: FlashMessages;
  errors?: Record<string, string>;
  [key: string]: unknown;
}

export interface Collection {
  id: string;
  workspace_id: string;
  slug: string;
  name: string;
  description: string;
  icon: string | null;
  write_policy: CollectionWritePolicy;
  freshness_ttl_days: number | null;
  sort_order: string;
  archived_at: string | null;
}

export type PageKind =
  | "document"
  | { database_row: { database_id: string; row_id: string } };

export interface Page {
  id: string;
  collection_id: string;
  parent_page_id: string | null;
  title: string;
  icon: string | null;
  cover_attachment_id: string | null;
  kind: PageKind;
  sort_order: string;
  database_id: string | null;
  freshness_ttl_days: number | null;
  verified_at: string | null;
  verified_by: string | null;
  created_by: string;
  created_at: string;
  updated_at: string;
  archived_at: string | null;
  version: number;
}

export type AuthorKind =
  | "human_author"
  | { agent_author: { model: string | null } };

export interface Citation {
  source_kind: string;
  source_ref: string;
  label: string;
  excerpt: string | null;
}

export interface Provenance {
  author_id: string;
  author_kind: AuthorKind;
  grant_id: string | null;
  proposal_id: string | null;
  reason: string | null;
  citations: Citation[];
  updated_at: string;
}

export type BlockKind =
  | "paragraph"
  | { heading: { level: number } }
  | "bullet_list_item"
  | { ordered_list_item: { start: number } }
  | { task_item: { checked: boolean } }
  | "quote"
  | { callout: { tone: string; icon: string | null } }
  | { code_block: { language: string } }
  | "divider"
  | { image: { attachment_id: string; caption: string } }
  | { file_embed: { attachment_id: string; filename: string } }
  | { page_link: { target_page_id: string } };

export interface Block {
  id: string;
  page_id: string;
  parent_block_id: string | null;
  rank: string;
  kind: BlockKind;
  markdown: string;
  provenance: Provenance;
  version: number;
}

export type BlockOp =
  | {
      replace_block: {
        block_id: string;
        expected_version: number;
        kind: BlockKind | null;
        markdown: string;
      };
    }
  | {
      insert_block_after: {
        after_block_id: string | null;
        parent_block_id: string | null;
        kind: BlockKind;
        markdown: string;
      };
    }
  | {
      delete_block: {
        block_id: string;
        expected_version: number;
      };
    }
  | {
      move_block: {
        block_id: string;
        new_parent_id: string | null;
        after_block_id: string | null;
      };
    }
  | {
      attach_citations: {
        block_id: string;
        citations: Citation[];
      };
    };

export interface Comment {
  id: string;
  page_id: string;
  block_id: string | null;
  parent_comment_id: string | null;
  author_id: string;
  body_markdown: string;
  resolved_at: string | null;
  created_at: string;
}

export interface Attachment {
  id: string;
  workspace_id: string;
  page_id: string;
  uploaded_by: string;
  filename: string;
  content_type: string;
  size_bytes: number;
  sha256_hex: string;
  s3_bucket: string;
  s3_key: string;
  status: string;
  created_at: string;
}

export type SearchMode = "hybrid" | "bm25" | "semantic";

export interface SearchResultItem {
  page_id: string;
  collection_id: string;
  title: string;
  score: number;
  matched_terms: string[];
  matched_fields: string[];
  fts_rank?: number | null;
  vec_rank?: number | null;
  vec_score?: number | null;
}

export interface SearchResponse {
  results: SearchResultItem[];
  mode?: SearchMode;
  vector_backend?: "neural" | "sketch" | "none";
}

export interface AuditFeedItem {
  seq: number;
  txid: number;
  actor_name: string;
  action: string;
  reason: string;
  summary: string;
  created_at: string;
}

export type SelectOptionColor = "gray" | "blue" | "green" | "amber" | "red" | "purple";

export interface SelectOption {
  id: string;
  label: string;
  color: SelectOptionColor;
}

export type RollupAgg = "count_all" | "count_values" | "sum_values" | "min_value" | "max_value";

export type PropertyKind =
  | "title"
  | "rich_text"
  | { number: { format: string } }
  | { date_prop: { include_time: boolean } }
  | { select: { options: SelectOption[] } }
  | { multi_select: { options: SelectOption[] } }
  | "checkbox"
  | "person"
  | "url"
  | { relation: { target_db_id: string; inverse_prop_id: string | null } }
  | { rollup: { relation_prop_id: string; target_prop_id: string; agg: RollupAgg } };

export interface PropertyDef {
  id: string;
  name: string;
  kind: PropertyKind;
  required: boolean;
  sort_order: string;
}

export interface DatabaseDef {
  id: string;
  collection_id: string;
  page_id: string;
  title: string;
  description: string;
  properties: PropertyDef[];
  version: number;
}

export type CellValue =
  | "empty"
  | { text_val: string }
  | { number_val: string }
  | { date_val: { start: string; end_date: string | null } }
  | { select_val: { option_id: string } }
  | { multi_select_val: { option_ids: string[] } }
  | { bool_val: boolean }
  | { principal_val: string[] }
  | { url_val: string }
  | { relation_val: { row_ids: string[] } };

export interface DbRow {
  id: string;
  database_id: string;
  page_id: string;
  cells: Record<string, CellValue>;
  created_by: string;
  created_at: string;
  updated_at: string;
  archived_at: string | null;
  version: number;
}

export interface EnrichedRow {
  row: DbRow;
  title: string;
  effective_cells: Record<string, CellValue>;
}

export type DbViewKind =
  | { table_view: { visible_prop_ids: string[]; column_widths: Record<string, number> } }
  | { board_view: { group_by_prop_id: string; card_prop_ids: string[]; hide_empty_groups: boolean } }
  | { calendar_view: { date_prop_id: string; card_prop_ids: string[] } };

export type FilterOp =
  | "eq"
  | "neq"
  | "gt"
  | "gte"
  | "lt"
  | "lte"
  | "contains"
  | "in_set"
  | "is_empty"
  | "is_not_empty";

export interface DbFilterRule {
  prop_id: string;
  op: FilterOp;
  value: unknown;
}

export interface DbSortRule {
  prop_id: string;
  desc: boolean;
}

export interface DbViewDef {
  id: string;
  database_id: string;
  name: string;
  kind: DbViewKind;
  filters: DbFilterRule[];
  filter_match_all: boolean;
  sorts: DbSortRule[];
  sort_order: string;
}

export interface BoardGroup {
  key: string;
  label: string;
  rows: EnrichedRow[];
}

export interface ViewQueryResult {
  database_id: string;
  view_id: string | null;
  rows: EnrichedRow[];
  board_groups: BoardGroup[];
  total_count: number;
}

export interface ProposalMeta {
  id: string;
  world_id: string;
  collection_id: string;
  target_page_id: string;
  title: string;
  reason: string;
  author_id: string;
  author_handle: string;
  grant_id: string;
  status: string;
  created_at: string;
  updated_at: string;
  decided_by: string | null;
  decided_at: string | null;
}

export interface WebhookSubPublic {
  id: string;
  workspace_id: string;
  collection_id: string | null;
  url: string;
  events: string[];
  enabled: boolean;
  created_at: string;
}

export interface ClaimRecord {
  resource: string;
  holder: string;
  grant_id: string;
  world_id: string | null;
  reason: string;
  acquired_at: string;
  expires_at: string;
}

export interface AiCitation {
  page_id: string;
  collection_id: string;
  block_id: string;
  title: string;
  excerpt: string;
}

export interface GardenStalePage {
  page_id: string;
  collection_id: string;
  title: string;
  days_since_verified: number;
  ttl_days: number;
}

export interface GardenBrokenLink {
  source_page_id: string;
  source_title: string;
  block_id: string;
  target_page_id: string;
  label: string;
}

export interface GardenReport {
  checked_pages: number;
  stale_pages: GardenStalePage[];
  broken_links: GardenBrokenLink[];
  scanned_at: string;
}
