-- Creates the cluster roles the access-control tests need, before any migration
-- runs.
--
-- Roles are cluster-wide, so they cannot be created inside a test transaction
-- that is rolled back, and they must exist while the access-control migration
-- runs: that migration only revokes from roles that are already present. Creating
-- them afterwards would leave the "does it revoke from an existing role" path
-- untested.
--
-- Nothing here is a real credential: every role is NOLOGIN, so none of them can
-- open a connection on their own, and SET ROLE is only possible for a superuser.

do $$
declare
    role_name text;
begin
    -- Mirrors the three roles a Supabase project ships with. service_role gets
    -- BYPASSRLS because that is what Supabase grants it; RLS is a backstop for
    -- clients, not for the server-side role, so the test has to model it honestly.
    foreach role_name in array array['anon', 'authenticated'] loop
        if not exists (select 1 from pg_roles where rolname = role_name) then
            execute format('create role %I nologin', role_name);
        end if;
    end loop;

    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin bypassrls;
    end if;

    -- An ordinary login-less role with no relationship to Supabase. Used to check
    -- that an unrelated role is refused too, not just the well-known names.
    if not exists (select 1 from pg_roles where rolname = 'jarvis_test_reader') then
        create role jarvis_test_reader nologin;
    end if;

    -- Used by the behavioural RLS test, which grants it full table privileges on
    -- purpose and then proves RLS still returns nothing.
    if not exists (select 1 from pg_roles where rolname = 'jarvis_test_probe') then
        create role jarvis_test_probe nologin;
    end if;
end;
$$;
