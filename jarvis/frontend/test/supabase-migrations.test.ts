import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

/**
 * Guards the migration set that `supabase db push` will apply.
 *
 * It lives with the web app because `pnpm test` is the only JavaScript test
 * runner in the repository; the files it reads are in `supabase/migrations`.
 */

const MIGRATION_FILE = /^(\d{14})_[a-z0-9_]+\.sql$/;
const directory = join(import.meta.dirname, '..', '..', 'supabase', 'migrations');

const files = readdirSync(directory)
  .filter((name) => name.endsWith('.sql'))
  .sort();

function read(name: string): string {
  return readFileSync(join(directory, name), 'utf8');
}

/** Statement lines only: comments and blank lines removed. */
function statements(source: string): string[] {
  return source
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('--'));
}

test('migration filenames follow the Supabase convention and sort into one order', () => {
  assert.ok(files.length >= 7, 'expected the full migration set');

  const versions = files.map((name) => {
    const match = MIGRATION_FILE.exec(name);
    assert.ok(match, `${name} must match YYYYMMDDHHMMSS_name.sql`);
    return match[1];
  });

  assert.deepEqual(versions, [...versions].sort(), 'filenames must be in apply order');
  assert.equal(new Set(versions).size, versions.length, 'versions must be unique');
});

test('every migration is one transaction', () => {
  for (const name of files) {
    const lines = statements(read(name));
    assert.equal(lines[0], 'begin;', `${name} must start with begin;`);
    assert.equal(lines[lines.length - 1], 'commit;', `${name} must end with commit;`);
    assert.equal(lines.filter((line) => line === 'begin;').length, 1, `${name} has one begin;`);
    assert.equal(lines.filter((line) => line === 'commit;').length, 1, `${name} has one commit;`);
  }
});

test('every table and function the application needs is created', () => {
  const source = files.map(read).join('\n');

  for (const table of [
    'users',
    'devices',
    'device_credentials',
    'pairing_codes',
    'device_challenges',
    'conversations',
    'messages',
    'conversation_summaries',
    'memories',
  ]) {
    assert.match(
      source,
      new RegExp(`create table jarvis\\.${table} \\(`),
      `missing jarvis.${table}`
    );
  }

  for (const routine of [
    'set_updated_at',
    'allocate_message_seq',
    'delete_memory',
    'purge_deleted_memories',
    'seed_initial_user',
  ]) {
    assert.match(
      source,
      new RegExp(`create or replace function jarvis\\.${routine}\\(`),
      `missing jarvis.${routine}`
    );
  }
});

test('the access-control migration locks the schema down for Supabase roles', () => {
  const source = files.map(read).join('\n');

  assert.match(source, /revoke all on schema jarvis from public;/);
  assert.match(source, /alter table jarvis\.memories enable row level security;/);
  assert.match(source, /'anon', 'authenticated', 'service_role'/);
  assert.match(source, /revoke all on all functions in schema jarvis from public;/);
});

const CHALLENGE_MIGRATION = '20261119130000_jarvis_device_challenges.sql';

/** Statement text only, so comments cannot satisfy a "no GRANT" assertion. */
function challengeSql(): string {
  return statements(read(CHALLENGE_MIGRATION)).join('\n');
}

test('only the new migration defines jarvis.device_challenges', () => {
  const definers = files.filter((name) =>
    /create table jarvis\.device_challenges \(/.test(read(name))
  );
  assert.deepEqual(definers, [CHALLENGE_MIGRATION]);
});

test('device challenges store only a nonce hash bound to a device and audience', () => {
  const sql = challengeSql();

  assert.match(sql, /create table jarvis\.device_challenges \(/);
  for (const column of [
    'id uuid primary key',
    'user_id uuid not null references jarvis.users (id) on delete cascade',
    'device_id uuid not null',
    'nonce_hash text not null',
    'audience text not null',
    'expires_at timestamptz not null',
    'consumed_at timestamptz',
    'created_at timestamptz not null default now()',
  ]) {
    assert.ok(sql.includes(column), `missing column definition: ${column}`);
  }

  assert.match(
    sql,
    /constraint device_challenges_nonce_hash check \(nonce_hash ~ '\^\[0-9a-f\]\{64\}\$'\)/
  );
  assert.doesNotMatch(sql, /\bnonce\s+text\b/i, 'the plaintext nonce must never be a column');
});

test('device challenges enforce one-time consumption and composite ownership', () => {
  const sql = challengeSql();

  assert.match(sql, /constraint device_challenges_nonce_unique unique \(nonce_hash\)/);
  assert.match(
    sql,
    /constraint device_challenges_audience check \(char_length\(audience\) between 1 and 64\)/
  );
  assert.match(sql, /constraint device_challenges_expires check \(expires_at > created_at\)/);
  assert.match(
    sql,
    /constraint device_challenges_consumed check \(consumed_at is null or consumed_at >= created_at\)/
  );
  assert.match(
    sql,
    /constraint device_challenges_device_ownership\s+foreign key \(device_id, user_id\)\s+references jarvis\.devices \(id, user_id\)\s+on delete cascade/
  );
  assert.match(
    sql,
    /create index device_challenges_device_idx\s+on jarvis\.device_challenges \(user_id, device_id\)\s+where consumed_at is null/
  );
});

test('device challenges are locked down without policies, grants or definer functions', () => {
  const sql = challengeSql();

  assert.match(sql, /alter table jarvis\.device_challenges enable row level security;/);
  assert.doesNotMatch(
    sql,
    /create\s+policy/i,
    'a policy would bypass the deny-by-default backstop'
  );
  assert.doesNotMatch(sql, /\bgrant\b/i, 'no client role may receive privileges');
  assert.doesNotMatch(sql, /security\s+definer/i, 'no elevated function is introduced');
  assert.doesNotMatch(
    sql,
    /create\s+(or\s+replace\s+)?function/i,
    'the migration adds no function'
  );

  assert.match(sql, /revoke all on jarvis\.device_challenges from public;/);
  assert.match(sql, /'anon', 'authenticated', 'service_role'/);
  assert.match(sql, /if exists \(select 1 from pg_roles where rolname = role_name\)/);
});

test('migrations contain no connection string, credential or browser-exposed variable', () => {
  for (const name of files) {
    const source = read(name);
    assert.equal(
      source.includes('NEXT_PUBLIC_'),
      false,
      `${name} must not name a NEXT_PUBLIC_ variable`
    );
    assert.equal(
      /postgres(ql)?:\/\//i.test(source),
      false,
      `${name} must not contain a connection string`
    );
    assert.equal(
      /password\s*=\s*'/i.test(source),
      false,
      `${name} must not contain a password literal`
    );
  }
});
