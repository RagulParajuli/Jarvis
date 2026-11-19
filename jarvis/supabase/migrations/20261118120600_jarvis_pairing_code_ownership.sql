-- 20261118120600 — Pairing codes must be consumed by a device of the same account.
--
-- Corrects two things in earlier files. Both are forward-only corrections; the
-- applied migrations are left exactly as they were.
--
-- 1. Ownership (fixes 20261118120100)
--    `pairing_codes.consumed_by_device_id` was a plain foreign key to
--    `devices (id)`. It proved the device existed but not that it belonged to the
--    pairing code's account, so a code issued to user A could be marked consumed
--    by user B's device. Everything else in the schema proves ownership with a
--    composite key; this was the one gap.
--
--    The replacement is `(consumed_by_device_id, user_id) -> devices (id, user_id)`,
--    which reuses `devices_id_user_unique`. `ON DELETE SET NULL
--    (consumed_by_device_id)` keeps the original behaviour for that column only:
--    deleting a device clears the consumption marker and leaves `user_id` intact,
--    so the pairing history still belongs to an account.
--
-- 2. Function privileges (fixes the claim in 20261118120500)
--    That file says `alter default privileges in schema jarvis revoke all on
--    functions from public` stops a future function from being executable by
--    PUBLIC. It does not. PostgreSQL grants EXECUTE to PUBLIC when a function is
--    created, and that built-in default is not an entry in `pg_default_acl`, so
--    ALTER DEFAULT PRIVILEGES has nothing to remove: after the statement,
--    `pg_default_acl` has no row for this schema and a newly created function
--    still has `proacl = NULL`, which means the built-in PUBLIC EXECUTE.
--
--    Consequence: every function added to this schema must be followed, in the
--    same transaction that creates it, by
--
--        revoke execute on function jarvis.<name>(<argument types>) from public;
--
--    The schema-level `revoke all on schema jarvis from public` (20261118120500)
--    is the control that keeps clients out even if a function is missed, because
--    EXECUTE is useless without schema USAGE. It is depth, not a substitute.

begin;

-- Refuse to apply on data that already violates the new rule, with a message that
-- names the problem instead of an opaque constraint error.
do $$
declare
    offending bigint;
begin
    select count(*) into offending
      from jarvis.pairing_codes pc
      join jarvis.devices d on d.id = pc.consumed_by_device_id
     where d.user_id <> pc.user_id;

    if offending > 0 then
        raise exception
            'cannot add pairing code ownership: % pairing code(s) name a device owned by another account',
            offending;
    end if;
end;
$$;

alter table jarvis.pairing_codes
    drop constraint pairing_codes_consumed_by_device_id_fkey;

alter table jarvis.pairing_codes
    add constraint pairing_codes_consumed_device_ownership
    foreign key (consumed_by_device_id, user_id)
    references jarvis.devices (id, user_id)
    on delete set null (consumed_by_device_id);

comment on column jarvis.pairing_codes.consumed_by_device_id is
    'Device that redeemed the code. Composite FK with user_id: the device must belong '
    'to the same account. Set to null when the device is deleted; the code row survives.';

-- Belt and braces for the functions that already exist. A function created after
-- this migration still needs its own REVOKE, per the header note above.
revoke all on all functions in schema jarvis from public;

commit;
