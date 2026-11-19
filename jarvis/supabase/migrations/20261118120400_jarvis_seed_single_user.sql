-- 20261118120400 — Idempotent single-user seed.
--
-- The display name is configuration, not identity: it is read from the
-- `jarvis.display_name` setting when the row is first created, and falls back to
-- a neutral label. Nothing personal is baked into the schema or into this file.
--
--   set jarvis.display_name = 'Whatever you want';
--   select jarvis.seed_initial_user();
--
-- Running this migration again, or calling the function on every boot, is safe:
-- it returns the existing account instead of creating a second one.

begin;

create or replace function jarvis.seed_initial_user()
returns uuid
language plpgsql
security invoker
set search_path = jarvis, pg_temp
as $$
declare
    configured_name text;
    existing_id uuid;
begin
    select id into existing_id
      from jarvis.users
     order by created_at
     limit 1;

    if existing_id is not null then
        return existing_id;
    end if;

    configured_name := nullif(btrim(coalesce(current_setting('jarvis.display_name', true), '')), '');

    insert into jarvis.users (display_name)
    values (coalesce(configured_name, 'Jarvis User'))
    returning id into existing_id;

    return existing_id;
end;
$$;

comment on function jarvis.seed_initial_user() is
    'Creates the single account row if it is missing and returns its id. Idempotent: '
    'repeat calls never create a second user.';

do $$
begin
    perform jarvis.seed_initial_user();
end;
$$;

commit;
