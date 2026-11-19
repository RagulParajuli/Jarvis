-- 20261118120500 — Deny-by-default access to the jarvis schema.
--
-- Layered on purpose:
--   1. The schema is not `public`, so the Supabase Data API cannot see it.
--   2. PUBLIC and the Supabase client roles hold no privileges on it.
--   3. Row level security is enabled with zero policies, so anything that is
--      accidentally granted still returns nothing.
--   4. The application reaches these tables as the schema owner over a server-only
--      pooled connection. Owners (and roles with BYPASSRLS) are not subject to RLS,
--      which is why the app keeps working while every client role is refused.
--
-- There is deliberately no Supabase Auth and no policy here. If a dedicated,
-- non-owner application role is introduced later it needs explicit policies or
-- BYPASSRLS; both are a conscious decision, not a default.

begin;

revoke all on schema jarvis from public;
revoke all on all tables in schema jarvis from public;
revoke all on all sequences in schema jarvis from public;
revoke all on all functions in schema jarvis from public;

do $$
declare
    role_name text;
begin
    foreach role_name in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = role_name) then
            execute format('revoke all on schema jarvis from %I', role_name);
            execute format('revoke all on all tables in schema jarvis from %I', role_name);
            execute format('revoke all on all sequences in schema jarvis from %I', role_name);
            execute format('revoke all on all functions in schema jarvis from %I', role_name);
            execute format('alter default privileges in schema jarvis revoke all on tables from %I', role_name);
            execute format('alter default privileges in schema jarvis revoke all on sequences from %I', role_name);
            execute format('alter default privileges in schema jarvis revoke all on functions from %I', role_name);
        end if;
    end loop;
end;
$$;

-- New objects must not inherit PUBLIC access either. Functions grant EXECUTE to
-- PUBLIC by default, which is exactly what this schema must not do.
alter default privileges in schema jarvis revoke all on tables from public;
alter default privileges in schema jarvis revoke all on sequences from public;
alter default privileges in schema jarvis revoke all on functions from public;

-- Backstop only: with no policy, a non-owner role reads and writes nothing.
alter table jarvis.users enable row level security;
alter table jarvis.devices enable row level security;
alter table jarvis.device_credentials enable row level security;
alter table jarvis.pairing_codes enable row level security;
alter table jarvis.conversations enable row level security;
alter table jarvis.messages enable row level security;
alter table jarvis.conversation_summaries enable row level security;
alter table jarvis.memories enable row level security;

commit;
