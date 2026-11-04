# CertTrack deploy runbook

How to stand up, deploy, back up and rebuild CertTrack on its $0 stack: one Oracle Always Free Ampere A1 VM running the app, kamal-proxy and Postgres 17 (Kamal 2). Files and backups go to Cloudflare R2, with a nightly copy of the files on the VM's own disk. Mail goes through the office's Google Workspace account (`smtp.gmail.com`), and AI runs on Cloudflare Workers AI. Do the sections in order the first time. Expect about an hour, most of it waiting on account sign-ups and DNS.

| What | Where it lives |
| --- | --- |
| App container (Puma + Solid Queue), kamal-proxy (TLS) | Oracle VM, Docker |
| Postgres 17 data | Oracle VM, `~/cert_track-db/data` (Kamal accessory `cert_track-db`) |
| Certificate files (photos and scans stored shrunk) | R2 bucket `certtrack-files` (private) |
| Nightly encrypted database dumps, newest 14 | R2 bucket `certtrack-backups` (private) |
| Nightly copy of the certificate files (also import item files and packet index PDFs) | The VM's own disk, `/var/lib/certtrack/file-copies` (`/rails/file_copies` inside the container); see "File copies" in section 9 |
| Docker images | `ghcr.io/austenhughes1/cert_track` (private) |
| Deploy config | `config/deploy.yml`, `.kamal/secrets`, `Dockerfile` |

## 0. On your machine

- Ruby 3.4.12 and `bundle install` in the repo, so `bin/kamal` works.
- The Docker CLI with the buildx plugin (`docker buildx version`). No local Docker daemon is needed: `kamal registry login` logs in client-side when none is running, and the image is built on the VM (the VM is arm64; this machine is x86).
- If Docker is the snap (`snap list docker`), it has a private `/tmp` and can't see the clone Kamal builds from (`/tmp/kamal-clones`), so the build fails with `open Dockerfile: no such file or directory`. Point Kamal at a folder in your home directory instead: `mkdir -p ~/kamal-tmp`, then add `export TMPDIR="$HOME/kamal-tmp"` to `deploy.env` (section 7).
- `config/master.key`. Keep a copy in your password manager. It decrypts the Rails credentials, which hold the Active Record encryption keys and the backup encryption key. **Without it, the backups cannot be decrypted.** If your shell exports a `RAILS_MASTER_KEY` for another app, `config/boot.rb` ignores it here (with a warning) whenever it doesn't match `config/master.key`. Before Nov 4, 2026 it didn't, and the credentials had been encrypted with that other key by mistake.
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
   - **Boot volume:** custom size **100 GB** (the Always Free allowance is 200 GB in total, boot and block volumes together). It also holds the nightly file copy. A volume can grow later but never shrink, so don't start bigger than you need (section 11, "Growing the boot volume").
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

7. **Budget alert.** Past the free 10 GB, R2 bills $0.015/GB-month. That was accepted on Nov 4, 2026 (PLAN.md), but there is no spending cap, so set an alert: Manage Account → Billing → **Billable Usage** → **Create budget alert**. Name it "R2 spend", set the threshold to **$1** (about 75 GB stored), and add your email. Add a second alert at **$5** (about 340 GB) if you like. Cloudflare emails once per billing period when usage-based spend crosses the threshold; it never pauses anything. Storage itself grows slowly and cheaply. The realistic surprise is a bug that writes in a loop, at $4.50 per million writes, which a daily alert would catch. Check usage any time on the same Billable Usage page.

## 4. Cloudflare Workers AI token

My Profile → API Tokens → Create Token → template **Workers AI** (Account · Workers AI · Read and Edit). Under Account Resources, pick your account. The token goes into `CLOUDFLARE_AI_API_TOKEN`. Check it:

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/models/search?per_page=1" \
  -H "Authorization: Bearer $CLOUDFLARE_AI_API_TOKEN" | head -c 200    # "success":true
```

## 5. Email (Google Workspace)

CertTrack sends through the office's existing Google Workspace account, `austen@abaventures.net` (`SMTP_USERNAME` in `config/deploy.yml`), with an app password. abaventures.net already sends its mail through Workspace, and its MX, SPF (`include:_spf.google.com`) and DKIM (`google._domainkey`) records are in place. It has no DMARC record (checked Nov 4, 2026); step 10 adds it, the one DNS change needed.

1. Sign in to that account and turn on **2-Step Verification** (myaccount.google.com → Security). App passwords only work with it on.
2. Go to https://myaccount.google.com/apppasswords and create an app password named **CertTrack**. Google shows 16 characters once. Put them, **without the spaces**, in `SMTP_PASSWORD` in `deploy.env` (section 7). If the page says app passwords aren't available, 2-Step Verification is off, the account uses Advanced Protection or security keys only, or the Workspace admin settings don't let users turn on 2-Step Verification (Admin console → Security → Authentication → 2-Step Verification).
3. **From address.** Gmail rewrites any From that isn't the account itself or one of its Gmail "Send mail as" aliases. So `MAIL_FROM` is `CertTrack <austen@abaventures.net>`, and `test/config/deploy_config_test.rb` checks it matches `SMTP_USERNAME`. To send as another address, add it as a "Send mail as" alias first, then relax that test.
4. **Changing the account's password revokes its app passwords**, and mail then stops with "535-5.7.8 Username and Password not accepted". After any password change, create a new app password and deploy it (section 10, rotation).
5. Production sends to `smtp.gmail.com:587` with STARTTLS required, user `SMTP_USERNAME`, password `SMTP_PASSWORD`, from `MAIL_FROM` (`config/environments/production.rb`). Oracle blocks outbound port 25, but 587 is open.
6. **Limits.** Gmail allows 2,000 messages a day per user (500 on a trial account), counted over a rolling 24 hours, and the owner's own mail from that account counts too. `MAIL_DAILY_LIMIT=1000` caps CertTrack at half of that per Denver day. On a trial account, lower it (e.g. to 250) until the subscription converts. Invites are never counted or held back. Password resets aren't counted either, but each user gets at most one reset email every 15 minutes (the link's lifetime) and 4 a day, and all users together at most 100 a day (`PasswordsController`), so someone scripting the "Forgot password" form can't use up the account's Gmail limit.
7. Every app email shows up in the account's **Sent** folder, and bounces arrive in its inbox.
8. **The office inbox.** Crew expiry notices ask crew to reply with their renewed certificate, so their Reply-To is `OFFICE_EMAIL` (`config/deploy.yml`, also `austen@abaventures.net`). It must be a real, monitored inbox.
9. If a Resend account, API key or `notify.abaventures.net` DNS records were ever created for CertTrack, delete them; nothing uses them.
10. **DMARC.** Wherever abaventures.net's DNS is hosted, add a TXT record named `_dmarc` (`_dmarc.abaventures.net`) with the value `v=DMARC1; p=none`. `p=none` only publishes a policy for receivers to check; it never blocks or quarantines the office's own mail. For daily reports of who sends as abaventures.net, add `; rua=mailto:austen@abaventures.net` (a few XML emails a day). Check it with `dig +short TXT _dmarc.abaventures.net`. Section 8's mail check needs it.

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
export SMTP_PASSWORD=xxxxxxxxxxxxxxxx          # section 5: Google app password, 16 characters, no spaces
export CLOUDFLARE_ACCOUNT_ID=xxx               # same value as R2_ACCOUNT_ID
export CLOUDFLARE_AI_API_TOKEN=xxx             # section 4
# export ANTHROPIC_API_KEY=sk-ant-xxx          # optional, see section 12
ENV
```

Before any kamal command, from the repo root:

```bash
source ~/.config/certtrack/deploy.env
for v in KAMAL_HOST KAMAL_REGISTRY_PASSWORD POSTGRES_PASSWORD R2_ACCOUNT_ID R2_ACCESS_KEY_ID \
         R2_SECRET_ACCESS_KEY SMTP_PASSWORD CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_AI_API_TOKEN; do
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
| `FILE_COPY_DIR` | `config/deploy.yml` | `/rails/file_copies`, the folder for the nightly file copy: a Kamal volume, `/var/lib/certtrack/file-copies` on the VM. Unset means file copies are off (development and test) |
| `SMTP_PASSWORD` | your shell | Google app password for `SMTP_USERNAME` (section 5) |
| `SMTP_USERNAME` | `config/deploy.yml` | `austen@abaventures.net`, the Workspace account that sends |
| `MAIL_FROM` | `config/deploy.yml` | `CertTrack <austen@abaventures.net>`. Must be `SMTP_USERNAME` or one of its Gmail "Send mail as" aliases |
| `MAIL_DAILY_LIMIT` | `config/deploy.yml` | `1000` app emails per Denver day (Gmail allows about 2,000 per account). Blank, zero, negative or not a whole number means 1000 |
| `SMTP_ADDRESS`, `SMTP_PORT` | `config/deploy.yml` (optional) | Not set; the defaults are `smtp.gmail.com` and `587` |
| `OFFICE_EMAIL` | `config/deploy.yml` | `austen@abaventures.net`, the Reply-To on crew expiry notices. It must be a real, monitored inbox |
| `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_AI_API_TOKEN` | your shell | Workers AI |
| `AI_PROVIDER` | `config/deploy.yml` | `workers_ai` (or `ollama`, `anthropic`; `fake` is for offline demos only) |
| `EXTRACTION_MODEL`, `EXTRACTION_VISION_MODEL` | `config/deploy.yml` | Set after the Phase 3 accuracy spike, `docs/IMPORT_SPIKE.md` (commented out until then; imports stop at the AI step until `EXTRACTION_MODEL` is set; without `EXTRACTION_VISION_MODEL`, pages OCR can't read are skipped and named in the certificate's notes) |
| `CHAT_MODEL` | `config/deploy.yml` | Set after `certtrack:eval_chat` in Phase 4 |
| `AI_DAILY_NEURON_BUDGET` | `config/deploy.yml` | `9000` |
| `AUTO_ACCEPT_ENABLED` | `config/deploy.yml` | `false` until you trust the import output |
| `ANTHROPIC_API_KEY` | your shell (optional) | Paid fallback only; see section 12 |
| `ANTHROPIC_MODEL` | `config/deploy.yml` (optional) | Model for `AI_PROVIDER=anthropic`, text and images; default `claude-haiku-5-5` |
| `OLLAMA_URL` | `config/deploy.yml` (optional) | Ollama endpoint for `AI_PROVIDER=ollama`; default `http://localhost:11434/v1`. It must be this machine or its private network (localhost, a private IP, or a Kamal accessory name such as `cert_track-ollama`). Any other host is refused before anything is sent, because certificate text would leave the VM |
| `WEB_CONCURRENCY`, `JOB_CONCURRENCY` | `config/deploy.yml` | `2` Puma workers, `1` process per Solid Queue worker (sized for 2 OCPU; see section 10) |

To change a `config/deploy.yml` value, edit it, commit, and run `bin/kamal deploy`. To change a secret, update `deploy.env`, `source` it, and run `bin/kamal deploy`. Kamal rewrites the container env on every deploy.

## 8. First deploy

Kamal builds from a **git clone of HEAD**, so commit everything first; uncommitted changes are ignored.

```bash
source ~/.config/certtrack/deploy.env

bin/kamal server bootstrap     # installs Docker on the VM (ubuntu has passwordless sudo) and adds ubuntu to the docker group
bin/kamal registry login       # logs in to GHCR locally and on the VM (the VM's docker pushes and pulls the image)
# the folder for the nightly file copy, owned by the container's rails user (uid 1000)
ssh ubuntu@$KAMAL_HOST 'sudo mkdir -p /var/lib/certtrack/file-copies && sudo chown 1000:1000 /var/lib/certtrack/file-copies'
bin/kamal setup                # builds on the VM, pushes, boots kamal-proxy, Postgres 17 and the app
```

If you skip the `mkdir`, Docker creates the folder owned by root. The nightly file copy then fails with that same command in its error, and admins see a banner on the dashboard. Running the command later fixes it without a redeploy.

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

In Gmail, open the message → Show original, and check for **SPF: PASS, DKIM: PASS, DMARC: PASS** for abaventures.net. DMARC shows only once the record from section 5, step 10 is published. A copy is in the sending account's Sent folder. If DKIM fails, turn it on in the Admin console: Apps → Google Workspace → Gmail → Authenticate email.

Copy the certificate files once, to check the file-copy folder (there are none yet, so it finishes at once):

```bash
bin/kamal app exec "bin/rails certtrack:copy_files_now"     # prints "File copy complete: ..."
```

Last, add a free uptime monitor (UptimeRobot or Better Stack, for example) on `https://certs.abaventures.net/up` every 5 minutes. It also tells you if Oracle reclaims the VM.

## 9. Backups and the restore drill

- `Backups::DatabaseJob` runs nightly at 03:00 America/Denver (`config/recurring.yml`). It runs `pg_dump` (plain SQL, `--clean --if-exists`), gzips the dump, encrypts it with AES-256-GCM using `backup_encryption_key` from the credentials, uploads it to `certtrack-backups/db/`, and keeps the newest 14. Check runs at https://certs.abaventures.net/jobs, the Mission Control dashboard (admins only).
- `Backups::FileCopyJob` copies the certificate files to the VM's own disk nightly at 04:15, after the dump (see "File copies" below). Check its runs at `/jobs`, or with `certtrack:file_copy_status`.
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

  Rehearse the file restore at the same time. It is a dry run that changes nothing:

  ```bash
  bin/kamal app exec "bin/rails certtrack:restore_files"
  ```

  "Still in storage" should equal "Blobs in the database" minus "No copy here".

  Write down the date and the result in PLAN.md (Phase 5, "A written restore drill, rehearsed once").

### File copies

R2 holds the only live copy of every certificate file. `Backups::FileCopyJob` keeps a second copy on the VM's own disk, so a file deleted by mistake, or a lost Cloudflare account, can be put back. R2 in turn covers losing the VM.

- **When:** nightly at 04:15 America/Denver (`config/recurring.yml`). The folder is `FILE_COPY_DIR` (`/rails/file_copies` in the container), the Kamal volume `/var/lib/certtrack/file-copies` on the VM. It must exist and be owned by uid 1000 (section 8).
- **What it copies:** every certificate file; every import item file still attached (waiting for review, rejected or duplicate, and failed until the 30-day purge deletes it); and every packet build's index PDF.
- **What it never copies:** thumbnails and previews (made again from their file), packet zips (rebuilt on demand, deleted after 7 days) and raw import uploads (deleted once unpacked).
- **R2 reads:** only files without a copy are downloaded, once each: 2 HEAD requests plus 1 GET per 5 MB, so 3 reads for a typical file (up to 5 MB) and 4 for one of 5-10 MB. Nothing is downloaded again on later nights. Each download streams to disk and must match the blob's size and MD5 before it is kept.
- **Layout:** `ab/cd/<key>` (the Active Storage disk layout), `trash/YYYY-MM-DD/`, `incoming/`, `status.json` and `copy.lock`. Files are 0600 and folders 0700, owned by uid 1000. The copies are not encrypted: anyone with root on the VM can read them, as with the database.
- **Deleted files:** when a file is deleted, or nothing kept uses it any more, its copy moves to `trash/<date>/`, dated the night the job first found it missing, and is deleted 30 days later. If its database row comes back first (the database restored in place), the next run moves the copy back out of the trash, even on its 30th night. The trash names copies by key only. Only a database backup from before the delete links a key to a file name, and only the newest 14 backups are kept: about two weeks of nightly ones, less after manual `certtrack:backup_now` runs. So for about 14 days a deleted file can be found by name ("Files missing from R2", step 2); from day 15 to day 30, only by opening the files in `trash/<date>/` one by one.
- **Free-space guard:** copying stops before free space on that disk drops under the larger of 5 GB and 10% of the disk (10 GB on the 100 GB boot volume), so Postgres always has room. The job logs it, and admins see an amber dashboard banner. Free up space or grow the volume (section 11).
- **The banner** also appears when the folder is missing or can't be written to, or when no complete copy has finished in 2 days (for example because some files keep failing). It shows the time of the last complete copy.
- **Commands:**

  ```bash
  bin/kamal app exec "bin/rails certtrack:copy_files_now"    # run the copy now
  bin/kamal app exec "bin/rails certtrack:file_copy_status"  # last run, last complete copy, files to keep / copied / not copied, trash, free space, errors
  bin/kamal app exec "bin/rails certtrack:restore_files"     # dry run; add CONFIRM=1 to upload
  ```

- The copies use the boot volume. To keep them off it, attach a block volume and mount it at `/var/lib/certtrack/file-copies` before the `mkdir` in section 8. It counts against the same 200 GB free allowance, and the free-space guard then applies to that volume.

**Files missing from R2** (bucket emptied, Cloudflare account lost, or a file deleted by mistake):

1. If the bucket or account is gone, create the bucket, CORS policy and API token again (section 3), update `deploy.env` and run `bin/kamal deploy`.
2. A file deleted in the app lost its database rows too. Steps 3 and 4 only look at blobs in the production database, so they can't bring it back; its copy waits in the trash for 30 days. To fetch one file by hand (and skip steps 3 and 4):
   1. Find its trash folder: `ssh ubuntu@$KAMAL_HOST 'sudo ls /var/lib/certtrack/file-copies/trash'`. The folder's date is the night the 04:15 copy first found the file missing, so it was deleted in the 24 hours before.
   2. List the backups with `bin/kamal app exec "bin/rails certtrack:list_backups"` and pick the last one taken before the delete, usually the 03:00 backup of the day before the folder's date. The newest backup won't have the file if it was deleted before that backup ran. Only the newest 14 backups are kept (about two weeks); after that, none names the file.
   3. Restore that backup into the scratch database: `bin/kamal app exec "bin/rails certtrack:restore_latest KEY=db/cert_track-<timestamp>.sql.gz.enc"`.
   4. Look up the file's key there: `bin/kamal accessory exec db --reuse "psql -U cert_track -d cert_track_restore_check -c \"select key, filename, byte_size from active_storage_blobs where filename ilike '%osha%'\""` (put part of the file's name in place of `osha`).
   5. Run `ssh ubuntu@$KAMAL_HOST 'sudo find /var/lib/certtrack/file-copies -name <key>'`, copy that file off with `sudo cat`, and attach it to the certificate again. Then drop the scratch database (section 9).

   Past that, open the files in that `trash/<date>/` folder by hand; `sudo file` shows each one's type. Restoring the whole database in place instead (section 13, step 6) brings every deleted row back, and steps 3 and 4 then upload their files from the trash, but it rolls everything else back to that night too.
3. Run `bin/kamal app exec "bin/rails certtrack:restore_files"`. It is a dry run: it asks R2 once about every blob that has a copy, and prints counts.
4. Run it again with `CONFIRM=1` to upload the missing files: `bin/kamal app exec "bin/rails certtrack:restore_files CONFIRM=1"`. A copy that fails its MD5 check is never uploaded. Thumbnails and previews of each restored file are deleted, and made again from it the next time a page shows them.

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
| File copies on the VM | `bin/kamal app exec "bin/rails certtrack:file_copy_status"`, or `ssh ubuntu@$KAMAL_HOST 'sudo du -sh /var/lib/certtrack/file-copies'` |

- Builds run on the production VM, so a deploy uses its CPU for a few minutes. Deploy outside busy hours.
- **Background jobs** (`config/queue.yml`, watched at `/jobs`). Solid Queue runs two workers inside the app container. The `imports` worker reads uploads (OCR, then the AI) with 2 threads, so at most two files are in OCR at once. The `default` worker runs everything else: backups, expiry scans and digests, all email (import summaries included), maintenance and Active Storage. A big import backlog therefore never delays the 3 a.m. backup or the 6 a.m. expiry emails; it only queues behind itself. Within the import queue OCR goes last, so a new batch unpacks at once and files already read move on to the AI. The `imports` worker also runs `Certificates::ShrinkFilesJob`, which stores new photos and scans shrunk; it is CPU work like OCR. It goes ahead of OCR but still waits for one of the 2 threads, so during a big import a HEIC photo just added on the certificate form can show "Converting to JPG…" for a while. Expect about 0.1-0.7 s per photo or PDF page (measured on the dev machine; the 2-core VM is slower).
- **Nightly jobs** (`config/recurring.yml`, Denver time): 03:00 database backup; 03:30 purge of uploads never attached; 03:45 import purge (failed items' files 30 days after they failed, leftover uploads, then extracted text); 03:50 packet zips past their last day (7 days after the day they were built); 04:15 file copy; 06:00 expiry scan, plus the weekly digest on Mondays.
- **Changing `POSTGRES_PASSWORD`**: run `bin/kamal accessory exec db -i --reuse "psql -U cert_track -d postgres"`, then `\password cert_track`. Put the new value in `deploy.env`, `source` it, and run `bin/kamal deploy`. The accessory's env var only matters on first initialization, so Postgres needs no reboot.
- **Rotating R2, Workers AI or GHCR tokens, or the Google app password**: create the new token or app password, update `deploy.env`, run `bin/kamal deploy` (plus `bin/kamal registry login` for GHCR), then revoke the old one (app passwords at https://myaccount.google.com/apppasswords). Changing the Google account's own password revokes every app password, so mail stops until you create a new one and deploy it.

## 11. Oracle caveats

- **Idle reclamation.** Oracle may reclaim an Always Free VM that has been idle for 7 days, meaning 95th-percentile CPU under 20%, network under 20% and, on A1, memory under 20%. CertTrack's normal load stays under all three. The Pay As You Go upgrade (section 1) is the main defense. Oracle's docs don't say whether it exempts the VM, so **confirm with Oracle support** and note the answer in PLAN.md. The uptime monitor tells you if it happens, and nightly backups in R2 plus section 13 bring CertTrack back in under an hour.
- **Capacity.** If creating the A1 instance fails with "Out of host capacity", retry later or in another availability domain. PAYG tenancies hit this less often.
- **Allowance.** The A1 allowance is 2 OCPU / 12 GB in total since June 2026. A second A1 VM, or a bigger one, will be billed.
- **Growing the boot volume.** Block storage is free up to 200 GB in total, boot and block volumes together, so the 100 GB boot volume can grow to 200 GB at no cost. Grow it when `df -h /` or the file-copy banner says space is short. A volume can grow but never shrink, and Oracle advises a backup first: on the boot volume's page, Boot volume backups → Create (5 volume backups are free).
  1. Open the boot volume's page (Compute → Instances → your instance → Boot volume), choose **Edit**, set the new size (no more than 200 GB minus any block volumes) and save. Oracle resizes it while the VM runs.
  2. Oracle then shows rescan commands for the VM. Run them over SSH.
  3. Grow the partition and filesystem: check the disk name with `lsblk` (usually `sda`, root on `sda1`), then `sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1`. Rebooting also works, since Ubuntu grows its root partition at boot. Check with `df -h /`.

## 12. Optional: Anthropic fallback

The fallback stays off unless the free Workers AI models prove inaccurate (see PLAN.md). Turning it on sends certificate text to Anthropic.

1. Uncomment `ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY` in `.kamal/secrets` and `- ANTHROPIC_API_KEY` under `env.secret` in `config/deploy.yml`.
2. Set `AI_PROVIDER: anthropic` under `env.clear` in `config/deploy.yml`, either as a one-time backlog run or permanently.
3. Add `export ANTHROPIC_API_KEY=sk-ant-...` to `~/.config/certtrack/deploy.env` (never to the repo), commit the config changes from steps 1 and 2, `source` the env file and run `bin/kamal deploy`.
4. To turn it off, set `AI_PROVIDER` back to `workers_ai` and deploy.

New uploads use the new provider at once. To send items the old model already read (in the review queue, rejected or failed) through it, use each item's **Read again** button. Only whole files can be read again. Accepted items, duplicates and cards cut from a multi-certificate PDF can't.

## 13. Rebuild from scratch (lost or reclaimed VM)

R2 still holds every file and the last 14 backups. The nightly file copies are lost with the VM; the first nightly run on the new VM copies everything from R2 again. You need this repo, `config/master.key` and `deploy.env`.

1. If the old instance still exists, terminate it so the new one fits in the Always Free A1 allowance.
2. Create a new VM and open its ports: section 1, steps 4 to 7, including the iptables commands.
3. Point the `certs.abaventures.net` A record at the new IP and wait for `dig +short` to show it.
4. Update `KAMAL_HOST` in `deploy.env`, `source` it, and run `ssh ubuntu@$KAMAL_HOST true` to accept the new host key.
5. Bring up an empty stack: `bin/kamal server bootstrap && bin/kamal registry login`, then the file-copy `mkdir` and `chown` from section 8, then `bin/kamal setup`.
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

- **`kamal setup` or `kamal deploy` fails at once with `failed to read dockerfile: open Dockerfile: no such file or directory`.** The local Docker is the snap and can't see Kamal's clone in `/tmp`. Set `TMPDIR` as in section 0 and run the command again.
- **The app container restarts with `ActiveSupport::MessageEncryptor::InvalidMessage` and the deploy times out.** The `RAILS_MASTER_KEY` Kamal sends (`config/master.key`) doesn't decrypt the committed `config/credentials.yml.enc`. Check it locally with that key alone: `env -u RAILS_MASTER_KEY bin/rails runner 'p Rails.application.credentials.config.keys'`.
- **No TLS certificate / `kamal setup` hangs on the proxy.** Check that `dig +short certs.abaventures.net` returns `KAMAL_HOST`, that the Cloudflare record is DNS only, and that 80/443 are open in **both** the security list and iptables. `bin/kamal proxy logs` shows the ACME errors.
- **`Blocked hosts` error page.** The request's host isn't `APP_HOST`. Only `certs.abaventures.net` is allowed (`config.hosts`), and `/up` is exempt.
- **Direct uploads fail with a CORS error in the browser console.** Check the R2 CORS policy (section 3, step 6). The origin must be exactly `https://certs.abaventures.net`, with no trailing slash.
- **R2 `SignatureDoesNotMatch` / `AccessDenied`.** Check the R2 keys, and that the token covers both buckets. The checksum settings (`request_checksum_calculation: when_required`) are in `config/storage.yml`.
- **Emails not arriving.** Look in the sending account's Sent folder (did it go out?) and its inbox (bounces). Failed `deliver_later` jobs show up in `/jobs` with Gmail's error:
  - "535-5.7.8 Username and Password not accepted": the app password is wrong or was revoked (a changed account password revokes it), or 2-Step Verification is off. Create a new one (section 5) and deploy it.
  - "Daily user sending limit exceeded": Gmail's own limit was hit, which also blocks the owner's mail for a while. Lower `MAIL_DAILY_LIMIT`. Password resets can add at most 100 a day (4 per user), so look in the Sent folder for what else went out from the account.
  - Mail arrives with a different From: `MAIL_FROM` isn't the account or one of its "Send mail as" aliases.

  Every app email counts against `MAIL_DAILY_LIMIT` (default 1,000 a day). Past it, the dashboard shows an amber banner and the rest wait: expiry alerts for the next daily run, weekly digests and import summaries for the next morning (summaries at 7:00 a.m. Denver).
- **File copy banner on the dashboard.** Run `bin/kamal app exec "bin/rails certtrack:file_copy_status"`. A root-owned folder needs only the `chown` from section 8, with no redeploy. A missing folder means the volume isn't mounted: run the `mkdir` and `chown` from section 8, then `bin/kamal deploy`. Low space needs space freed, or a bigger volume (section 11). Failed files are listed with their errors; the next night tries them again.
- **A photo or scan kept at full size.** A file that couldn't be read is kept as it is and logged at warn as `[Certificates::ShrinkFilesJob] blob N kept as it is: ...`. A PDF that is encrypted, signed or a form, or that can't be parsed or fails the check after re-encoding, is left alone and logged at info as `[Certificates::PdfShrinker] ... left as it is: <reason>`. A PDF with no large plain JPEG pages (made on a computer, or with unusual images), or one that wouldn't shrink by 20%, is left alone without a log line. If poppler is missing, the job fails and shows in `/jobs`.
- **`permission denied ... docker.sock` on the VM.** `ubuntu` isn't in the docker group yet. Log out and back in, or run `bin/kamal server bootstrap` again.
