## Vellum `Modb.Erasure` orchestration: workspace/page secret hints, crypto-shredding,
## live record redaction/deletion, audit/replay scrubbing, FTS/Vec cleanup & compaction.
module ErasureOps
expose map_erasure_error,
erasure_receipt_to_json,
scan_page_secret_hints,
scan_workspace_secrets,
list_erasure_receipts_json,
get_erasure_receipt_json,
execute_secret_purge_locked
use Crypto
use Db
use Domain.Blocks
use Domain.Secrets
use Domain.Types{AppError, Block, Comment, Page, PageKind, Provenance}
use Json
use Modb{Store}
use Modb.Erasure
use Modb.Ledger
use Modb.Table

## Converts `Modb.Erasure` errors into Vellum's typed `AppError` (fail-closed HTTP status codes).
fn map_erasure_error(err: Erasure.ErasureError) : AppError
  case err
    Erasure.LedgerFailure(e): Db.map_ledger_error(e)
    Erasure.ExportFailure(_): ServerFailed(reason: Erasure.to_text(err))
    Erasure.FtsFailure(e): Db.map_fts_error(e)
    Erasure.VecFailure(e): Db.map_vec_error(e)
    Erasure.InvalidRequest(reason: _) | Erasure.KeyNotFound(subject_id: _) | Erasure
      .ReceiptAlreadyExists(id: _): BadInput(reason: Erasure.to_text(err))
    Erasure.ReceiptNotFound(id: rid): Missing(entity: "erasure_receipt", id: rid)
    Erasure.ErasureDenied(reason: _) | Erasure.KeyShredded(subject_id: _): Forbidden(
      reason: Erasure.to_text(err)
    )
    Erasure.CryptoFailure(detail: _): ServerFailed(reason: Erasure.to_text(err))
  end
end

## Serializes a verifiable `Modb.Erasure.ErasureReceipt` (zero raw PII/secrets).
fn erasure_receipt_to_json(r: Erasure.ErasureReceipt) : Json
  Json.Object({
    "id": Json.String(r.id),
    "subject_id_sha256": Json.String(r.subject_id_sha256),
    "erased_by": Json.String(r.erased_by),
    "reason": Json.String(r.reason),
    "at": r.at.to_json,
    "key_shredded": Json.Boolean(r.key_shredded?),
    "rows_deleted": Json.int(r.rows_deleted),
    "fts_docs_deleted": Json.int(r.fts_docs_deleted),
    "vec_docs_deleted": Json.int(r.vec_docs_deleted),
    "replay_calls_scrubbed": Json.int(r.replay_calls_scrubbed),
    "read_logs_scrubbed": Json.int(r.read_logs_scrubbed),
    "audit_entries_redacted": Json.int(r.audit_entries_redacted),
    "pre_erasure_tip_hash": Json.String(r.pre_erasure_tip_hash),
    "post_erasure_tip_hash": Json.String(r.post_erasure_tip_hash),
    "compacted": Json.Boolean(r.compacted?)
  })
end

fn make_hint_json(
  target_kind: Text,
  page: Page,
  block_id: Option(Text),
  comment_id: Option(Text),
  f: Secrets.SecretFinding
) : Json
  Json.Object({
    "target_kind": Json.String(target_kind),
    "page_id": Json.String(page.id),
    "page_title": Json.String(page.title),
    "collection_id": Json.String(page.collection_id),
    "block_id": block_id.to_json,
    "comment_id": comment_id.to_json,
    "kind": Json.String(f.kind),
    "label": Json.String(f.label),
    "severity": Json.String(f.severity),
    "masked_preview": Json.String(f.masked_preview),
    "match_sha256": Json.String(f.match_sha256)
  })
end

## Scans one page's title, canonical blocks, and comments for exposed credentials (`raw_token` omitted).
fn scan_page_secret_hints(
  _store: Store,
  page: Page,
  blocks: List(Block),
  comments: List(Comment)
) : List(Json)
  var hints = []
  for f in Secrets.scan_text(page.title)
    hints = hints.append(make_hint_json("page_title", page, None, None, f))
  end
  for blk in blocks
    for f in Secrets.scan_text(blk.markdown)
      hints = hints.append(make_hint_json("block", page, Some(blk.id), None, f))
    end
  end
  for cmt in comments
    for f in Secrets.scan_text(cmt.body_markdown)
      hints = hints.append(make_hint_json("comment", page, cmt.block_id, Some(cmt.id), f))
    end
  end
  hints
end

## Scans all active workspace pages, blocks, and comments for exposed credentials.
fn scan_workspace_secrets(store: Store) : Result(List(Json), AppError)
  rows = try Table.scan(store, Db.pages_table(), None, None, 500).map_error(Db.map_table_error)
  var out = []
  for (_pid, pg) in rows
    if pg.archived_at == None
      blks = try Db.load_page_blocks(store, pg.id)
      cmt_rows = try Table.lookup(store, Db.comments_table(), Db.comments_by_page(), pg.id)
        .map_error(Db.map_table_error)
      cmts = cmt_rows.map(fn(x) x.1 end)
      for h in scan_page_secret_hints(store, pg, blks, cmts)
        out = out.append(h)
      end
    end
  end
  Ok(out)
end

## Lists all persisted `Modb.Erasure.ErasureReceipt`s newest-last in JSON form.
fn list_erasure_receipts_json(store: Store) : Result(List(Json), AppError)
  recs = try Erasure.list_erasure_receipts(store).map_error(map_erasure_error)
  Ok(recs.map(fn(r) erasure_receipt_to_json(r) end))
end

## Fetches a single `Modb.Erasure.ErasureReceipt` as JSON.
fn get_erasure_receipt_json(store: Store, id: Text) : Result(Option(Json), AppError)
  rec_opt = try Erasure.get_erasure_receipt(store, id).map_error(map_erasure_error)
  Ok(rec_opt.map(fn(r) erasure_receipt_to_json(r) end))
end

fn append_unique_text(xs: List(Text), item: Text) : List(Text)
  t = item.trim
  if t.empty? or xs.contains?(t)
    xs
  else
    xs.append(t)
  end
end

fn page_contains_any_token?(pg: Page, blks: List(Block), cmts: List(Comment), tokens: List(Text)) : Bool
  for tok in tokens
    if pg.title.contains?(tok)
      return true
    end
    for b in blks
      if b.markdown.contains?(tok)
        return true
      end
    end
    for c in cmts
      if c.body_markdown.contains?(tok)
        return true
      end
    end
  end
  false
end

## Executes a complete Admin-only `Modb.Erasure` crypto-shredding + live sanitization +
## audit/replay scrubbing + FTS/Vec cleanup + optional CoW physical compaction purge.
fn execute_secret_purge_locked(
  files: Files,
  rng: SecureRandom,
  receipt_id: Text,
  subject_id: Text,
  target_page_id_opt: Option(Text),
  target_block_id_opt: Option(Text),
  target_comment_id_opt: Option(Text),
  mode: Text,
  extra_tokens: List(Text),
  compact?: Bool,
  reviewer: Text,
  is_admin: Bool,
  reason: Text,
  now: Time
) : Result((Erasure.ErasureReceipt, Int, Int, List(Text)), AppError)
  if not is_admin
    return Error(Forbidden(reason: "only Owner/Admin may execute Modb.Erasure secret purges"))
  end
  clean_mode = mode.trim.ascii_lowercase
  if clean_mode != "redact" and clean_mode != "delete_page"
    return Error(BadInput(reason: "erasure mode must be 'redact' or 'delete_page'"))
  end
  if clean_mode == "delete_page" and target_page_id_opt == None
    return Error(BadInput(reason: "page_id is required when mode is 'delete_page'"))
  end
  if not files.read_only.exists?(Db.ledger_db_path)
    return Error(Missing(entity: "ledger", id: Db.ledger_db_path))
  end

  eff_subject_id = if subject_id.trim.empty?: "secret:#{receipt_id}" else: subject_id.trim

  # 1. Read snapshot to discover secret tokens, affected pages, and neural vector dimensions
  (tokens, affected_page_ids, neural_dims_pairs, existing_key_opt) = try Ledger.read_locked(
    files.read_only,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      var toks = []
      for et in extra_tokens
        toks = append_unique_text(toks, et)
      end
      case target_page_id_opt
        Some(pid):
          pg = case try Table.get(store, Db.pages_table(), pid).map_error(Db.map_table_error)
            Some(p) if p.archived_at == None: p
            Some(_) | None: return Error(Missing(entity: "page", id: pid))
          end
          blks = try Db.load_page_blocks(store, pg.id)
          cmt_rows = try Table.lookup(store, Db.comments_table(), Db.comments_by_page(), pg.id)
            .map_error(Db.map_table_error)
          cmts = cmt_rows.map(fn(x) x.1 end)
          case (target_block_id_opt, target_comment_id_opt)
            (Some(bid), _):
              for b in blks
                if b.id == bid
                  for f in Secrets.scan_text(b.markdown)
                    toks = append_unique_text(toks, f.raw_token)
                  end
                end
              end
            (None, Some(cid)):
              for c in cmts
                if c.id == cid
                  for f in Secrets.scan_text(c.body_markdown)
                    toks = append_unique_text(toks, f.raw_token)
                  end
                end
              end
            (None, None):
              for f in Secrets.scan_text(pg.title)
                toks = append_unique_text(toks, f.raw_token)
              end
              for b in blks
                for f in Secrets.scan_text(b.markdown)
                  toks = append_unique_text(toks, f.raw_token)
                end
              end
              for c in cmts
                for f in Secrets.scan_text(c.body_markdown)
                  toks = append_unique_text(toks, f.raw_token)
                end
              end
          end
        None:
          all_pgs = try Table.scan(store, Db.pages_table(), None, None, 500).map_error(
            Db.map_table_error
          )
          for (_pid, pg) in all_pgs
            if pg.archived_at == None
              blks = try Db.load_page_blocks(store, pg.id)
              cmt_rows = try Table.lookup(
                store,
                Db.comments_table(),
                Db.comments_by_page(),
                pg.id
              ).map_error(Db.map_table_error)
              cmts = cmt_rows.map(fn(x) x.1 end)
              for f in Secrets.scan_text(pg.title)
                toks = append_unique_text(toks, f.raw_token)
              end
              for b in blks
                for f in Secrets.scan_text(b.markdown)
                  toks = append_unique_text(toks, f.raw_token)
                end
              end
              for c in cmts
                for f in Secrets.scan_text(c.body_markdown)
                  toks = append_unique_text(toks, f.raw_token)
                end
              end
            end
          end
      end

      if clean_mode == "redact" and toks.empty?
        return Error(BadInput(reason: "no exposed secrets detected or specified for redaction"))
      end

      var aff = []
      case target_page_id_opt
        Some(pid): aff = append_unique_text(aff, pid)
        None: Unit
      end
      if not toks.empty? and target_block_id_opt == None and target_comment_id_opt == None
        all_pgs2 = try Table.scan(store, Db.pages_table(), None, None, 500).map_error(
          Db.map_table_error
        )
        for (_pid2, pg2) in all_pgs2
          if pg2.archived_at == None and not aff.contains?(pg2.id)
            blks2 = try Db.load_page_blocks(store, pg2.id)
            cmt_rows2 = try Table.lookup(
              store,
              Db.comments_table(),
              Db.comments_by_page(),
              pg2.id
            ).map_error(Db.map_table_error)
            cmts2 = cmt_rows2.map(fn(x) x.1 end)
            if page_contains_any_token?(pg2, blks2, cmts2, toks)
              aff = append_unique_text(aff, pg2.id)
            end
          end
        end
      end

      var nd_pairs = []
      for pid in aff
        case try Table.get(store, Db.page_neural_dims_table(), pid).map_error(Db.map_table_error)
          Some(d): nd_pairs = nd_pairs.append((pid, d))
          None: Unit
        end
      end

      kopt = try Erasure.get_subject_key(store, eff_subject_id).map_error(map_erasure_error)
      Ok((toks, aff, nd_pairs, kopt))
    end
  )

  # Ensure audit reason itself never echoes raw secrets
  raw_reason = if reason.trim.empty?: "One-click Modb.Erasure secret purge (#{clean_mode})" else: reason.trim
  (san_reason, _r_cnt) = Secrets.redact_tokens(raw_reason, tokens)
  safe_reason = if san_reason.trim.empty?: "One-click Modb.Erasure secret purge (#{clean_mode})" else: san_reason.trim

  # 2. Layer A: Provision subject encryption key & seal quarantine record outside tx closures
  key_rec = case existing_key_opt
    Some(kr): kr
    None:
      pm = Ledger.WriteMeta(
        principal: reviewer,
        action: "erasure.provision_key",
        reason: safe_reason,
        at: now
      )
      try Erasure.provision_subject_key_locked(
        files,
        Db.ledger_db_path,
        Db.vellum_schema(),
        rng,
        eff_subject_id,
        pm
      ).map_error(map_erasure_error)
  end

  sealed_val_bytes = if not key_rec.shredded?
    case Bytes.from_base64url(key_rec.key_b64)
      Some(raw_k) if raw_k.size == 32:
        nonce = rng.bytes(12)
        aad = "modb:erase:v1:#{eff_subject_id}:secret_purge".bytes
        pt = Json.Object({
          "receipt_id": Json.String(receipt_id),
          "mode": Json.String(clean_mode),
          "token_count": Json.int(tokens.size),
          "page_count": Json.int(affected_page_ids.size)
        }).to_text.bytes
        case Crypto.seal(raw_k, nonce, pt, aad)
          Ok(ct): "modb-enc:v1:#{nonce.to_base64url}:#{ct.to_base64url}".bytes
          Error(_): "erasure-quarantine:#{receipt_id}".bytes
        end
      Some(_) | None: "erasure-quarantine:#{receipt_id}".bytes
    end
  else
    "erasure-quarantine:#{receipt_id}".bytes
  end
  qkey_bytes = "vlm_quarantine:#{receipt_id}".bytes

  # 3. Live sanitization / deletion preserving secondary indexes + registering subject ref
  wmeta = Ledger.WriteMeta(
    principal: reviewer,
    action: "erasure.sanitize_live",
    reason: safe_reason,
    at: now
  )
  (blocks_redacted, comments_redacted) = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    wmeta,
    "sanitize live records before Modb.Erasure #{receipt_id}",
    Json.Object({
      "receipt_id": Json.String(receipt_id),
      "mode": Json.String(clean_mode),
      "affected_pages": affected_page_ids.to_json
    }),
    Db.map_ledger_error,
    fn(tx)
      var cur = try Modb.tx_put(tx, "vlm_erasure_quarantine", qkey_bytes, sealed_val_bytes)
        .map_error(fn(e) ServerFailed(reason: e.to_text) end)
      cur = try Erasure.tx_register_subject_ref(
        cur,
        eff_subject_id,
        "vlm_erasure_quarantine",
        qkey_bytes,
        target_page_id_opt
      ).map_error(map_erasure_error)

      var b_cnt = 0
      var c_cnt = 0
      for pid in affected_page_ids
        is_deleted_target = clean_mode == "delete_page" and target_page_id_opt == Some(pid)
        if is_deleted_target
          cmt_rows = try Table.tx_lookup(cur, Db.comments_table(), Db.comments_by_page(), pid)
            .map_error(Db.map_table_error)
          for (cid, _c) in cmt_rows
            cur = try Table.delete(cur, Db.comments_table(), cid).map_error(Db.map_table_error)
            c_cnt += 1
          end
          att_rows = try Table.tx_lookup(
            cur,
            Db.attachments_table(),
            Db.attachments_by_page(),
            pid
          ).map_error(Db.map_table_error)
          for (aid, _a) in att_rows
            cur = try Table.delete(cur, Db.attachments_table(), aid).map_error(Db.map_table_error)
          end
          blk_rows = try Table.tx_lookup(cur, Db.blocks_table(), Db.blocks_by_page(), pid)
            .map_error(Db.map_table_error)
          for (bid, _b) in blk_rows
            cur = try Db.tx_delete_block_row(cur, bid)
            b_cnt += 1
          end
          case try Table.tx_get(cur, Db.page_meta_table(), pid).map_error(Db.map_table_error)
            Some(_pm): cur = try Db.tx_delete_page_meta(cur, pid)
            None: Unit
          end
          case try Table.tx_get(cur, Db.page_neural_dims_table(), pid).map_error(
            Db.map_table_error
          )
            Some(_nd): cur = try Db.tx_delete_page_neural_dims(cur, pid)
            None: Unit
          end
          skey = Db.page_summary_key(pid)
          case try Table.tx_get(cur, Db.summaries_table(), skey).map_error(Db.map_table_error)
            Some(_sm): cur = try Db.tx_delete_summary(cur, skey)
            None: Unit
          end
          case try Table.tx_get(cur, Db.pages_table(), pid).map_error(Db.map_table_error)
            Some(_pg): cur = try Db.tx_delete_page_row(cur, pid)
            None: Unit
          end
        else
          case try Table.tx_get(cur, Db.pages_table(), pid).map_error(Db.map_table_error)
            Some(pg):
              blk_rows = try Table.tx_lookup(cur, Db.blocks_table(), Db.blocks_by_page(), pid)
                .map_error(Db.map_table_error)
              var next_blks = []
              for (_bid, blk) in blk_rows
                allow_blk = target_block_id_opt == None or target_block_id_opt == Some(blk.id)
                eff_blk = if allow_blk and not tokens.empty?
                  (red_md, n_rep) = Secrets.redact_tokens(blk.markdown, tokens)
                  if n_rep > 0
                    b_cnt += 1
                    next_prov = Provenance(
                      author_id: blk.provenance.author_id,
                      author_kind: blk.provenance.author_kind,
                      grant_id: blk.provenance.grant_id,
                      proposal_id: blk.provenance.proposal_id,
                      reason: Some("redacted via Modb.Erasure #{receipt_id}"),
                      citations: blk.provenance.citations,
                      updated_at: now
                    )
                    nb = Block(
                      id: blk.id,
                      page_id: blk.page_id,
                      parent_block_id: blk.parent_block_id,
                      rank: blk.rank,
                      kind: blk.kind,
                      markdown: red_md,
                      provenance: next_prov,
                      version: blk.version + 1
                    )
                    cur = try Db.tx_put_block_row(cur, nb)
                    nb
                  else
                    blk
                  end
                else
                  blk
                end
                next_blks = next_blks.append(eff_blk)
              end
              sorted_next_blks = Blocks.sort_blocks(next_blks)

              cmt_rows = try Table.tx_lookup(cur, Db.comments_table(), Db.comments_by_page(), pid)
                .map_error(Db.map_table_error)
              for (_cid, cmt) in cmt_rows
                allow_cmt = target_comment_id_opt == None or target_comment_id_opt == Some(cmt.id)
                if allow_cmt and not tokens.empty?
                  (red_body, c_rep) = Secrets.redact_tokens(cmt.body_markdown, tokens)
                  if c_rep > 0
                    c_cnt += 1
                    nc = Comment(
                      id: cmt.id,
                      page_id: cmt.page_id,
                      block_id: cmt.block_id,
                      parent_comment_id: cmt.parent_comment_id,
                      author_id: cmt.author_id,
                      body_markdown: red_body,
                      resolved_at: cmt.resolved_at,
                      created_at: cmt.created_at
                    )
                    cur = try Db.tx_put_comment(cur, nc)
                  end
                end
              end

              case try Table.tx_get(cur, Db.page_neural_dims_table(), pid).map_error(
                Db.map_table_error
              )
                Some(_nd): cur = try Db.tx_delete_page_neural_dims(cur, pid)
                None: Unit
              end

              (raw_red_title, _t_rep) = Secrets.redact_tokens(pg.title, tokens)
              safe_title = if raw_red_title.trim.empty?: "[REDACTED]" else: raw_red_title
              bumped_pg = Page(
                id: pg.id,
                collection_id: pg.collection_id,
                parent_page_id: pg.parent_page_id,
                title: safe_title,
                icon: pg.icon,
                cover_attachment_id: pg.cover_attachment_id,
                kind: pg.kind,
                sort_order: pg.sort_order,
                database_id: pg.database_id,
                freshness_ttl_days: pg.freshness_ttl_days,
                verified_at: pg.verified_at,
                verified_by: pg.verified_by,
                created_by: pg.created_by,
                created_at: pg.created_at,
                updated_at: now,
                archived_at: pg.archived_at,
                version: pg.version + 1
              )
              cur = try Db.tx_put_page_row(cur, bumped_pg)
              if bumped_pg.kind == Document
                cur = try Db.tx_refresh_page_summary(cur, bumped_pg, sorted_next_blks)
              end
            None: Unit
          end
        end
      end
      Ok((cur, (b_cnt, c_cnt)))
    end
  )

  # 4. Dual-Layer Modb.Erasure: shred key, delete refs, remove FTS/Vec docs, scrub Replay/Audit
  var vec_list = []
  for pid in affected_page_ids
    vec_list = vec_list.append((Db.sketch_vec_index(), pid))
  end
  for (npid, ndims) in neural_dims_pairs
    vec_list = vec_list.append((Db.neural_vec_index(ndims), npid))
  end
  ereq = Erasure.ErasureRequest(
    receipt_id: receipt_id,
    subject_id: eff_subject_id,
    match_tokens: tokens,
    extra_bucket_keys: [],
    fts_indexes: affected_page_ids.map(fn(pid) (Db.fts_index(), pid) end),
    vec_indexes: vec_list,
    shred_key?: true,
    scrub_audit?: true,
    scrub_replay?: true,
    scrub_read_log?: true
  )
  erased_rec = try Erasure.erase_subject_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    ereq,
    reviewer,
    true,
    safe_reason,
    now
  ).map_error(map_erasure_error)

  # 5. Re-index surviving redacted pages cleanly in FTS + Sketch Vec
  var surviving_pids = []
  for pid in affected_page_ids
    if not (clean_mode == "delete_page" and target_page_id_opt == Some(pid))
      surviving_pids = surviving_pids.append(pid)
    end
  end
  if not surviving_pids.empty?
    rmeta = Ledger.WriteMeta(
      principal: reviewer,
      action: "erasure.reindex",
      reason: "reindex sanitized pages after #{receipt_id}",
      at: now
    )
    _reindexed = try Ledger.transact_locked(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      rmeta,
      "reindexed #{surviving_pids.size} sanitized pages",
      Json.Object({"receipt_id": Json.String(receipt_id)}),
      Db.map_ledger_error,
      fn(tx)
        var cur = tx
        for pid in surviving_pids
          case try Table.tx_get(cur, Db.pages_table(), pid).map_error(Db.map_table_error)
            Some(pg):
              b_rows = try Table.tx_lookup(cur, Db.blocks_table(), Db.blocks_by_page(), pid)
                .map_error(Db.map_table_error)
              cur = try Db.tx_index_page(cur, pg, Blocks.sort_blocks(b_rows.map(fn(x) x.1 end)))
            None: Unit
          end
        end
        Ok((cur, Unit))
      end
    )
  end

  # 6. Physical CoW compaction to evict dead historical B+Tree pages
  final_rec = if compact?
    (_crep, crec) = try Erasure.compact_after_erasure(
      files,
      Db.ledger_db_path,
      Db.vellum_schema(),
      receipt_id,
      now
    ).map_error(map_erasure_error)
    crec
  else
    erased_rec
  end

  Ok((final_rec, blocks_redacted, comments_redacted, affected_page_ids))
end
