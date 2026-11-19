-- 20261118120100 — Trusted devices, their public keys, and one-time pairing codes.
--
-- Everything here is per user. `devices` owns `(id, user_id)` as a unique pair so
-- that dependent tables can prove at the database level that a row belongs to the
-- same user as the device it points at.

begin;

create table jarvis.devices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references jarvis.users (id) on delete cascade,
    label text not null,
    platform text not null,
    status text not null default 'pending',
    paired_at timestamptz,
    last_seen_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint devices_label_length
        check (char_length(btrim(label)) between 1 and 80),
    constraint devices_platform_valid
        check (platform in ('android', 'ios', 'windows', 'macos', 'linux', 'web')),
    constraint devices_status_valid
        check (status in ('pending', 'trusted', 'revoked')),
    constraint devices_revoked_at_consistency
        check ((status = 'revoked') = (revoked_at is not null)),

    -- Ownership anchor for composite foreign keys in this and later migrations.
    constraint devices_id_user_unique unique (id, user_id)
);

comment on table jarvis.devices is
    'A device that may authenticate as the account owner. Revocation is a status '
    'change, so the row survives as history; credentials below are what actually stops working.';
comment on column jarvis.devices.status is
    'pending = paired but not yet approved, trusted = may mint tokens, revoked = permanently refused.';

create index devices_user_status_idx on jarvis.devices (user_id, status);
create index devices_trusted_recent_idx
    on jarvis.devices (last_seen_at desc)
    where status = 'trusted';

create trigger devices_set_updated_at
    before update on jarvis.devices
    for each row execute function jarvis.set_updated_at();

create table jarvis.device_credentials (
    id uuid primary key default gen_random_uuid(),
    device_id uuid not null,
    user_id uuid not null,
    key_fingerprint text not null,
    public_key text not null,
    algorithm text not null default 'ES256',
    created_at timestamptz not null default now(),
    retired_at timestamptz,

    constraint device_credentials_fingerprint_hex
        check (key_fingerprint ~ '^[0-9a-f]{64}$'),
    constraint device_credentials_public_key_length
        check (char_length(public_key) between 16 and 4096),
    constraint device_credentials_algorithm_valid
        check (algorithm in ('ES256', 'ES384', 'ES512', 'RS256', 'EdDSA')),
    constraint device_credentials_fingerprint_unique unique (key_fingerprint),

    constraint device_credentials_device_ownership
        foreign key (device_id, user_id) references jarvis.devices (id, user_id)
        on delete cascade
);

comment on table jarvis.device_credentials is
    'Public signing keys, one active key per device. Only public material is stored; '
    'the private key never leaves the device secure store.';
comment on column jarvis.device_credentials.retired_at is
    'Set when a key is rotated out. A retired key can never authenticate again.';

create unique index device_credentials_one_active_per_device
    on jarvis.device_credentials (device_id)
    where retired_at is null;

create index device_credentials_user_idx on jarvis.device_credentials (user_id);

create table jarvis.pairing_codes (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references jarvis.users (id) on delete cascade,
    code_hash text not null,
    expires_at timestamptz not null,
    used_at timestamptz,
    consumed_by_device_id uuid references jarvis.devices (id) on delete set null,
    attempts integer not null default 0,
    created_at timestamptz not null default now(),

    constraint pairing_codes_hash_hex
        check (code_hash ~ '^[0-9a-f]{64}$'),
    constraint pairing_codes_hash_unique unique (code_hash),
    constraint pairing_codes_attempts_range
        check (attempts between 0 and 1000),
    constraint pairing_codes_expiry_after_creation
        check (expires_at > created_at),
    constraint pairing_codes_used_after_creation
        check (used_at is null or used_at >= created_at)
);

comment on table jarvis.pairing_codes is
    'One-time pairing codes, stored only as a SHA-256 hex digest. The plaintext code '
    'exists in memory long enough to be shown to the user and is never persisted or logged.';

create index pairing_codes_live_idx
    on jarvis.pairing_codes (expires_at)
    where used_at is null;

commit;
