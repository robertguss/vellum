## Automated AES-256-GCM Encrypted S3 / Local Backup & Verified Restore Drill Engine (`Modb.Export` + `Arvo.S3`).
## Kept standalone from `Main` so Web/API binaries pay zero lowering overhead.
module BackupOps
expose derive_backup_key,
s3_config_from_env,
seal_backup_envelope,
open_backup_envelope,
backup_to_s3,
backup_to_file,
restore_from_s3,
restore_from_file,
run_restore_drill_s3,
run_restore_drill_file
use Arvo.S3
use Crypto
use Db
use Http
use Json
use Modb.Export
use Modb.Ledger

fn timestamp_slug(now: Time) : Text
  var chars = []
  for ch in Json.encode(now).chars
    if ch.ascii_letter? or ch.ascii_digit?
      chars = chars.append(ch)
    end
  end
  if chars.empty?: "0" else: Text.from_chars(chars)
end

fn non_empty_env(env: Env, key_name: Text) : Option(Text)
  case env.get(key_name)
    Some(v) if not v.trim.empty?: Some(v.trim)
    Some(_) | None: None
  end
end

## Resolves the 32-byte AES-256-GCM backup key from `VELLUM_BACKUP_KEY` (64 hex chars),
## or deterministically derives a domain-separated key from `VELLUM_SECRET_KEY`.
fn derive_backup_key(env: Env) : Result(Bytes, Text)
  case non_empty_env(env, "VELLUM_BACKUP_KEY")
    Some(hex_str):
      kb = try Bytes.from_hex(hex_str).or_fail("VELLUM_BACKUP_KEY must be valid hexadecimal")
      return Error("VELLUM_BACKUP_KEY must be 64 hex characters (32 bytes)") if kb.size != 32
      Ok(kb)
    None:
      sec_hex = try non_empty_env(env, "VELLUM_SECRET_KEY").or_fail(
        "missing VELLUM_BACKUP_KEY or VELLUM_SECRET_KEY env var"
      )
      sb = try Bytes.from_hex(sec_hex).or_fail("VELLUM_SECRET_KEY must be valid hexadecimal")
      return Error("VELLUM_SECRET_KEY must be 64 hex characters (32 bytes)") if sb.size != 32
      Ok(Crypto.sha256(Bytes.join(["vellum:backup:v1:".bytes, sb])))
  end
end

## Reads AWS/S3-compatible endpoint & credentials from `VELLUM_S3_*` env vars and validates them.
fn s3_config_from_env(env: Env) : Result(S3.S3Config, Text)
  endpoint = try non_empty_env(env, "VELLUM_S3_ENDPOINT").or_fail("missing VELLUM_S3_ENDPOINT env var")
  bucket = try non_empty_env(env, "VELLUM_S3_BUCKET").or_fail("missing VELLUM_S3_BUCKET env var")
  region = non_empty_env(env, "VELLUM_S3_REGION") or "us-east-1"
  access_key = try non_empty_env(env, "VELLUM_S3_ACCESS_KEY_ID").or_fail(
    "missing VELLUM_S3_ACCESS_KEY_ID env var"
  )
  secret_key = try non_empty_env(env, "VELLUM_S3_SECRET_ACCESS_KEY").or_fail(
    "missing VELLUM_S3_SECRET_ACCESS_KEY env var"
  )
  sess_tok = non_empty_env(env, "VELLUM_S3_SESSION_TOKEN")
  path_style? = (env.get("VELLUM_S3_PATH_STYLE") or "").trim != "0"
  cfg = S3.S3Config(
    endpoint: endpoint,
    region: region,
    bucket: bucket,
    access_key_id: access_key,
    secret_access_key: secret_key,
    session_token: sess_tok,
    path_style?: path_style?
  )
  _ = try S3.validate_config(cfg).map_error(fn(e) S3.to_text(e) end)
  Ok(cfg)
end

fn backup_prefix(env: Env) : Text
  raw = non_empty_env(env, "VELLUM_BACKUP_PREFIX") or "backups/vellum"
  p1 = raw.drop_suffix("/") or raw
  p2 = p1.drop_prefix("/") or p1
  if p2.empty?: "backups/vellum" else: p2
end

fn envelope_aad(object_key: Text) : Bytes
  "vellum:backup:v1:#{object_key}".bytes
end

## Verifies `snap` and encrypts its canonical JSON representation using AES-256-GCM bound to `object_key`.
fn seal_backup_envelope(
  key: Bytes,
  rng: SecureRandom,
  object_key: Text,
  snap: Export.PortableSnapshot,
  now: Time
) : Result(Bytes, Text)
  if key.size != 32
    return Error("backup key must be exactly 32 bytes")
  end
  _ = try Export.verify_snapshot(snap).map_error(fn(e) Export.to_text(e) end)
  pt = Export.encode_snapshot_json(snap).bytes
  nonce = rng.bytes(12)
  ct = try Crypto.seal(key, nonce, pt, envelope_aad(object_key)).map_error(fn(e) e.to_text end)
  env_json = Json.Object({
    "format_version": Json.int(1),
    "alg": Json.String("aes-256-gcm"),
    "object_key": Json.String(object_key),
    "source_txid": Json.int(snap.source_txid),
    "schema_version": Json.int(snap.schema_version),
    "bucket_count": Json.int(snap.bucket_count),
    "entry_count": Json.int(snap.entry_count),
    "snapshot_sha256": Json.String(snap.sha256),
    "created_at": now.to_json,
    "nonce_b64": Json.String(nonce.to_base64url),
    "ciphertext_b64": Json.String(ct.to_base64url)
  })
  Ok(env_json.to_text.bytes)
end

## Decrypts and verifies an encrypted backup envelope, failing closed on wrong key, AAD mismatch,
## or snapshot checksum corruption.
fn open_backup_envelope(
  key: Bytes,
  object_key: Text,
  raw: Bytes
) : Result(Export.PortableSnapshot, Text)
  if key.size != 32
    return Error("backup key must be exactly 32 bytes")
  end
  txt = try raw.decode_utf8.or_fail("backup envelope is not valid UTF-8")
  j = try Json.parse(txt).map_error(fn(e) "invalid backup envelope JSON: #{e}" end)
  if j.int_at("format_version") != Some(1)
    return Error("unsupported backup envelope format_version")
  end
  if j.text_at("alg") != Some("aes-256-gcm")
    return Error("unsupported backup encryption algorithm")
  end
  if j.text_at("object_key") != Some(object_key)
    return Error("backup envelope object_key mismatch")
  end
  nonce_b64 = try j.text_at("nonce_b64").or_fail("backup envelope missing nonce_b64")
  ct_b64 = try j.text_at("ciphertext_b64").or_fail("backup envelope missing ciphertext_b64")
  nonce = try Bytes.from_base64url(nonce_b64).or_fail("invalid nonce_b64 in backup envelope")
  ct = try Bytes.from_base64url(ct_b64).or_fail("invalid ciphertext_b64 in backup envelope")
  if nonce.size != 12
    return Error("invalid backup AES-GCM nonce length")
  end
  pt = try Crypto.open(key, nonce, ct, envelope_aad(object_key)).map_error(fn(e)
    "backup decryption failed: #{e.to_text}"
  end)
  snap = try Json.decode_strict[Export.PortableSnapshot](pt).map_error(fn(e)
    "invalid decrypted PortableSnapshot: #{e.to_text}"
  end)
  if j.text_at("snapshot_sha256") != Some(snap.sha256)
    return Error("backup envelope snapshot_sha256 disagrees with decrypted snapshot")
  end
  _ = try Export.verify_snapshot(snap).map_error(fn(e) Export.to_text(e) end)
  Ok(snap)
end

fn build_object_key(env: Env, snap: Export.PortableSnapshot, key_override: Option(Text), now: Time) : Result(
  Text,
  Text
)
  raw_key = case key_override
    Some(k) if not k.trim.empty?: k.trim
    Some(_) | None: "#{backup_prefix(env)}/#{timestamp_slug(now)}-tx#{snap.source_txid}.vellum.enc.json"
  end
  S3.sanitize_object_key(raw_key).map_error(fn(e) S3.to_text(e) end)
end

## Takes a lock-coordinated `Modb.Export` snapshot of `src_path`, encrypts it with AES-256-GCM,
## and uploads it to S3 via AWS SigV4.
fn backup_to_s3(
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network,
  src_path: Text,
  key_override: Option(Text)
) : Result(Json, Text)
  now = clock.now
  bkey = try derive_backup_key(env)
  s3_cfg = try s3_config_from_env(env)
  snap = try Export.export_locked(files.read_only, src_path, Db.vellum_schema(), true, now)
    .map_error(fn(e) Export.to_text(e) end)
  obj_key = try build_object_key(env, snap, key_override, now)
  env_bytes = try seal_backup_envelope(bkey, rng, obj_key, snap, now)
  req = try S3.sign_request(
    s3_cfg,
    "PUT",
    obj_key,
    [],
    [("Content-Type", "application/octet-stream")],
    env_bytes,
    now
  ).map_error(fn(e) S3.to_text(e) end)
  resp = try Http.send(req, net).map_error(fn(e) "S3 backup upload failed: #{e.to_text}" end)
  if resp.status < 200 or resp.status >= 300
    return Error("S3 backup PUT failed with HTTP #{resp.status}: #{resp.text or ""}")
  end
  Ok(
    Json.Object({
      "ok": Json.Boolean(true),
      "target": Json.String("s3"),
      "bucket": Json.String(s3_cfg.bucket),
      "object_key": Json.String(obj_key),
      "bytes_uploaded": Json.int(env_bytes.size),
      "source_txid": Json.int(snap.source_txid),
      "schema_version": Json.int(snap.schema_version),
      "bucket_count": Json.int(snap.bucket_count),
      "entry_count": Json.int(snap.entry_count),
      "snapshot_sha256": Json.String(snap.sha256),
      "created_at": now.to_json
    })
  )
end

## Takes a lock-coordinated `Modb.Export` snapshot of `src_path`, encrypts it with AES-256-GCM,
## and writes it atomically to a local file `out_path`.
fn backup_to_file(
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  src_path: Text,
  out_path: Text
) : Result(Json, Text)
  now = clock.now
  bkey = try derive_backup_key(env)
  snap = try Export.export_locked(files.read_only, src_path, Db.vellum_schema(), true, now)
    .map_error(fn(e) Export.to_text(e) end)
  clean_label = out_path.trim
  return Error("out_path must not be empty") if clean_label.empty?
  env_bytes = try seal_backup_envelope(bkey, rng, clean_label, snap, now)
  try files.write_bytes(clean_label, env_bytes).map_error(fn(e) e.to_text end)
  Ok(
    Json.Object({
      "ok": Json.Boolean(true),
      "target": Json.String("file"),
      "path": Json.String(clean_label),
      "object_key": Json.String(clean_label),
      "bytes_written": Json.int(env_bytes.size),
      "source_txid": Json.int(snap.source_txid),
      "schema_version": Json.int(snap.schema_version),
      "bucket_count": Json.int(snap.bucket_count),
      "entry_count": Json.int(snap.entry_count),
      "snapshot_sha256": Json.String(snap.sha256),
      "created_at": now.to_json
    })
  )
end

fn restore_verified_snapshot(
  files: Files,
  clock: Clock,
  snap: Export.PortableSnapshot,
  object_key: Text,
  dst_path: Text
) : Result(Json, Text)
  now = clock.now
  db = try Export.import_db(files, dst_path, Db.vellum_schema(), snap, now).map_error(fn(e)
    Export.to_text(e)
  end)
  rep = try Ledger.verify_all(db).map_error(fn(e) Db.map_ledger_error(e).to_text end)
  Ok(
    Json.Object({
      "verified": Json.Boolean(true),
      "object_key": Json.String(object_key),
      "restored_path": Json.String(dst_path),
      "source_txid": Json.int(snap.source_txid),
      "schema_version": Json.int(snap.schema_version),
      "entry_count": Json.int(snap.entry_count),
      "audit_entries": Json.int(rep.audit.entry_count),
      "invariants_checked": Json.int(rep.invariants_checked),
      "audit_last_hash": Json.String(rep.audit.last_hash),
      "snapshot_sha256": Json.String(snap.sha256)
    })
  )
end

## Downloads an encrypted backup from S3, decrypts/verifies it, restores into `dst_path`,
## and runs full `Modb.verify` + `Modb.Ledger.verify_all`.
fn restore_from_s3(
  files: Files,
  clock: Clock,
  env: Env,
  net: Network,
  object_key: Text,
  dst_path: Text
) : Result(Json, Text)
  now = clock.now
  bkey = try derive_backup_key(env)
  s3_cfg = try s3_config_from_env(env)
  clean_key = try S3.sanitize_object_key(object_key.trim).map_error(fn(e) S3.to_text(e) end)
  req = try S3.sign_request(s3_cfg, "GET", clean_key, [], [], "".bytes, now).map_error(fn(e)
    S3.to_text(e)
  end)
  resp = try Http.send(req, net).map_error(fn(e) "S3 backup GET failed: #{e.to_text}" end)
  if resp.status < 200 or resp.status >= 300
    return Error("S3 backup GET failed with HTTP #{resp.status}: #{resp.text or ""}")
  end
  snap = try open_backup_envelope(bkey, clean_key, resp.body)
  restore_verified_snapshot(files, clock, snap, clean_key, dst_path)
end

## Decrypts a local encrypted backup file `in_path`, restores into `dst_path`, and verifies integrity.
fn restore_from_file(
  files: Files,
  clock: Clock,
  env: Env,
  in_path: Text,
  dst_path: Text
) : Result(Json, Text)
  bkey = try derive_backup_key(env)
  clean_in = in_path.trim
  raw = try files.read_only.read_bytes(clean_in).map_error(fn(e) e.to_text end)
  snap = try open_backup_envelope(bkey, clean_in, raw)
  restore_verified_snapshot(files, clock, snap, clean_in, dst_path)
end

## Runs a non-destructive S3 restore verification drill into `drill_path` and cleans up the temp file.
fn run_restore_drill_s3(
  files: Files,
  clock: Clock,
  env: Env,
  net: Network,
  object_key: Text,
  drill_path: Text
) : Result(Json, Text)
  _rm0 = files.remove(drill_path)
  res = try restore_from_s3(files, clock, env, net, object_key, drill_path)
  rm_ok? = files.remove(drill_path) is Ok(_)
  Ok(with_drill_cleaned(res, rm_ok?))
end

fn with_drill_cleaned(j: Json, cleaned?: Bool) : Json
  case j
    Json.Object(m): Json.Object(m.set("drill_cleaned", Json.Boolean(cleaned?)))
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): j
  end
end

## Runs a non-destructive local file restore verification drill into `drill_path` and cleans up.
fn run_restore_drill_file(
  files: Files,
  clock: Clock,
  env: Env,
  in_path: Text,
  drill_path: Text
) : Result(Json, Text)
  _rm0 = files.remove(drill_path)
  res = try restore_from_file(files, clock, env, in_path, drill_path)
  rm_ok? = files.remove(drill_path) is Ok(_)
  Ok(with_drill_cleaned(res, rm_ok?))
end
