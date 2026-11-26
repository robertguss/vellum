## Authentication, fail-closed env configuration, OIDC/SSO PKCE login/callback,
## and dual Human (MoDB session) + Agent (`vlm_ag_...` Bearer + MoDB grant) authentication.
module Routes.Auth
expose AuthMode(..),
PersonalLoginInput(..),
auth_mode,
auth_mode_text,
loopback_request?,
app_secret_key,
resolve_app_secret_key,
ensure_app_secret_key,
secure_cookies?,
session_cfg,
oidc_config,
s3_config,
s3_configured?,
use_local_attachments,
local_attachment_sig,
verify_local_attachment_sig,
load_inertia_config,
wants_json?,
require_session_csrf,
shared_props,
shared_props_for,
guest_redirect_or_401,
authenticate,
show_login,
start_oidc_login,
oidc_callback,
solo_login,
personal_login,
post_logout
use Api
use Arvo.Auth
use Arvo.Csrf
use Arvo.Flash
use Arvo.Id
use Arvo.Inertia
use Arvo.Modb.Sessions
use Arvo.Oidc
use Arvo.S3
use Arvo.Session
use Crypto
use Db
use Domain.Policy
use Domain.Types{AppError, AuthContext, Principal}
use Json
use Modb.Ledger
use Modb.Table

enum AuthMode
  SoloMode
  PersonalMode
  TeamMode
end

struct PersonalLoginInput
  passphrase: Text
  return_to: Option(Text)
end

secret_key_file_path = ".vellum_secret"

fn auth_mode(env: Env) : Result(AuthMode, AppError)
  raw = (env.get("VELLUM_MODE") or "").trim.ascii_lowercase
  if raw.empty? or raw == "team"
    Ok(TeamMode)
  else if raw == "solo"
    Ok(SoloMode)
  else if raw == "personal"
    Ok(PersonalMode)
  else
    Error(ServerFailed(reason: "invalid VELLUM_MODE '#{raw}' (expected solo, personal, or team)"))
  end
end

fn auth_mode_text(mode: AuthMode) : Text
  case mode
    SoloMode: "solo"
    PersonalMode: "personal"
    TeamMode: "team"
  end
end

fn extract_host_without_port(raw_header: Text) : Text
  trimmed = raw_header.trim.ascii_lowercase
  if trimmed.starts_with?("[")
    if trimmed.contains?("]")
      "#{(trimmed.split("]").first or "")}]"
    else
      trimmed
    end
  else
    parts = trimmed.split(":")
    if parts.size == 2
      parts.first or trimmed
    else
      trimmed
    end
  end
end

fn loopback_host_value?(raw_host: Text) : Bool
  h = extract_host_without_port(raw_host)
  h == "localhost" or h == "127.0.0.1" or h == "::1" or h == "[::1]"
end

## Returns whether bind config and HTTP Host headers are strictly loopback.
fn loopback_request?(req: Api.Request, env: Env) : Bool
  case env.get("VELLUM_BIND")
    Some(b) if not b.trim.empty?:
      if not loopback_host_value?(b)
        return false
      end
    Some(_) | None: Unit
  end
  case req.header("X-Forwarded-Host")
    Some(fh) if not fh.trim.empty?:
      if not loopback_host_value?(fh)
        return false
      end
    Some(_) | None: Unit
  end
  case req.header("Host")
    Some(h) if not h.trim.empty?: loopback_host_value?(h)
    Some(_) | None: true
  end
end

fn require_solo_loopback(req: Api.Request, env: Env) : Result(Unit, AppError)
  if loopback_request?(req, env)
    Ok(Unit)
  else
    Error(
      Forbidden(
        reason: "solo mode requires loopback bind/host (use VELLUM_MODE=personal or team for remote access)"
      )
    )
  end
end

fn parse_hex_secret_key(raw_hex: Text, source_label: Text) : Result(Bytes, AppError)
  decoded = try Bytes.from_hex(raw_hex.trim).or_fail(
    ServerFailed(reason: "#{source_label} must be valid hex")
  )
  if decoded.size != 32
    return Error(ServerFailed(reason: "#{source_label} must decode to 32 bytes (64 hex chars)"))
  end
  Ok(decoded)
end

## Reads and validates the required 32-byte (64-hex-char) AEAD application secret key from env.
fn app_secret_key(env: Env) : Result(Bytes, AppError)
  raw_hex = try env.get("VELLUM_SECRET_KEY").or_fail(
    ServerFailed(reason: "missing VELLUM_SECRET_KEY env var")
  )
  parse_hex_secret_key(raw_hex, "VELLUM_SECRET_KEY")
end

## Resolves the AEAD secret key from env, or `.vellum_secret` in Solo/Personal modes (returns `None` if not yet initialized).
fn resolve_app_secret_key(rf: ReadFiles, env: Env) : Result(Option(Bytes), AppError)
  case env.get("VELLUM_SECRET_KEY")
    Some(raw) if not raw.trim.empty?: return Ok(
      Some(try parse_hex_secret_key(raw, "VELLUM_SECRET_KEY"))
    )
    Some(_) | None: Unit
  end
  mode = try auth_mode(env)
  if mode == TeamMode
    return Error(ServerFailed(reason: "missing VELLUM_SECRET_KEY env var"))
  end
  if rf.exists?(secret_key_file_path)
    stored = try rf.read_text(secret_key_file_path).map_error(fn(e)
      ServerFailed(reason: "failed reading #{secret_key_file_path}: #{e.to_text}")
    end)
    Ok(Some(try parse_hex_secret_key(stored, secret_key_file_path)))
  else
    Ok(None)
  end
end

## Resolves or generates & persists the 32-byte AEAD key in Solo/Personal modes.
fn ensure_app_secret_key(files: Files, rng: SecureRandom, env: Env) : Result(Bytes, AppError)
  case try resolve_app_secret_key(files.read_only, env)
    Some(k): Ok(k)
    None:
      fresh = rng.bytes(32)
      try files.write_text(secret_key_file_path, fresh.to_hex).map_error(fn(e)
        ServerFailed(reason: "failed writing #{secret_key_file_path}: #{e.to_text}")
      end)
      Ok(fresh)
  end
end

## Whether cookies must carry the `Secure` attribute (disabled only when `VELLUM_INSECURE_COOKIES=1`).
fn secure_cookies?(env: Env) : Bool
  (env.get("VELLUM_INSECURE_COOKIES") or "").trim != "1"
end

## Session cookie configuration (`vellum_session`, 7-day TTL, AES-256-GCM + SHA-256 MoDB backing).
fn session_cfg(env: Env) : Session.SessionConfig
  Session.SessionConfig(
    cookie_name: "vellum_session",
    ttl_seconds: 604800,
    secure?: secure_cookies?(env)
  )
end

fn require_env_text(env: Env, key_name: Text) : Result(Text, AppError)
  raw = try env.get(key_name).or_fail(ServerFailed(reason: "missing #{key_name} env var"))
  trimmed = raw.trim
  if trimmed.empty?
    return Error(ServerFailed(reason: "#{key_name} env var must not be empty"))
  end
  Ok(trimmed)
end

fn parse_csv_list(raw: Option(Text)) : List(Text)
  case raw
    None: []
    Some(s): s.split(",").map(fn(x) x.trim end).filter(fn(x) not x.empty? end)
  end
end

## Builds `Arvo.Oidc.OidcConfig` from environment variables (fail-closed if unconfigured).
fn oidc_config(env: Env) : Result(Oidc.OidcConfig, AppError)
  provider_id = case env.get("VELLUM_OIDC_PROVIDER_ID")
    Some(v) if not v.trim.empty?: v.trim
    Some(_) | None: "oidc"
  end
  client_id = try require_env_text(env, "VELLUM_OIDC_CLIENT_ID")
  client_secret = try require_env_text(env, "VELLUM_OIDC_CLIENT_SECRET")
  redirect_uri = try require_env_text(env, "VELLUM_OIDC_REDIRECT_URI")
  issuer = try require_env_text(env, "VELLUM_OIDC_ISSUER")
  auth_url = try require_env_text(env, "VELLUM_OIDC_AUTH_URL")
  token_url = try require_env_text(env, "VELLUM_OIDC_TOKEN_URL")
  userinfo_opt = case env.get("VELLUM_OIDC_USERINFO_URL")
    Some(u) if not u.trim.empty?: Some(u.trim)
    Some(_) | None: None
  end
  allowed_domains = parse_csv_list(env.get("VELLUM_OIDC_ALLOWED_DOMAINS"))
  require_verified? = (env.get("VELLUM_OIDC_REQUIRE_VERIFIED_EMAIL") or "").trim != "0"

  Ok(
    Oidc.OidcConfig(
      provider_id: provider_id,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      scopes: Oidc.default_scopes(),
      endpoints: Oidc.ProviderEndpoints(
        issuer: issuer,
        authorization_endpoint: auth_url,
        token_endpoint: token_url,
        userinfo_endpoint: userinfo_opt,
        jwks_uri: None
      ),
      allowed_domains: allowed_domains,
      require_verified_email?: require_verified?,
      cookie_name: "vellum_oidc_state",
      state_ttl_seconds: 600,
      secure_cookie?: secure_cookies?(env)
    )
  )
end

fn non_empty_env?(env: Env, key_name: Text) : Bool
  case env.get(key_name)
    Some(v): not v.trim.empty?
    None: false
  end
end

## Returns `true` when all required S3 object-storage variables are configured.
fn s3_configured?(env: Env) : Bool
  non_empty_env?(env, "VELLUM_S3_ENDPOINT") and
    non_empty_env?(env, "VELLUM_S3_BUCKET") and
    non_empty_env?(env, "VELLUM_S3_ACCESS_KEY_ID") and
    non_empty_env?(env, "VELLUM_S3_SECRET_ACCESS_KEY")
end

## Uses local disk attachments in Solo/Personal modes when S3 is unconfigured (or when explicitly enabled).
fn use_local_attachments(env: Env) : Result(Bool, AppError)
  if s3_configured?(env)
    return Ok(false)
  end
  override = (env.get("VELLUM_ATTACHMENTS_BACKEND") or "").trim.ascii_lowercase
  if override == "local"
    return Ok(true)
  end
  mode = try auth_mode(env)
  Ok(mode == SoloMode or mode == PersonalMode)
end

## Computes HMAC-SHA256 signature binding a local attachment upload URL to ID, expiry, size, and SHA-256.
fn local_attachment_sig(
  key: Bytes,
  att_id: Text,
  exp_sec: Int,
  size_bytes: Int,
  sha256_hex: Text
) : Text
  payload = "local-upload:v1:#{att_id}:#{exp_sec}:#{size_bytes}:#{sha256_hex.trim.ascii_lowercase}"
  Crypto.hmac_sha256(key, payload.bytes).to_hex
end

## Verifies a local attachment upload HMAC signature in constant time.
fn verify_local_attachment_sig(
  key: Bytes,
  att_id: Text,
  exp_sec: Int,
  size_bytes: Int,
  sha256_hex: Text,
  provided_sig: Text
) : Bool
  expected = local_attachment_sig(key, att_id, exp_sec, size_bytes, sha256_hex)
  Crypto.constant_time_eq?(expected.bytes, provided_sig.trim.ascii_lowercase.bytes)
end

## Builds `Arvo.S3.S3Config` from environment variables (fail-closed if unconfigured).
fn s3_config(env: Env) : Result(S3.S3Config, AppError)
  endpoint = try require_env_text(env, "VELLUM_S3_ENDPOINT")
  bucket = try require_env_text(env, "VELLUM_S3_BUCKET")
  access_key_id = try require_env_text(env, "VELLUM_S3_ACCESS_KEY_ID")
  secret_access_key = try require_env_text(env, "VELLUM_S3_SECRET_ACCESS_KEY")
  region = case env.get("VELLUM_S3_REGION")
    Some(r) if not r.trim.empty?: r.trim
    Some(_) | None: "us-east-1"
  end
  path_style? = (env.get("VELLUM_S3_PATH_STYLE") or "").trim != "0"
  Ok(
    S3.S3Config(
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      session_token: None,
      path_style?: path_style?
    )
  )
end

## Loads Vite dev or production manifest `InertiaConfig` via `ReadFiles`.
fn load_inertia_config(rf: ReadFiles, env: Env) : Result(Inertia.InertiaConfig, AppError)
  title = "Vellum"
  head = "<meta name=\"theme-color\" content=\"#0f172a\">"
  case env.get("VELLUM_VITE_DEV_URL")
    Some(url) if not url.trim.empty?: return Ok(
      Inertia.dev_config(title, url.trim, "src/main.tsx", head)
    )
    Some(_) | None: Unit
  end
  manifest_bytes = try rf.read_bytes("public/manifest.json").map_error(fn(e)
    ServerFailed(reason: "missing public/manifest.json: #{e.to_text}")
  end)
  Inertia.config_from_manifest(title, manifest_bytes, "src/main.tsx", head).map_error(fn(msg)
    ServerFailed(reason: "invalid Vite manifest: #{msg}")
  end)
end

## Whether `req` expects JSON (`/api/...` or explicit `Accept: application/json` without `X-Inertia`).
fn wants_json?(req: Api.Request) : Bool
  return true if req.path.starts_with?("/api/")
  accept = (req.header("Accept") or "").ascii_lowercase
  accept.contains?("application/json") and not Inertia.request?(req)
end

## Enforces `X-XSRF-TOKEN` on state-changing requests authenticated via cookie session.
## Bearer-authenticated Agent requests have `session == None` and bypass CSRF checks.
fn require_session_csrf(req: Api.Request, auth: AuthContext) : Result(Unit, AppError)
  case auth.session
    None: Ok(Unit)
    Some(sess):
      if Csrf.safe_method?(req) or Csrf.verify(req, sess)
        Ok(Unit)
      else
        Error(Forbidden(reason: "invalid or missing X-XSRF-TOKEN header"))
      end
  end
end

fn principal_public_json(p: Principal) : Json
  Json.Object({
    "id": Json.String(p.id),
    "kind": p.kind.to_json,
    "handle": Json.String(p.handle),
    "display_name": Json.String(p.display_name),
    "email": p.email.to_json,
    "avatar_url": p.avatar_url.to_json,
    "role": p.role.to_json
  })
end

## Computes Inertia shared props (`auth`, `flash`) and whether the flash cookie must be cleared.
fn shared_props(req: Api.Request, auth: Option(AuthContext), key: Bytes) : (Map(Text, Json), Bool)
  (flash, had_flash?) = Flash.take(req, key)
  auth_json = case auth
    None: Json.Null
    Some(a): principal_public_json(a.principal)
  end
  ({"auth": auth_json, "flash": flash.to_json}, had_flash?)
end

## Computes Inertia shared props using `resolve_app_secret_key` (safe in uninitialized Solo/Personal mode).
fn shared_props_for(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  (Map(Text, Json), Bool),
  AppError
)
  case try resolve_app_secret_key(rf, env)
    Some(key): Ok(shared_props(req, auth, key))
    None:
      auth_json = case auth
        None: Json.Null
        Some(a): principal_public_json(a.principal)
      end
      Ok(({"auth": auth_json, "flash": Flash.empty().to_json}, false))
  end
end

fn safe_return_to(raw: Option(Text)) : Text
  case raw
    None: "/"
    Some(s):
      trimmed = s.trim
      bad_chars? = trimmed.contains?("\r") or trimmed.contains?("\n")
      if trimmed.starts_with?("/") and not trimmed.starts_with?("//") and not bad_chars?
        trimmed
      else
        "/"
      end
  end
end

## Redirects unauthenticated browser requests (`/auth/solo/login` on loopback Solo, else `/login`) or returns 401 for JSON.
fn guest_redirect_or_401(req: Api.Request, env: Env) : Result(Api.Response, AppError)
  if wants_json?(req)
    return Error(Unauthenticated)
  end
  mode = try auth_mode(env)
  if mode == SoloMode and loopback_request?(req, env)
    ret = safe_return_to(Some(req.path))
    Ok(Inertia.redirect("/auth/solo/login?return_to=#{ret}"))
  else
    Ok(Inertia.redirect("/login"))
  end
end

fn map_oidc_error(err: Oidc.OidcError) : AppError
  case err
    Oidc.EmailDomainNotAllowed(email: _) | Oidc.EmailUnverified(email: _) | Oidc.IdentityMismatch(
      reason: _
    ): Forbidden(reason: err.to_text)
    Oidc.MissingStateCookie | Oidc.InvalidStateCookie | Oidc.StateMismatch | Oidc.StateExpired | Oidc
      .MissingCode | Oidc.ProviderError(code: _, description: _): BadInput(reason: err.to_text)
    Oidc.InvalidConfig(reason: _) | Oidc.InvalidKey | Oidc.CryptoFailed(_) | Oidc.HttpFailed(_) | Oidc
      .UnexpectedStatus(status: _, body: _) | Oidc.BadPayload(reason: _): ServerFailed(
        reason: err.to_text
      )
  end
end

fn authenticate_bearer(raw_tok: Text, rf: ReadFiles, now: Time) : Result(AuthContext, AppError)
  token_hash = Crypto.sha256(raw_tok.bytes).to_hex
  res = Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      tok_pair = try Table.lookup_unique(
        store,
        Db.agent_tokens_table(),
        Db.agent_tokens_by_hash(),
        token_hash
      ).map_error(Db.map_table_error)
      tok = case tok_pair
        Some((_tid, t)): t
        None: return Error(Unauthenticated)
      end
      if tok.revoked_at != None
        return Error(Unauthenticated)
      end
      case tok.expires_at
        Some(exp) if now >= exp: return Error(Unauthenticated)
        Some(_) | None: Unit
      end

      principal = case try Table.get(store, Db.principals_table(), tok.principal_id).map_error(
        Db.map_table_error
      )
        Some(p) if not p.suspended: p
        Some(_) | None: return Error(Unauthenticated)
      end

      grant = case Db.verify_grant_chain_read_only(store, tok.grant_id, now)
        Ok(g): g
        Error(_): return Error(Unauthenticated)
      end

      Ok(
        AuthContext(
          principal: principal,
          grant_id: grant.id,
          session: None,
          allowed_collections: grant.allowed_views,
          allowed_actions: grant.allowed_actions
        )
      )
    end
  )
  case res
    Ok(ctx): Ok(ctx)
    Error(err): Error(err)
  end
end

## Read-only dual authenticator: accepts either `Authorization: Bearer vlm_ag_...` or `vellum_session` cookie.
fn authenticate(req: Api.Request, rf: ReadFiles, clock: Clock, env: Env) : Result(
  AuthContext,
  AppError
)
  now = clock.now
  if Policy.extract_bearer_token(req) is Some(raw_tok)
    return authenticate_bearer(raw_tok, rf, now)
  end

  key = case try resolve_app_secret_key(rf, env)
    Some(k): k
    None: return Error(Unauthenticated)
  end
  scfg = session_cfg(env)
  maybe_sess = try Sessions.load_read_only(req, rf, Db.sessions_db_path, clock, key, scfg).map_error(
    fn(_e) ServerFailed(reason: "session storage read failed") end
  )
  sess = case maybe_sess
    Some(s): s
    None: return Error(Unauthenticated)
  end

  Ledger.read_locked(
    rf,
    Db.ledger_db_path,
    Db.vellum_schema(),
    Db.map_ledger_error,
    fn(db)
      store = Ledger.store(db)
      principal = case try Table.get(store, Db.principals_table(), sess.member_id).map_error(
        Db.map_table_error
      )
        Some(p) if not p.suspended: p
        Some(_) | None: return Error(Unauthenticated)
      end

      grant = case Db.verify_grant_chain_read_only(store, principal.root_grant_id, now)
        Ok(g): g
        Error(_): return Error(Unauthenticated)
      end

      Ok(
        AuthContext(
          principal: principal,
          grant_id: grant.id,
          session: Some(sess),
          allowed_collections: grant.allowed_views,
          allowed_actions: grant.allowed_actions
        )
      )
    end
  )
end

## `GET /login` — Renders the authentication screen for guests (`solo` | `personal` | `team`), or redirects signed-in users to `/`.
fn show_login(req: Api.Request, auth: Option(AuthContext), rf: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  if auth != None
    return Ok(Inertia.redirect("/"))
  end
  mode = try auth_mode(env)
  icfg = try load_inertia_config(rf, env)
  if Inertia.check_version(req, icfg) is Some(ver_res)
    return Ok(ver_res)
  end
  (shared, had_flash?) = try shared_props_for(req, None, rf, env)
  res = Inertia.render(
    req,
    icfg,
    "Auth/Login",
    {"auth_mode": Json.String(auth_mode_text(mode)), "oidc_enabled": Json.Boolean(mode == TeamMode)},
    shared
  )
  Ok(Flash.clear_if_present(res, had_flash?, secure_cookies?(env)))
end

fn finish_local_owner_login(
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  key: Bytes,
  raw_email: Text,
  display_name: Text,
  action_name: Text,
  reason: Text,
  return_to: Text,
  json_reply?: Bool
) : Result(Api.Response, AppError)
  norm_email = Auth.normalize_email(raw_email)
  now = clock.now
  new_pid = "usr_#{Id.ulid(rng, clock)}"
  new_gid = "gr_#{Id.ulid(rng, clock)}"
  meta = Ledger.WriteMeta(principal: norm_email, action: action_name, reason: reason, at: now)
  audit_payload = Json.Object({"email": Json.String(norm_email), "action": Json.String(action_name)})
  principal = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    reason,
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      Db.tx_upsert_human_principal(tx, norm_email, display_name, None, new_pid, new_gid, now)
    end
  )
  scfg = session_cfg(env)
  (sess, cookie_val) = try Sessions.create(
    files,
    Db.sessions_db_path,
    rng,
    clock,
    key,
    principal.id,
    scfg
  ).map_error(fn(_e) ServerFailed(reason: "failed to create session") end)

  if json_reply?
    base = Api.encoded_json_response(
      200,
      Json.Object({"ok": Json.Boolean(true), "redirect_to": Json.String(return_to)})
    ).with_header("Content-Type", "application/json; charset=utf-8")
    Ok(Auth.login_response(base, sess, cookie_val, scfg))
  else
    redir0 = Inertia.redirect(return_to)
    redir1 = Auth.login_response(redir0, sess, cookie_val, scfg)
    Ok(Flash.attach(redir1, rng, key, Flash.with_notice("Signed in"), secure_cookies?(env)))
  end
end

## `GET|POST /auth/solo/login` — Auto-provisions loopback local Owner session in `VELLUM_MODE=solo`.
fn solo_login(
  req: Api.Request,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  mode = try auth_mode(env)
  if mode != SoloMode
    return Error(Forbidden(reason: "solo login is only available in VELLUM_MODE=solo"))
  end
  try require_solo_loopback(req, env)
  key = try ensure_app_secret_key(files, rng, env)
  email = case env.get("VELLUM_OWNER_EMAIL")
    Some(e) if not e.trim.empty?: e.trim
    Some(_) | None: "owner@localhost"
  end
  display_name = case env.get("VELLUM_OWNER_NAME")
    Some(n) if not n.trim.empty?: n.trim
    Some(_) | None: "Local Owner"
  end
  ret = safe_return_to(req.query_param("return_to"))
  finish_local_owner_login(
    files,
    rng,
    clock,
    env,
    key,
    email,
    display_name,
    "auth.solo_login",
    "loopback solo workspace sign in",
    ret,
    false
  )
end

## `POST /auth/personal/login` — Authenticates single Workspace Owner via configured passphrase/scrypt hash in `VELLUM_MODE=personal`.
fn personal_login(
  _req: Api.Request,
  input: PersonalLoginInput,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  mode = try auth_mode(env)
  if mode != PersonalMode
    return Error(Forbidden(reason: "personal login is only available in VELLUM_MODE=personal"))
  end
  hash_opt = case env.get("VELLUM_PERSONAL_PASSPHRASE_HASH")
    Some(h) if not h.trim.empty?: Some(h.trim)
    Some(_) | None: None
  end
  plain_opt = case env.get("VELLUM_PERSONAL_PASSPHRASE")
    Some(p) if not p.trim.empty?: Some(p.trim)
    Some(_) | None: None
  end

  verified? = case (hash_opt, plain_opt)
    (Some(phc), _): Auth.verify_password(input.passphrase, phc)
    (None, Some(expected)):
      if expected.bytes.size < 8
        return Error(
          ServerFailed(reason: "VELLUM_PERSONAL_PASSPHRASE must be at least 8 characters")
        )
      end
      Crypto.constant_time_eq?(
        Crypto.sha256(input.passphrase.bytes),
        Crypto.sha256(expected.bytes)
      )
    (None, None):
      return Error(
        ServerFailed(
          reason: "VELLUM_MODE=personal requires VELLUM_PERSONAL_PASSPHRASE_HASH or VELLUM_PERSONAL_PASSPHRASE"
        )
      )
  end
  if not verified?
    return Error(Unauthenticated)
  end

  key = try ensure_app_secret_key(files, rng, env)
  email = case env.get("VELLUM_OWNER_EMAIL")
    Some(e) if not e.trim.empty?: e.trim
    Some(_) | None: "owner@vellum.local"
  end
  display_name = case env.get("VELLUM_OWNER_NAME")
    Some(n) if not n.trim.empty?: n.trim
    Some(_) | None: "Workspace Owner"
  end
  ret = safe_return_to(input.return_to)
  finish_local_owner_login(
    files,
    rng,
    clock,
    env,
    key,
    email,
    display_name,
    "auth.personal_login",
    "personal passphrase workspace sign in",
    ret,
    true
  )
end

## `GET /auth/oidc/login` — Redirects the browser to the configured OIDC provider with PKCE S256 & AEAD state.
fn start_oidc_login(req: Api.Request, rng: SecureRandom, clock: Clock, env: Env) : Result(
  Api.Response,
  AppError
)
  key = try app_secret_key(env)
  cfg = try oidc_config(env)
  Oidc.start_login(cfg, key, rng, clock, req.query_param("return_to")).map_error(map_oidc_error)
end

## `GET /auth/oidc/callback` — Completes OIDC PKCE callback, JIT-provisions human `Principal` + root `Grant`,
## opens a MoDB session, and sets `vellum_session` + `XSRF-TOKEN` cookies.
fn oidc_callback(
  req: Api.Request,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Result(Api.Response, AppError)
  key = try app_secret_key(env)
  cfg = try oidc_config(env)
  identity = try Oidc.complete_callback(cfg, req, key, clock, net).map_error(map_oidc_error)

  norm_email = Auth.normalize_email(identity.email)
  display_name = case identity.name
    Some(n) if not n.trim.empty?: n.trim
    Some(_) | None: (norm_email.split("@").first or "Vellum User")
  end
  now = clock.now
  new_pid = "usr_#{Id.ulid(rng, clock)}"
  new_gid = "gr_#{Id.ulid(rng, clock)}"

  meta = Ledger.WriteMeta(
    principal: norm_email,
    action: "auth.oidc_login",
    reason: "OIDC callback JIT sign in",
    at: now
  )
  audit_payload = Json.Object({
    "provider_id": Json.String(identity.provider_id),
    "issuer": Json.String(identity.issuer),
    "subject": Json.String(identity.subject),
    "email": Json.String(norm_email)
  })
  avatar = identity.picture
  principal = try Ledger.transact_locked(
    files,
    Db.ledger_db_path,
    Db.vellum_schema(),
    meta,
    "signed in #{norm_email} via OIDC",
    audit_payload,
    Db.map_ledger_error,
    fn(tx)
      Db.tx_upsert_human_principal(tx, norm_email, display_name, avatar, new_pid, new_gid, now)
    end
  )

  scfg = session_cfg(env)
  (sess, cookie_val) = try Sessions.create(
    files,
    Db.sessions_db_path,
    rng,
    clock,
    key,
    principal.id,
    scfg
  ).map_error(fn(_e) ServerFailed(reason: "failed to create session") end)

  redir0 = Inertia.redirect(identity.return_to)
  redir1 = Oidc.clear_state_cookie(redir0, cfg)
  redir2 = Auth.login_response(redir1, sess, cookie_val, scfg)
  Ok(Flash.attach(redir2, rng, key, Flash.with_notice("Signed in"), secure_cookies?(env)))
end

## `POST /logout` — Verifies CSRF when a session exists, revokes the MoDB session, and clears cookies.
fn post_logout(req: Api.Request, auth: Option(AuthContext), files: Files, env: Env) : Result(
  Api.Response,
  AppError
)
  case auth
    Some(a):
      try require_session_csrf(req, a)
      case a.session
        Some(sess): _u = try Sessions.revoke(files, Db.sessions_db_path, sess.id).map_error(
          Db.map_table_error
        )
        None: Unit
      end
    None: Unit
  end
  scfg = session_cfg(env)
  Ok(Auth.logout_response(Inertia.redirect("/login"), scfg))
end
