## Standalone Vellum Encrypted S3 / Local Backup & Restore Drill CLI (`mo run backup.mo`).
module Backup
expose main
use BackupOps
use Db

struct BackupCliArgs
  subcommand: Text
  db_path: Text
  object_key: Option(Text)
  in_path: Option(Text)
  out_path: Option(Text)
  tmp_path: Text
end

fn parse_cli(raw_args: List(Text)) : Result(BackupCliArgs, Text)
  args = case raw_args.first
    Some("--"): raw_args.drop(1)
    Some(_) | None: raw_args
  end
  var sub = ""
  var db_path = Db.ledger_db_path
  var key_opt = None
  var in_opt = None
  var out_opt = None
  var tmp_path = "vellum-restore-drill.modb"

  var i = 0
  while i < args.size
    a = args.get(i) or ""
    if a == "backup" or a == "restore" or a == "verify"
      sub = a
    else if a == "--db"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--db requires a path") if v.empty?
      db_path = v
    else if a == "--key"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--key requires an S3 object key") if v.empty?
      key_opt = Some(v)
    else if a == "--in"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--in requires a local file path") if v.empty?
      in_opt = Some(v)
    else if a == "--out"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--out requires a destination path") if v.empty?
      out_opt = Some(v)
    else if a == "--tmp"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--tmp requires a temporary path") if v.empty?
      tmp_path = v
    else
      return Error("unknown argument '#{a}'")
    end
    i += 1
  end

  if sub.empty?
    return Error("usage: backup | restore | verify [--db path] [--key s3_key | --in file] [--out path] [--tmp path]")
  end
  Ok(
    BackupCliArgs(
      subcommand: sub,
      db_path: db_path,
      object_key: key_opt,
      in_path: in_opt,
      out_path: out_opt,
      tmp_path: tmp_path
    )
  )
end

fn main(
  args: Args,
  console: Console,
  files: Files,
  clock: Clock,
  env: Env,
  rng: SecureRandom,
  net: Network
) : Int
  cfg = case parse_cli(args.list)
    Ok(c): c
    Error(msg):
      console.print("vellum backup error: #{msg}")
      return 2
  end

  res = if cfg.subcommand == "backup"
    case cfg.out_path
      Some(out_f): BackupOps.backup_to_file(files, rng, clock, env, cfg.db_path, out_f)
      None: BackupOps.backup_to_s3(files, rng, clock, env, net, cfg.db_path, cfg.object_key)
    end
  else if cfg.subcommand == "restore"
    dst = case cfg.out_path
      Some(d): d
      None:
        console.print("vellum backup error: restore requires --out <path>")
        return 2
    end
    case (cfg.in_path, cfg.object_key)
      (Some(inf), _): BackupOps.restore_from_file(files, clock, env, inf, dst)
      (None, Some(k)): BackupOps.restore_from_s3(files, clock, env, net, k, dst)
      (None, None): Error("restore requires --key <s3-key> or --in <local-file>")
    end
  else
    case (cfg.in_path, cfg.object_key)
      (Some(inf), _): BackupOps.run_restore_drill_file(files, clock, env, inf, cfg.tmp_path)
      (None, Some(k)): BackupOps.run_restore_drill_s3(files, clock, env, net, k, cfg.tmp_path)
      (None, None): Error("verify requires --key <s3-key> or --in <local-file>")
    end
  end

  case res
    Ok(j):
      console.print(j.to_text)
      0
    Error(msg):
      console.print("vellum backup failed: #{msg}")
      1
  end
end
