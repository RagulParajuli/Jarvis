-- Mirrors the parts of a freshly created Supabase project that the migrations
-- interact with, so the local suite can prove compatibility without a project.
--
-- On Supabase, the `extensions` schema already exists and pgcrypto / pg_trgm
-- are already installed in it. The first migration uses `if not exists`, so it
-- must cope with both being present, and `extensions.digest(...)` in the
-- memories migration must resolve against the installed extension.
--
-- Run before any migration, after bootstrap-test-roles.sql:
--
--   JARVIS_TEST_SUPABASE_LIKE=1 ./supabase/scripts/test-db.sh
--
-- Nothing here is Supabase-specific configuration: it only recreates the
-- pre-existing objects, so it cannot mask a missing step in a migration.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
