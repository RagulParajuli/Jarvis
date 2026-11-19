-- Access control: dedicated schema, nothing granted by default, RLS as a backstop.
--
-- The roles this file talks about are created by scripts/bootstrap-test-roles.sql
-- before the migrations run, so the assertions are about real roles instead of
-- "if it exists" no-ops.

begin;

select jarvis_test.ok(
    (select count(*) from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'jarvis' and c.relkind = 'r') = 9,
    'the jarvis schema holds exactly the nine expected tables');

select jarvis_test.ok(
    (select bool_and(c.relrowsecurity) from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'jarvis' and c.relkind = 'r'),
    'row level security is enabled on every jarvis table');

select jarvis_test.ok(
    (select count(*) from pg_policies where schemaname = 'jarvis') = 0,
    'no policy grants access to a client role');

-- The bootstrap is part of the contract: without these roles every role-scoped
-- assertion below would silently pass.
select jarvis_test.ok(
    (select count(*) from pg_roles
      where rolname in ('anon', 'authenticated', 'service_role', 'jarvis_test_reader')) = 4,
    'the test runner created the anon, authenticated, service_role and ordinary roles');

-- No table privilege for PUBLIC, which is what an unauthenticated PostgREST
-- request would use.
select jarvis_test.ok(
    not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
         where n.nspname = 'jarvis'
           and c.relkind = 'r'
           and acl.grantee = 0
           and acl.privilege_type in
               ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')),
    'PUBLIC holds no privileges on jarvis tables');

-- PUBLIC must not be able to reach the schema at all; that is the check that
-- actually keeps an unauthenticated client out.
select jarvis_test.ok(
    not exists (
        select 1
          from pg_namespace n
          cross join lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) acl
         where n.nspname = 'jarvis'
           and acl.grantee = 0
           and acl.privilege_type in ('USAGE', 'CREATE')),
    'PUBLIC has no USAGE or CREATE on the jarvis schema');

-- Functions default to EXECUTE for PUBLIC, so the revoke must actually be there.
select jarvis_test.ok(
    not exists (
        select 1
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
         where n.nspname = 'jarvis'
           and acl.grantee = 0
           and acl.privilege_type = 'EXECUTE'),
    'PUBLIC cannot execute jarvis functions');

-- The identity sequence behind jarvis.messages is the only sequence in the
-- schema. Assert it exists so the sequence checks below cannot pass vacuously.
select jarvis_test.ok(
    (select count(*) from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'jarvis' and c.relkind = 'S') > 0,
    'the jarvis schema owns at least one sequence');

select jarvis_test.ok(
    not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          cross join lateral aclexplode(coalesce(c.relacl, acldefault('S', c.relowner))) acl
         where n.nspname = 'jarvis'
           and c.relkind = 'S'
           and acl.grantee = 0
           and acl.privilege_type in ('USAGE', 'SELECT', 'UPDATE')),
    'PUBLIC holds no privilege on jarvis sequences');

-- No direct grant to a client role or to an unrelated ordinary role, on any
-- object in the schema.
select jarvis_test.ok(
    not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          cross join lateral aclexplode(
              coalesce(c.relacl,
                  acldefault((case when c.relkind = 'S' then 'S' else 'r' end)::"char",
                             c.relowner))) acl
          join pg_roles r on r.oid = acl.grantee
         where n.nspname = 'jarvis'
           and c.relkind in ('r', 'S')
           and r.rolname in ('anon', 'authenticated', 'service_role', 'jarvis_test_reader')),
    'client roles and ordinary roles hold no privilege on jarvis tables or sequences');

select jarvis_test.ok(
    not exists (
        select 1
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
          join pg_roles r on r.oid = acl.grantee
         where n.nspname = 'jarvis'
           and r.rolname in ('anon', 'authenticated', 'service_role', 'jarvis_test_reader')),
    'client roles and ordinary roles cannot execute jarvis functions');

-- The same check through the privilege system, which also covers privileges
-- inherited through role membership rather than granted directly.
select jarvis_test.ok(
    not has_schema_privilege('anon', 'jarvis', 'USAGE'),
    'anon cannot use the jarvis schema');
select jarvis_test.ok(
    not has_schema_privilege('authenticated', 'jarvis', 'USAGE'),
    'authenticated cannot use the jarvis schema');
select jarvis_test.ok(
    not has_schema_privilege('service_role', 'jarvis', 'USAGE'),
    'service_role is not relied on for database access');
select jarvis_test.ok(
    not has_schema_privilege('jarvis_test_reader', 'jarvis', 'USAGE'),
    'an ordinary role cannot use the jarvis schema');

-- service_role bypasses RLS by design (Supabase grants that), so its protection
-- has to come from privileges alone. Say so explicitly.
select jarvis_test.ok(
    (select rolbypassrls from pg_roles where rolname = 'service_role'),
    'service_role bypasses row level security, and is stopped by privileges instead');
select jarvis_test.ok(
    not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'jarvis'
           and (
               (c.relkind = 'r'
                and (has_table_privilege('service_role', c.oid, 'SELECT')
                  or has_table_privilege('service_role', c.oid, 'INSERT')
                  or has_table_privilege('service_role', c.oid, 'UPDATE')
                  or has_table_privilege('service_role', c.oid, 'DELETE')))
            or (c.relkind = 'S'
                and (has_sequence_privilege('service_role', c.oid, 'USAGE')
                  or has_sequence_privilege('service_role', c.oid, 'SELECT')
                  or has_sequence_privilege('service_role', c.oid, 'UPDATE')))
           )),
    'service_role holds no table or sequence privilege despite bypassing RLS');

select jarvis_test.ok(
    not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'jarvis'
           and (
               (c.relkind = 'r'
                and (has_table_privilege('jarvis_test_reader', c.oid, 'SELECT')
                  or has_table_privilege('jarvis_test_reader', c.oid, 'INSERT')
                  or has_table_privilege('jarvis_test_reader', c.oid, 'UPDATE')
                  or has_table_privilege('jarvis_test_reader', c.oid, 'DELETE')))
            or (c.relkind = 'S'
                and (has_sequence_privilege('jarvis_test_reader', c.oid, 'USAGE')))
           )),
    'an ordinary role holds no table or sequence privilege');

-- Behavioural proof, not just catalog proof. jarvis_test_probe is granted every
-- read/write privilege a leaked client would need, and RLS with no policies still
-- has to return nothing and refuse writes.
select jarvis_test.reset_data();
insert into jarvis.users (id, display_name)
values ('00000000-0000-7000-8000-0000000000aa', 'Probe Target');

grant usage on schema jarvis to jarvis_test_probe;
grant select, insert, update, delete on all tables in schema jarvis to jarvis_test_probe;
grant usage on schema jarvis_test to jarvis_test_probe;
grant execute on all functions in schema jarvis_test to jarvis_test_probe;

set local role jarvis_test_probe;

-- Without a sequence grant, an identity insert is impossible.
select jarvis_test.fails(
    $$select nextval('jarvis.messages_id_seq')$$,
    '42501',
    'a masked-client role cannot advance a jarvis sequence');
select jarvis_test.fails(
    $$select jarvis.allocate_message_seq(
          '00000000-0000-7000-8000-0000000000ff',
          '00000000-0000-7000-8000-0000000000aa')$$,
    '42501',
    'a masked-client role cannot execute a jarvis function');

do $probe$
declare
    visible bigint;
    touched bigint;
begin
    select count(*) into visible from jarvis.users;
    perform jarvis_test.ok(visible = 0,
        'row level security hides every row from a fully granted client role');

    with changed as (
        update jarvis.users set display_name = display_name returning 1
    )
    select count(*) into touched from changed;
    perform jarvis_test.ok(touched = 0,
        'an update by a client role touches no row');

    with removed as (
        delete from jarvis.users returning 1
    )
    select count(*) into touched from removed;
    perform jarvis_test.ok(touched = 0,
        'a delete by a client role removes no row');

    perform jarvis_test.fails(
        $$insert into jarvis.users (display_name) values ('Probe Insert')$$,
        '42501',
        'an insert by a client role is refused by row level security');
end;
$probe$;

reset role;

-- The same privileges plus sequence and function access still see nothing: RLS
-- is the last line, not the first.
grant usage, select on all sequences in schema jarvis to jarvis_test_probe;
grant execute on all functions in schema jarvis to jarvis_test_probe;

set local role jarvis_test_probe;
do $granted$
declare
    advanced bigint;
    visible bigint;
begin
    select nextval('jarvis.messages_id_seq') into advanced;
    perform jarvis_test.ok(advanced > 0,
        'sequence access works once granted, so the refusal above was a privilege check');

    select count(*) into visible from jarvis.users;
    perform jarvis_test.ok(visible = 0,
        'even with sequence and function access the probe still reads no account row');
end;
$granted$;
reset role;

rollback;
