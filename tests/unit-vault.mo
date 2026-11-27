## Unit tests for `VaultOps` (`vault-ops.mo`) & `Domain.Policy` FERPA Vault / Department Group enforcement.
module Tests.UnitVault
use Db
use Domain.Policy
use Domain.Types{AuthContext, Principal, PrincipalKind, WorkspaceRole}
use Json
use Modb.Ledger
use VaultOps

fn mk_auth(pid: Text, handle: Text, kind: PrincipalKind, role: WorkspaceRole, views: Option(List(Text)), now: Time) : AuthContext
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
    allowed_actions: ["workspace:*"]
  )
end

test "VaultOps local-AI URL guard, Department Group allowlists, zero-exfiltration AI lock & Modb.Ledger FERPA audit"
  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  env_def = Env.of({})
  env_loc = Env.of({"VELLUM_AI_LOCAL_ONLY": "1"})

  # 1. Local/campus AI endpoint checks
  assert VaultOps.is_local_ai_url?("http://127.0.0.1:11434/v1/chat/completions", env_def)
  assert VaultOps.is_local_ai_url?("https://localhost:8443/v1", env_def)
  assert VaultOps.is_local_ai_url?("http://[::1]:8000/v1", env_def)
  assert not VaultOps.is_local_ai_url?("https://api.openai.com/v1/chat/completions", env_def)
  assert VaultOps.is_local_ai_url?("https://campus-gateway.internal/v1", env_loc)

  # 2. Seed Department Group + FERPA Restricted Vault policies in MoDB
  files = Files.in_memory({})
  rng = SecureRandom.seeded(20261127)
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "vault.seed",
    reason: "seed unit test vault policies",
    at: t0
  )
  seed_res = Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "seed groups and policies",
    Json.Object({"seed": Json.Boolean(true)}),
    Db.map_ledger_error,
    fn(tx)
      grp = Json.Object({
        "id": Json.String("grp_reg"),
        "slug": Json.String("registrar"),
        "name": Json.String("Registrar"),
        "description": Json.Null,
        "member_principal_ids": Json.Array([Json.String("usr_ada")]),
        "created_by": Json.String("usr_ada"),
        "created_at": t0.to_json,
        "updated_at": t0.to_json
      })
      pol_grp = Json.Object({
        "collection_id": Json.String("col_ferpa_grp"),
        "security_tier": Json.String("ferpa_restricted"),
        "allowed_group_ids": Json.Array([Json.String("grp_reg")]),
        "allowed_principal_ids": Json.Array([]),
        "allow_local_ai": Json.Boolean(false),
        "updated_by": Json.String("usr_ada"),
        "updated_at": t0.to_json
      })
      pol_direct_loc = Json.Object({
        "collection_id": Json.String("col_ferpa_loc"),
        "security_tier": Json.String("ferpa_restricted"),
        "allowed_group_ids": Json.Array([]),
        "allowed_principal_ids": Json.Array([Json.String("usr_bob")]),
        "allow_local_ai": Json.Boolean(true),
        "updated_by": Json.String("usr_ada"),
        "updated_at": t0.to_json
      })
      t1 = try VaultOps.tx_put_json(tx, VaultOps.dept_groups_bucket, "grp_reg", grp)
      t2 = try VaultOps.tx_put_json(t1, VaultOps.vault_policies_bucket, "col_ferpa_grp", pol_grp)
      t3 = try VaultOps.tx_put_json(
        t2,
        VaultOps.vault_policies_bucket,
        "col_ferpa_loc",
        pol_direct_loc
      )
      Ok((t3, Unit))
    end
  )
  assert seed_res is Ok(Unit)

  # 3. Verify apply_vault_restrictions + Domain.Policy.collection_permitted?
  chk = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      assert (try VaultOps.is_ferpa_restricted(store, "col_ferpa_grp")) == true
      assert (try VaultOps.is_ferpa_restricted(store, "col_std")) == false

      # AI locks
      assert (try VaultOps.ai_allowed_for_collection(
        store,
        "col_std",
        "https://api.openai.com/v1/chat/completions",
        false
      )) == true
      assert (try VaultOps.ai_allowed_for_collection(
        store,
        "col_ferpa_grp",
        "https://api.openai.com/v1/chat/completions",
        false
      )) == false
      assert (try VaultOps.ai_allowed_for_collection(
        store,
        "col_ferpa_grp",
        "http://127.0.0.1:11434/v1/chat/completions",
        false
      )) == false
      assert (try VaultOps.ai_allowed_for_collection(
        store,
        "col_ferpa_loc",
        "https://api.openai.com/v1/chat/completions",
        false
      )) == false
      assert (try VaultOps.ai_allowed_for_collection(
        store,
        "col_ferpa_loc",
        "http://127.0.0.1:11434/v1/chat/completions",
        false
      )) == true
      assert VaultOps.require_ai_allowed_for_collection(
        store,
        "col_ferpa_loc",
        "https://api.openai.com/v1/chat/completions",
        false
      ) is Error(_)

      ada_views = try VaultOps.apply_vault_restrictions(store, "usr_ada", None)
      bob_views = try VaultOps.apply_vault_restrictions(store, "usr_bob", Some(["workspace:*"]))
      bot_views = try VaultOps.apply_vault_restrictions(store, "agt_bot", None)

      ada = mk_auth("usr_ada", "ada", Human, Owner, ada_views, t0)
      bob = mk_auth("usr_bob", "bob", Human, Member, bob_views, t0)
      bot = mk_auth("agt_bot", "bot", Agent, Bot, bot_views, t0)

      # Ada (Registrar member) reads col_ferpa_grp & col_std, denied col_ferpa_loc
      assert Policy.collection_permitted?(ada, "col_std")
      assert Policy.collection_permitted?(ada, "col_ferpa_grp")
      assert not Policy.collection_permitted?(ada, "col_ferpa_loc")

      # Bob (direct principal on col_ferpa_loc) reads col_ferpa_loc & col_std, denied col_ferpa_grp
      assert Policy.collection_permitted?(bob, "col_std")
      assert Policy.collection_permitted?(bob, "col_ferpa_loc")
      assert not Policy.collection_permitted?(bob, "col_ferpa_grp")

      # Agent with workspace:* denied both restricted vaults
      assert Policy.collection_permitted?(bot, "col_std")
      assert not Policy.collection_permitted?(bot, "col_ferpa_grp")
      assert not Policy.collection_permitted?(bot, "col_ferpa_loc")

      Ok(Unit)
    end
  )
  assert chk is Ok(Unit)

  # 4. Verify FERPA read/export audit recording + filtering + Ledger integrity
  ada_auth = mk_auth("usr_ada", "ada", Human, Owner, None, t0)
  bob_auth = mk_auth("usr_bob", "bob", Human, Member, None, t0)
  assert VaultOps.record_ferpa_read_audit_locked(
    files,
    rng,
    Clock.fixed(t0),
    ada_auth,
    "ferpa.page.viewed",
    "col_ferpa_grp",
    "page",
    "pg_1",
    "unit view"
  ) is Ok(Unit)
  assert VaultOps.record_ferpa_read_audit_locked(
    files,
    rng,
    Clock.fixed(t0),
    bob_auth,
    "ferpa.db_row.viewed",
    "col_ferpa_loc",
    "database",
    "db_1",
    "unit db query"
  ) is Ok(Unit)

  audit_chk = Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      _rep = try Ledger.verify_all(db).map_error(Db.map_ledger_error)
      all_ev = try VaultOps.list_ferpa_audit_json(Ledger.store(db), None, None, None, 50)
      assert all_ev.size == 2
      grp_ev = try VaultOps.list_ferpa_audit_json(
        Ledger.store(db),
        Some("col_ferpa_grp"),
        Some("ada"),
        Some("ferpa.page.viewed"),
        50
      )
      assert grp_ev.size == 1
      assert (grp_ev.first or Json.Null).text_at("resource_id") == Some("pg_1")
      Ok(Unit)
    end
  )
  assert audit_chk is Ok(Unit)
end
