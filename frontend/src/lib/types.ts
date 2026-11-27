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
  alert?: string | null;
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
  | { table_block: { has_header: boolean } }
  | { toggle: { summary: string; open: boolean } }
  | "table_of_contents"
  | { image: { attachment_id: string; caption: string } }
  | { file_embed: { attachment_id: string; filename: string } }
  | { page_link: { target_page_id: string } }
  | { database_view_embed: { database_id: string; view_id: string | null } }
  | { ai_brief: { prompt: string; source_scope: string | null; refreshed_at: string | null } };

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
  at?: string;
  created_at?: string;
}

export type SelectOptionColor = "gray" | "blue" | "green" | "amber" | "red" | "purple";

export interface SelectOption {
  id: string;
  label: string;
  color: SelectOptionColor;
}

export type RollupAgg =
  | "count_all"
  | "count_values"
  | "sum_values"
  | "min_value"
  | "max_value"
  | "percent_per_group";

export type AiOutputKind =
  | "ai_text"
  | { ai_number: { format: string } }
  | "ai_date"
  | "ai_bool"
  | { ai_select: { options: SelectOption[] } };

export type AiColumnMode = "auto_apply" | "stage_proposal";

export interface AiCellMeta {
  id: string;
  database_id: string;
  row_id: string;
  prop_id: string;
  model: string;
  prompt_hash: string;
  input_hash: string;
  stale: boolean;
  rationale: string | null;
  citations: Citation[];
  proposal_id: string | null;
  computed_at: string;
}

export interface AiColumnUsageSummary {
  calls_used: number;
  daily_call_cap: number;
  remaining_calls: number;
  day_iso?: string;
}

export interface AiFeedSyncResult {
  feed_id: string;
  from_txid: number;
  to_txid: number;
  events_seen: number;
  pages_read: number;
  subtrees_skipped: number;
  marked_stale_count: number;
}

export interface RunAiColumnResponse {
  database_id: string;
  prop_id: string;
  mode: AiColumnMode;
  model: string;
  attempted_calls: number;
  updated_count: number;
  skipped_budget_count: number;
  usage: AiColumnUsageSummary;
  results: Array<{
    row_id: string;
    status: "applied" | "staged" | "validation_error";
    value?: CellValue;
    rationale?: string | null;
    error?: string;
  }>;
  proposal: ProposalMeta | null;
}

export type PropertyKind =
  | "title"
  | "rich_text"
  | { number: { format: string } }
  | { date_prop: { include_time: boolean } }
  | { select: { options: SelectOption[] } }
  | { multi_select: { options: SelectOption[] } }
  | { status: { options: SelectOption[]; done_option_ids: string[] } }
  | "checkbox"
  | "person"
  | "email"
  | "file_list"
  | "url"
  | { unique_id: { prefix: string } }
  | { formula: { expression: string; format: string } }
  | "created_time"
  | "created_by"
  | "last_edited_time"
  | "last_edited_by"
  | { relation: { target_db_id: string; inverse_prop_id: string | null } }
  | { rollup: { relation_prop_id: string; target_prop_id: string; agg: RollupAgg } }
  | {
      ai_derived: {
        prompt: string;
        source_prop_ids: string[];
        include_row_body: boolean;
        output_kind: AiOutputKind;
        mode: AiColumnMode;
        daily_call_cap: number;
      };
    };

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
  | { files_val: { attachment_ids: string[] } }
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
  rollups?: Record<string, CellValue>;
  title?: string;
  effective_cells?: Record<string, CellValue>;
}

export type DbViewKind =
  | { table_view: { visible_prop_ids: string[]; column_widths: Record<string, number> } }
  | { board_view: { group_by_prop_id: string; card_prop_ids: string[]; hide_empty_groups: boolean } }
  | { calendar_view: { date_prop_id: string; card_prop_ids: string[] } }
  | { gallery_view: { cover_prop_id: string | null; card_prop_ids: string[]; card_size: string } }
  | {
      timeline_view: {
        start_date_prop_id: string;
        end_date_prop_id: string | null;
        card_prop_ids: string[];
      };
    };

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
  group_key?: string;
  key?: string;
  label: string;
  rows: EnrichedRow[];
}

export interface ViewQueryResult {
  view?: DbViewDef;
  database_id?: string;
  view_id?: string | null;
  rows: EnrichedRow[];
  board_groups?: BoardGroup[] | null;
  total_count: number;
}

export interface ProposalMeta {
  id: string;
  world_id: string;
  collection_id: string;
  target_page_id: string;
  target_database_id?: string | null;
  branch_kind?: "proposal" | "scenario";
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

export interface BlockDiffEntry {
  block_id: string;
  change: "added" | "removed" | "modified";
  rank: string;
  page_id?: string;
  page_title?: string | null;
  before_kind: BlockKind | null;
  after_kind: BlockKind | null;
  before_markdown: string | null;
  after_markdown: string | null;
}

export interface BucketDiffSummary {
  bucket: string;
  added: number;
  removed: number;
  modified: number;
}

export interface PrincipalSummary {
  id: string;
  handle: string;
  display_name: string;
  kind: PrincipalKind;
  role: WorkspaceRole;
}

export interface RelationTargetOption {
  row_id: string;
  page_id: string;
  title: string;
}

export interface DecimalDelta {
  database_id: string;
  database_title: string;
  prop_id: string;
  prop_name: string;
  format: string;
  is_rollup: boolean;
  live_total: string;
  scenario_total: string;
  delta: string;
  changed: boolean;
}

export interface DbCellDiff {
  prop_id: string;
  prop_name: string;
  before: CellValue;
  after: CellValue;
}

export interface DbRowDiffEntry {
  database_id: string;
  database_title: string;
  row_id: string;
  page_id: string;
  change: "added" | "modified" | "removed";
  row_title: string;
  cell_diffs: DbCellDiff[];
}

export interface DbSchemaDiffEntry {
  database_id: string;
  database_title: string;
  prop_id: string;
  prop_name: string;
  change: "added" | "removed" | "modified";
  before_kind: PropertyKind | null;
  after_kind: PropertyKind | null;
  before_required: boolean | null;
  after_required: boolean | null;
}

export interface ScenarioQueryResponse {
  proposal: ProposalMeta;
  database: DatabaseDef;
  query_result: ViewQueryResult;
  deltas: DecimalDelta[];
  row_changes: Record<string, "added" | "modified">;
  removed_rows: EnrichedRow[];
  live_row_count: number;
  scenario_row_count: number;
  schema_changed: boolean;
  step_count: number;
}

export interface ProposalComment {
  id: string;
  proposal_id: string;
  target_kind: string;
  target_ref: string | null;
  parent_comment_id: string | null;
  author_id: string;
  author_handle: string;
  author_kind: AuthorKind;
  body_markdown: string;
  steer_requested: boolean;
  resolved_at: string | null;
  created_at: string;
}

export interface SteerProposalResponse {
  proposal: ProposalMeta;
  human_comment: ProposalComment;
  agent_comment: ProposalComment;
  revised_block_id: string;
  revised_markdown: string;
  model: string;
}

export interface ProposalDiffResponse {
  proposal: ProposalMeta;
  page_title?: string | null;
  database_title?: string | null;
  bucket_diffs: BucketDiffSummary[];
  block_diffs?: BlockDiffEntry[];
  db_row_diffs?: DbRowDiffEntry[];
  db_schema_diffs?: DbSchemaDiffEntry[];
  rollup_deltas?: DecimalDelta[];
  comments?: ProposalComment[];
  step_count?: number;
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
  kind_tag?: string;
  heading_path?: string | null;
}

export interface RlmTraceStep {
  step: number;
  op: "read_program" | "sub_llm" | "synthesize" | string;
  target: string;
  detail: string;
  rows_scanned: number;
  ops_used: number;
  result_count: number;
  answer_hash: string | null;
}

export interface RlmDbSlice {
  database_id: string;
  database_title: string;
  collection_id: string;
  row_id: string;
  page_id: string;
  title: string;
  cells_summary: string;
}

export interface RlmTaintSummary {
  session_id: string;
  untrusted_tainted: boolean;
  max_sensitivity_read: string;
  untrusted_sources: string[];
}

export interface DeepResearchResponse {
  tier: string;
  answer: string;
  model: string;
  session_id: string;
  rows_scanned: number;
  ops_used: number;
  subcalls_used: number;
  max_subcalls: number;
  citations: AiCitation[];
  db_slices: RlmDbSlice[];
  trace: RlmTraceStep[];
  executed_script?: string | null;
  depth_used?: number;
  max_depth?: number;
  child_sessions?: string[];
  grant_calls_debited?: number;
  taint: RlmTaintSummary;
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

export interface GardenDuplicatePair {
  page_a_id: string;
  page_a_title: string;
  collection_a_id: string;
  page_b_id: string;
  page_b_title: string;
  collection_b_id: string;
  similarity: number;
  possible_contradiction: boolean;
  contradiction_reason: string | null;
}

export interface GardenCitationDrift {
  dependent_page_id: string;
  dependent_page_title: string;
  dependent_collection_id: string;
  dependent_block_id: string;
  cited_page_id: string;
  cited_page_title: string;
  cited_block_id: string;
  cited_block_version: number;
  dependent_updated_at: string;
  cited_updated_at: string;
  summary: string;
}

export interface GardenReport {
  checked_pages: number;
  stale_pages: GardenStalePage[];
  broken_links: GardenBrokenLink[];
  duplicate_pairs?: GardenDuplicatePair[];
  citation_drifts?: GardenCitationDrift[];
  scanned_at: string;
}

export type EditorLens = "studio" | "markdown" | "patchwork" | "xray";

export interface BlueprintDef {
  id: string;
  slug: string;
  name: string;
  description: string;
  icon: string | null;
  fields: PropertyDef[];
  default_template_markdown: string;
  version: number;
}

export interface PageBlueprintMeta {
  page_id: string;
  blueprint_id: string;
  values: Record<string, CellValue>;
  updated_at: string;
}

export interface ResolvedMetric {
  token: string;
  database_id: string;
  property_id: string;
  agg: string;
  status: "ok" | "forbidden" | "missing_property" | "invalid_agg" | "invalid_token";
  value: string | null;
  live_value: string | null;
  scenario_value: string | null;
  delta: string | null;
  format: string;
  database_title: string | null;
  property_name: string | null;
  row_count: number;
}

export interface BlockContextResponse {
  block: Block;
  page: Page;
  collection: Collection;
  prev_block: Block | null;
  next_block: Block | null;
  page_blueprint: BlueprintDef | null;
  page_meta: PageBlueprintMeta | null;
  comments: Comment[];
}

export interface LivingSummary {
  id: string;
  entity_kind: "page" | "database" | string;
  entity_id: string;
  collection_id: string;
  title: string;
  structural_summary: string;
  semantic_summary: string | null;
  headings: string[];
  word_count: number;
  open_tasks: number;
  done_tasks: number;
  row_count: number;
  blueprint_slug: string | null;
  estimated_tokens: number;
  source_version: number;
  semantic_source_version: number;
  updated_at: string;
}

export interface ContextPack {
  id: string;
  slug: string;
  name: string;
  description: string;
  collection_ids: string[];
  pinned_page_ids: string[];
  database_ids: string[];
  query_hint: string | null;
  fresh_only: boolean;
  include_full_blocks: boolean;
  token_budget: number;
  created_by: string;
  updated_at: string;
  version: number;
}

export interface CompiledPackItem {
  entity_kind: string;
  entity_id: string;
  collection_id: string;
  title: string;
  inclusion_mode: string;
  tokens_used: number;
  pinned: boolean;
}

export interface CompiledPackResult {
  pack: ContextPack;
  markdown: string;
  tokens_used: number;
  token_budget: number;
  budget_utilization_pct: number;
  included_items: CompiledPackItem[];
  omitted_count: number;
  skipped_stale_count: number;
  compiled_at: string;
}

export interface ExplicitBacklink {
  source_page_id: string;
  source_title: string;
  source_collection_id: string;
  block_id: string;
  kind: "page_link" | "citation" | string;
  excerpt: string;
}

export interface SemanticBacklink {
  page_id: string;
  collection_id: string;
  title: string;
  similarity: number;
  summary: string;
  vector_backend: "neural" | "sketch" | string;
}

export interface ReplayBaseline {
  pin_id: string;
  schema_version: number;
  txid: number;
  pinned_at: string;
}

export interface ReplayCallRecord {
  seq: number;
  audit_seq: number | null;
  principal: string;
  grant_id: string | null;
  world_id: string | null;
  action: string;
  reason: string;
  at: string;
  page_id: string | null;
  database_id: string | null;
  outcome: unknown;
}

export interface ReplaySummary {
  total_calls: number;
  excluded: number;
  unchanged: number;
  reply_changed: number;
  now_refused: number;
  now_invariant_blocked: number;
  still_refused: number;
  now_accepted: number;
  migrations_run: number[];
}

export interface ReplayBucketDiff {
  bucket: string;
  added: number;
  removed: number;
  modified: number;
}

export interface ReplayProposalSummary {
  id: string;
  description: string;
  filter: unknown;
  base_call_seq: number;
  created_by: string;
  created_at: string;
  status: unknown;
  summary: ReplaySummary;
  outcomes: unknown[];
  bucket_diffs: ReplayBucketDiff[];
}

export interface ReplayStatusResponse {
  baseline: ReplayBaseline | null;
  call_count: number;
  calls: ReplayCallRecord[];
  proposals: ReplayProposalSummary[];
}

export interface PageTimeTravelStop {
  seq: number;
  stop_before_seq: number;
  label: string;
  principal: string;
  action: string;
  reason: string;
  world_id: string | null;
  grant_id: string | null;
  at: string;
}

export interface PageHistoryResponse {
  page_id: string;
  current_version: number;
  baseline: ReplayBaseline | null;
  can_scrub: boolean;
  total_replay_calls: number;
  stops: PageTimeTravelStop[];
}

export interface PageTimeTravelResponse {
  page_id: string;
  stop_before_seq: number;
  existed_at_point: boolean;
  historical_page: Page | null;
  historical_blocks: Block[];
  historical_markdown: string;
  ops_to_live_count: number;
  summary: ReplaySummary;
  outcomes: unknown[];
}

export interface TaintProvenanceEntry {
  trust: string;
  writer: string;
  updated_at: string;
}

export interface PageTaintProvenance {
  trust: "trusted" | "untrusted" | string;
  page: TaintProvenanceEntry | null;
  blocks: Record<string, TaintProvenanceEntry>;
  untrusted_block_ids: string[];
}

export interface TaintPolicySummary {
  peer_agents_taint: boolean;
  max_sensitivity_when_tainted: string;
  exfil_sinks: string[];
  external_actions: string[];
  block_write_down: boolean;
  strict_no_write_down: boolean;
}

export interface TaintSessionRecord {
  id: string;
  principal: string;
  grant_id: string | null;
  parent_session_id: string | null;
  untrusted_tainted: boolean;
  untrusted_sources: string[];
  max_sensitivity_read: string;
  sensitive_sources: string[];
  blocked_attempts: number;
  opened_at: string;
  updated_at: string;
  cleared_at: string | null;
  cleared_by: string | null;
  closed: boolean;
}

export interface TaintUntrustedRecord {
  bucket: string;
  key_hex: string;
  writer: string;
  trust: string;
  recorded_txid: number;
  updated_at: string;
}

export interface TaintStatusResponse {
  policy: TaintPolicySummary;
  sessions: TaintSessionRecord[];
  untrusted: {
    pages: TaintUntrustedRecord[];
    blocks: TaintUntrustedRecord[];
    proposals: TaintUntrustedRecord[];
  };
}

export interface SecretHint {
  target_kind: string;
  page_id: string;
  page_title: string;
  collection_id: string;
  block_id: string | null;
  comment_id: string | null;
  kind: string;
  label: string;
  severity: string;
  masked_preview: string;
  match_sha256: string;
}

export interface ErasureReceiptRecord {
  id: string;
  subject_id_sha256: string;
  erased_by: string;
  reason: string;
  at: string;
  key_shredded: boolean;
  rows_deleted: number;
  fts_docs_deleted: number;
  vec_docs_deleted: number;
  replay_calls_scrubbed: number;
  read_logs_scrubbed: number;
  audit_entries_redacted: number;
  pre_erasure_tip_hash: string;
  post_erasure_tip_hash: string;
  compacted: boolean;
}

export interface ErasureStatusResponse {
  findings: SecretHint[];
  receipts: ErasureReceiptRecord[];
}

export interface PurgeSecretResponse {
  receipt: ErasureReceiptRecord;
  blocks_redacted: number;
  comments_redacted: number;
  affected_page_ids: string[];
}

export interface GrantTreeNode {
  id: string;
  parent_id: string | null;
  principal_id: string;
  principal_handle: string | null;
  principal_name: string | null;
  principal_kind: PrincipalKind | null;
  model_id: string | null;
  role: WorkspaceRole | null;
  allowed_actions: string[];
  allowed_collections: string[] | null;
  max_calls: number;
  used_calls: number;
  utilization_pct: number;
  expires_at: string;
  revoked: boolean;
  revoked_directly: boolean;
  revoked_via: string | null;
  status: "active" | "revoked" | "expired" | "exhausted" | string;
  depth: number;
  descendant_count: number;
  chain: string[];
  token_prefix: string | null;
  token_label: string | null;
  last_used_at: string | null;
}

export interface GrantTreeSummary {
  total_grants: number;
  active_grants: number;
  active_agent_grants: number;
  delegated_grants: number;
  revoked_grants: number;
  expired_grants: number;
  exhausted_grants: number;
  total_calls_used: number;
  total_call_budget: number;
}

export interface GrantTreeResponse {
  summary: GrantTreeSummary;
  grants: GrantTreeNode[];
}

export interface KillAllGrantsResponse {
  revoked_count: number;
  revoked_grant_ids: string[];
  reason: string;
}

export interface DeptGroup {
  id: string;
  slug: string;
  name: string;
  description: string | null;
  member_principal_ids: string[];
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface VaultPolicy {
  collection_id: string;
  security_tier: "standard" | "ferpa_restricted" | string;
  allowed_group_ids: string[];
  allowed_principal_ids: string[];
  allow_local_ai: boolean;
  updated_by?: string | null;
  updated_at?: string | null;
}

export interface CollectionSecuritySummary {
  collection_id: string;
  security_tier: "standard" | "ferpa_restricted" | string;
  allowed_group_ids: string[];
  allowed_principal_ids: string[];
  allow_local_ai: boolean;
}

export interface FerpaAuditEntry {
  id: string;
  at: string;
  action: string;
  collection_id: string;
  resource_kind: string;
  resource_id: string;
  principal_id: string;
  principal_handle: string;
  grant_id: string;
  reason: string;
}

export interface VaultPrincipalSummary {
  id: string;
  handle: string;
  display_name: string;
  email: string | null;
  role: WorkspaceRole | string;
  kind: PrincipalKind | string;
}

export interface VaultCollectionSummary {
  id: string;
  slug: string;
  name: string;
}

export interface VaultStatusResponse {
  groups: DeptGroup[];
  policies: VaultPolicy[];
  collections: VaultCollectionSummary[];
  principals: VaultPrincipalSummary[];
  recent_audit: FerpaAuditEntry[];
}
