-- Schema shape, the single-row guard, and seed idempotency.

begin;

select jarvis_test.ok(to_regclass('jarvis.users') is not null, 'jarvis.users exists');
select jarvis_test.ok(to_regclass('jarvis.devices') is not null, 'jarvis.devices exists');
select jarvis_test.ok(to_regclass('jarvis.device_credentials') is not null, 'jarvis.device_credentials exists');
select jarvis_test.ok(to_regclass('jarvis.pairing_codes') is not null, 'jarvis.pairing_codes exists');
select jarvis_test.ok(to_regclass('jarvis.conversations') is not null, 'jarvis.conversations exists');
select jarvis_test.ok(to_regclass('jarvis.messages') is not null, 'jarvis.messages exists');
select jarvis_test.ok(to_regclass('jarvis.conversation_summaries') is not null, 'jarvis.conversation_summaries exists');
select jarvis_test.ok(to_regclass('jarvis.memories') is not null, 'jarvis.memories exists');

select jarvis_test.ok(
    exists (select 1 from pg_namespace where nspname = 'jarvis'),
    'the jarvis schema is a real schema, not a search_path alias');

select jarvis_test.ok(
    (select count(*) from pg_tables where schemaname = 'public'
       and tablename in ('users', 'devices', 'messages', 'memories')) = 0,
    'no Jarvis table is created in the public schema');

-- The migration seeded exactly one account.
select jarvis_test.ok(
    (select count(*) from jarvis.users) = 1,
    'the migration created exactly one account');
select jarvis_test.ok(
    (select btrim(display_name) from jarvis.users) <> '',
    'the seeded account has a non-empty display name');

-- Idempotency: repeating the seed returns the same row.
select jarvis_test.ok(
    jarvis.seed_initial_user() = (select id from jarvis.users),
    're-running the seed returns the existing account');
select jarvis_test.ok(
    (select count(*) from jarvis.users) = 1,
    're-running the seed does not create a second account');

-- The display name is configuration, not hardcoded identity.
select jarvis_test.reset_data();
set local jarvis.display_name = '  Configured Owner  ';
select jarvis.seed_initial_user();
select jarvis_test.ok(
    (select display_name from jarvis.users) = 'Configured Owner',
    'the seeded display name comes from the jarvis.display_name setting');
select jarvis_test.ok(
    jarvis.seed_initial_user() = (select id from jarvis.users)
      and (select count(*) from jarvis.users) = 1,
    'the configured seed stays idempotent');

-- With no setting, a neutral default is used rather than a personal name.
select jarvis_test.reset_data();
select set_config('jarvis.display_name', '', true);
select jarvis.seed_initial_user();
select jarvis_test.ok(
    (select display_name from jarvis.users) = 'Jarvis User',
    'an unset display name falls back to a neutral default');

-- Personal-deployment guard: a second account cannot exist.
select jarvis_test.reset_data();
insert into jarvis.users (display_name) values ('First Account');
select jarvis_test.fails(
    $$insert into jarvis.users (display_name) values ('Second Account')$$,
    '23505',
    'a second account is rejected by users_single_row');

select jarvis_test.reset_data();

rollback;
