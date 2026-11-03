# CertTrack deploy runbook

How to stand up, deploy, back up and rebuild CertTrack on its $0 stack: one Oracle Always Free Ampere A1 VM running the app, kamal-proxy and Postgres 17 (Kamal 2). Files and backups go to Cloudflare R2, mail goes through Resend, and AI runs on Cloudflare Workers AI. Do the sections in order the first time. Expect about an hour, most of it waiting on account sign-ups and DNS.

| What | Where it lives |
| --- | --- |
| App container (Puma + Solid Queue), kamal-proxy (TLS) | Oracle VM, Docker |
| Postgres 17 data | Oracle VM, `~/cert_track-db/data` (Kamal accessory `cert_track-db`) |
| Certificate files | R2 bucket `certtrack-files` (private) |
| Nightly encrypted database dumps, newest 14 | R2 bucket `certtrack-backups` (private) |
| Docker images | `ghcr.io/austenhughes1/cert_track` (private) |
| Deploy config | `config/deploy.yml`, `.kamal/secrets`, `Dockerfile` |

## 0. On your machine

- Ruby 3.4.12 and `bundle install` in the repo, so `bin/kamal` works.
- The Docker CLI with the buildx plugin (`docker buildx version`), and a running local Docker daemon for `kamal registry login`. The image itself is built on the VM (the VM is arm64; this machine is x86), so the local daemon does almost no work.
- `config/master.key`. Keep a copy in your password manager. It decrypts the Rails credentials, which hold the Active Record encryption keys and the backup encryption key. **Without it, the backups cannot be decrypted.**
- SSH key. Create one if you don't have one:

  ```bash
  ssh-keygen -t ed25519 -C "certtrack-deploy" -f ~/.ssh/id_ed25519
  ```

## 1. Oracle Cloud VM

1. Create an Oracle Cloud account with a **US West** home region (Phoenix or San Jose). You can't change the home region later.
2. **Upgrade to Pay As You Go**: Billing & Cost Management → Upgrade and Manage Payment → Pay As You Go. Always Free resources stay free. PAYG also makes "Out of host capacity" errors for A1 much less likely, and it may exempt the VM from idle reclamation (see section 11).
3. Add a guard against surprise charges: Billing & Cost Management → Budgets → Create Budget, amount **$1**, with an email alert at 100%.
4. Create the instance: Compute → Instances → Create instance.
   - **Image:** Canonical Ubuntu **24.04** (the aarch64 build is picked automatically for Ampere shapes).
   - **Shape:** Ampere → `VM.Standard.A1.Flex`, **2 OCPU, 12 GB** memory. That is the whole Always Free A1 allowance since June 2026, so don't go higher.
   - **Networking:** create a new VCN with a public subnet, and tick "Automatically assign public IPv4 address".
   - **SSH keys:** upload `~/.ssh/id_ed25519.pub`.
   - **Boot volume:** custom size **100 GB** (the Always Free allowance is 200 GB in total).
5. Note the instance's **public IP**. This guide calls it `KAMAL_HOST`.
6. **Open 80 and 443 in the security list**: Networking → Virtual cloud networks → your VCN → the public subnet → its security list (Default Security List) → Add Ingress Rules. Add two stateful rules, source CIDR `0.0.0.0/0`, IP protocol TCP, destination port `80`, then the same for `443`. Port 22 is already open. If your IP is static, you can narrow the port 22 rule to it.
7. **Open 80 and 443 in the VM's own firewall.** Oracle's Ubuntu images ship iptables rules that REJECT everything except SSH, even when the security list allows the traffic. Do this *before* Docker is installed (section 8), so the saved rules don't capture Docker's chains:

   ```bash
   ssh ubuntu@<public-ip>         # accept the host key; Kamal and the remote builder need it in known_hosts

   sudo apt-get update && sudo apt-get -y full-upgrade

   sudo iptables -L INPUT -n --line-numbers     # last rule: REJECT all ... reject-with icmp-host-prohibited
   REJECT_AT=$(sudo iptables -L INPUT -n --line-numbers | awk '$2 == "REJECT" { print $1; exit }')
   sudo iptables -I INPUT "${REJECT_AT:?no REJECT rule in INPUT}" -p tcp -m state --state NEW --dport 443 -j ACCEPT
   sudo iptables -I INPUT "$REJECT_AT" -p tcp -m state --state NEW --dport 80 -j ACCEPT
   sudo iptables -L INPUT -n --line-numbers     # 80 and 443 now sit above the REJECT rule

   # Persist across reboots (writes /etc/iptables/rules.v4).
   command -v netfilter-persistent || sudo apt-get install -y iptables-persistent
   sudo netfilter-persistent save

   sudo reboot
   ```

   After the reboot, run `sudo iptables -L INPUT -n` again to confirm the rules survived. Don't enable `ufw`. If you change these rules later, after Docker is installed, edit `/etc/iptables/rules.v4`, then run `sudo netfilter-persistent reload && sudo systemctl restart docker`. The reload flushes Docker's NAT rules, and restarting Docker puts them back.

## 2. GitHub Container Registry token

GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token. Fine-grained tokens don't work with GHCR.

- Scope: **`write:packages`** (it includes `read:packages`).
- Expiration: a year, with a calendar reminder to rotate it.
- This becomes `KAMAL_REGISTRY_PASSWORD`. The package `ghcr.io/austenhughes1/cert_track` is created private on the first push. Keep it private.

## 3. Cloudflare R2 (files and backups)

1. Cloudflare dashboard → **R2 Object Storage**. Enabling R2 asks for a payment method; usage stays inside the free tier.
2. Create bucket **`certtrack-files`**: Standard storage class, location Automatic (or the Western North America hint). Leave **Public access off**: no r2.dev URL and no custom domain. The app hands out presigned URLs that expire in 5 minutes.
3. Create bucket **`certtrack-backups`** the same way, also private. Don't add a lifecycle rule shorter than 14 days, because the backup job does its own pruning to the newest 14.
4. **R2 API token:** R2 → Manage API tokens → Create API token.
   - Permission: **Object Read & Write**.
   - Scope: **Apply to specific buckets only**, `certtrack-files` and `certtrack-backups`.
   - Copy the **Access Key ID** into `R2_ACCESS_KEY_ID` and the **Secret Access Key** into `R2_SECRET_ACCESS_KEY`. Cloudflare shows the secret only once.
5. **Account ID:** the 32-hex-character ID shown on the R2 overview page (it's also in the S3 endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`). It goes into `R2_ACCOUNT_ID`, and the same value into `CLOUDFLARE_ACCOUNT_ID`.
6. **CORS on `certtrack-files`** (direct uploads from the browser PUT straight to R2): bucket → Settings → CORS Policy → Add CORS policy → **JSON** tab. Paste the contents of [`config/r2-cors.json`](../config/r2-cors.json), then Save. The policy allows `PUT`, `GET` and `HEAD` from `https://certs.abaventures.net`, with the headers Active Storage sends (`Content-Type`, `Content-MD5`, `Content-Disposition`). If the dashboard rejects the `x-amz-*` wildcard, delete that entry; CertTrack never sends `x-amz-meta-*` headers. The backups bucket gets no CORS policy.

   Wrangler alternative (it takes a different JSON shape):

   ```bash
   cat > /tmp/r2-cors-wrangler.json <<'JSON'
   { "rules": [ { "allowed": { "origins": ["https://certs.abaventures.net"],
                               "methods": ["PUT", "GET", "HEAD"],
                               "headers": ["Content-Type", "Content-MD5", "Content-Disposition", "x-amz-*"] },
                  "exposeHeaders": ["ETag"], "maxAgeSeconds": 3600 } ] }
   JSON
   npx wrangler r2 bucket cors set certtrack-files --file /tmp/r2-cors-wrangler.json
   npx wrangler r2 bucket cors list certtrack-files
   ```

   Check the policy (changes can take about 30 seconds to apply):

   ```bash
   curl -si -X OPTIONS "https://certtrack-files.$R2_ACCOUNT_ID.r2.cloudflarestorage.com/cors-check" \
     -H "Origin: https://certs.abaventures.net" \
     -H "Access-Control-Request-Method: PUT" \
     -H "Access-Control-Request-Headers: content-type,content-md5,content-disposition" | grep -i '^access-control'
   # expect: access-control-allow-origin: https://certs.abaventures.net
   ```

## 4. Cloudflare Workers AI token

My Profile → API Tokens → Create Token → template **Workers AI** (Account · Workers AI · Read and Edit). Under Account Resources, pick your account. The token goes into `CLOUDFLARE_AI_API_TOKEN`. Check it:

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/models/search?per_page=1" \
  -H "Authorization: Bearer $CLOUDFLARE_AI_API_TOKEN" | head -c 200    # "success":true
```

## 5. Resend (email from notify.abaventures.net)

1. Create a Resend account → Domains → Add domain → **`notify.abaventures.net`** (region us-east-1 is fine).
2. Add the DNS records Resend shows, in the abaventures.net zone. All of them sit on the `notify` subdomain, so the main domain's existing mail setup (MX, SPF, DKIM) is untouched. Resend shows names relative to the zone; copy names and values exactly. They look like this:

   | Type | Name | Value |
   | --- | --- | --- |
   | TXT (DKIM) | `resend._domainkey.notify` | `p=MIGfMA0...` (long key from Resend) |
   | MX | `send.notify` | `feedback-smtp.us-east-1.amazonses.com`, priority 10 |
   | TXT (SPF) | `send.notify` | `v=spf1 include:amazonses.com ~all` |
   | TXT (DMARC, recommended) | `_dmarc.notify` | `v=DMARC1; p=none;` |

3. Click **Verify** and wait for "Verified" (minutes to a few hours).
4. API Keys → Create API key, permission **Sending access**, restricted to `notify.abaventures.net`. It goes into `RESEND_API_KEY`.
5. Nothing else to configure. Production sends over SMTP: `smtp.resend.com:587`, STARTTLS, user `resend`, password `RESEND_API_KEY` (`config/environments/production.rb`), from `MAIL_FROM`. Oracle blocks outbound port 25, but 587 is open. The free plan allows 100 emails/day and 3,000/month.
6. **The office inbox.** `notify.abaventures.net` only sends and can't receive mail. Crew expiry notices ask crew to reply with their renewed certificate, so their Reply-To is `OFFICE_EMAIL` (`config/deploy.yml`, set to `austen@abaventures.net`). Make sure that address is a real, monitored inbox on the main domain, such as a Google Workspace user, group or alias, and send it a test email. If it isn't, change `OFFICE_EMAIL` before crew notices go out.

## 6. DNS for the app

Create an **A record**: `certs.abaventures.net` → `KAMAL_HOST`. If the zone is on Cloudflare, set the record to **DNS only (grey cloud)**. kamal-proxy gets its own Let's Encrypt certificate on the VM, and Cloudflare's proxy would intercept the challenge. Wait until it resolves:

```bash
dig +short certs.abaventures.net     # must print KAMAL_HOST before kamal setup
```

## 7. Export the deploy environment

Kamal reads every secret from your shell (`.kamal/secrets` maps names to `$VARS`). `RAILS_MASTER_KEY` is read from `config/master.key`. Keep the values in a file **outside the repo**, and copy them into your password manager too:

```bash
mkdir -p ~/.config/certtrack && touch ~/.config/certtrack/deploy.env && chmod 600 ~/.config/certtrack/deploy.env
cat > ~/.config/certtrack/deploy.env <<'ENV'
export KAMAL_HOST=203.0.113.10                 # VM public IP (section 1)
export KAMAL_REGISTRY_PASSWORD=ghp_xxx         # GitHub classic PAT, write:packages (section 2)
export POSTGRES_PASSWORD=xxx                   # generate ONCE: openssl rand -hex 32
export R2_ACCOUNT_ID=xxx                       # section 3
export R2_ACCESS_KEY_ID=xxx
export R2_SECRET_ACCESS_KEY=xxx
export RESEND_API_KEY=re_xxx                   # section 5
export CLOUDFLARE_ACCOUNT_ID=xxx               # same value as R2_ACCOUNT_ID
export CLOUDFLARE_AI_API_TOKEN=xxx             # section 4
# export ANTHROPIC_API_KEY=sk-ant-xxx          # optional, see section 12
ENV
```

Before any kamal command, from the repo root:

```bash
source ~/.config/certtrack/deploy.env
for v in KAMAL_HOST KAMAL_REGISTRY_PASSWORD POSTGRES_PASSWORD R2_ACCOUNT_ID R2_ACCESS_KEY_ID \
         R2_SECRET_ACCESS_KEY RESEND_API_KEY CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_AI_API_TOKEN; do
  [ -n "${!v}" ] || echo "MISSING: $v"
done; [ -s config/master.key ] || echo "MISSING: config/master.key"
bin/kamal config > /dev/null && echo "deploy.yml parses"
```

An unset variable becomes an **empty** secret without any warning, so don't skip the check. Don't share the output of `bin/kamal secrets print`, because it prints the secret values.

`POSTGRES_PASSWORD` only takes effect when Postgres first initializes its data directory. To change it later, see section 10.

**All environment variables.** This mirrors the table in PLAN.md, plus the two deploy-only variables.

| Variable | Set in | Value |
| --- | --- | --- |
| `KAMAL_HOST` | your shell | VM public IP. Used for the server, the db accessory host and the remote builder |
| `KAMAL_REGISTRY_PASSWORD` | your shell | GitHub classic PAT with `write:packages` |
| `RAILS_MASTER_KEY` | `config/master.key` | Rails credentials (encryption keys, `backup_encryption_key`) |
| `POSTGRES_PASSWORD` | your shell | Postgres accessory superuser `cert_track`; the app and backups use it too |
| `APP_HOST` | `config/deploy.yml` | `certs.abaventures.net` (email links, allowed host) |
| `SOLID_QUEUE_IN_PUMA` | `config/deploy.yml` | `1` |
| `DB_HOST` | `config/deploy.yml` | `cert_track-db` (the accessory on Kamal's docker network) |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | your shell | R2 credentials |
| `R2_BUCKET`, `R2_BACKUP_BUCKET` | `config/deploy.yml` | `certtrack-files`, `certtrack-backups` |
| `RESEND_API_KEY` | your shell | Resend API key (SMTP password) |
| `MAIL_FROM` | `config/deploy.yml` | `CertTrack <certtrack@notify.abaventures.net>` |
| `OFFICE_EMAIL` | `config/deploy.yml` | `austen@abaventures.net`, the Reply-To on crew expiry notices. It must be a real, monitored inbox on the main domain: `notify.abaventures.net` is send-only, so replies sent there bounce |
| `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_AI_API_TOKEN` | your shell | Workers AI |
| `AI_PROVIDER` | `config/deploy.yml` | `workers_ai` (or `ollama`, `anthropic`) |
| `EXTRACTION_MODEL`, `EXTRACTION_VISION_MODEL` | `config/deploy.yml` | Set after the Phase 3 accuracy spike (commented out until then) |
| `CHAT_MODEL` | `config/deploy.yml` | Set after `certtrack:eval_chat` in Phase 4 |
| `AI_DAILY_NEURON_BUDGET` | `config/deploy.yml` | `9000` |
| `AUTO_ACCEPT_ENABLED` | `config/deploy.yml` | `false` until you trust the import output |
| `ANTHROPIC_API_KEY` | your shell (optional) | Paid fallback only; see section 12 |
| `WEB_CONCURRENCY`, `JOB_CONCURRENCY` | `config/deploy.yml` | `2` Puma workers, `1` Solid Queue process (sized for 2 OCPU) |

To change a `config/deploy.yml` value, edit it, commit, and run `bin/kamal deploy`. To change a secret, update `deploy.env`, `source` it, and run `bin/kamal deploy`. Kamal rewrites the container env on every deploy.

## 8. First deploy

Kamal builds from a **git clone of HEAD**, so commit everything first; uncommitted changes are ignored.

```bash
source ~/.config/certtrack/deploy.env

bin/kamal server bootstrap     # installs Docker on the VM (ubuntu has passwordless sudo) and adds ubuntu to the docker group
bin/kamal registry login       # logs in to GHCR locally and on the VM (the VM's docker pushes and pulls the image)
bin/kamal setup                # builds on the VM, pushes, boots kamal-proxy, Postgres 17 and the app
```

The first build takes about 10 minutes on two Ampere cores. Here is what `kamal setup` does:

1. It builds the arm64 image natively on the VM (`builder.remote`) and pushes it to GHCR.
2. It boots kamal-proxy on 80/443 and the `cert_track-db` accessory (`postgres:17`, data in `~/cert_track-db/data`, port bound to `127.0.0.1` only).
3. It starts the app. `bin/docker-entrypoint` runs `bin/rails db:prepare` whenever the container command is `./bin/rails server` (the image default). Because `POSTGRES_USER=cert_track` is a superuser in the postgres image, `db:prepare` creates `cert_track_production`, `_cache`, `_queue` and `_cable` and loads their schemas. On later deploys it runs pending migrations.
4. kamal-proxy switches traffic over once `/up` returns 200, and fetches the Let's Encrypt certificate on the first HTTPS request.

If the first deploy times out, Postgres was probably still initializing when the app booted. Run `bin/kamal deploy` again. The app container restarts on its own, so a second try is all it needs.

**Create the first admin:**

```bash
bin/kamal app exec -i "bin/rails certtrack:create_admin"
# or non-interactively: bin/kamal app exec -i "bin/rails certtrack:create_admin EMAIL=you@abaventures.net NAME='Your Name'"
# (without a terminal it generates a password and prints it once)
```

**Verify:**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://certs.abaventures.net/up      # 200
curl -sSI http://certs.abaventures.net/ | head -3                               # 301 to https://
echo | openssl s_client -connect certs.abaventures.net:443 -servername certs.abaventures.net 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates                                 # issuer: Let's Encrypt
```

Then sign in at https://certs.abaventures.net as the admin, and run two smoke tests:

```bash
# R2: write, read back and delete a test object in certtrack-files
bin/kamal app exec 'bin/rails runner "s = ActiveStorage::Blob.service; s.upload(%(smoke-test), StringIO.new(%(ok))); puts s.download(%(smoke-test)); s.delete(%(smoke-test))"'

# Email: sends a real password-reset email to the admin (the link is harmless if unused)
bin/kamal app exec 'bin/rails runner "PasswordsMailer.reset(User.find_by!(email_address: %(you@abaventures.net))).deliver_now"'
```

In Gmail, open the message → Show original, and check for **SPF: PASS, DKIM: PASS, DMARC: PASS**.

Last, add a free uptime monitor (UptimeRobot or Better Stack, for example) on `https://certs.abaventures.net/up` every 5 minutes. It also tells you if Oracle reclaims the VM.

## 9. Backups and the restore drill

- `Backups::DatabaseJob` runs nightly at 03:00 America/Denver (`config/recurring.yml`). It runs `pg_dump` (plain SQL, `--clean --if-exists`), gzips the dump, encrypts it with AES-256-GCM using `backup_encryption_key` from the credentials, uploads it to `certtrack-backups/db/`, and keeps the newest 14. Check runs at https://certs.abaventures.net/jobs, the Mission Control dashboard (admins only).
- Take a backup now (do this right after the first deploy):

  ```bash
  bin/kamal app exec "bin/rails certtrack:backup_now"
  ```

- **Restore drill** (Phase 0's done-when; repeat it every few months). This restores the newest backup into a scratch database, `cert_track_restore_check` by default. It loads the dump into a new, empty `<target>_restoring` database, then drops the target (if it exists) and renames the new one into its place, so a failed restore leaves the target as it was. It prints row counts for users, crew members, certificates and projects. It refuses to touch the app's own databases unless `FORCE=1` is set.

  ```bash
  bin/kamal app exec "bin/rails certtrack:restore_latest"
  # another scratch name or an older backup:
  # bin/kamal app exec "bin/rails certtrack:restore_latest TARGET_DATABASE=cert_track_drill KEY=db/cert_track-20261103T100000Z.sql.gz.enc"

  # compare with production, then drop the scratch database
  bin/kamal accessory exec db --reuse "psql -U cert_track -d cert_track_production -c 'select count(*) from users'"
  bin/kamal accessory exec db --reuse "psql -U cert_track -d postgres -c 'DROP DATABASE cert_track_restore_check'"
  ```

  Write down the date and the result in PLAN.md (Phase 5, "A written restore drill, rehearsed once").

## 10. Day-to-day operations

| Task | Command |
| --- | --- |
| Deploy the committed HEAD | `bin/kamal deploy` |
| Tail logs / Rails console / DB console / shell | `bin/kamal logs`, `bin/kamal console`, `bin/kamal dbc`, `bin/kamal shell` |
| List versions and roll back | `bin/kamal app containers`, then `bin/kamal rollback <version>` |
| Proxy (TLS) logs | `bin/kamal proxy logs` |
| Postgres logs / restart | `bin/kamal accessory logs db`, `bin/kamal accessory reboot db` (brief downtime; data persists) |
| psql as superuser | `bin/kamal accessory exec db -i --reuse "psql -U cert_track -d cert_track_production"` |
| Disk and build cache on the VM | `ssh ubuntu@$KAMAL_HOST 'df -h / && docker system df'`, and every so often `ssh ubuntu@$KAMAL_HOST docker builder prune -f --filter until=720h` |

- Builds run on the production VM, so a deploy uses its CPU for a few minutes. Deploy outside busy hours.
- **Changing `POSTGRES_PASSWORD`**: run `bin/kamal accessory exec db -i --reuse "psql -U cert_track -d postgres"`, then `\password cert_track`. Put the new value in `deploy.env`, `source` it, and run `bin/kamal deploy`. The accessory's env var only matters on first initialization, so Postgres needs no reboot.
- **Rotating R2, Resend, Workers AI or GHCR tokens**: create the new token, update `deploy.env`, run `bin/kamal deploy` (plus `bin/kamal registry login` for GHCR), then revoke the old token.

## 11. Oracle caveats

- **Idle reclamation.** Oracle may reclaim an Always Free VM that has been idle for 7 days, meaning 95th-percentile CPU under 20%, network under 20% and, on A1, memory under 20%. CertTrack's normal load stays under all three. The Pay As You Go upgrade (section 1) is the main defense. Oracle's docs don't say whether it exempts the VM, so **confirm with Oracle support** and note the answer in PLAN.md. The uptime monitor tells you if it happens, and nightly backups in R2 plus section 13 bring CertTrack back in under an hour.
- **Capacity.** If creating the A1 instance fails with "Out of host capacity", retry later or in another availability domain. PAYG tenancies hit this less often.
- **Allowance.** The A1 allowance is 2 OCPU / 12 GB in total since June 2026. A second A1 VM, or a bigger one, will be billed.

## 12. Optional: Anthropic fallback

The fallback stays off unless the free Workers AI models prove inaccurate (see PLAN.md). Turning it on sends certificate text to Anthropic.

1. Uncomment `ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY` in `.kamal/secrets` and `- ANTHROPIC_API_KEY` under `env.secret` in `config/deploy.yml`.
2. Set `AI_PROVIDER: anthropic` under `env.clear` in `config/deploy.yml`, either as a one-time backlog run or permanently.
3. Add `export ANTHROPIC_API_KEY=sk-ant-...` to `~/.config/certtrack/deploy.env` (never to the repo), commit the config changes from steps 1 and 2, `source` the env file and run `bin/kamal deploy`.
4. To turn it off, set `AI_PROVIDER` back to `workers_ai` and deploy.

## 13. Rebuild from scratch (lost or reclaimed VM)

R2 still holds every file and the last 14 backups. You need this repo, `config/master.key` and `deploy.env`.

1. If the old instance still exists, terminate it so the new one fits in the Always Free A1 allowance.
2. Create a new VM and open its ports: section 1, steps 4 to 7, including the iptables commands.
3. Point the `certs.abaventures.net` A record at the new IP and wait for `dig +short` to show it.
4. Update `KAMAL_HOST` in `deploy.env`, `source` it, and run `ssh ubuntu@$KAMAL_HOST true` to accept the new host key.
5. Bring up an empty stack: `bin/kamal server bootstrap && bin/kamal registry login && bin/kamal setup`.
6. Restore the newest backup in place of the production database that `kamal setup` just created. That database has HEAD's schema, which can be newer than the backup, so the restore doesn't replay over it. It loads the dump into an empty `cert_track_production_restoring` database, then drops `cert_track_production` and renames the restored one into its place. The database then carries the backup's own `schema_migrations`, so the next boot runs only the migrations added since the backup.

   ```bash
   bin/kamal app stop
   bin/kamal app exec "bin/rails certtrack:restore_latest TARGET_DATABASE=cert_track_production FORCE=1"
   bin/kamal app start      # the entrypoint runs db:prepare again, which applies the migrations newer than the backup
   ```

   If the restore fails while loading, `cert_track_production` is left untouched and you can retry. If it fails at the final drop-and-rename step, the error names the database that holds the restored data. Once `cert_track_production` is gone, rename it by hand: `bin/kamal accessory exec db --reuse "psql -U cert_track -d postgres -c 'ALTER DATABASE cert_track_production_restoring RENAME TO cert_track_production'"`.

   The cache, queue and cable databases aren't backed up. They start empty, and Solid Queue re-creates its recurring tasks from `config/recurring.yml`.
7. Verify: `/up` returns 200 with a valid certificate, an existing user can sign in, and a certificate's file opens (served from R2). Then take a fresh `certtrack:backup_now`.

## Troubleshooting

- **No TLS certificate / `kamal setup` hangs on the proxy.** Check that `dig +short certs.abaventures.net` returns `KAMAL_HOST`, that the Cloudflare record is DNS only, and that 80/443 are open in **both** the security list and iptables. `bin/kamal proxy logs` shows the ACME errors.
- **`Blocked hosts` error page.** The request's host isn't `APP_HOST`. Only `certs.abaventures.net` is allowed (`config.hosts`), and `/up` is exempt.
- **Direct uploads fail with a CORS error in the browser console.** Check the R2 CORS policy (section 3, step 6). The origin must be exactly `https://certs.abaventures.net`, with no trailing slash.
- **R2 `SignatureDoesNotMatch` / `AccessDenied`.** Check the R2 keys, and that the token covers both buckets. The checksum settings (`request_checksum_calculation: when_required`) are in `config/storage.yml`.
- **Emails not arriving.** Check Resend → Logs, confirm the domain shows Verified, and confirm `MAIL_FROM` is on `notify.abaventures.net`. Failed `deliver_later` jobs show up in `/jobs`.
- **`permission denied ... docker.sock` on the VM.** `ubuntu` isn't in the docker group yet. Log out and back in, or run `bin/kamal server bootstrap` again.
