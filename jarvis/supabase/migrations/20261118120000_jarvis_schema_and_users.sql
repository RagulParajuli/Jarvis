-- 20261118120000 — Jarvis storage foundation: schema, extensions, account row.
--
-- Conventions for every file in supabase/migrations:
--   * timestamped, forward-only; corrections arrive as a new file, never as an edit
--   * exactly one transaction per file, so a failed run leaves nothing behind
--   * no credential, token, access code or personal identifier is ever stored in SQL
--
-- The `jarvis` schema is deliberately not `public`: the Supabase Data API only
-- exposes configured schemas, so these tables are unreachable from the browser
-- even if a key is leaked. See 20261118120500_jarvis_access_control.sql.

begin;

-- Composite foreign keys below use the PostgreSQL 15 `ON DELETE SET NULL
-- (column)` form. Fail early and clearly instead of with a syntax error.
do $$
begin
    if current_setting('server_version_num')::integer < 150000 then
        raise exception
            'Jarvis requires PostgreSQL 15 or newer (composite foreign keys with column-list SET NULL).';
    end if;
end;
$$;

create schema if not exists jarvis;

comment on schema jarvis is
    'Jarvis application tables. Not exposed through the Supabase Data API; '
    'reachable only by the server-side database role.';

-- Supabase keeps extensions in `extensions`; plain PostgreSQL has no such
-- schema, so create it to keep local and hosted environments identical.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create table jarvis.users (
    id uuid primary key default gen_random_uuid(),
    display_name text not null default 'Jarvis User',
    timezone text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint users_display_name_length
        check (char_length(btrim(display_name)) between 1 and 120),
    constraint users_timezone_length
        check (timezone is null or char_length(btrim(timezone)) between 1 and 64)
);

comment on table jarvis.users is
    'Account owner. Personal deployment: exactly one row, enforced by users_single_row.';
comment on column jarvis.users.display_name is
    'Presentation name only, never derived from an identity provider. Configure it with '
    '`set jarvis.display_name` before seeding; nothing personal is hardcoded here.';

-- Personal deployment guard. Dropping this index is the only structural change
-- needed to allow more than one account later.
create unique index users_single_row on jarvis.users ((true));

create or replace function jarvis.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = jarvis, pg_temp
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

comment on function jarvis.set_updated_at() is
    'Keeps updated_at accurate for rows changed in place.';

create trigger users_set_updated_at
    before update on jarvis.users
    for each row execute function jarvis.set_updated_at();

commit;
