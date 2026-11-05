# Certificate Tracking Service — Build Plan

Nov 2, 2026 (updated Nov 4, 2026) · @Austen Hughes

## Summary and how to use this plan

Build **CertTrack** (working name), a Rails 8 app for ABA Ventures. It tracks crew certificates against per-project requirements, imports bulk uploads with AI, emails expiry warnings, and answers "does X have Y?". It runs at **$0/month** on free tiers while stored files stay under 10 GB. Past that, Cloudflare R2 bills cents per GB, which the owner accepted on Nov 4, 2026. The one other paid item is an optional AI fallback that costs cents.

**In scope**

- Crew roster, plus certificate records with completion date, expiration date and one or more attached files per line item.
- A master list of certificate types. Each project selects its own subset, optionally per crew role.
- A compliance matrix per project showing who is valid, expiring or missing each required certificate.
- Bulk import: drop many files or zip archives. AI identifies certificate type, holder and dates, and a person reviews anything uncertain.
- Email alerts at 90, 60, 30 and 7 days before expiry, and on expiry.
- An "Ask" box (free, no AI) plus an optional AI chat that answers questions such as "Does Juan Ortiz have OSHA 30?"

**Handing this to Claude Code**

1. Save the Markdown copy of this doc as `docs/PLAN.md` in a new, empty Git repo.
2. Open Claude Code in that repo and paste the kickoff prompt below.
3. Run one phase per session. Claude Code ticks the phase checklist in `docs/PLAN.md` as it goes.

```text
You are building CertTrack, specified in docs/PLAN.md. Read the whole file before doing anything.

Rules:
- Follow "Locked decisions" exactly. Do not substitute paid services, other frameworks or extra gems without asking me first. Free options are a hard requirement. The one exception is R2 storage past 10 GB, which I accepted on Nov 4, 2026.
- Work one phase at a time, in order, starting with Phase 0. Before coding a phase, restate its checklist and list open questions.
- Write Minitest tests for every model, job and service object. A phase is done only when its acceptance criteria pass and bin/rails test is green.
- Never send certificate files or personal data to any service not named in PLAN.md.
- Keep secrets in Rails credentials or the env vars listed in PLAN.md. Never commit them.
- At the end of each phase, tick its checklist in PLAN.md and summarize what changed and what I need to do by hand (accounts, DNS, keys).
```

## Locked decisions: stack and hosting

Every layer runs on a free tier, so steady-state cost is **$0/month** while stored files stay under 10 GB. Past 10 GB, R2 bills $0.015/GB-month; the owner accepted that on Nov 4, 2026, rather than move files elsewhere. The only other paid item is an AI fallback that stays off unless the free model proves inaccurate.

| Layer | Choice | Monthly cost | Notes |
| --- | --- | --- | --- |
| Framework | Ruby 3.4, Rails 8.x (latest stable), Hotwire, `tailwindcss-rails`, importmap | $0 | Owner's strongest stack |
| Database | PostgreSQL 17 as a Kamal accessory on the same VM; extensions `pg_trgm`, `citext` | $0 | `pg_trgm` powers fuzzy name matching |
| Jobs and schedules | Solid Queue inside Puma (`SOLID_QUEUE_IN_PUMA=1`), recurring tasks in `config/recurring.yml`, `mission_control-jobs` dashboard | $0 | No Redis, no separate worker ([Solid Queue](https://github.com/rails/solid_queue)) |
| Auth | Rails 8 authentication generator plus a `role` enum on `User` | $0 | No Devise needed |
| Hosting | Oracle Cloud Always Free Ampere A1 VM: 2 OCPU, 12 GB RAM, ARM64, Ubuntu | $0 | 200 GB block storage, 10 TB egress/month ([Oracle](https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm)) |
| Deploy | Kamal 2 with kamal-proxy (automatic Let's Encrypt TLS), arm64 images | $0 | Rails 8 default deploy tool |
| File storage | Cloudflare R2 through the Active Storage S3 service. Photos and scans are stored shrunk to 2400 px on the long side, JPEG quality 80; full-size originals are not kept | $0 under 10 GB, then $0.015/GB-month | Free: 10 GB-month, 1M writes, 10M reads, no egress fees ([R2](https://developers.cloudflare.com/r2/pricing/)). The owner accepted the overage past 10 GB on Nov 4, 2026; a Cloudflare budget alert warns of it |
| Backups | Nightly `pg_dump` to a second R2 bucket, 30 kept. Nightly copy of the certificate files from R2 to the VM's own disk (`Backups::FileCopyJob`, 04:15); copies of deleted files are kept 30 days | $0 | The dumps let a lost VM be rebuilt in under an hour. The file copy covers a file deleted by mistake or a lost Cloudflare account |
| Email | Google Workspace: the owner's existing account (`austen@abaventures.net`) over `smtp.gmail.com:587` with STARTTLS and an app password | $0 (existing subscription) | About 2,000 messages/day per account over a rolling 24 hours (500 on a trial account), shared with the owner's own mail. The app stops at `MAIL_DAILY_LIMIT` (1,000) a day ([Google](https://support.google.com/a/answer/166852)) |
| Text extraction | `poppler-utils` (`pdftotext`, `pdftoppm`; `pdfimages` and `pdfinfo` for shrinking scans) and Tesseract OCR in the Docker image | $0 | Runs locally; no data leaves the VM |
| AI (extraction, chat) | Cloudflare Workers AI free allocation via its OpenAI-compatible endpoint, called with the `ruby_llm` gem | $0 | 10,000 neurons/day; Cloudflare does not train on customer content ([pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/), [privacy](https://developers.cloudflare.com/workers-ai/privacy/)) |
| AI paid fallback (off by default) | Claude Haiku 5.5 via `ruby_llm` | About $0.0005 per page | $0.10/M input, $0.50/M output under 100K-token prompts ([Anthropic](https://platform.claude.com/docs/en/docs/about-claude/pricing)) |
| Archives and PDFs | `rubyzip` to unpack, `combine_pdf` to split multi-certificate PDFs | $0 | Both MIT licensed |
| Domain | `certs.abaventures.net`, an A record pointing at the VM | $0 | Domain already owned |
| Uptime | Rails `/up` health check plus a free uptime monitor | $0 | Alerts if the VM goes down |

**Considered and rejected**

- **Render**: cheapest always-on setup is about $13/month (Starter web $7 plus Postgres $6). Its free web service sleeps and free Postgres expires after 30 days ([Render](https://render.com/articles/how-much-does-cloud-application-hosting-cost-for-small-businesses)).
- **Gemini API free tier**: free and capable, but free-tier prompts and responses are used to improve Google products ([Google](https://ai.google.dev/gemini-api/docs/billing)). That rules it out for employee documents, which can include license numbers and dates of birth.
- **Google Cloud e2-micro**: always free, but 1 GB RAM is too small for Rails, Postgres and OCR on one box. Keep as an emergency fallback only.
- **Other file stores past 10 GB** (storage study, Nov 4, 2026): R2 Infrequent Access costs more until about 2 TB. Backblaze B2 saves under $1/month at 100 GB but adds a company this plan doesn't name to hold personal data. Oracle Object Storage costs more and shares the VM's account. Files on the VM's own disk would put every file on the machine most likely to disappear, so the disk holds only the second copy.
- **Resend** for email (the first choice, never set up): 100 emails/day on the free plan. The owner's Google Workspace account sends more, costs nothing extra and needs only a DMARC record in DNS.

**Oracle caveats Claude Code must handle**

- Oracle may reclaim an Always Free VM that is idle for 7 days: 95th-percentile CPU under 20%, network under 20% and, on A1, memory under 20%. Upgrade the tenancy to Pay As You Go (card on file; Always Free resources stay free). Confirm with Oracle whether that exempts the VM, since the docs page does not say.
- The A1 allowance was halved in June 2026 from 4 OCPU / 24 GB to 2 OCPU / 12 GB ([InfoQ](https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/)). Size the VM at exactly 2 OCPU / 12 GB.
- Images must be built for `arm64`. If the dev machine is x86, set Kamal's builder to build remotely on the VM.

**Environment variables**

| Variable | Purpose |
| --- | --- |
| `RAILS_MASTER_KEY` | Rails credentials |
| `POSTGRES_PASSWORD` | Database accessory |
| `APP_HOST` | `certs.abaventures.net`, used in email links |
| `SOLID_QUEUE_IN_PUMA` | `1` in production |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | R2 credentials |
| `R2_BUCKET`, `R2_BACKUP_BUCKET` | Files bucket and backups bucket |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | The Google Workspace account that sends (`austen@abaventures.net`) and its app password |
| `MAIL_FROM` | Sender, `CertTrack <austen@abaventures.net>`. Must be `SMTP_USERNAME` or one of its Gmail "Send mail as" aliases, because Gmail rewrites any other From |
| `MAIL_DAILY_LIMIT` | App emails per Denver day, default `1000`; a blank, zero, negative or non-numeric value means 1000 |
| `SMTP_ADDRESS`, `SMTP_PORT` | Optional overrides, normally unset; defaults `smtp.gmail.com` and `587` |
| `OFFICE_EMAIL` | Office inbox that crew expiry notices reply to, currently `austen@abaventures.net` (the same inbox that sends) |
| `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_AI_API_TOKEN` | Workers AI |
| `AI_PROVIDER` | `workers_ai` (default), `ollama` or `anthropic`; `fake` for offline demos (tests always use it) |
| `EXTRACTION_MODEL`, `EXTRACTION_VISION_MODEL` | Model IDs, chosen in the Phase 3 accuracy spike |
| `CHAT_MODEL` | Model ID, chosen with `certtrack:eval_chat` in Phase 4 |
| `AI_DAILY_NEURON_BUDGET` | Default `9000`, leaves headroom under the 10,000 free neurons |
| `AUTO_ACCEPT_ENABLED` | Default `false`; turn on after the owner trusts the import output |
| `ANTHROPIC_API_KEY` | Optional; only for the paid fallback |
| `ANTHROPIC_MODEL` | Optional; the fallback's model, default `claude-haiku-5-5` |
| `OLLAMA_URL` | Optional; Ollama endpoint for `AI_PROVIDER=ollama`, default `http://localhost:11434/v1` |
| `FILE_COPY_DIR` | Folder for the nightly copy of the certificate files, `/rails/file_copies` (a Kamal volume on the VM). Unset means file copies are off, as in development and test |

## Data model

There are thirteen tables. Certificates hang off crew members, requirements and packet builds hang off projects, and import items stage AI results until they are accepted.

```ruby
# Schema sketch. Claude Code writes real migrations from this.
# All tables get timestamps. FKs are indexed and use on_delete: :restrict unless noted.

users                 # from the Rails 8 auth generator
  email_address  citext   unique, not null
  password_digest
  name           string
  role           integer  enum admin | manager | viewer, default viewer
  receives_digest boolean default true

crew_roles            # Foreman, Operator, Laborer, Climber, Driver ...
  name           citext   unique, not null

crew_members
  first_name, last_name  string not null
  preferred_name string
  name_aliases   string[] default []   # "Jon Smith", "J. Smith" as seen on cards
  email          citext   nullable
  phone          string
  employer       string   # "ABA Ventures" or subcontractor name
  crew_role_id   ref      nullable
  active         boolean  default true
  notes          text
  # GIN trigram index on lower(first_name || ' ' || last_name)

certificate_types     # the master list
  name           citext   unique, not null    # "OSHA 30-Hour Construction"
  code           string   unique              # "OSHA30"
  issuing_body   string
  validity_months integer nullable            # null = never expires
  aliases        string[] default []          # names as printed on real cards
  description    text
  active         boolean  default true
  position       integer

projects
  name           string   not null
  code           string   unique
  client         string   # prime contractor or GC
  location       string
  starts_on, ends_on date
  status         integer  enum planned | active | closed
  packet_built_at datetime nullable    # time of the latest packet build
  # has_one_attached :packet   (latest zip only; deleted 7 days after it is built)

project_requirements  # each project's subset of the master list
  project_id     ref      on_delete: :cascade
  certificate_type_id ref
  crew_role_id   ref      nullable   # null = everyone on the project
  notes          text
  # unique [project_id, certificate_type_id, crew_role_id] (treat null as a value)

project_assignments
  project_id     ref      on_delete: :cascade
  crew_member_id ref
  crew_role_id   ref      nullable   # role on this project; falls back to member's role
  starts_on, ends_on date
  # unique [project_id, crew_member_id]

certificates          # one line item per earned certificate
  crew_member_id ref
  certificate_type_id ref
  certificate_number string
  issued_by      string   # trainer or provider
  completed_on   date
  expires_on     date     nullable
  expires_on_source integer enum printed | computed | manual | none
  source         integer  enum manual | import
  import_item_id ref      nullable
  verified_by_id ref users nullable
  verified_at    datetime
  superseded_at  datetime nullable  # set when a newer cert of the same type is added
  notes          text
  # has_many_attached :files   (photos and scans stored shrunk; see Implementation notes)
  # index [crew_member_id, certificate_type_id, superseded_at]
  # index [expires_on] where superseded_at is null

import_batches
  uploaded_by_id ref users
  status         integer  enum receiving | processing | needs_review | completed | failed
  files_count, items_count, accepted_count, review_count, error_count integer default 0
  # has_many_attached :uploads   (raw files and zips as dropped; deleted once unpacked)

import_items          # one detected certificate (a file, or a page range of a PDF)
  import_batch_id ref     on_delete: :cascade
  original_filename string
  page_range     string   # "1-2"; null for single images
  sha256         string   # SHA-256 of the original file; unique with page_range
  status         integer  enum pending | extracting | needs_review | accepted | rejected | duplicate | failed
  extracted_text text     # OCR or pdftotext output
  extraction     jsonb    # raw model JSON, see Bulk import
  confidence     decimal(3,2)
  holder_name_raw, certificate_name_raw string
  matched_crew_member_id ref nullable
  matched_certificate_type_id ref nullable
  proposed_completed_on, proposed_expires_on date
  proposed_certificate_number string
  provider       string   # workers_ai | ollama | anthropic
  ai_units_used  integer  # neurons or tokens, for budget tracking
  certificate_id ref nullable   # set on accept
  reviewed_by_id ref users nullable
  reviewed_at    datetime
  error_message  text
  # has_one_attached :file   (until accepted: the certificate then holds the file; a failed
  #                           item's file is deleted 30 days after it failed)

packet_builds         # one per compliance packet built: the lasting record of what was sent
  project_id     ref      on_delete: :cascade (Project has_many, dependent: :destroy)
  built_by_id    ref users nullable, on_delete: :nullify   # who started it
  built_at       datetime not null   # equals the time printed on index.pdf and packet_built_at
  packet_filename string  not null   # the zip's name, e.g. "2417-packet-2026-11-04.zip"
  certificate_count, file_count, gap_count integer default 0
  # has_one_attached :index_pdf   ("<code>-packet-<date>-index.pdf", kept for good)
  # index [project_id, built_at]

expiry_notifications  # send log; prevents duplicates
  certificate_id ref      on_delete: :cascade
  threshold      integer  enum d90 | d60 | d30 | d7 | expired
  recipient_email citext
  sent_at        datetime
  # unique [certificate_id, threshold, recipient_email]

ai_usage_days
  day            date     unique
  provider       string
  units_used     integer default 0
  requests       integer default 0
```

**Rules the models must enforce**

- **Expiration date.** Use the printed date when the card has one (`printed`). Otherwise compute `completed_on + validity_months` (`computed`). If the type never expires, leave it null (`none`).
- **Current certificate.** For a crew member and type, the current certificate is the one with `superseded_at` null. Saving a newer certificate of the same type sets `superseded_at` on the older one. History is kept, never deleted.
- **Required types for a person on a project.** All `project_requirements` for that project where `crew_role_id` is null or equals the assignment's role (falling back to the member's role).
- **Compliance status per required type**, with `today` in America/Denver:
  - `missing`: no current certificate.
  - `expired`: `expires_on` is before today.
  - `expiring`: `expires_on` is within 30 days.
  - `lapses_on_project`: valid today but expires before the project's `ends_on`.
  - `valid`: everything else, including types that never expire.
- **Dedupe.** Reject an import item whose `sha256` and page\_range pair already exists; mark it `duplicate` and link it to the original. The `sha256` saved on the import row is of the file as uploaded, so a file is still recognized after its item lets go of it on accept, and after its stored copy is shrunk. Rejected items keep their files, because they stay the original for this check.
- **Name normalization.** Compare names case-insensitively, without punctuation or middle initials, and check `name_aliases`. Accepting an import that matched on a variant spelling adds that spelling to `name_aliases`.

## Core features and screens

Nine screens cover the manual workflow. Everything here works without AI, so Phases 1 and 2 ship a usable tracker before the import pipeline exists.

| Screen | Route | What it does | Who can edit |
| --- | --- | --- | --- |
| Dashboard | `/` | Counts of expired, expiring (30 days) and missing across active projects; review-queue count; next 20 expirations | n/a |
| Crew | `/crew_members` | Search (trigram), filter by active, employer, role and status. Member page lists current certificates with a history toggle, the files on each line item, project assignments and per-project compliance | admin, manager |
| Certificate | nested under crew member | Add or edit a line item: type, number, issuer, completed and expires dates, notes. Drag-and-drop **multiple files per line item** (PDF, JPG, PNG, HEIC, WEBP; 25 MB max each) with thumbnail preview and download | admin, manager |
| Master list | `/certificate_types` | CRUD for certificate types: aliases, validity months, issuing body, sort order | admin |
| Projects | `/projects` | CRUD; a requirements editor that ticks types from the master list, each optionally limited to one role; "copy requirements from project"; crew assignments with role | admin, manager |
| Compliance matrix | `/projects/:id/compliance` | Rows are assigned crew, columns are required types, cells are colored by status with the expiry date. Click a cell to open the certificate. Export CSV. **Download packet**: a zip of every current certificate file for the project's crew plus an index PDF. The zip is kept 7 days; each build's index PDF is kept for good under "Past builds" | n/a |
| Imports | `/imports` | Drop zone for many files or zips, live batch progress, review queue | admin, manager |
| Ask and Chat | `/ask`, `/chat` | See the AI chatbot section | n/a (all roles can ask) |
| Users | `/users` | Invite users, set roles, toggle digest emails | admin |

**Implementation notes**

- Use Active Storage direct uploads to R2. Configure CORS on the bucket for `https://certs.abaventures.net` (PUT from the browser).
- Generate thumbnails with `image_processing` and libvips. A PDF's thumbnail comes from `PdfThumbnailPreviewer` (`config/initializers/active_storage_previewers.rb`): its first page as a 320 px JPEG at quality 80 from `pdftoppm`, about 3-5 KB instead of Poppler's 27-236 KB full-page PNG. 320 px is twice the largest PDF image the app shows (the 160 px thumbnail); raise `PREVIEW_SIZE` before showing a bigger one.
- Store photos and scans shrunk; the full-size original is not kept (owner's decision, Nov 4, 2026). After any save that attaches files, `Certificates::ShrinkFilesJob` (imports queue) handles the attachments that save created:
  - Images (JPEG, PNG, WEBP, HEIC, HEIF) become a JPEG that fits in 2400 × 2400 px and is never enlarged. EXIF orientation is applied, colours are converted to sRGB, transparency is flattened onto white, and the JPEG is saved at quality 80 with all metadata stripped, GPS included. The name keeps its base with a `.jpg` extension.
  - HEIC and HEIF are always converted, so every browser can show them. So is any image carrying EXIF, XMP or IPTC metadata (a phone photo's GPS location, time and phone model), even when the JPEG isn't smaller, so no certificate photo is stored with it. Any other image is replaced only when the JPEG is under 80% of its size.
  - Scanned PDFs: each page image drawn above 220 ppi is re-encoded in place at 200 ppi, quality 80. Pages, the text layer, fonts, outlines, metadata, tags and page labels are kept. The result must have the same page count and `pdftotext` output, every page must render and match the original, and it must be under 80% of the original's size. PDFs made on a computer have no big images and stay as they are.
  - Left alone: encrypted or signed PDFs, and PDFs with forms, layers, attached files or scripts; CMYK and other unusual page images. A file that can't be read is kept as it is.
  - The new file is marked (`shrunk` in its metadata) so it is never processed twice.
  - Measured on generated samples: a phone JPEG keeps 8-15% of its size, a HEIC 13-32%, a PNG 1-6%, and a 300 dpi scanned PDF page 19-21% (1.1 MB becomes about 0.2 MB). OCR still read every name, date and number of 8 pt and up. Re-run the check on real samples once there are some.
- Packets: every build records a `PacketBuild` with who started it, when, its counts and a copy of its `index.pdf`. Only the latest zip is stored. It is kept through the 7th day after the day it was built, whatever the time (`Project::PACKET_KEPT_FOR`; the packet page shows that date), and the 03:50 `Maintenance::PurgeOldPacketsJob` deletes it the next morning. The packet page then says the zip expired and offers Rebuild; its "Past builds" table lists every build, newest first, with an index PDF download. Every signed-in role may build packets and download them. A project with past builds can't be deleted, only closed.
- Name files in the packet `Last_First - CODE - exp YYYY-MM-DD.ext` so a prime contractor's reviewer can scan them.
- Compute compliance in one query per project (join assignments, requirements and current certificates) rather than per cell. Matrix pages must render in under 500 ms for 50 crew × 15 types.
- Viewers are read-only. Enforce roles with a small `authorize!` helper in controllers; no extra gem.

**Seed master list (examples only; the owner edits the real list and validity periods)**

OSHA 10 Construction, OSHA 30 Construction, First Aid/CPR/AED, Flagger, Competent Person (Excavation and Trenching), Confined Space Entry, Fall Protection, Authorized Climber, Climber Rescue, RF Safety Awareness, Fiber Optic Technician, CDL Class A, Aerial Lift Operator, Forklift or Telehandler Operator, Rigger and Signal Person. Seed every `validity_months` as null so nothing is computed until the owner sets it.

## Bulk import pipeline

Free local OCR reads every file first. A free model then turns the text into JSON, and plain Ruby, not the model, matches people and certificate types. Nothing becomes a certificate until it passes strict auto-accept rules or a person approves it.

**Steps (one job per step, all on Solid Queue)**

1. **Intake.** `POST /imports` takes many files via direct upload: PDF, JPG, JPEG, PNG, HEIC, WEBP and ZIP, up to 500 MB per batch. Create an `ImportBatch` and enqueue `Imports::ExpandJob`.
2. **Expand.** Unzip with `rubyzip` into `Dir.mktmpdir`, recursing into nested zips two levels deep. Skip `__MACOSX`, `.DS_Store`, `Thumbs.db` and hidden files. Reject entries with `..` or absolute paths. Stop at 2,000 entries or 2 GB uncompressed (zip-bomb guard). Each supported file is a candidate; hash it with SHA-256. Once every upload is unpacked, the uploads themselves are deleted; a file uploaded on its own (not in a zip) stays, as its item's file. If unpacking stops on an unexpected error, the uploads are kept for the redo, and the nightly purge deletes them 30 days after the drop.
3. **Extract text (free, local).** For PDFs run `pdftotext -layout` per page. If a page yields fewer than 40 characters, it is a scan: rasterize with `pdftoppm -r 300` and run `tesseract`. For images, auto-rotate and convert to grayscale with libvips, then run `tesseract`. Store the text in `extracted_text` with `=== page N ===` markers.
4. **AI extraction (free model).** Send the page text, the master list (code, name, aliases) and the JSON schema below. Use `EXTRACTION_MODEL` through `ruby_llm` with structured output. If OCR text is unusable, send the page image (long side 1,568 px or less) to `EXTRACTION_VISION_MODEL` instead. A blank page needs no call. Without a vision model, unreadable pages are skipped and named in the certificate's notes. Usually one call per source file returns every certificate in it, with page numbers. A file with more than 24,000 characters of text takes one call per 24,000 characters, never splitting a page. Unreadable pages go in extra vision calls, as many images per call as the model accepts. The replies are merged.
5. **Split.** For each certificate returned, create an `ImportItem`. Multi-page PDFs are split by page range with `combine_pdf`, and the split file is attached to the item. The whole PDF is not kept once its pages are split out.
6. **Match type (Ruby).** Accept `certificate_type_code` only if it exists in the master list. Otherwise fuzzy-match `certificate_name_as_printed` against names and aliases with `pg_trgm`; similarity of 0.45 or more is a suggestion, not a match.
7. **Match person (Ruby).** Normalize the holder name and compare against crew full names and `name_aliases` with `pg_trgm`. An exact normalized match is a match. Otherwise the best candidate at 0.6 or more, beating the runner-up by at least 0.15, becomes a suggestion. No candidate means review offers "create crew member".
8. **Dates.** Parse ISO dates. Reject `completed_on` in the future and `expires_on` before `completed_on`. If `expires_on` is null and the type has `validity_months`, compute it and mark `computed`.
9. **Decide.** Auto-accept only when all hold: type matched by code, person matched exactly, `completed_on` present, expiry present or type never expires, model confidence 0.85 or more, and `AUTO_ACCEPT_ENABLED` is on. Everything else goes to `needs_review`. Ship with `AUTO_ACCEPT_ENABLED=false` until the owner has reviewed about 100 items and trusts the output.
10. **Review queue.** File preview on the left, editable proposed fields on the right: person picker showing suggestions, type picker, dates, number. Actions are Accept, Reject, Skip and "Create crew member from this", with keyboard shortcuts (`a`, `r`, `s`). HEIC/HEIF photos are previewed as a JPEG (2000 px max, quality 80). Accepting creates the `Certificate`, moves the file to it (the import item no longer links to it, and import pages link to the certificate instead) and sets `verified_by`. If two items share person, type and number (front and back photos of one card), offer to merge them into one certificate with two files.
11. **Finish.** When every item is terminal, set the batch status and email the uploader a summary: accepted, needs review, duplicates, failed.

**Model output contract**

```json
{
  "certificates": [
    {
      "pages": [1],
      "holder_name": "Juan A. Ortiz",
      "certificate_type_code": "OSHA30",
      "certificate_name_as_printed": "OSHA 30-Hour Construction Industry Outreach Training",
      "issuer": "Example Safety Training LLC",
      "certificate_number": "30-1234567",
      "completed_on": "2025-03-14",
      "expires_on": null,
      "confidence": 0.92,
      "notes": "No expiration printed"
    }
  ],
  "non_certificate_pages": []
}
```

Prompt rules to put in the system prompt: dates are ISO `YYYY-MM-DD`; use null when a field is absent and never guess; `certificate_type_code` must be a code from the supplied list or null; one entry per distinct certificate; pages are 1-indexed; ignore cover sheets and course outlines (list them in `non_certificate_pages`).

**Staying inside the free allocation**

- Before every AI call, check `ai_usage_days`. If today's usage is at `AI_DAILY_NEURON_BUDGET`, or the API returns HTTP 429 or a quota error, reschedule the job for 00:05 UTC, just after the 10,000-neuron allocation resets at 00:00 UTC.
- Estimate neurons from the token counts in each response, using per-model rates from the Workers AI pricing page stored in config.
- Before a file's first call, estimate what the whole file will cost. A file estimated over one day's budget fails with a message to split it or use `AI_PROVIDER=anthropic`. A file stopped part way by the budget keeps its finished calls and resumes from there, so no paid call is repeated.
- Text-only calls are much cheaper than image calls, which is why OCR runs first.
- A large first backlog can take several days to drain for free. For a one-time catch-up, the owner can set `AI_PROVIDER=anthropic`: at Haiku 5.5 rates a page costs well under $0.001, so 2,000 pages is roughly $1.

**Accuracy harness (required in Phase 3)**

Build `test/fixtures/import_samples/` with 20 to 30 real certificates and a hand-written expected JSON for each. Add `bin/rails certtrack:eval_extraction[provider,model]` to print per-field accuracy for type, holder, completed date and expiry. Pick the free model with the best score. If no free model reaches 90% on type, holder and dates, leave the review queue as the safety net or switch to the paid fallback. That choice is the owner's. Keep the sample files out of Git (`.gitignore`) because they contain personal data.

## Expiration notifications

A daily job at 6:00 a.m. Mountain time emails one digest per manager whenever a certificate crosses 90, 60, 30 or 7 days to expiry, or expires. Each certificate, threshold and recipient combination is sent once.

**Job design**

- `Notifications::ExpiryScanJob` runs from `config/recurring.yml` on the schedule `0 6 * * * America/Denver`.
- It scans current certificates only: `superseded_at` null, crew member active, `expires_on` not null.
- A certificate crosses a threshold when `expires_on - today` is at or below 90, 60, 30 or 7 days, or below 0 for `expired`. On a missed day it sends the most urgent unsent threshold only, never a burst of older ones.
- Insert into `expiry_notifications` before sending. The unique index makes re-runs safe.
- Each item in the digest lists the active projects that require that type, so the reader sees impact: "Juan Ortiz, Flagger, expires Dec 1, needed on Project 2417 and 2420."

**Recipients**

| Who | When | Content |
| --- | --- | --- |
| Users with `receives_digest` (admins, managers) | Daily, only if something new crossed a threshold | Grouped by project, then person; links to member pages |
| Same users | Mondays, always | Everything expiring within 30 days, plus missing requirements on active projects |
| Crew member (opt-in per member, needs an email) | At 30 and 7 days | Their own certificate, with instructions to send the renewal to the office |
| Import uploader | When a batch finishes | Accepted, needs review, duplicates, failed |

**Delivery**

- Use Action Mailer over the office's Google Workspace SMTP (`smtp.gmail.com:587`, STARTTLS required, an app password); no extra gem. It replaced Resend on Nov 4, 2026, before Resend was ever set up.
- Send from the Workspace account itself: `MAIL_FROM` is `SMTP_USERNAME` or one of its Gmail "Send mail as" aliases, because Gmail rewrites any other From. Every app email lands in that account's Sent folder, and bounces arrive in its inbox.
- Gmail allows about 2,000 emails a day per account over a rolling 24 hours (500 on a trial account), shared with the owner's own mail. Count sends in the job and stop at `MAIL_DAILY_LIMIT` (default 1,000) per Denver day. Past it, defer the rest to the next run and show a banner on the dashboard.
- Invites and password resets aren't counted; the other ~1,000 covers them and the owner's own mail. Invites are never held back. Resets are, so a script posting the "Forgot password" form can't use up the account: one reset email per user every 15 minutes (the link's lifetime), at most 4 a day per user, and at most 100 a day in all (`PasswordsController`). The per-user cap stops someone who knows one address from using up everyone's resets. A held-back request gets the same answer as any other. Because Gmail's window is rolling, two full app days back to back could put up to 2,000 sends inside 24 hours; lower `MAIL_DAILY_LIMIT` for a hard margin.
- The digest design keeps normal volume to a few emails a day.
- Add Rails mailer previews for every email, and a "Send test digest to me" button on the Users page.

## AI chatbot: options and design

Build two free layers. An **Ask box** with no AI answers "does X have Y?" exactly and instantly. An **AI chat** on the Workers AI free allocation handles looser questions through read-only tools. Claude Haiku 5.5 is a switch-on fallback at about a tenth of a cent per question.

**Options investigated**

| Option | Cost | Data handling | Fit | Verdict |
| --- | --- | --- | --- | --- |
| Ask box: Postgres fuzzy matching, no AI | $0 | Never leaves the server | Exact for "does X have Y", "who has Y", "what does X have", "who expires soon" | **Build first (Phase 4a)** |
| Workers AI free allocation with tool calling | $0, shares the 10,000 neurons/day with imports | Not used to train models ([Cloudflare](https://developers.cloudflare.com/workers-ai/privacy/)) | Good for plain questions; quality depends on the model chosen | **Build (Phase 4b), default** |
| Claude Haiku 5.5 with tool calling | About $0.001/question, so 1,000 questions is about $1 | Not used for training under Anthropic's commercial terms | Strongest tool use of the options | Fallback switch |
| Gemini API free tier | $0 | Free-tier content is used to improve Google products ([Google](https://ai.google.dev/gemini-api/docs/billing)) | Strong | Rejected |
| Ollama on the same VM | $0 | Fully local | Slow on 2 ARM cores; competes with Postgres for 12 GB RAM | Not recommended |

The Haiku estimate assumes two model round trips of about 4,000 input tokens and 400 output tokens per question at $0.10/M input and $0.50/M output.

**Ask box (`/ask`, Phase 4a)**

- `AskQuery.new(text, user:).call` returns a result object; it is a plain Ruby service with no AI.
- Find the person by trigram-matching 2- and 3-word windows of the question against crew names and `name_aliases`. Find the type by matching windows against codes, names and aliases.
- Detect intent from keywords: "have/has/does" means check; "who has" means list holders; "expir" means an expiring list (parse "in 60 days", default 30); "missing" plus a project means compliance gaps.
- Answers name the evidence: "Yes. Juan Ortiz has OSHA 30 Construction, completed Mar 14, 2025, no expiration. \[View\]" or "No. Juan Ortiz has no current Flagger certificate; the last one expired Aug 2, 2026."
- When the match is ambiguous, ask: "Did you mean Juan Ortiz or Juana Ortega?"
- Test with at least 30 phrasings, including misspellings and nicknames.

**AI chat (`/chat`, Phase 4b)**

- Use `ruby_llm`'s Rails integration (`acts_as_chat`, `acts_as_message`, `acts_as_tool_call`) to store conversations ([RubyLLM](https://github.com/crmne/ruby_llm)).
- Point `ruby_llm`'s OpenAI-compatible provider at `https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/v1` ([Cloudflare](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility)). Pick `CHAT_MODEL` from catalog models that support function calling. Confirm the exact config keys against the `ruby_llm` docs.
- Tools are read-only `RubyLLM::Tool` classes, scoped to the signed-in user:
  - `find_crew_members(name)`: up to 5 matches with id, name, role, employer, active.
  - `find_certificate_types(query)`: matches from the master list.
  - `check_certificate(crew_member_id, certificate_type_id)`: status, expiry and certificate id.
  - `list_certificates(crew_member_id, include_history)`: current, or all.
  - `who_has(certificate_type_id, status)`: holders filtered by status.
  - `expiring(within_days, project_id)`: certificates expiring soon, optionally for one project.
  - `project_compliance(project_id)`: gaps by person and type.
- System prompt: answer only from tool results; say plainly when a tool returns nothing; never invent names, dates or numbers; format dates as "Mar 14, 2025"; link people as `[Name](/crew_members/:id)`.
- Guardrails: no write tools; at most 6 tool calls per question; Rails 8 `rate_limit` of 10 questions per minute per user; log every question and tool call.
- If the daily budget is used up, answer with the Ask box result and the note "AI chat is paused until tomorrow; here is the direct lookup."
- Add `bin/rails certtrack:eval_chat` with 25 question-and-answer pairs from seed data, and use it to choose `CHAT_MODEL`.

## Cost estimate

Expected running cost is **$0/month**, assuming up to 100 crew members with about 15 certificates each and files averaging 2 MB as uploaded (3 GB). Stored shrunk and without extra copies, that comes to about 0.5-0.7 GB if most files are photos or scans, and up to about 3 GB if most are PDFs made on a computer, which don't shrink. These sizes come from generated samples (storage study, Nov 4, 2026).

| Item | Free allowance | Expected use | Monthly cost |
| --- | --- | --- | --- |
| Oracle A1 VM (app, Postgres, OCR, the nightly file copy) | 2 OCPU, 12 GB RAM, 200 GB disk | One VM, 100 GB boot volume | $0 |
| Cloudflare R2 (files, backups) | 10 GB-month | About 0.5-3 GB of files, under 1 GB of backups | $0; beyond 10 GB $0.015/GB-month, e.g. about $1.37/month at 100 GB (accepted by the owner Nov 4, 2026) |
| Google Workspace email | About 2,000/day per account, shared with the owner's own mail | 30 to 150/month | $0 (existing subscription) |
| Workers AI (imports, chat) | 10,000 neurons/day | A few uploads and questions a day | $0 |
| Domain | Already owned | One subdomain | $0 |
| Optional: Haiku 5.5 for a one-time backlog | n/a | 2,000 pages | About $1, once |
| Optional: Haiku 5.5 for chat | n/a | 1,000 questions | About $1 |

If the Oracle VM becomes unavailable, the lowest-cost managed fallback found is Render at about $13/month (Starter web service plus the smallest Postgres).

## Build phases and checklists

There are six phases, each shippable on its own: the tracker is useful after Phase 2, and AI arrives in Phases 3 and 4. Claude Code ticks these boxes as it finishes each item.

### Phase 0: Accounts, skeleton, deploy

Owner, by hand:

- [ ] Create an Oracle Cloud account with a US West home region. Create one A1 VM (2 OCPU, 12 GB, Ubuntu 24.04 LTS, 100 GB boot volume) and upgrade the tenancy to Pay As You Go. Open ports 80 and 443 in the security list. (Nov 4, 2026: done in Phoenix, except the Pay As You Go upgrade; the tenancy is still on the Free Trial.)
- [x] Create a Cloudflare account, R2 buckets `certtrack-files` and `certtrack-backups`, an R2 API token, and a Workers AI API token. Note the account ID. Add a Cloudflare budget alert so R2 spend past the free 10 GB is never a surprise.
- [ ] Turn on 2-Step Verification for the sending Workspace account (`austen@abaventures.net`), create a CertTrack app password, publish a DMARC record for abaventures.net (it has none; `docs/DEPLOY.md` section 5, step 10), and after the first deploy confirm SPF, DKIM and DMARC pass for abaventures.net. (Nov 4, 2026: all done except the SPF/DKIM/DMARC check on the first email, the admin invitation.)
- [x] On the VM, before the first deploy, create the folder for the nightly file copy (`docs/DEPLOY.md`, "File copies").
- [x] Add a DNS A record pointing `certs.abaventures.net` at the VM's public IP.

Claude Code:

- [x] `rails new certtrack --database=postgresql --css=tailwind` on the latest Rails 8 and Ruby 3.4.
- [x] Add gems: `ruby_llm`, `rubyzip`, `combine_pdf`, `aws-sdk-s3`, `mission_control-jobs`.
- [x] Dockerfile: install `poppler-utils`, `tesseract-ocr`, `tesseract-ocr-eng`, and libvips with HEIC support.
- [x] Kamal: arm64 builder, Postgres 17 accessory with a volume, secrets from `.kamal/secrets`, proxy host `certs.abaventures.net` with SSL, `SOLID_QUEUE_IN_PUMA=1`.
- [x] Rails authentication generator, `role` enum, and `bin/rails certtrack:create_admin`.
- [x] Nightly `Backups::DatabaseJob` (pg\_dump, gzip, upload to R2, keep 30; 14 until Nov 4, 2026) and `bin/rails certtrack:restore_latest`.
- [x] GitHub Actions running tests, RuboCop and Brakeman (the Rails 8 default CI).

Done when: `https://certs.abaventures.net/up` returns 200 with a valid certificate, the admin can sign in, and a backup restores into a scratch database.

Status (Nov 2, 2026): code complete; the app lives in the `cert-track` repo (Rails app name `CertTrack`). Backup and restore are tested locally against Postgres. Still open, and blocked on the owner's accounts and VM: the first `kamal setup`, the live `/up` and TLS check, and a restore drill on the server. The Dockerfile has not been built yet, because Docker isn't available on the dev machine. Steps are in `docs/DEPLOY.md`.

Status (Nov 4, 2026): deployed. `https://certs.abaventures.net/up` returns 200 with a Let's Encrypt certificate, and HTTP redirects to HTTPS. `certtrack:backup_now` uploaded an encrypted backup to `certtrack-backups`, and `certtrack:restore_latest` restored it into a scratch database on the server (1 user, matching production), which was then dropped. The admin `austen@abaventures.net` exists and was sent an invitation; the last done-when item is the owner signing in. The first deploy found the credentials encrypted with a `RAILS_MASTER_KEY` exported for another project, not `config/master.key`. They were regenerated with fresh values before any data existed, and `config/boot.rb` now ignores a mismatching env key.

### Phase 1: Core tracker

- [x] Migrations, models, validations and the model rules from the Data model section.
- [x] Crew CRUD with trigram search and filters.
- [x] Certificate line items with multiple attached files: direct upload to R2, photos and scans stored shrunk (2400 px JPEG at quality 80; scanned PDF pages at 200 ppi), thumbnails.
- [x] Master list CRUD with aliases; seed the example list.
- [x] Projects, requirements editor with optional role, "copy requirements", assignments.
- [x] `Compliance::ProjectReport` service, matrix view, CSV export, packet zip built in a background job (zip kept 7 days; each build's record and index PDF kept for good).
- [x] Dashboard and role-based authorization.

Done when: a project with 5 required types (one role-specific) and 3 assigned people shows correct `missing`, `expired`, `expiring`, `lapses_on_project` and `valid` cells; the packet zip holds the right files with the naming convention; a viewer gets a 403 on every write action.

Status (Nov 2, 2026): met in tests (`test/services/compliance/`, packet tests, `test/integration/authorization_audit_test.rb`). The one exception is that viewers may `POST /projects/:id/packet`, because building a packet only reads data; the audit test allowlists it.

### Phase 2: Expiration emails

- [x] Action Mailer over Google Workspace SMTP (Resend until Nov 4, 2026), digest and weekly mailers with previews.
- [x] `Notifications::ExpiryScanJob` in `config/recurring.yml`, the send log, crew opt-in, daily email cap (`MAIL_DAILY_LIMIT`, default 1,000), "send test digest" button.

Done when: tests using `travel_to` show each threshold fires exactly once, a same-day re-run sends nothing, a missed week sends only the most urgent threshold, and a real digest arrives passing SPF and DKIM.

Status (Nov 2, 2026): every `travel_to` criterion passes in `test/jobs/notifications/`. Still open (updated Nov 4, 2026): a real digest sent through Gmail with SPF, DKIM and DMARC passing for abaventures.net, which waits on the app password.

### Phase 3: Bulk import

- [ ] Spike first: build the accuracy harness, compare 2 or 3 free Workers AI text models and 1 vision model, record scores in this file, set `EXTRACTION_MODEL` and `EXTRACTION_VISION_MODEL`.
- [x] Pipeline steps 1 to 11, the daily budget tracking, and rescheduling on quota errors.
- [x] Review queue with keyboard shortcuts and front/back merge.

Done when: one zip of 20 samples (a nested zip, a multi-certificate PDF, a HEIC photo, a duplicate and a non-certificate page) accounts for every file; the duplicate is flagged; a zip-slip entry is rejected; a simulated quota error reschedules to 00:05 UTC; and field accuracy is 90% or more, or the owner signs off on the review-queue workflow.

Status (Nov 3, 2026): everything except the model spike is met in tests, using the fake AI provider. `test/integration/import_pipeline_acceptance_test.rb` runs a synthetic zip of about 20 files through the whole pipeline, and every file is accounted for:
- the nested zip is read;
- the multi-certificate PDF is split;
- the HEIC photo is read by OCR;
- the duplicate is flagged;
- the course outline goes to review;
- the zip-slip entry is rejected;
- exactly one summary email is sent.

`test/jobs/imports/ai_extract_job_test.rb` covers the 00:05 UTC reschedule. Since the first pass, these were added:
- a "Read again" action (`Imports::Reread`);
- a separate `imports` job queue, so backups and expiry emails never wait behind an import;
- import summaries now count toward the daily email cap.

Still open:
- The spike. The harness (`bin/rails certtrack:eval_extraction`, `docs/IMPORT_SPIKE.md`) is built. Comparing models and the 90% accuracy check wait on real samples in `test/fixtures/import_samples/` and a Workers AI token.
- Until `EXTRACTION_MODEL` is set, production imports stop at the AI step with a clear message.
- Keep `AUTO_ACCEPT_ENABLED` false until about 100 imported items have been reviewed by hand.

### Phase 4: Ask box and AI chat

- [x] 4a: `AskQuery`, `/ask`, 30-phrasing test suite.
- [ ] 4b: `ruby_llm` chat persistence, the seven read-only tools, system prompt, rate limit, budget fallback, `certtrack:eval_chat`.

Done when: the Ask box answers all 30 phrasings correctly and chat scores at least 22 of 25 with no invented names, dates or numbers.

Status (Nov 3, 2026): 4a is met. `test/services/ask_query_test.rb` has 128 phrasings, all passing. They cover:
- typos and nicknames;
- expiring, expired and lacking lists;
- project gaps and project requirements;
- time windows.

The Ask box uses no AI. 4b is not started.

### Phase 5: Hardening (optional)

- [ ] Crew self-upload: a signed, expiring link per crew member opens a phone camera upload that feeds the review queue.
- [ ] A `certificate_events` table recording who created, edited, verified or superseded each certificate.
- [ ] Error emails to admins via a `Rails.error` subscriber, plus a free uptime monitor on `/up`.
- [ ] A written restore drill, rehearsed once.

### Storage and email changes (Nov 4, 2026)

A storage study found that most stored bytes were copies nothing read: a zipped iPhone photo was stored 4 to 5 times, and every packet added a full copy of its files for good. The owner decided the points below on Nov 4, 2026. Nothing was deployed yet, so no data needed moving.

Owner decisions:

- [x] Stay on R2 and pay its overage past 10 GB ($0.015/GB-month), with a Cloudflare budget alert (`docs/DEPLOY.md`, section 3).
- [x] Delete packet zips 7 days after they are built, and keep each build's index PDF as the record of what was sent (`PacketBuild`, `Maintenance::PurgeOldPacketsJob` at 03:50).
- [x] Store photos and scans shrunk to 2400 px, JPEG quality 80, without the full-size original (`Certificates::ShrinkFilesJob`, which replaces the HEIC-only `ConvertHeicJob`).
- [x] Copy the certificate files from R2 to the VM's own disk every night, and keep copies of deleted files 30 days (`Backups::FileCopyJob` at 04:15; `certtrack:copy_files_now`, `certtrack:file_copy_status` and `certtrack:restore_files`; a dashboard banner for admins).
- [x] Send email through the owner's Google Workspace account instead of Resend (`smtp.gmail.com:587`, an app password, `MAIL_DAILY_LIMIT` 1,000).
- [x] Keep 30 nightly database backups instead of 14 (`Backups::Storage::DEFAULT_KEEP`), so a deleted file's copy can be found by name for its whole 30 days in the trash. About 30 extra small encrypted dumps in R2.
- [x] Leave location data (EXIF/GPS) on import files while they wait for review; it is removed when a file is accepted and shrunk.
- [x] Rejected import items keep their files: they stay the original for duplicate detection, and "Read again" can undo a wrong rejection. Only failed items' files are deleted, 30 days after they failed.

Fixes that needed no decision:

- [x] Raw uploads are deleted once unpacked.
- [x] Accepting an import moves its file to the certificate. Deleting the certificate, or removing one of its files, now deletes the stored file, and no copy stays behind on the import pages.
- [x] HEIC review previews are stored as a JPEG at quality 80 instead of a 2-4 MB PNG.
- [x] PDF thumbnails come from a 320 px JPEG instead of a full-page PNG.

The plan's volume (1,500 certificates at 2 MB) should now take about 0.5-0.7 GB instead of 11-13 GB, judging from generated samples. `test/integration/certificate_storage_lifecycle_test.rb` follows one zip (an iPhone HEIC photo and a scanned PDF) from the drop zone through review, shrinking, the nightly copy, a packet and its purge, to deletion.

Still open:

- Run the shrink legibility check on real samples once `test/fixtures/import_samples/` has some, since a shrunk file replaces its original for good.
- After the first deploy, open a PDF thumbnail and a shrunk photo. The production image has older libvips and poppler than the dev machine.

## Risks, security and open questions

The biggest risk of the $0 design is that free tiers can change or be withdrawn. Every free dependency therefore has a backup or a paid fallback that costs cents to $13/month.

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Oracle reclaims the idle VM or cuts the free tier again | App offline | Pay As You Go upgrade, nightly backups in R2, `kamal setup` plus restore rebuilds in under an hour, Render fallback at about $13/month |
| Free AI allocation too small for the first backlog | Imports take days | Automatic rescheduling; optional one-time Haiku run for about $1 |
| Free model misreads a name or date | Wrong compliance data | Auto-accept off by default, review queue, accuracy harness |
| Workers AI retires a model | Extraction or chat errors | Model IDs live in env vars; re-run the eval tasks and swap |
| Gmail's per-account limit (about 2,000/day, shared with the owner's mail) | Some emails a day late; if the account hits Gmail's limit, the owner's own mail is refused too | `MAIL_DAILY_LIMIT` 1,000 leaves about half for the owner; the digest design |
| Stored files grow past R2's free 10 GB | R2 bills $0.015/GB-month, about $1.37/month at 100 GB | Photos and scans stored shrunk, packet zips deleted after 7 days, a Cloudflare budget alert; the owner accepted the cost on Nov 4, 2026 |
| Files deleted from R2 by mistake, or the Cloudflare account lost | Certificate files gone | The nightly copy on the VM's disk; `certtrack:restore_files` puts files back; copies of deleted files are kept 30 days, findable by name the whole time (30 database backups are kept) |
| Single VM, no redundancy | Downtime during outages | Acceptable for an internal tool; uptime alerts |

**Security and privacy (required, not optional)**

- Certificates carry personal data, and CDL cards can show license numbers and dates of birth. Keep both R2 buckets private. Serve files only through authenticated Rails endpoints with signed URLs that expire within 5 minutes.
- Encrypt `certificate_number` with Active Record encryption (`encrypts`). Purge `extracted_text` and `extraction` 30 days after an item is accepted, rejected, failed or marked duplicate (items still waiting for review keep theirs).
- Import files: raw uploads are deleted once unpacked and never kept more than 30 days. A failed item's file is deleted 30 days after it failed. Rejected items keep their files, as the original for duplicate detection. An accepted file belongs only to its certificate, so deleting the certificate, or removing one of its files, deletes the stored file. `Maintenance::PurgeImportExtractionsJob` (nightly, 03:45) does all of this: first the failed items' files, then any uploads still kept, then the extracted text.
- Certificate photos are stored without their EXIF, XMP and IPTC metadata, GPS location included (`Certificates::ShrinkFilesJob`). Two exceptions: a file libvips can't read is kept as it is, and a scanned PDF's page images keep whatever they hold. Import files are stored as uploaded, metadata included, until they are accepted: items waiting for review, rejected items (kept for good) and failed items (30 days). Only editors can open them. The nightly VM copy holds them too, and keeps its copy of a photo replaced on acceptance in its trash for 30 days.
- Packet zips hold full copies of the crew's files, so they live at most 8 days and 4 hours: through the 7th day after the build day, then the 03:50 purge. Index PDFs hold crew names, certificate numbers and dates, and are kept for good as the record of what was sent (owner's decision, Nov 4, 2026). They go only with their project, and a project with past builds can't be deleted.
- The nightly file copies on the VM are plain files that only the app's user and root can read (files 0600, folders 0700), on the same machine as the database. They are not encrypted.
- Encrypt database dumps with a key from Rails credentials before uploading them to R2.
- Data leaves the VM only to Cloudflare (storage and Workers AI), Google (email content, through the owner's Workspace account) and, if switched on, Anthropic. Nothing else.
- Invite-only accounts with no public sign-up, `force_ssl`, and the generator's built-in rate limit on sign-in.

**Open questions for the owner**

- [ ] Roughly how many crew members and active projects are there?
- [ ] What is the real master list, and how many months is each type valid?
- [ ] Should crew members get their own expiry emails, and are subcontractor workers tracked in the same roster?
- [ ] Who should receive the daily and weekly digests?
- [ ] Do any prime contractors require a specific packet format or cover sheet?

## Sources

Prices and limits checked November 2, 2026; R2, Cloudflare billing and Google Workspace entries checked November 4, 2026.

- [Oracle Cloud Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm): A1 allowance, block storage, egress, idle reclamation
- [InfoQ: Oracle cuts Always Free A1 allowance](https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/)
- [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- [Cloudflare Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
- [Cloudflare Workers AI data usage](https://developers.cloudflare.com/workers-ai/privacy/)
- [Cloudflare Workers AI OpenAI-compatible endpoints](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility)
- [Cloudflare budget alerts](https://developers.cloudflare.com/billing/manage/budget-alerts/): email when usage-based spend crosses a dollar threshold; no cap
- [Gmail sending limits in Google Workspace](https://support.google.com/a/answer/166852): 2,000 messages/day per user (500 on trials), over a rolling 24 hours
- [Google: sign in with app passwords](https://support.google.com/accounts/answer/185833): needs 2-Step Verification; revoked when the account password changes
- [Claude API pricing](https://platform.claude.com/docs/en/docs/about-claude/pricing): Haiku 5.5 rates
- [Claude PDF support](https://platform.claude.com/docs/build-with-claude/pdf-support): 1,500 to 3,000 tokens per page
- [Gemini API billing](https://ai.google.dev/gemini-api/docs/billing): free-tier data use
- [Render: hosting costs for small businesses](https://render.com/articles/how-much-does-cloud-application-hosting-cost-for-small-businesses)
- [RubyLLM](https://github.com/crmne/ruby_llm)
- [Solid Queue](https://github.com/rails/solid_queue)
