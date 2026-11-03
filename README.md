# CertTrack

CertTrack is an internal Rails 8.1 app for ABA Ventures that tracks crew certificates against each project's
requirements. It keeps a crew roster with dated certificate records and attached files, a master list of certificate
types that each project picks from (optionally per crew role), and a per-project compliance matrix. It also emails
expiry warnings, bulk-imports scanned cards with AI extraction plus a human review queue, and answers questions such as
"does Juan Ortiz have OSHA 30?". The full spec, locked stack decisions and phase checklists are in
[docs/PLAN.md](docs/PLAN.md).

## Prerequisites

| Tool | Version | Why |
| --- | --- | --- |
| Ruby | 3.4.12 (`.ruby-version`) | Any version manager works (chruby, rbenv, mise) |
| PostgreSQL | 17 or newer, plus `pg_dump`/`psql` of the server's major version | Production runs 17, so avoid 18-only features. Backup tests shell out to `pg_dump`/`psql` |
| libvips | 8.13 or newer, built with libheif and the libde265 plugin | Active Storage variants, thumbnails, HEIC to JPEG |
| poppler | `pdftotext`, `pdftoppm` | PDF text extraction and page images for import |
| Tesseract | with English data | OCR for scanned certificates |

By default `config/database.yml` connects over the local socket as your OS user, so that role needs `CREATEDB`.
Otherwise set `DATABASE_URL`, e.g. `postgres://postgres:postgres@localhost:5432`.

**Ubuntu 24.04**

```sh
sudo apt-get install libpq-dev libvips42t64 libheif-plugin-libde265 poppler-utils tesseract-ocr tesseract-ocr-eng
# PostgreSQL 17 from the PGDG repo (https://www.postgresql.org/download/linux/ubuntu/)
sudo apt-get install postgresql-common && sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
sudo apt-get install postgresql-17
```

**macOS**

```sh
brew install postgresql@17 vips poppler tesseract
```

**Ubuntu 22.04**: the system libvips (8.12) is too old for Rails 8.1. Install libvips, poppler and Tesseract from
conda-forge into their own prefix, then point the dynamic loader at it:

```sh
conda create -y -p ~/cert-tools -c conda-forge --override-channels libvips poppler tesseract
export LD_LIBRARY_PATH="$HOME/cert-tools/lib"
export PATH="$PATH:$HOME/cert-tools/bin"   # append, so conda's binaries don't shadow system ones
```

Set those two variables only in shells you use for this project (for example a sourced env file or direnv), not in
`~/.bashrc`, because `LD_LIBRARY_PATH` affects every program.

Check that libvips is new enough and can read HEIC:

```sh
bundle exec ruby -rvips -e 'puts "libvips #{Vips.version_string}, HEIF #{Vips.type_find("VipsOperation", "heifload").zero? ? "missing" : "ok"}"'
```

## Setup and running

```sh
bin/setup                 # bundle install, db:prepare, clear logs and tmp, then start bin/dev
bin/setup --skip-server   # the same, without starting the server
bin/dev                   # Rails on http://localhost:3000 plus the Tailwind watcher (Procfile.dev)
```

There is no public sign-up. Create the first admin, then invite everyone else from **Users** (`/users`):

```sh
bin/rails certtrack:create_admin EMAIL=you@example.com NAME="Your Name"
```

On a terminal it prompts for the password. Without a terminal it generates one and prints it once. Running it for an
existing user promotes that user to admin, and the user keeps their password unless you pass `PASSWORD=`.

Mailer previews are at `/rails/mailers` in development. In production the Solid Queue dashboard is at `/jobs` (admins
only).

## Tests and CI

```sh
bin/rails test                     # Minitest + fixtures
bin/rails test test/models/user_test.rb
PARALLEL_WORKERS=1 bin/rails test  # run serially
```

`TEST_DB_SUFFIX` gives a run its own test database (`cert_track_test<suffix>`), so several runs can share one Postgres
server:

```sh
TEST_DB_SUFFIX=_mine bin/rails db:test:prepare
TEST_DB_SUFFIX=_mine bin/rails test
```

Tests make no network calls. S3/R2, SMTP and AI providers are stubbed. The test environment uses fixed Active Record
encryption keys (`config/environments/test.rb`), so tests and CI don't need `config/master.key`.

`bin/ci` runs the same checks as GitHub Actions, in the order set in `config/ci.rb`: setup, RuboCop, bundler-audit,
importmap audit, Brakeman, tests, a seeds check, and system tests once `test/system` exists. Note that its setup step
runs `bin/setup --skip-server`, which prepares the development database and clears `log/` and `tmp/`.

GitHub Actions (`.github/workflows/ci.yml`) runs these jobs:

- `scan_ruby`: Brakeman and bundler-audit.
- `scan_js`: importmap audit.
- `lint`: RuboCop (omakase).
- `test`: a `postgres:17` service plus the apt packages above, with `postgresql-client-17` from PGDG first on `PATH`.
- `system-test`: skipped until system tests exist.

`bin/brakeman` runs with `--ensure-latest`, so CI fails as soon as a newer Brakeman is released. Merge Dependabot's
weekly update PR or run `bundle update brakeman` to fix it.

## Deploy

CertTrack deploys with Kamal 2 to an Oracle Cloud ARM64 VM, with PostgreSQL 17 as an accessory, Cloudflare R2 for
files and backups, and Resend for email. See [docs/DEPLOY.md](docs/DEPLOY.md).

## Status

Phase checklists (Phase 0 skeleton and deploy through Phase 5 hardening) live in [docs/PLAN.md](docs/PLAN.md) under
"Build phases and checklists".
