## Vellum — AI-Native Collaborative Knowledge Base built with Mo, 100% Pure MoDB, and Arvo.
module Main
use Domain.Types{AuthContext}
use Routes.Ai
use Routes.Auth
use Routes.Chat
use Routes.ChatMoat
use Routes.Collab
use Routes.Databases
use Routes.Importer
use Routes.Mcp
use Routes.Packs
use Routes.Sync
use Routes.Vault
use Routes.Workspace

api
  port 8080
  static "/assets" from "public/assets"
  auth AuthContext via Auth.authenticate

  get "/login" Auth.show_login
  get "/auth/oidc/login" Auth.start_oidc_login
  get "/auth/oidc/callback" Auth.oidc_callback
  get "/auth/solo/login" Auth.solo_login
  post "/auth/solo/login" Auth.solo_login
  post "/auth/personal/login" Auth.personal_login
  post "/logout" Auth.post_logout

  get "/" Workspace.home
  get "/c/:slug" Workspace.show_collection
  get "/p/:id" Workspace.show_page
  get "/d/:id" Databases.show_database
  get "/proposals" Workspace.proposals_page
  get "/packs" Packs.packs_page
  get "/llms.txt" Packs.llms_txt
  get "/admin" Workspace.admin_page
  get "/chat" Chat.chat_page
  post "/mcp" Mcp.handle_mcp
  post "/api/webhooks/github" Collab.github_pr_webhook

  scope "/api"
    get "/collections/:slug" Workspace.show_collection
    post "/collections" Workspace.create_collection
    get "/pages/:id" Workspace.show_page
    get "/pages/:id/backlinks" Workspace.page_backlinks
    get "/pages/:id/history" Collab.page_replay_history
    get "/pages/:id/time-travel" Collab.page_time_travel
    post "/pages" Workspace.create_page
    patch "/pages/:id" Workspace.update_page
    patch "/pages/:id/blocks" Workspace.patch_blocks
    post "/pages/:id/verify" Workspace.verify_page
    post "/pages/:id/comments" Workspace.create_comment
    get "/search" Workspace.search
    post "/attachments/presign" Workspace.presign_attachment
    put "/attachments/:id/upload" Workspace.upload_local_attachment
    post "/attachments/:id/commit" Workspace.commit_attachment
    get "/attachments/:id/download" Workspace.download_attachment
    post "/admin/agents" Workspace.mint_agent_token
    get "/admin/grants/tree" Workspace.grants_tree
    post "/admin/grants/kill-all" Workspace.kill_all_agent_grants
    post "/admin/grants/:id/revoke" Workspace.revoke_grant
    get "/audit" Workspace.audit_index
    get "/admin/vault/status" Vault.vault_status
    get "/admin/groups" Vault.list_groups
    post "/admin/groups" Vault.create_group
    patch "/admin/groups/:id" Vault.update_group
    delete "/admin/groups/:id" Vault.delete_group
    patch "/collections/:id/security" Vault.update_collection_security
    get "/admin/ferpa/audit" Vault.ferpa_audit_index

    get "/databases" Databases.list_databases
    post "/databases" Databases.create_database
    get "/databases/:id" Databases.show_database
    patch "/databases/:id" Databases.update_database_schema
    post "/databases/:id/views" Databases.create_view
    patch "/databases/:id/views/:view_id" Databases.update_view
    delete "/databases/:id/views/:view_id" Databases.delete_view
    post "/databases/:id/query" Databases.query_database
    post "/databases/:id/scenarios" Collab.open_db_scenario
    post "/databases/:id/scenarios/:proposal_id/query" Collab.query_db_scenario
    post "/databases/:id/rows" Databases.create_row
    patch "/databases/:id/rows/:row_id" Databases.update_row
    delete "/databases/:id/rows/:row_id" Databases.delete_row
    get "/databases/:id/ai-columns/status" Ai.ai_columns_status
    post "/databases/:id/ai-columns/sync-feed" Ai.sync_ai_column_feed
    post "/databases/:id/ai-columns/:prop_id/run" Ai.run_ai_column

    get "/events" Collab.events_stream
    get "/claims" Collab.list_claims
    post "/claims" Collab.acquire_claim
    post "/claims/heartbeat" Collab.heartbeat_claim
    post "/claims/release" Collab.release_claim
    get "/proposals" Collab.list_proposals
    post "/proposals" Collab.open_proposal
    post "/proposals/:id/ops" Collab.stage_proposal_ops
    post "/proposals/:id/mutations" Collab.stage_proposal_mutation
    get "/proposals/:id/diff" Collab.diff_proposal
    post "/proposals/:id/accept" Collab.accept_proposal
    post "/proposals/:id/reject" Collab.reject_proposal
    get "/proposals/:id/comments" Collab.list_proposal_comments
    post "/proposals/:id/comments" Collab.create_proposal_comment
    post "/proposals/:id/comments/:comment_id/resolve" Collab.resolve_proposal_comment
    post "/proposals/:id/hunks/reject" Collab.reject_proposal_hunk
    post "/proposals/:id/steer" Ai.steer_proposal
    post "/admin/replay/baseline" Collab.pin_replay_baseline
    get "/admin/replay/status" Collab.replay_status
    post "/admin/replay/simulate" Collab.simulate_replay
    post "/admin/replay/:id/accept" Collab.accept_replay
    post "/admin/replay/:id/discard" Collab.discard_replay
    get "/admin/taint/status" Collab.taint_status
    post "/admin/taint/sessions/:id/clear" Collab.clear_taint_session
    get "/admin/erasure/status" Workspace.erasure_status
    post "/admin/erasure/purge" Workspace.purge_secret
    get "/admin/erasure/receipts/:id/download" Workspace.download_erasure_receipt
    post "/grants/delegate" Collab.delegate_grant
    get "/webhooks" Collab.list_webhooks
    post "/webhooks" Collab.create_webhook

    get "/blueprints" Workspace.list_blueprints
    post "/blueprints" Workspace.create_blueprint
    put "/blueprints/:id" Workspace.update_blueprint
    put "/pages/:id/meta" Workspace.set_page_blueprint_meta
    put "/pages/:id/markdown" Workspace.sync_page_markdown
    post "/metrics/resolve" Workspace.resolve_metrics
    get "/blocks/:block_id" Workspace.show_block_context
    get "/summaries" Packs.list_summaries
    get "/packs" Packs.list_packs
    post "/packs" Packs.create_pack
    put "/packs/:id" Packs.update_pack
    delete "/packs/:id" Packs.delete_pack
    get "/packs/:slug" Packs.compile_pack_json
    get "/packs/:slug/markdown" Packs.compile_pack_markdown
    get "/sync/snapshot" Sync.sync_snapshot
    post "/sync/push" Sync.sync_push
    post "/import/notion" Importer.import_notion
    post "/ai/ask" Ai.ask_workspace
    post "/ai/deep-research" Ai.deep_research
    post "/ai/draft" Ai.draft_blocks
    post "/ai/brief/refresh" Ai.refresh_ai_brief
    get "/admin/garden" Ai.run_garden
    post "/admin/garden/propose" Ai.propose_garden_fix
  end

  scope "/api/v1"
    get "/events" Collab.events_stream
    get "/chat/channels" Chat.list_channels
    post "/chat/channels" Chat.create_channel
    patch "/chat/channels/:id" Chat.update_channel
    get "/chat/channels/:id/messages" Chat.list_messages
    post "/chat/channels/:id/messages" Chat.post_message
    patch "/chat/channels/:id/messages/:msg_id" Chat.edit_message
    delete "/chat/channels/:id/messages/:msg_id" Chat.delete_message
    post "/chat/channels/:id/messages/:msg_id/reactions" Chat.toggle_reaction
    post "/chat/channels/:id/read" Chat.mark_channel_read
    get "/chat/inbox" Chat.list_inbox
    post "/chat/inbox/ack" Chat.ack_inbox
    get "/chat/search" Chat.search_chat
    post "/chat/channels/:id/messages/:msg_id/create-task" ChatMoat.create_task_from_message
    post "/chat/channels/:id/messages/:msg_id/draft-proposal" ChatMoat.draft_proposal_from_message
    get "/chat/entities" ChatMoat.list_linkable_entities
    post "/chat/import/slack" ChatMoat.import_slack_batch
  end

  job "arvo.jobs.drain" Workspace.drain_jobs every 10.seconds
  job "vellum.garden" Ai.garden_job every 1.hour

  status Unauthenticated = 401
  status Forbidden(_) = 403
  status Missing(_) = 404
  status Conflict(_) = 409
  status BadInput(_) = 422
  status ServerFailed(_) = 500
end
