## Vellum Phase 3a2 Integration Test Suite (split from Phase3a for Mo lowering work limit).
module Tests.Phase3a2
use Main
use Api
use Arvo.WebTest
use Crypto
use Domain.Types{BlockOp, Citation, CollectionWritePolicy}
use Http
use Json
use Routes.Ai
use Routes.Collab
use Routes.Workspace

fn must_page(res: Api.Response) : WebTest.InertiaPage
  case WebTest.inertia_page(res)
    Ok(p): p
    Error(_): stop "expected valid Inertia page"
  end
end

fn cookie_pair_from_set(res: Api.Response, name: Text) : Text
  for h in res.headers_named("Set-Cookie")
    if h.starts_with?("#{name}=")
      return (h.split(";").first or "").trim
    end
  end
  stop "missing Set-Cookie header"
end

fn must_json(raw: Text) : Json
  case Json.parse(raw)
    Ok(j): j
    Error(_): stop "expected valid JSON"
  end
end

test "Main.test.16"
  # Phase 3.2: Modb.Vec contradiction detection, cited-dependency drift, Proposals-Only Gardener,
  # and HMAC-SHA256 signed GitHub PR-to-Runbook bridge.
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-p32.js",
        "css": ["assets/main-p32.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-p32.js": "console.log('p32');",
    "public/assets/main-p32.css": "body{margin:0}"
  })
  rng = SecureRandom.seeded(20261206)
  t0 = Time.parse("2026-12-06T09:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  gh_secret = "gh-bridge-test-secret"
  env = Env.of({
    "VELLUM_MODE": "solo",
    "VELLUM_INSECURE_COOKIES": "1",
    "VELLUM_GITHUB_WEBHOOK_SECRET": gh_secret
  })
  empty_net = Network.fake(Http.replies([]))

  guest = WebTest.new().with_header("Host", "127.0.0.1:8080")
  login_res = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/auth/solo/login?return_to=/")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert login_res.status == 303
  owner = WebTest.absorb(guest, login_res)

  ops_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "ops-runbooks",
          name: "Ops Runbooks",
          description: None,
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert ops_col_res.status == 201
  ops_col_id = must_json(ops_col_res.text).text_at("id") or stop "ops_col_id"

  sec_col_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/collections").with_json(
        Workspace.CreateCollectionInput(
          slug: "secret-vault",
          name: "Secret Vault",
          description: None,
          icon: None,
          write_policy: DirectWithAudit,
          freshness_ttl_days: None
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_col_res.status == 201
  sec_col_id = must_json(sec_col_res.text).text_at("id") or stop "sec_col_id"

  # 1. Seed authoritative source page + dependent page with block citation & excerpt, then update source
  p_auth_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Public API Rate Limit Spec",
          markdown: "Public API rate limit is 100 req/s per tenant.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed rate limit spec")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert p_auth_res.status == 201
  p_auth_j = must_json(p_auth_res.text)
  p_auth_id = p_auth_j.text_at("page.id") or stop "p_auth_id"
  b_auth_blk = (p_auth_j.list_at("blocks") or []).first or stop "b_auth_blk"
  b_auth_id = b_auth_blk.text_at("id") or stop "b_auth_id"

  p_dep_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Gateway Failover SOP",
          markdown: "Respect upstream API rate limit before retrying gateway failover.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed dependent sop")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert p_dep_res.status == 201
  p_dep_j = must_json(p_dep_res.text)
  p_dep_id = p_dep_j.text_at("page.id") or stop "p_dep_id"
  b_dep_blk = (p_dep_j.list_at("blocks") or []).first or stop "b_dep_blk"
  b_dep_id = b_dep_blk.text_at("id") or stop "b_dep_id"

  cite_patch = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{p_dep_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            AttachCitations(
              block_id: b_dep_id,
              citations: [
                Citation(
                  source_kind: "block",
                  source_ref: b_auth_id,
                  label: "Rate Limit §1",
                  excerpt: Some("Public API rate limit is 100 req/s per tenant.")
                )
              ]
            )
          ],
          expected_versions: {},
          reason: Some("link block dependency citation")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert cite_patch.status == 200

  bump_auth = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.patch("/api/pages/#{p_auth_id}/blocks").with_json(
        Workspace.PatchBlocksInput(
          ops: [
            ReplaceBlock(
              block_id: b_auth_id,
              expected_version: 1,
              kind: None,
              markdown: "Public API rate limit is 25 req/s per tenant during failover."
            )
          ],
          expected_versions: {b_auth_id: 1},
          reason: Some("tighten failover rate limit")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bump_auth.status == 200

  # 2. Seed Modb.Vec near-duplicate contradicting pair + cross-collection secret doc
  dup_a = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Deploy Rollback Checklist Alpha",
          markdown: "Always enable feature flag legacy_auth during canary deploy step 2 within 30 seconds.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed alpha rollback")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dup_a.status == 201
  dup_a_id = must_json(dup_a.text).text_at("page.id") or stop "dup_a_id"

  dup_b = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: ops_col_id,
          parent_page_id: None,
          title: "Deploy Rollback Checklist Beta",
          markdown: "Never enable feature flag legacy_auth during canary deploy step 2 within 10 seconds.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed beta rollback contradiction")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dup_b.status == 201

  sec_pg = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/pages").with_json(
        Workspace.CreatePageInput(
          collection_id: sec_col_id,
          parent_page_id: None,
          title: "Secret Rollback Checklist Vault",
          markdown: "Never enable feature flag legacy_auth during canary deploy step 2 within 10 seconds secret_vault.",
          icon: None,
          freshness_ttl_days: None,
          reason: Some("seed secret vault doc")
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert sec_pg.status == 201

  # Scoped agent restricted ONLY to ops_col_id verifies ACL isolation in GET /api/admin/garden
  mint_ops = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/agents").with_json(
        Json.Object({
          "handle": Json.String("@ops_gardener"),
          "display_name": Json.String("Ops Gardener"),
          "model_id": Json.Null,
          "label": Json.String("ops-garden"),
          "allowed_actions": Json.Array([Json.String("read"), Json.String("propose")]),
          "allowed_collections": Json.Array([Json.String(ops_col_id)]),
          "max_calls": Json.int(50),
          "ttl_days": Json.int(7)
        })
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert mint_ops.status == 201
  ag_tok = must_json(mint_ops.text).text_at("raw_token") or stop "ag_tok"
  ag_ops = WebTest.new().with_header("Host", "127.0.0.1:8080").with_header(
    "Authorization",
    "Bearer #{ag_tok}"
  )

  g_scan = ApiTest.send(
    Main,
    WebTest.prepare(ag_ops, Api.get("/api/admin/garden")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert g_scan.status == 200
  assert not g_scan.text.contains?("Secret Rollback Checklist Vault")
  gj = must_json(g_scan.text)
  drifts = gj.list_at("citation_drifts") or []
  assert drifts.any?(fn(d)
    d.text_at("dependent_page_id") == Some(p_dep_id) and
      d.text_at("cited_page_id") == Some(p_auth_id) and
      d.text_at("cited_block_id") == Some(b_auth_id)
  end)
  dups = gj.list_at("duplicate_pairs") or []
  assert dups.any?(fn(dp) dp.bool_at("possible_contradiction") == Some(true) end)

  # Show page also surfaces cited-dependency drifts
  dep_show = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{p_dep_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert dep_show.status == 200
  assert (must_json(dep_show.text).list_at("citation_drifts") or []).size >= 1

  # 3. Proposals-Only Invariant: even on DirectWithAudit collection, POST /api/admin/garden/propose
  # opens a Modb.World Change Proposal without mutating live content until accepted
  gp_res = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/admin/garden/propose").with_json(
        Ai.GardenProposeInput(
          kind: "citation_drift",
          target_page_id: p_dep_id,
          target_block_id: Some(b_dep_id),
          related_page_id: Some(p_auth_id),
          related_block_id: Some(b_auth_id),
          reason: Some("Sync cited rate limit change"),
          deterministic_fallback: Some(true)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gp_res.status == 201
  gp_j = must_json(gp_res.text)
  gp_id = gp_j.text_at("proposal.id") or stop "gp_id"
  assert gp_j.text_at("proposal.status") == Some("open")

  # Verify live p_dep is STILL untouched
  dep_before_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{p_dep_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert not (must_json(dep_before_acc.text).text_at("anchored_markdown") or "").contains?(
    "Gardener sync review"
  )

  # Accept gardener proposal -> live page now reflects reconciliation callout
  acc_gp = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{gp_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Accept gardener drift reconciliation"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_gp.status == 200
  dep_after_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{p_dep_id}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(dep_after_acc.text).text_at("anchored_markdown") or "").contains?(
    "Gardener sync review"
  )

  # Duplicate/contradiction gardener proposal also stages cleanly as Modb.World proposal
  gp_dup = ApiTest.send(
    Main,
    WebTest.prepare(
      ag_ops,
      Api.post("/api/admin/garden/propose").with_json(
        Ai.GardenProposeInput(
          kind: "duplicate_contradiction",
          target_page_id: dup_a_id,
          target_block_id: None,
          related_page_id: None,
          related_block_id: None,
          reason: Some("Reconcile Always vs Never flag rollout"),
          deterministic_fallback: Some(true)
        )
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert gp_dup.status == 201

  # 4. Signed Inbound GitHub PR Webhook Bridge (`POST /api/webhooks/github`)
  gh_payload = Json.Object({
    "action": Json.String("opened"),
    "repository": Json.Object({"full_name": Json.String("acme/gateway")}),
    "changed_files": Json.Array([Json.String("docs/gateway-failover-sop.md")]),
    "pull_request": Json.Object({
      "number": Json.int(412),
      "title": Json.String("Gateway failover rate limit retry update"),
      "body": Json.String("Respect upstream API rate limit before retrying gateway failover."),
      "html_url": Json.String("https://github.com/acme/gateway/pull/412"),
      "merged": Json.Boolean(false),
      "head": Json.Object({"sha": Json.String("abc1234deadbeef")})
    })
  })
  gh_req_base = Api.post("/api/webhooks/github").with_json(gh_payload)

  # Unsigned or invalid HMAC signature fails closed with 403
  unsigned_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.new().with_header("Host", "127.0.0.1:8080").with_header("X-GitHub-Event", "pull_request"),
      gh_req_base
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert unsigned_res.status == 403

  bad_sig_res = ApiTest.send(
    Main,
    WebTest.prepare(
      WebTest.new()
        .with_header("Host", "127.0.0.1:8080")
        .with_header("X-GitHub-Event", "pull_request")
        .with_header("X-Hub-Signature-256", "sha256=deadbeef"),
      gh_req_base
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert bad_sig_res.status == 403

  # Valid HMAC-SHA256 signature stages Modb.World Change Proposals under @github-pr-bridge
  sig_hex = Crypto.hmac_sha256(gh_secret.bytes, gh_req_base.body).to_hex.ascii_lowercase
  signed_client = WebTest.new()
    .with_header("Host", "127.0.0.1:8080")
    .with_header("X-GitHub-Event", "pull_request")
    .with_header("X-Hub-Signature-256", "sha256=#{sig_hex}")
  signed_res = ApiTest.send(
    Main,
    WebTest.prepare(signed_client, gh_req_base),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert signed_res.status == 201
  sj = must_json(signed_res.text)
  assert (sj.int_at("matched_pages") or 0) >= 1
  gh_props = sj.list_at("proposals") or []
  assert gh_props.size >= 1
  gh_p0 = gh_props.first or stop "gh_p0"
  gh_prop_id = gh_p0.text_at("id") or stop "gh_prop_id"
  gh_target_pg = gh_p0.text_at("target_page_id") or stop "gh_target_pg"
  assert gh_p0.text_at("author_handle") == Some("@github-pr-bridge")
  assert gh_p0.text_at("status") == Some("open")

  # Verify Proposals-Only invariant: target live page does NOT contain PR #412 before review
  before_gh_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{gh_target_pg}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert not (must_json(before_gh_acc.text).text_at("anchored_markdown") or "").contains?(
    "PR #412"
  )

  acc_gh = ApiTest.send(
    Main,
    WebTest.prepare(
      owner,
      Api.post("/api/proposals/#{gh_prop_id}/accept").with_json(
        Collab.ProposalDecisionInput(reason: Some("Accept PR #412 runbook update"))
      )
    ),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert acc_gh.status == 200
  after_gh_acc = ApiTest.send(
    Main,
    WebTest.prepare(owner, Api.get("/api/pages/#{gh_target_pg}")),
    files,
    clock,
    env,
    rng,
    empty_net
  )
  assert (must_json(after_gh_acc.text).text_at("anchored_markdown") or "").contains?("PR #412")
end

