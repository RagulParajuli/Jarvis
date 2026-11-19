-- 20261119130000 — Persistent one-time device challenges.
--
-- S5.3 needs a server-issued, short-lived challenge that can be consumed once.
-- The nonce is stored only as a SHA-256 hex digest, like pairing codes, and is
-- bound to both the device and the intended API audience. A single atomic
-- `UPDATE ... WHERE consumed_at is null` at consumption time is what makes a
-- challenge one-time; an in-memory nonce or a client timestamp cannot provide
-- that guarantee across serverless instances or restarts.
--
-- Ownership follows the established pattern: `devices` owns `(id, user_id)` as
-- a unique pair, and this table proves with a composite foreign key that a
-- challenge can only ever belong to a device of its own account.

begin;

create table jarvis.device_challenges (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references jarvis.users (id) on delete cascade,
    device_id uuid not null,
    nonce_hash text not null,
    audience text not null,
    expires_at timestamptz not null,
    consumed_at timestamptz,
    created_at timestamptz not null default now(),

    constraint device_challenges_nonce_hash check (nonce_hash ~ '^[0-9a-f]{64}$'),
    constraint device_challenges_nonce_unique unique (nonce_hash),
    constraint device_challenges_audience check (char_length(audience) between 1 and 64),
    constraint device_challenges_expires check (expires_at > created_at),
    constraint device_challenges_consumed check (consumed_at is null or consumed_at >= created_at),

    constraint device_challenges_device_ownership
        foreign key (device_id, user_id)
        references jarvis.devices (id, user_id)
        on delete cascade
);

comment on table jarvis.device_challenges is
    'Server-issued one-time challenges for device assertions. Only the SHA-256 digest '
    'of the nonce is stored; each row is bound to one device and one API audience.';
comment on column jarvis.device_challenges.nonce_hash is
    'SHA-256 hex of the challenge nonce. The plaintext exists only in the response that issues it.';
comment on column jarvis.device_challenges.audience is
    'The API this challenge was issued for; consumption must require the same value.';
comment on column jarvis.device_challenges.consumed_at is
    'Set exactly once, under a row lock, when the matching assertion is accepted.';

create index device_challenges_device_idx
    on jarvis.device_challenges (user_id, device_id)
    where consumed_at is null;

-- Deny by default, as in 20261118120500: RLS with no policies is a backstop, not
-- the primary control. The application connects as the schema owner.
alter table jarvis.device_challenges enable row level security;

-- No SECURITY DEFINER function is introduced here; this migration creates no
-- function at all. The revokes below are defence in depth: default privileges
-- already prevent future client-role grants, but an explicit statement keeps the
-- posture visible next to the new table. Roles are guarded because a plain
-- Postgres database does not have the Supabase client roles.
revoke all on jarvis.device_challenges from public;

do $$
declare
    role_name text;
begin
    foreach role_name in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = role_name) then
            execute format('revoke all on jarvis.device_challenges from %I', role_name);
        end if;
    end loop;
end;
$$;

commit;
