# Jarvis database

PostgreSQL storage foundation for Jarvis: trusted devices, conversation history,
conversation summaries and long-term memory. Everything here is designed for a
single personal account on Supabase PostgreSQL, reached only by server-side code.

No database has been created, no credentials exist in this repository, and no
application code reads these tables yet. This directory is schema, tests and the
development-only setup workflow; the [Supabase development project](#supabase-development-project)
section below is the one to follow once you have a project.

## Layout

| Path                                  | What it is                                                                                           |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `migrations/`                         | Timestamped, forward-only SQL migrations                                                             |
| `tests/`                              | SQL assertion suites run against a scratch database                                                  |
| `scripts/test-db.sh`                  | Runs migrations + tests in a throwaway container (Linux, macOS, WSL, Git Bash)                       |
| `scripts/test-db.ps1`                 | Same, for Windows PowerShell                                                                         |
| `scripts/bootstrap-test-roles.sql`    | Creates the client roles the access-control tests need, before migrations run                        |
| `scripts/bootstrap-supabase-like.sql` | Optional: recreates the pre-existing `extensions` schema and extensions a fresh Supabase project has |

## Running the tests

Docker is the only requirement. No local `psql`, no Supabase project, no
credentials: the script starts a temporary `postgres` container with trust
authentication, creates the Supabase client roles (`anon`, `authenticated`,
`service_role`) plus two ordinary test roles, applies every migration in filename
order, runs every test file, then deletes the container. The roles are created
first so the access-control migration's revokes are exercised against roles that
actually exist, and the tests assert that rather than skipping.

```bash
./supabase/scripts/test-db.sh
```

```powershell
pwsh -File supabase/scripts/test-db.ps1
```

Set `JARVIS_TEST_POSTGRES_IMAGE` to test another server version (`postgres:17`).
PostgreSQL 15 or newer is required: ownership is enforced with composite foreign
keys that use the `ON DELETE SET NULL (column)` form introduced in 15.

Set `JARVIS_TEST_SUPABASE_LIKE=1` to start from the state a fresh Supabase
project is in — the `extensions` schema exists and `pgcrypto` and `pg_trgm` are
already installed there — instead of an empty database. This is the closest
local approximation of a hosted project, and it is how the "compatible with
Supabase" claim above is checked:

```bash
JARVIS_TEST_SUPABASE_LIKE=1 ./supabase/scripts/test-db.sh
JARVIS_TEST_POSTGRES_IMAGE=postgres:17 JARVIS_TEST_SUPABASE_LIKE=1 ./supabase/scripts/test-db.sh
```

```powershell
$env:JARVIS_TEST_SUPABASE_LIKE = '1'; pwsh -File supabase/scripts/test-db.ps1
```

The suites cover the schema shape, seed idempotency, ownership constraints
(including pairing-code consumption), sequence allocation under real concurrency
(two `dblink` sessions, one blocking on the other's row lock, with bounded
`statement_timeout`/`lock_timeout` so a broken assumption fails instead of
hanging), deletion behaviour, uniqueness/idempotency, and the access-control
posture — catalog checks plus a behavioural RLS test with a role that has been
granted everything a leaked client would need.

## Migrations

| File                                               | Contents                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------- |
| `20261118120000_jarvis_schema_and_users.sql`       | `jarvis` schema, extensions, `users`, single-row guard, `updated_at` trigger    |
| `20261118120100_jarvis_devices.sql`                | `devices`, `device_credentials`, `pairing_codes`                                |
| `20261118120200_jarvis_conversations.sql`          | `conversations`, `messages`, `conversation_summaries`, `allocate_message_seq()` |
| `20261118120300_jarvis_memories.sql`               | `memories`, soft delete, permanent delete, purge                                |
| `20261118120400_jarvis_seed_single_user.sql`       | Idempotent account seed                                                         |
| `20261118120500_jarvis_access_control.sql`         | Revokes, default privileges, RLS enablement                                     |
| `20261118120600_jarvis_pairing_code_ownership.sql` | Composite pairing-code ownership; corrected function-privilege documentation    |
| `20261119130000_jarvis_device_challenges.sql`      | Persistent one-time device challenges, RLS-enabled and grant-free               |

Order matters and is implied by the filenames: the schema and account come first,
then devices, then conversations and memories, then the seed, then the
access-control lockdown, and finally the ownership correction for pairing codes.
`supabase db push` applies them in filename order and records each version in
`supabase_migrations.schema_migrations`; a version that is already recorded is
skipped, so a timestamp must never be changed once it has been applied.

Rules:

- **Forward-only.** Never edit an applied migration; add a new timestamped file.
  There are no down migrations, because they are rarely tested and often wrong.
- **One transaction per file**, so a failed migration leaves nothing behind.
- **Never store credentials.** No access codes, API keys, tokens, pairing codes in
  plaintext, or private keys. Only SHA-256 digests and public keys belong here.
- **Never hardcode identity.** The account row gets its display name from the
  `jarvis.display_name` setting at seed time (default: `Jarvis User`).
- Generate names with the Supabase CLI convention (`YYYYMMDDHHMMSS_name.sql`) so
  `supabase db push` and the local runner agree on order.

`pnpm test` (in `frontend/`) includes `test/supabase-migrations.test.ts`, which
fails if a filename breaks the convention, versions are out of order or
duplicated, a file is not exactly one `begin;` … `commit;` transaction, a
required table or function is missing, or a migration contains a connection
string or a `NEXT_PUBLIC_` variable.

### Compatibility with Supabase PostgreSQL

Verified locally against PostgreSQL 16 and 17, including a run that starts from
the state a fresh Supabase project is in
(`JARVIS_TEST_SUPABASE_LIKE=1`, see below):

- PostgreSQL 15 or newer is required, and the first migration refuses to run on
  anything older with a clear message.
- Supabase already ships an `extensions` schema with `pgcrypto` and `pg_trgm`
  installed there. The first migration uses `if not exists` for all three, and
  the memories migration addresses `extensions.digest(...)` explicitly, so both
  a plain database and a Supabase project end up identical.
- The access-control migration revokes from `anon`, `authenticated` and
  `service_role` only when those roles exist, which they always do on Supabase.
- `alter default privileges` and the revokes assume migrations run as the
  database owner (`postgres`), which is what the Supabase CLI uses.
- Each file is an explicit transaction. The CLI sends a migration file as one
  batch, so the inner `begin;`/`commit;` is harmless: it is the outermost
  transaction either way, and a failure still rolls the whole file back.
- `gen_random_uuid()`, `to_tsvector('english', …)`, `gin_trgm_ops`, generated
  columns and column-list `ON DELETE SET NULL` are all supported.

## Supabase development project

This repository contains no project, no credentials and no remote migration
history. Everything below is a manual step you perform once, on your machine,
against a **development** project. Never point it at production.

### 1. Create the project

1. In the Supabase dashboard, create a project named `jarvis-dev` in the region
   closest to you. Use the free plan unless you have a reason not to.
2. Choose a strong database password and store it in your password manager. Do
   not put it in a file, a shell history you keep, or this repository.
3. Do not enable any Auth providers. This design has no Supabase Auth.

### 2. Collect the two connection strings

Project Settings → Database → **Connection string**. You need two, and they are
not interchangeable:

| Use                   | Dashboard name                                                         | Host / port                 | Goes in        |
| --------------------- | ---------------------------------------------------------------------- | --------------------------- | -------------- |
| Application runtime   | **Transaction pooler**                                                 | `…pooler.supabase.com:6543` | `DATABASE_URL` |
| Migrations and checks | **Direct connection** (or **Session pooler** if direct is unavailable) | `db.<ref>.supabase.co:5432` | `DIRECT_URL`   |

Both are `postgresql://` URLs with TLS. If your password contains characters
such as `@`, `:`, `/` or `?`, percent-encode them or the URL will parse wrongly.
Add `?sslmode=require` if the dashboard's copy button omits it.

Put them in `frontend/.env.local`, which is git-ignored:

```env
DATABASE_URL=postgresql://postgres.<ref>:<password>@<region>.pooler.supabase.com:6543/postgres
DIRECT_URL=postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres
```

`DIRECT_URL` is for the CLI and the verification script only. Do not add it to
Vercel, do not give it to the Python agent, Flutter or the browser, and never
prefix either variable with `NEXT_PUBLIC_`.

### 3. Apply the migrations

The CLI needs a project config file. This repository does not commit one (it is
git-ignored), because it pins CLI-version-specific defaults:

```bash
# From the repository root (this file lives in supabase/):
supabase init           # creates supabase/config.toml; leaves migrations/ alone
```

Then apply the migrations through the direct connection. Check what would run
first, then apply:

```bash
# Load DIRECT_URL from the file you already filled in.
set -a; . frontend/.env.local; set +a

supabase db push --remote "$DIRECT_URL" --dry-run   # lists pending migrations, changes nothing
supabase db push --remote "$DIRECT_URL"             # asks once; default answer is No
```

In PowerShell, load the value without retyping it (this reads the file, so the
string never enters your shell history):

```powershell
$env:DIRECT_URL = (Select-String -Path frontend/.env.local -Pattern '^DIRECT_URL=(.*)$').Matches.Groups[1].Value
supabase db push --remote "$env:DIRECT_URL" --dry-run
supabase db push --remote "$env:DIRECT_URL"
```

Notes:

- `--remote "$DIRECT_URL"` is the CLI v3 spelling. On older CLIs the equivalent
  flag is `--db-url "$DIRECT_URL"`. If you instead `supabase link <ref>` and run
  a bare `supabase db push --remote`, the CLI resolves the project's own direct
  connection — also fine, but the explicit URL makes it obvious that migrations
  never go through the pooler.
- The first push creates `supabase_migrations.schema_migrations`.
- Do not run `supabase db reset --remote` against a database you care about.
  Never run any of these commands against production.
- If a push fails halfway, the failing file rolled back and was not recorded;
  fix the file (or add a new migration) and push again. Do not edit the history
  table by hand unless you are repairing a known mismatch.

### 4. Verify the setup

After the push, run the read-only checks from `frontend/`:

```powershell
cd frontend
pnpm db:verify --development
```

On Linux or macOS the same command works unchanged. The script loads
`.env.local` automatically and refuses to run without `--development`, so it
cannot be pointed at production by accident.

It prints each connection as `pooled:6543/postgres` or `direct:5432/postgres`
(never the host or password), then runs these checks:

| Check                                    | What it proves                                                          |
| ---------------------------------------- | ----------------------------------------------------------------------- |
| `env-no-public-variable`                 | No `NEXT_PUBLIC_DATABASE_URL` exists to leak into the bundle            |
| `env-separate-endpoints`                 | Runtime and migrations use different connection strings                 |
| `env-runtime-pooling`                    | `DATABASE_URL` is the transaction pooler (warns on port 5432)           |
| `env-runtime-tls` / `env-migrations-tls` | Remote connections keep TLS enabled                                     |
| `admin-connection`                       | The direct endpoint is reachable; otherwise the run stops here          |
| `server-version`                         | PostgreSQL is 15 or newer                                               |
| `migrations-applied`                     | Every version in `supabase/migrations` is in the history table          |
| `schema-objects`                         | All 9 tables and 5 functions exist                                      |
| `rls-enabled`                            | Row level security is on for every table                                |
| `client-roles-denied`                    | `anon`, `authenticated`, `service_role` and `PUBLIC` hold no privileges |
| `seed-account`                           | Exactly one account row exists                                          |
| `runtime-connect` / `runtime-read`       | The pooled connection works and can read `jarvis.users`                 |

Exit code `0` means the setup is usable, `1` means something failed, `2` means
the `--development` flag was missing. Every statement is a `select`; the script
never writes, migrates or seeds.

### 5. Point the app at it locally (optional)

`DATABASE_URL` in `frontend/.env.local` is already enough for `pnpm dev`. The
token endpoint and the LiveKit UI do not read the database yet, so a broken
database connection does not affect them.

When you deploy, add **only** `DATABASE_URL` (the pooled string) to the Vercel
project's environment variables, for Production and Preview separately. Keep
`DIRECT_URL` on your machine.

### Safety rules

- One development project, one password manager entry, zero secrets in git.
  `.env`, `.env.*`, `supabase/.temp/`, `supabase/config.toml` and `supabase/.env`
  are ignored.
- Run `--dry-run` before every push, and read the list it prints.
- Take a manual backup or restore point before any destructive change
  (`supabase db dump --remote "$DIRECT_URL"` writes a file, not a secret).
- If you ever suspect the database password leaked, rotate it in the dashboard;
  the connection strings change and nothing else in this repository needs to.
- The service-role key and the anon key are not used by this design. Do not add
  them to the frontend environment.

## Security model

- Tables live in the `jarvis` schema, not `public`. The Supabase Data API only
  exposes configured schemas, so the browser cannot reach them.
- `PUBLIC`, `anon`, `authenticated` and `service_role` hold no privileges on the
  schema, its tables, sequences or functions. `service_role` is denied by
  privileges even though it has `BYPASSRLS`, matching how Supabase configures it.
- **Default privileges cannot revoke the built-in `EXECUTE` on functions.**
  PostgreSQL grants `EXECUTE` to `PUBLIC` when a function is created, and that
  grant is not recorded in `pg_default_acl`, so `ALTER DEFAULT PRIVILEGES ...
REVOKE ALL ON FUNCTIONS FROM PUBLIC` leaves it in place. Every function added to
  this schema must therefore be followed, in the same transaction, by
  `REVOKE EXECUTE ON FUNCTION jarvis.<name>(<argument types>) FROM PUBLIC;`.
  Revoking schema `USAGE` from `PUBLIC` is the control that keeps clients out if a
  function is missed; it is depth, not a substitute.
- Row level security is enabled on every table with **zero policies**. It is a
  backstop, not the primary control: the application connects as the schema owner
  over a server-only pooled connection, and owners are not subject to RLS.
- If a dedicated non-owner application role is introduced later, it needs explicit
  policies or `BYPASSRLS`. Both are a deliberate decision, never a default.
- No Supabase Auth. Single account, no browser-side database access, and device
  trust is Jarvis's own concern. Revisit only if multi-device sharing needs it.
- The Python agent never receives a connection string. It will call authenticated
  Next.js endpoints in a later stage.
- Flutter and browser code never receive database access of any kind.

## Data model notes

- `devices` owns `(id, user_id)` as a unique pair; `conversations`, `messages`,
  `conversation_summaries`, `memories` and `pairing_codes` reference it through
  composite foreign keys. A row cannot point at another account's device,
  conversation or message, even if application code is wrong. A pairing code can
  only be consumed by a device of its own account.
- `messages.seq` is allocated by `jarvis.allocate_message_seq()`. The `UPDATE`
  takes a row lock on the conversation, so concurrent writers queue and receive
  different numbers; `unique (conversation_id, seq)` is the backstop. Gaps are
  expected when a reserved number is never used.
- `messages.agent_item_id` is unique per conversation, so a retried agent write
  can use `on conflict ... do nothing` instead of duplicating a turn.
- `memories.content_hash` is a stored generated column: SHA-256 of the trimmed,
  lowercased content, hex encoded. It deduplicates active memories only, so a
  forgotten fact can be remembered again.
- History and memory are separate tables with separate lifecycles. Deleting a
  conversation removes its messages and summaries and leaves memories intact,
  with their provenance nulled out.
- Memory search uses `tsvector` and trigram indexes today. A nullable `vector`
  column plus an HNSW index can be added later without a table rewrite, so
  pgvector is deliberately not enabled yet.

### Deletion behaviour

| Action                                     | Effect                                                                                                                                                     |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Delete an account (`users` row)            | Cascades to devices, credentials, pairing codes, conversations, messages, summaries and memories                                                           |
| Delete a conversation                      | Its messages and summaries go; memories survive with provenance set to null                                                                                |
| Delete a device                            | Its credentials go; conversations and messages keep existing with `device_id` null, and pairing codes keep their account with `consumed_by_device_id` null |
| `jarvis.delete_memory(id, user, false)`    | Soft delete: `status = 'deleted'`, `deleted_at` stamped                                                                                                    |
| `jarvis.delete_memory(id, user, true)`     | Permanent delete: the row is gone immediately                                                                                                              |
| `jarvis.purge_deleted_memories('30 days')` | Removes soft-deleted memories past the undo window                                                                                                         |

## Environment variables

No values belong in this repository. `.env`, `.env.*`, `supabase/.temp/` and
`supabase/config.toml` are git-ignored, and `frontend/.env.example` documents the
two the app cares about.

| Scope                                          | Variable                                                               |
| ---------------------------------------------- | ---------------------------------------------------------------------- |
| Vercel / Next.js server                        | `DATABASE_URL` (pooled transaction endpoint, TLS)                      |
| Local tooling, migrations and `pnpm db:verify` | `DIRECT_URL` (direct endpoint)                                         |
| Supabase CLI on a developer machine            | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, `SUPABASE_DB_PASSWORD` |
| Python agent (later)                           | `JARVIS_API_BASE_URL`, `JARVIS_SERVICE_TOKEN`                          |

`DATABASE_URL` and `DIRECT_URL` both live in `frontend/.env.local` on a
developer machine; only `DATABASE_URL` is added to Vercel. No `NEXT_PUBLIC_`
database variable, ever. The Supabase anon and service-role keys are not used by
this design.

## Deliberately not in this stage

Device pairing flows, device assertion verification, `/api/*` history or memory
endpoints, the Python agent client, the management UI, pgvector embeddings and the
region choice for the Supabase project.
