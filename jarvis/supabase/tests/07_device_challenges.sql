-- Device challenges: persistent, one-time, bound to a device and an API audience.
--
-- These assertions run against a fresh database in a throwaway container, so the
-- temporary rows below are rolled back at the end of the file.

begin;

select jarvis_test.ok(
    to_regclass('jarvis.device_challenges') is not null,
    'jarvis.device_challenges exists');

select jarvis_test.ok(
    (select relrowsecurity from pg_class where oid = 'jarvis.device_challenges'::regclass),
    'row level security is enabled on device challenges');

select jarvis_test.ok(
    (select count(*) from pg_policies
      where schemaname = 'jarvis' and tablename = 'device_challenges') = 0,
    'no policy grants access to device challenges');

select jarvis_test.ok(
    (select count(*) from information_schema.columns
      where table_schema = 'jarvis'
        and table_name = 'device_challenges'
        and column_name in ('id', 'user_id', 'device_id', 'nonce_hash', 'audience',
                            'expires_at', 'consumed_at', 'created_at')) = 8,
    'all eight challenge columns are present');

select jarvis_test.ok(
    exists (
        select 1 from pg_constraint c
         where c.conrelid = 'jarvis.device_challenges'::regclass
           and c.conname = 'device_challenges_device_ownership'
           and c.contype = 'f'
           and c.confdeltype = 'c'
           and c.confrelid = 'jarvis.devices'::regclass
           and (select array_agg(a.attname::text order by u.ord)
                  from unnest(c.conkey) with ordinality as u(attnum, ord)
                  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = u.attnum)
               = array['device_id', 'user_id']::text[]
           and (select array_agg(a.attname::text order by u.ord)
                  from unnest(c.confkey) with ordinality as u(attnum, ord)
                  join pg_attribute a on a.attrelid = c.confrelid and a.attnum = u.attnum)
               = array['id', 'user_id']::text[]
    ),
    'a challenge is owned by the same account as its device and cascades on delete');

select jarvis_test.ok(
    exists (select 1 from pg_constraint
             where conrelid = 'jarvis.device_challenges'::regclass
               and conname = 'device_challenges_nonce_unique' and contype = 'u'),
    'nonce hashes are unique');

select jarvis_test.ok(
    exists (select 1 from pg_index i
              join pg_class ic on ic.oid = i.indexrelid
             where i.indrelid = 'jarvis.device_challenges'::regclass
               and ic.relname = 'device_challenges_device_idx'
               and i.indpred is not null),
    'a partial index covers only unconsumed challenges');

select jarvis_test.ok(
    not exists (select 1 from pg_proc p
                  join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'jarvis' and p.prosecdef),
    'no SECURITY DEFINER function was introduced');

select jarvis_test.ok(
    not exists (
        select 1 from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
         where n.nspname = 'jarvis'
           and c.relname = 'device_challenges'
           and (acl.grantee = 0 or acl.grantee in (
                   select oid from pg_roles
                    where rolname in ('anon', 'authenticated', 'service_role')))
           and acl.privilege_type in
               ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')),
    'PUBLIC and the Supabase client roles hold no privileges on challenges');

select jarvis_test.disable_single_user_guard();
select jarvis_test.reset_data();

insert into jarvis.users (id, display_name) values
    ('00000000-0000-7000-8000-00000000000a', 'Owner A'),
    ('00000000-0000-7000-8000-00000000000b', 'Owner B');

insert into jarvis.devices (id, user_id, label, platform, status, paired_at) values
    ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
     'Phone A', 'android', 'trusted', now()),
    ('00000000-0000-7000-8000-0000000000d2', '00000000-0000-7000-8000-00000000000b',
     'Phone B', 'android', 'trusted', now());

-- Ownership is checked through the composite foreign key, in both directions.
select jarvis_test.fails(
    $$insert into jarvis.device_challenges
          (user_id, device_id, nonce_hash, audience, expires_at)
      values ('00000000-0000-7000-8000-00000000000a',
              '00000000-0000-7000-8000-0000000000d2',
              repeat('a', 64), 'jarvis-token-api-v1', now() + interval '2 minutes')$$,
    '23503',
    'a challenge cannot bind another account''s device');

insert into jarvis.device_challenges (id, user_id, device_id, nonce_hash, audience, expires_at)
values ('00000000-0000-7000-8000-0000000000f1',
        '00000000-0000-7000-8000-00000000000a',
        '00000000-0000-7000-8000-0000000000d1',
        repeat('b', 64), 'jarvis-token-api-v1', now() + interval '2 minutes');

select jarvis_test.fails(
    $$insert into jarvis.device_challenges
          (user_id, device_id, nonce_hash, audience, expires_at)
      values ('00000000-0000-7000-8000-00000000000a',
              '00000000-0000-7000-8000-0000000000d1',
              repeat('b', 64), 'jarvis-token-api-v1', now() + interval '2 minutes')$$,
    '23505',
    'a nonce hash can only be stored once');

select jarvis_test.fails(
    $$update jarvis.device_challenges
          set nonce_hash = 'not-a-hex-digest'
        where id = '00000000-0000-7000-8000-0000000000f1'$$,
    '23514',
    'only a SHA-256 hex digest is accepted');

select jarvis_test.fails(
    $$update jarvis.device_challenges
          set audience = ''
        where id = '00000000-0000-7000-8000-0000000000f1'$$,
    '23514',
    'an audience is required');

-- The row lock in this conditional update is what makes a challenge one-time.
update jarvis.device_challenges
   set consumed_at = now()
 where id = '00000000-0000-7000-8000-0000000000f1'
   and consumed_at is null
returning id;

select jarvis_test.ok(
    (select count(*) from jarvis.device_challenges where consumed_at is not null) = 1,
    'a challenge can be consumed');

select jarvis_test.ok(
    not exists (
        select 1 from jarvis.device_challenges
        where id = '00000000-0000-7000-8000-0000000000f1'
          and consumed_at is null),
    'the same challenge cannot be consumed again');

delete from jarvis.devices where id = '00000000-0000-7000-8000-0000000000d1';

select jarvis_test.ok(
    (select count(*) from jarvis.device_challenges) = 0,
    'deleting the device cascades to its challenges');

rollback;
