## Unit tests for `ChatOps` (`chat-ops.mo`): pure helpers, channel ACLs, DM dedup,
## message windows, idempotency keys, read cursors, Calm Inbox, and ACL-filtered search.
module Tests.UnitChat
use ChatOps
use Db
use Domain.Policy
use Domain.Types{AuthContext, Principal, PrincipalKind, WorkspaceRole}
use Json
use Modb.Ledger

fn mk_auth(
  pid: Text,
  handle: Text,
  kind: PrincipalKind,
  role: WorkspaceRole,
  views: Option(List(Text)),
  actions: List(Text),
  now: Time
) : AuthContext
  p = Principal(
    id: pid,
    kind: kind,
    handle: handle,
    display_name: handle,
    email: None,
    avatar_url: None,
    role: role,
    model_id: None,
    root_grant_id: "gr_#{pid}",
    suspended: false,
    created_at: now,
    last_seen_at: None
  )
  AuthContext(
    principal: p,
    grant_id: "gr_#{pid}",
    session: None,
    allowed_collections: views,
    allowed_actions: actions
  )
end

fn mk_channel(
  id: Text,
  kind: Text,
  col_id: Option(Text),
  slug: Text,
  name: Text,
  members: List(Text),
  now: Time
) : Json
  Json.Object({
    "id": Json.String(id),
    "kind": Json.String(kind),
    "collection_id": col_id.to_json,
    "slug": Json.String(slug),
    "name": Json.String(name),
    "topic": Json.String(""),
    "member_principal_ids": Json.Array(members.map(fn(m) Json.String(m) end)),
    "archived_at": Json.Null,
    "created_by": Json.String("usr_ada"),
    "created_at": now.to_json,
    "updated_at": now.to_json,
    "last_message_at": Json.Null,
    "last_message_id": Json.Null
  })
end

fn mk_msg(
  id: Text,
  ch_id: Text,
  parent_id: Option(Text),
  author_id: Text,
  author_handle: Text,
  body: Text,
  is_decision: Bool,
  now: Time
) : Json
  Json.Object({
    "id": Json.String(id),
    "channel_id": Json.String(ch_id),
    "parent_message_id": parent_id.to_json,
    "author_id": Json.String(author_id),
    "author_handle": Json.String(author_handle),
    "author_display_name": Json.String(author_handle),
    "author_kind": Json.String("human"),
    "body_markdown": Json.String(body),
    "attachment_ids": Json.Array([]),
    "reactions": Json.Object({}),
    "linked_row_ids": Json.Array([]),
    "linked_proposal_ids": Json.Array([]),
    "is_decision": Json.Boolean(is_decision),
    "client_msg_id": Json.Null,
    "edited_at": Json.Null,
    "deleted_at": Json.Null,
    "created_at": now.to_json
  })
end

test "ChatOps helpers, ACL checks, and Modb channel/message/inbox/search operations"
  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"

  # 1. Pure string/mention/preview helpers
  assert ChatOps.slugify_channel("  Eng Architecture! ") == "eng-architecture"
  assert ChatOps.slugify_channel("Ops / Release-1") == "ops-release-1"
  assert ChatOps.normalize_handle("@Alice") == "alice"
  assert ChatOps.normalize_handle("  Bob_01 ") == "bob_01"

  mentions = ChatOps.extract_mentions("Ping @Alice and @bob_1, also @alice again.")
  assert mentions.contains?("alice")
  assert mentions.contains?("bob_1")
  assert mentions.size == 2

  long_body = "Header line\nThis is a summary message about quarterly planning."
  prev = ChatOps.msg_preview(long_body)
  assert prev.contains?("quarterly planning")

  # 2. Channel ACLs across public, private, DM, and scoped grants
  ada = mk_auth("usr_ada", "ada", Human, Owner, None, Policy.all_valid_actions(), t0)
  bob = mk_auth("usr_bob", "bob", Human, Member, None, ["read", "comment"], t0)
  carol = mk_auth(
    "usr_carol",
    "carol",
    Human,
    Member,
    Some(["collection:col_other"]),
    ["read", "comment"],
    t0
  )
  bot_ro = mk_auth("agt_bot", "bot", Agent, Bot, Some(["collection:col_std"]), ["read"], t0)

  ch_pub = mk_channel("ch_pub", "public", Some("col_std"), "eng-pub", "Eng Pub", [], t0)
  ch_priv = mk_channel(
    "ch_priv",
    "private",
    Some("col_std"),
    "sec-priv",
    "Sec Priv",
    ["usr_ada", "usr_bob"],
    t0
  )
  ch_dm = mk_channel(
    "ch_dm",
    "dm",
    None,
    "dm-ada-bob",
    "ada, bob",
    ["usr_ada", "usr_bob"],
    t0
  )

  assert ChatOps.can_access_channel?(ada, ch_pub, "read")
  assert ChatOps.can_access_channel?(bob, ch_pub, "read")
  assert not ChatOps.can_access_channel?(carol, ch_pub, "read")
  assert ChatOps.can_access_channel?(bot_ro, ch_pub, "read")
  assert not ChatOps.can_access_channel?(bot_ro, ch_pub, "comment")

  assert ChatOps.can_access_channel?(ada, ch_priv, "read")
  assert ChatOps.can_access_channel?(bob, ch_priv, "read")
  assert not ChatOps.can_access_channel?(carol, ch_priv, "read")
  assert not ChatOps.can_access_channel?(bot_ro, ch_priv, "read")

  assert ChatOps.can_access_channel?(ada, ch_dm, "read")
  assert ChatOps.can_access_channel?(bob, ch_dm, "read")
  assert not ChatOps.can_access_channel?(carol, ch_dm, "read")
  assert ChatOps.require_channel_access(carol, ch_dm, "read") is Error(_)

  # 3. Modb channel/DM/message/window/idempotency/unread/inbox/search operations
  files = Files.in_memory({})
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "chat.unit.seed",
    reason: "seed unit chat data",
    at: t0
  )
  seed_res = Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "seed chat",
    Json.Object({"seed": Json.Boolean(true)}),
    Db.map_ledger_error,
    fn(tx)
      t1 = try ChatOps.tx_put_channel(tx, "ch_pub", ch_pub)
      t2 = try ChatOps.tx_put_channel(t1, "ch_priv", ch_priv)
      t3 = try ChatOps.tx_put_channel(t2, "ch_dm", ch_dm)
      got_ch = try ChatOps.tx_get_channel(t3, "ch_pub")
      assert got_ch != None

      m1 = mk_msg("msg_01", "ch_pub", None, "usr_ada", "ada", "Kickoff hello world", false, t0)
      m2 = mk_msg(
        "msg_02",
        "ch_pub",
        None,
        "usr_bob",
        "bob",
        "Decision: ship launch checklist @ada",
        true,
        t0 + 1.seconds
      )
      m2b = mk_msg(
        "msg_02b",
        "ch_pub",
        None,
        "usr_ada",
        "ada",
        "Followup launch ping @bob",
        false,
        t0 + 2.seconds
      )
      m3 = mk_msg("msg_03", "ch_pub", Some("msg_01"), "usr_bob", "bob", "Thread reply here", false, t0 + 3.seconds)
      m4 = mk_msg("msg_04", "ch_priv", None, "usr_ada", "ada", "Private secret launch token", false, t0 + 4.seconds)
      t4 = try ChatOps.tx_put_message(t3, "ch_pub", "msg_01", m1)
      t5 = try ChatOps.tx_put_message(t4, "ch_pub", "msg_02", m2)
      t5b = try ChatOps.tx_put_message(t5, "ch_pub", "msg_02b", m2b)
      t6 = try ChatOps.tx_put_message(t5b, "ch_pub", "msg_03", m3)
      t7 = try ChatOps.tx_put_message(t6, "ch_priv", "msg_04", m4)
      assert (try ChatOps.tx_get_message(t7, "ch_pub", "msg_02")) != None

      t8 = try ChatOps.tx_put_idempotency(t7, "ch_pub", "usr_ada", "cli_1", "msg_01")
      assert (try ChatOps.tx_lookup_idempotency(t8, "ch_pub", "usr_ada", "cli_1")) == Some("msg_01")
      assert (try ChatOps.tx_lookup_idempotency(t8, "ch_pub", "usr_ada", "cli_missing")) == None

      t9 = try ChatOps.tx_put_read_cursor(
        t8,
        "usr_bob",
        "ch_pub",
        Json.Object({"last_read_message_id": Json.String("msg_01"), "updated_at": t0.to_json})
      )
      inbox1 = Json.Object({
        "id": Json.String("ntf_01"),
        "recipient_principal_id": Json.String("usr_ada"),
        "kind": Json.String("mention"),
        "channel_id": Json.String("ch_pub"),
        "message_id": Json.String("msg_02"),
        "parent_message_id": Json.Null,
        "actor_id": Json.String("usr_bob"),
        "actor_handle": Json.String("bob"),
        "preview": Json.String("Decision: ship launch checklist @ada"),
        "read_at": Json.Null,
        "created_at": t0.to_json
      })
      t10 = try ChatOps.tx_put_inbox(t9, "usr_ada", "ntf_01", inbox1)
      assert (try ChatOps.tx_scan_inbox(t10, "usr_ada", 10)).size == 1
      assert (try ChatOps.tx_scan_all_inbox(t10, 10)).size == 1
      assert (try ChatOps.tx_scan_all_messages(t10, 10)).size >= 5
      Ok((t10, Unit))
    end
  )
  assert seed_res is Ok(Unit)

  chk = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      assert (try ChatOps.get_channel(store, "ch_dm")) != None
      assert (try ChatOps.list_all_channels(store)).size == 3
      assert (try ChatOps.find_existing_dm(store, ["usr_bob", "usr_ada"])) != None
      assert (try ChatOps.find_existing_dm(store, ["usr_ada", "usr_bob", "usr_carol"])) == None

      assert (try ChatOps.get_message(store, "ch_pub", "msg_01")) != None
      assert (try ChatOps.scan_channel_raw_messages(store, "ch_pub")).size == 4
      assert (try ChatOps.scan_all_messages(store, 10)).size == 5

      (roots, roots_more, reply_counts) = try ChatOps.scan_channel_messages_window(
        store,
        "ch_pub",
        None,
        None,
        None,
        false,
        10
      )
      assert roots.size == 3
      assert not roots_more
      assert reply_counts.get("msg_01") == Some(1)

      (roots_p1, p1_more, _rc1) = try ChatOps.scan_channel_messages_window(
        store,
        "ch_pub",
        None,
        None,
        None,
        false,
        1
      )
      assert roots_p1.size == 1 and p1_more

      (dec_roots, _dm, _drc) = try ChatOps.scan_channel_messages_window(
        store,
        "ch_pub",
        None,
        None,
        None,
        true,
        10
      )
      assert dec_roots.size == 1

      (replies, _rm, _rrc) = try ChatOps.scan_channel_messages_window(
        store,
        "ch_pub",
        None,
        None,
        Some("msg_01"),
        false,
        10
      )
      assert replies.size == 1

      (paged_before, _bm, _brc) = try ChatOps.scan_channel_messages_window(
        store,
        "ch_pub",
        Some("msg_02"),
        None,
        None,
        false,
        10
      )
      assert paged_before.size == 1
      assert (paged_before.first or Json.Null).text_at("id") == Some("msg_01")

      assert (try ChatOps.get_read_cursor(store, "usr_bob", "ch_pub")) != None
      assert (try ChatOps.count_channel_unread(store, "usr_bob", "ch_pub")) == 1
      assert (try ChatOps.count_channel_unread(store, "usr_ada", "ch_pub")) == 1

      assert (try ChatOps.unread_inbox_count(store, "usr_ada")) == 1
      assert (try ChatOps.list_inbox(store, "usr_ada", true, 10)).size == 1

      # ACL-filtered search & decisions_only filter
      ada_hits = try ChatOps.search_visible_messages(store, ada, "launch", None, None, false, 20)
      assert ada_hits.size == 3
      ada_dec = try ChatOps.search_visible_messages(store, ada, "", None, None, true, 20)
      assert ada_dec.size == 1
      assert (ada_dec.first or Json.Null).text_at("message_id") == Some("msg_02")

      # Bot scoped only to col_std sees public launch msgs, NOT private channel msg
      bot_hits = try ChatOps.search_visible_messages(store, bot_ro, "launch", None, None, false, 20)
      assert bot_hits.size == 2

      # Carol with col_other sees zero hits in col_std
      carol_hits = try ChatOps.search_visible_messages(store, carol, "launch", None, None, false, 20)
      assert carol_hits.size == 0

      Ok(Unit)
    end
  )
  assert chk is Ok(Unit)
end
