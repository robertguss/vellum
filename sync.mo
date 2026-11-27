## Conflict-safe two-way local Markdown mirror CLI (`vellum sync`).
## Mirrors permitted collections to local `<dir>/<collection_slug>/*.md` as YAML frontmatter +
## `<!-- blk:... -->` anchored Markdown, routing divergent edits cleanly into `Modb.World`
## Change Proposals without ever clobbering local files or inserting `<<<<<<<` markers.
module Sync
expose SyncCliConfig(..),
SyncRunSummary(..),
run_sync_command,
main
use Domain.Blueprints
use Domain.Sync{SyncManifest, SyncManifestEntry, classify_file_sync, empty_manifest, sha256_text}
use Http
use Json

## Parsed CLI options for `vellum sync` / `pull` / `push` / `status`.
struct SyncCliConfig
  subcommand: Text
  root_dir: Text
  server_url: Text
  token: Text
  collections: Option(Text)
  reason: Option(Text)
end

## Telemetry summary returned by `run_sync_command`.
struct SyncRunSummary
  pulled: Int
  pushed: Int
  proposals_opened: Int
  conflicts_skipped: Int
  clean: Int
end

fn non_empty_opt(s: Text) : Option(Text)
  t = s.trim
  if t.empty?: None else: Some(t)
end

fn trim_trailing_slash(url: Text) : Text
  t = url.trim
  t.drop_suffix("/") or t
end

fn parse_cli_args(raw_args: List(Text), env: Env) : Result(SyncCliConfig, Text)
  args = case raw_args.first
    Some("--"): raw_args.drop(1)
    Some(_) | None: raw_args
  end

  def_url = env.get("VELLUM_SYNC_URL") or (env.get("VELLUM_URL") or "http://127.0.0.1:8080")
  def_tok = env.get("VELLUM_SYNC_TOKEN") or (env.get("VELLUM_TOKEN") or "")

  var subcmd = "sync"
  var sub_set = false
  var dir = "docs"
  var url = trim_trailing_slash(def_url)
  var tok = def_tok.trim
  var cols_opt = None
  var reason_opt = None

  var i = 0
  n = args.size
  while i < n
    arg = args.get(i) or ""
    if arg == "--dir" or arg == "-d"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--dir requires a relative folder path") if v.empty?
      dir = v.drop_suffix("/") or v
    else if arg == "--url" or arg == "-u"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--url requires a server URL") if v.empty?
      url = trim_trailing_slash(v)
    else if arg == "--token" or arg == "-t"
      i += 1
      v = (args.get(i) or "").trim
      return Error("--token requires a bearer token") if v.empty?
      tok = v
    else if arg == "--collection" or arg == "--collections" or arg == "-c"
      i += 1
      v = (args.get(i) or "").trim
      cols_opt = non_empty_opt(v)
    else if arg == "--reason" or arg == "-r"
      i += 1
      v = (args.get(i) or "").trim
      reason_opt = non_empty_opt(v)
    else if arg.starts_with?("-")
      return Error("unknown flag '#{arg}'")
    else if not sub_set
      subcmd = arg.trim.ascii_lowercase
      sub_set = true
    else
      return Error("unexpected argument '#{arg}'")
    end
    i += 1
  end

  if subcmd != "sync" and subcmd != "pull" and subcmd != "push" and subcmd != "status"
    return Error("unknown subcommand '#{subcmd}' (expected sync, pull, push, or status)")
  end
  if tok.empty?
    return Error("missing bearer token (--token or VELLUM_SYNC_TOKEN)")
  end

  Ok(
    SyncCliConfig(
      subcommand: subcmd,
      root_dir: dir,
      server_url: url,
      token: tok,
      collections: cols_opt,
      reason: reason_opt
    )
  )
end

fn load_manifest(files: Files, root_dir: Text, server_url: Text) : SyncManifest
  mpath = "#{root_dir}/.vellum-sync.json"
  if not files.exists?(mpath)
    return empty_manifest(server_url, [])
  end
  case files.read_text(mpath)
    Error(_): empty_manifest(server_url, [])
    Ok(raw):
      case Json.decode_strict[SyncManifest](raw.bytes)
        Ok(m): m
        Error(_): empty_manifest(server_url, [])
      end
  end
end

fn save_manifest(files: Files, root_dir: Text, manifest: SyncManifest) : Result(Unit, Text)
  try files.make_folder(root_dir).map_error(fn(e) e.to_text end)
  mpath = "#{root_dir}/.vellum-sync.json"
  pretty = Json.pretty(manifest.to_json)
  files.write_text(mpath, "#{pretty}\n").map_error(fn(e) e.to_text end)
end

fn scan_local_markdown_files(files: Files, root_dir: Text) : Map(Text, Text)
  var out = {}
  return out if not files.exists?(root_dir)
  top_entries = case files.list(root_dir)
    Ok(xs): xs
    Error(_): return out
  end
  for entry in top_entries
    continue if entry.starts_with?(".")
    if entry.ends_with?(".md")
      case files.read_text("#{root_dir}/#{entry}")
        Ok(txt): out = out.set(entry, txt)
        Error(_): Unit
      end
    else
      sub_path = "#{root_dir}/#{entry}"
      case files.list(sub_path)
        Ok(sub_entries):
          for fname in sub_entries
            if fname.ends_with?(".md") and not fname.starts_with?(".")
              rel = "#{entry}/#{fname}"
              case files.read_text("#{root_dir}/#{rel}")
                Ok(txt): out = out.set(rel, txt)
                Error(_): Unit
              end
            end
          end
        Error(_): Unit
      end
    end
  end
  out
end

fn write_mirror_file(files: Files, root_dir: Text, rel_path: Text, content: Text) : Result(
  Unit,
  Text
)
  parts = rel_path.split("/")
  if parts.size >= 2
    col_dir = parts.take(parts.size - 1).join("/")
    try files.make_folder("#{root_dir}/#{col_dir}").map_error(fn(e) e.to_text end)
  else
    try files.make_folder(root_dir).map_error(fn(e) e.to_text end)
  end
  files.write_text("#{root_dir}/#{rel_path}", content).map_error(fn(e) e.to_text end)
end

fn fetch_remote_snapshot(cfg: SyncCliConfig, net: Network) : Result(
  (List(Text), List(Json)),
  Text
)
  var req = Http.get("#{cfg.server_url}/api/sync/snapshot").header(
    "Authorization",
    "Bearer #{cfg.token}"
  ).header("Accept", "application/json")
  case cfg.collections
    Some(c) if not c.empty?: req = req.query("collections", c)
    Some(_) | None: Unit
  end
  res = try Http.send(req, net).map_error(fn(e) "snapshot HTTP failed: #{e.to_text}" end)
  if res.status < 200 or res.status >= 300
    return Error("GET /api/sync/snapshot returned HTTP #{res.status}: #{res.text}")
  end
  raw_txt = case res.body.decode_utf8
    Some(t): t
    None: return Error("snapshot response was not valid UTF-8")
  end
  body = case Json.parse(raw_txt)
    Ok(j): j
    Error(e): return Error(e.to_text)
  end
  cols_json = body.list_at("collections") or []
  col_slugs = cols_json.map(fn(c) c.text_at("slug") or "" end).filter(fn(s) not s.empty? end)
  pages_json = body.list_at("pages") or []
  Ok((col_slugs, pages_json))
end

fn post_sync_push(
  cfg: SyncCliConfig,
  rel_path: Text,
  page_id_opt: Option(Text),
  col_id_opt: Option(Text),
  expected_ver_opt: Option(Int),
  markdown_doc: Text,
  net: Network
) : Result((Int, Json), Text)
  payload = Json.Object({
    "page_id": case page_id_opt
      Some(p): Json.String(p)
      None: Json.Null
    end,
    "collection_id": case col_id_opt
      Some(c): Json.String(c)
      None: Json.Null
    end,
    "rel_path": Json.String(rel_path),
    "markdown_document": Json.String(markdown_doc),
    "expected_version": case expected_ver_opt
      Some(v): Json.int(v)
      None: Json.Null
    end,
    "reason": case cfg.reason
      Some(r): Json.String(r)
      None: Json.String("vellum sync")
    end
  })
  req = Http.post("#{cfg.server_url}/api/sync/push").json(payload).header(
    "Authorization",
    "Bearer #{cfg.token}"
  ).header("Accept", "application/json")
  res = try Http.send(req, net).map_error(fn(e) "push HTTP failed: #{e.to_text}" end)
  if res.status < 200 or res.status >= 300
    return Error("POST /api/sync/push returned HTTP #{res.status}: #{res.text}")
  end
  raw_push_txt = case res.body.decode_utf8
    Some(t): t
    None: return Error("push response was not valid UTF-8")
  end
  parsed = case Json.parse(raw_push_txt)
    Ok(j): j
    Error(e): return Error(e.to_text)
  end
  Ok((res.status, parsed))
end

fn run_sync_command(
  cfg: SyncCliConfig,
  files: Files,
  console: Console,
  clock: Clock,
  net: Network
) : Result(SyncRunSummary, Text)
  now_iso = clock.now.to_text
  manifest0 = load_manifest(files, cfg.root_dir, cfg.server_url)
  (remote_cols, remote_pages) = try fetch_remote_snapshot(cfg, net)
  local_files = scan_local_markdown_files(files, cfg.root_dir)

  # Map remote pages by canonical `rel_path` and also by `page_id`
  var remote_by_rel = {}
  var remote_by_pid = {}
  for rp in remote_pages
    rel = rp.text_at("rel_path") or ""
    pid = rp.text_at("page_id") or ""
    if not rel.empty?
      remote_by_rel = remote_by_rel.set(rel, rp)
    end
    if not pid.empty?
      remote_by_pid = remote_by_pid.set(pid, rp)
    end
  end

  # Map manifest entries by `rel_path`
  var man_by_rel = manifest0.files
  var seen_rels = Set.empty
  var all_rels = []
  for (rel, _rp) in remote_by_rel.entries
    if not seen_rels.has?(rel)
      seen_rels = seen_rels.add(rel)
      all_rels = all_rels.append(rel)
    end
  end
  for (rel, _txt) in local_files.entries
    if not seen_rels.has?(rel)
      seen_rels = seen_rels.add(rel)
      all_rels = all_rels.append(rel)
    end
  end
  all_rels = all_rels.sort

  var next_files = man_by_rel
  var pulled = 0
  var pushed = 0
  var proposals_opened = 0
  var conflicts_skipped = 0
  var clean = 0

  for rel in all_rels
    local_opt = local_files.get(rel)
    local_sha_opt = local_opt.map(sha256_text)

    # Resolve remote record matching `rel` directly or via frontmatter/manifest page_id
    fm_opt = case local_opt
      Some(txt):
        case Blueprints.parse_yaml_frontmatter(txt)
          Ok(f): Some(f)
          Error(_): None
        end
      None: None
    end
    man_entry_opt = man_by_rel.get(rel)
    pid_hint_opt = case fm_opt
      Some(f) if f.page_id != None: f.page_id
      Some(_) | None: man_entry_opt.map(fn(e) e.page_id end)
    end
    remote_opt = case remote_by_rel.get(rel)
      Some(rp): Some(rp)
      None:
        case pid_hint_opt
          Some(pid): remote_by_pid.get(pid)
          None: None
        end
    end

    remote_ver_opt = case remote_opt
      Some(r): r.int_at("version")
      None: None
    end
    remote_sha_opt = case remote_opt
      Some(r): r.text_at("content_sha256")
      None: None
    end
    action = classify_file_sync(man_entry_opt, local_sha_opt, remote_ver_opt, remote_sha_opt)

    if cfg.subcommand == "status"
      console.print("[#{action}] #{rel}")
      if action == "clean"
        clean += 1
      end
      continue
    end

    if action == "clean"
      clean += 1
      # Ensure manifest tracks unmodified matches too
      case (man_entry_opt, remote_opt)
        (None, Some(rp)):
          pid = rp.text_at("page_id") or ""
          cid = rp.text_at("collection_id") or ""
          cslug = rp.text_at("collection_slug") or ""
          rver = rp.int_at("version") or 1
          rsha = rp.text_at("content_sha256") or ""
          next_files = next_files.set(
            rel,
            SyncManifestEntry(
              page_id: pid,
              collection_id: cid,
              collection_slug: cslug,
              rel_path: rel,
              version: rver,
              content_sha256: rsha,
              synced_at: now_iso
            )
          )
        (_, _): Unit
      end
      continue
    end

    if (action == "pull_new" or action == "pull_update") and cfg.subcommand != "push"
      case remote_opt
        Some(rp):
          doc = rp.text_at("markdown_document") or ""
          pid = rp.text_at("page_id") or ""
          cid = rp.text_at("collection_id") or ""
          cslug = rp.text_at("collection_slug") or ""
          rver = rp.int_at("version") or 1
          rsha = rp.text_at("content_sha256") or sha256_text(doc)
          canonical_rel = rp.text_at("rel_path") or rel
          try write_mirror_file(files, cfg.root_dir, canonical_rel, doc)
          next_files = next_files.set(
            canonical_rel,
            SyncManifestEntry(
              page_id: pid,
              collection_id: cid,
              collection_slug: cslug,
              rel_path: canonical_rel,
              version: rver,
              content_sha256: rsha,
              synced_at: now_iso
            )
          )
          pulled += 1
          console.print("[PULL] #{canonical_rel} (v#{rver})")
        None: Unit
      end
      continue
    end

    if cfg.subcommand == "pull"
      # Never overwrite dirty local file or unresolved conflict on pull-only!
      conflicts_skipped += 1
      console.print("[SKIP CONFLICT ON PULL] #{rel} (run `sync` to open a Change Proposal)")
      continue
    end

    if action == "push_create" or action == "push_update" or action == "conflict_proposal"
      local_doc = local_opt or ""
      exp_ver = case man_entry_opt
        Some(e): Some(e.version)
        None:
          case fm_opt
            Some(f): f.version
            None: None
          end
      end
      col_id_hint = man_entry_opt.map(fn(e) e.collection_id end)
      (_st, push_j) = try post_sync_push(
        cfg,
        rel,
        pid_hint_opt,
        col_id_hint,
        exp_ver,
        local_doc,
        net
      )
      outcome = push_j.text_at("outcome") or ""
      if outcome == "applied" or outcome == "created" or outcome == "unchanged"
        canonical_rel = push_j.text_at("rel_path") or rel
        canonical_doc = push_j.text_at("markdown_document") or local_doc
        canonical_sha = push_j.text_at("content_sha256") or sha256_text(canonical_doc)
        pg_j = push_j.get("page") or Json.Null
        pid = pg_j.text_at("id") or (pid_hint_opt or "")
        cid = pg_j.text_at("collection_id") or (col_id_hint or "")
        pver = pg_j.int_at("version") or 1
        cslug = (canonical_rel.split("/").first or "")
        try write_mirror_file(files, cfg.root_dir, canonical_rel, canonical_doc)
        if canonical_rel != rel
          next_files = next_files.remove(rel)
        end
        next_files = next_files.set(
          canonical_rel,
          SyncManifestEntry(
            page_id: pid,
            collection_id: cid,
            collection_slug: cslug,
            rel_path: canonical_rel,
            version: pver,
            content_sha256: canonical_sha,
            synced_at: now_iso
          )
        )
        if outcome == "unchanged"
          clean += 1
        else
          pushed += 1
        end
        console.print("[PUSH #{outcome.ascii_uppercase}] #{canonical_rel} (v#{pver})")
      else if outcome == "proposal_opened"
        # Conflict-safe invariant: NEVER clobber the local file or inject <<<<<<< markers!
        proposals_opened += 1
        prop_id = push_j.text_at("proposal.id") or ""
        creason = push_j.text_at("conflict_reason") or "conflict"
        live_v = push_j.int_at("live_version") or 0
        console.print(
          "[CONFLICT -> PROPOSAL #{prop_id}] #{rel} (#{creason}, live v#{live_v}; local file preserved for Patchwork review at #{cfg.server_url}/proposals)"
        )
      end
    end
  end

  if cfg.subcommand != "status"
    try save_manifest(
      files,
      cfg.root_dir,
      SyncManifest(
        schema_version: 1,
        server_url: cfg.server_url,
        collections: remote_cols,
        files: next_files
      )
    )
  end

  Ok(
    SyncRunSummary(
      pulled: pulled,
      pushed: pushed,
      proposals_opened: proposals_opened,
      conflicts_skipped: conflicts_skipped,
      clean: clean
    )
  )
end

fn main(
  args: Args,
  console: Console,
  files: Files,
  clock: Clock,
  env: Env,
  net: Network
) : Int
  cfg = case parse_cli_args(args.list, env)
    Ok(c): c
    Error(msg):
      console.print("vellum sync error: #{msg}")
      return 2
  end
  case run_sync_command(cfg, files, console, clock, net)
    Ok(sum):
      console.print(
        "vellum sync complete: pulled=#{sum.pulled}, pushed=#{sum.pushed}, proposals=#{sum.proposals_opened}, skipped=#{sum.conflicts_skipped}, clean=#{sum.clean}"
      )
      0
    Error(msg):
      console.print("vellum sync failed: #{msg}")
      1
  end
end
