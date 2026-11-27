## Unit tests for `BackupOps` encrypted AES-256-GCM S3 & local snapshot backups + verified restore drills.
module Tests.UnitBackup
use Arvo.S3
use BackupOps
use Db
use Domain.Types{Collection, CollectionWritePolicy}
use Http
use Modb.Export
use Modb.Ledger
use Modb.Table

test "BackupOps AES-256-GCM S3 & file backup/restore round-trip, tamper fail-closed, and Ledger.verify_all"
  files = Files.in_memory({})
  rng = SecureRandom.seeded(20261220)
  t0 = Time.parse("2026-11-27T18:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)

  env = Env.of({
    "VELLUM_SECRET_KEY": "1111111111111111111111111111111122222222222222222222222222222222",
    "VELLUM_S3_ENDPOINT": "http://127.0.0.1:9000",
    "VELLUM_S3_BUCKET": "vellum-uploads",
    "VELLUM_S3_REGION": "us-east-1",
    "VELLUM_S3_ACCESS_KEY_ID": "vellum",
    "VELLUM_S3_SECRET_ACCESS_KEY": "vellum-dev-secret-key",
    "VELLUM_S3_PATH_STYLE": "1"
  })

  # Seed a non-trivial vellum.modb with a Collection + accountable audit entry
  seed_col = Collection(
    id: "col_backup_test",
    workspace_id: Db.default_workspace_id,
    slug: "backup-vault",
    name: "Backup Vault Secret Title",
    description: "Confidential backup verification collection",
    icon: None,
    write_policy: DirectWithAudit,
    freshness_ttl_days: None,
    sort_order: "z",
    archived_at: None
  )
  meta = Ledger.WriteMeta(
    principal: "@ada",
    action: "collection.create",
    reason: "seed backup test",
    at: t0
  )
  assert Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "created backup test collection",
    seed_col.id.to_json,
    Db.map_ledger_error,
    fn(tx)
      t1 = try Db.tx_put_collection(tx, seed_col)
      Ok((t1, Unit))
    end
  ) is
    Ok(Unit)

  # 1. Local encrypted backup file does NOT leak plaintext, rejects wrong key / AAD / tamper
  local_bak = "local-backup.vellum.enc.json"
  loc_res = case BackupOps.backup_to_file(files, rng, clock, env, Db.ledger_db_path, local_bak)
    Ok(j): j
    Error(_): stop "backup_to_file failed"
  end
  assert loc_res.bool_at("ok") == Some(true)
  assert loc_res.text_at("target") == Some("file")

  raw_bak = case files.read_only.read_text(local_bak)
    Ok(s): s
    Error(_): stop "read backup failed"
  end
  assert not raw_bak.contains?("Backup Vault Secret Title")
  assert not raw_bak.contains?("col_backup_test")

  raw_bytes = case files.read_only.read_bytes(local_bak)
    Ok(b): b
    Error(_): stop "read backup bytes"
  end
  wrong_key = Bytes.from_hex("9999999999999999999999999999999988888888888888888888888888888888") or
    stop "wrong_key"
  assert BackupOps.open_backup_envelope(wrong_key, local_bak, raw_bytes) is Error(_)
  assert BackupOps.open_backup_envelope(
    case BackupOps.derive_backup_key(env)
      Ok(k): k
      Error(_): stop "derive_backup_key failed"
    end,
    "other-object-key.enc.json",
    raw_bytes
  ) is
    Error(_)

  tampered_txt = raw_bak.replace("\"alg\":\"aes-256-gcm\"", "\"alg\":\"none\"")
  assert BackupOps.open_backup_envelope(
    case BackupOps.derive_backup_key(env)
      Ok(k): k
      Error(_): stop "derive_backup_key2 failed"
    end,
    local_bak,
    tampered_txt.bytes
  ) is
    Error(_)

  # 2. Local restore + verify drill restores exact data and cleans drill file
  drill_res = case BackupOps.run_restore_drill_file(
    files,
    clock,
    env,
    local_bak,
    "drill-local.modb"
  )
    Ok(j): j
    Error(_): stop "run_restore_drill_file failed"
  end
  assert drill_res.bool_at("verified") == Some(true)
  assert drill_res.bool_at("drill_cleaned") == Some(true)
  assert (drill_res.int_at("audit_entries") or 0) >= 2
  assert not files.exists?("drill-local.modb")

  # 3. Encrypted S3 PUT upload & S3 GET restore via Arvo.S3 + Network.fake
  s3_cfg = case BackupOps.s3_config_from_env(env)
    Ok(c): c
    Error(_): stop "s3_config_from_env failed"
  end
  # Predictable object key via override so Network.fake matches exact SigV4 request & encrypted payload
  obj_key = "backups/vellum/fixed-tx.vellum.enc.json"
  bkey = case BackupOps.derive_backup_key(env)
    Ok(k): k
    Error(_): stop "derive_backup_key3 failed"
  end
  snap0 = case Export.export_locked(files.read_only, Db.ledger_db_path, Db.vellum_schema(), true, t0)
    Ok(s): s
    Error(_): stop "export_locked failed"
  end
  # Separate rng copy from same state for deterministic check isn't needed if we match PUT/GET directly:
  put_rng = SecureRandom.seeded(777)
  env_bytes = case BackupOps.seal_backup_envelope(
    bkey,
    SecureRandom.seeded(777),
    obj_key,
    snap0,
    t0
  )
    Ok(b): b
    Error(_): stop "seal_backup_envelope failed"
  end
  put_req = case S3.sign_request(
    s3_cfg,
    "PUT",
    obj_key,
    [],
    [("Content-Type", "application/octet-stream")],
    env_bytes,
    t0
  )
    Ok(r): r
    Error(_): stop "s3 put sign failed"
  end
  get_req = case S3.sign_request(s3_cfg, "GET", obj_key, [], [], "".bytes, t0)
    Ok(r): r
    Error(_): stop "s3 get sign failed"
  end
  s3_net = Network.fake(
    Http.replies([
      (put_req, Http.reply(200, "")),
      (get_req, Http.reply(200, env_bytes.decode_utf8 or stop "utf8"))
    ])
  )

  s3_bak = case BackupOps.backup_to_s3(
    files,
    put_rng,
    clock,
    env,
    s3_net,
    Db.ledger_db_path,
    Some(obj_key)
  )
    Ok(j): j
    Error(_): stop "backup_to_s3 failed"
  end
  assert s3_bak.bool_at("ok") == Some(true)
  assert s3_bak.text_at("object_key") == Some(obj_key)

  s3_rest = case BackupOps.restore_from_s3(
    files,
    clock,
    env,
    s3_net,
    obj_key,
    "restored-s3.modb"
  )
    Ok(j): j
    Error(_): stop "restore_from_s3 failed"
  end
  assert s3_rest.bool_at("verified") == Some(true)
  assert s3_rest.int_at("source_txid") == Some(snap0.source_txid)

  # Verify restored MoDB file contains exact collection and passes Ledger.verify_all
  restored_chk = Ledger.read_locked(
    files.read_only,
    "restored-s3.modb",
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      _rep = try Ledger.verify_all(db).map_error(Db.map_ledger_error)
      copt = try Table.get(Ledger.store(db), Db.collections_table(), "col_backup_test").map_error(
        Db.map_table_error
      )
      Ok(copt.map(fn(c) c.name end))
    end
  )
  assert restored_chk == Ok(Some("Backup Vault Secret Title"))
end
