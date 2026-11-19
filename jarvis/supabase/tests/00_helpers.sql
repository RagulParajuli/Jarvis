-- Test helpers. These live only in the scratch test database and are never
-- created by a migration.

create schema if not exists jarvis_test;

comment on schema jarvis_test is
    'Assertion helpers for the database tests. Not part of the Jarvis schema.';

create or replace function jarvis_test.ok(p_condition boolean, p_message text)
returns void
language plpgsql
as $$
begin
    if p_condition is not true then
        raise exception 'assertion failed: %', p_message;
    end if;
end;
$$;

-- Asserts that a statement is rejected with a specific SQLSTATE, for example
-- 23503 (foreign key) or 23505 (unique). The inner block is a subtransaction,
-- so the surrounding test transaction survives an expected failure.
create or replace function jarvis_test.fails(p_sql text, p_sqlstate text, p_message text)
returns void
language plpgsql
as $$
begin
    begin
        execute p_sql;
    exception
        when others then
            if sqlstate = p_sqlstate then
                return;
            end if;
            raise exception 'expected SQLSTATE % but got % (%) while checking: %',
                p_sqlstate, sqlstate, sqlerrm, p_message;
    end;

    raise exception 'expected SQLSTATE % but the statement succeeded: %', p_sqlstate, p_message;
end;
$$;

-- Empties every Jarvis table through the account cascade. Cheap, and it keeps
-- assertions absolute instead of relative to whatever a previous file left behind.
create or replace function jarvis_test.reset_data()
returns void
language plpgsql
as $$
begin
    truncate jarvis.users cascade;
end;
$$;

-- Drops the personal-deployment single-row guard so ownership tests can create a
-- second account. Call it inside a transaction that is rolled back.
create or replace function jarvis_test.disable_single_user_guard()
returns void
language plpgsql
as $$
begin
    drop index if exists jarvis.users_single_row;
end;
$$;
