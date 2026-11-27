# Vellum Deployment & Operations Runbook (Render -> AWS / Bare Metal)

Vellum runs as a single pure-Mo binary (`mo serve`) backed by embedded MoDB B+Tree files (`vellum.modb`, `sessions.modb`) and customer-owned S3 object storage.

---

## 1. Google Workspace OIDC Configuration

1. In Google Cloud Console -> **APIs & Services -> Credentials**, create an **OAuth 2.0 Web Client**.
2. Add your Authorized Redirect URI:
   - Production: `https://<your-domain>/auth/oidc/callback`
   - Local dev: `http://127.0.0.1:8080/auth/oidc/callback`
3. Configure environment variables:

```bash
VELLUM_OIDC_PROVIDER_ID=google
VELLUM_OIDC_CLIENT_ID=<google-client-id>.apps.googleusercontent.com
VELLUM_OIDC_CLIENT_SECRET=<google-client-secret>
VELLUM_OIDC_REDIRECT_URI=https://<your-domain>/auth/oidc/callback
VELLUM_OIDC_ALLOWED_DOMAINS=your-org.edu
VELLUM_OIDC_REQUIRE_VERIFIED_EMAIL=1
# Optional session lifetime in seconds (28800 = 8h recommended for FERPA workspaces)
VELLUM_SESSION_TTL_SECONDS=28800
```

When `VELLUM_OIDC_PROVIDER_ID=google`, Vellum automatically configures Google's OpenID Connect endpoints (`accounts.google.com`, `oauth2.googleapis.com`, `openidconnect.googleapis.com`, `www.googleapis.com/oauth2/v3/certs`), hints `&hd=<domain>` on the login redirect when a single domain (or `VELLUM_OIDC_GOOGLE_HD`) is configured, and enforces `email_verified=true` plus `VELLUM_OIDC_ALLOWED_DOMAINS` fail-closed on callback.

---

## 2. Render Blueprint Deployment (Single Stateful Instance + AWS S3)

1. Provision an AWS S3 bucket for attachments and encrypted database backups (block public access, enable bucket versioning & lifecycle retention).
2. Connect the repository to Render using [`render.yaml`](../render.yaml):
   - Attaches a persistent disk at `/var/lib/vellum` for `vellum.modb` and `sessions.modb`.
   - Exposes `GET /healthz` health checks and binds dynamically to `${PORT:-8080}`.
3. Populate the secrets (`VELLUM_SECRET_KEY`, `VELLUM_BACKUP_KEY`, `VELLUM_OIDC_CLIENT_ID`, `VELLUM_OIDC_CLIENT_SECRET`, `VELLUM_OIDC_REDIRECT_URI`, `VELLUM_OIDC_ALLOWED_DOMAINS`, `VELLUM_S3_*`, `VELLUM_AI_API_KEY`).
4. Note: Because Render attaches persistent disks to a single container instance, schedule automated encrypted backups using a periodic job inside that instance or host cron hitting S3 directly.

---

## 3. Encrypted S3 Snapshots & Verified Restore Drills (`backup.mo`)

Vellum exports consistent lock-coordinated `Modb.Export` snapshots (safe under live `mo serve` traffic), encrypts them client-side with **AES-256-GCM** using `VELLUM_BACKUP_KEY` (or a SHA-256 domain-separated subkey of `VELLUM_SECRET_KEY`), and uploads/verifies them against S3 via AWS SigV4.

### Create an Encrypted S3 Backup

```bash
mo run --root /var/lib/vellum /app/backup.mo -- backup --db vellum.modb
# Or local air-gapped encrypted file:
mo run --root /var/lib/vellum /app/backup.mo -- backup --db vellum.modb --out snapshot.enc.json
```

### Run a Non-Destructive Restore Verification Drill

Downloads and decrypts the snapshot into a temporary `.modb`, runs full `Modb.verify` B+Tree checksums and `Modb.Ledger.verify_all` audit hash-chain verification, prints JSON telemetry, and removes the temporary drill database:

```bash
mo run --root /var/lib/vellum /app/backup.mo -- verify --key backups/vellum/20261127-190000Z-tx42.vellum.enc.json
```

### Restore Into a Fresh Database File

```bash
mo run --root /var/lib/vellum /app/backup.mo -- restore \
  --key backups/vellum/20261127-190000Z-tx42.vellum.enc.json \
  --out restored.modb
```

---

## 4. AWS EC2 / Bare-Metal Portability Runbook

Because all state lives in portable `.modb` files + S3 objects:

1. Run a recent encrypted S3 backup (`mo run --root /var/lib/vellum backup.mo -- backup`) on the source host.
2. On the destination Ubuntu/Debian server with `mo` installed and repository checked out (plus `npm run build` in `frontend/`):

```bash
mkdir -p /var/lib/vellum
mo run --root /var/lib/vellum /opt/vellum/backup.mo -- restore \
  --key backups/vellum/<latest>.vellum.enc.json \
  --out vellum.modb
```

3. Start `mo serve /opt/vellum/main.mo --bind 127.0.0.1 --port 8080 --workers 4 --data /var/lib/vellum` behind Caddy/Nginx TLS with a daily systemd timer running `mo run --root /var/lib/vellum /opt/vellum/backup.mo -- backup --db vellum.modb`.
