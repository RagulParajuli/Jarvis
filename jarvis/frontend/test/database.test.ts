import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import type { QueryResultRow } from 'pg';
import {
  DATABASE_CA_CERT_VARIABLE,
  DATABASE_POOL_MAX,
  DatabaseConfigurationError,
  DatabaseQueryError,
  type QueryExecutor,
  createDatabase,
  databasePoolConfig,
  isDatabaseConfigured,
  readDatabaseUrl,
  safeDatabaseError,
} from '../lib/database.ts';

const SECRET = 'sup3r-s3cret-p4ssword';

const FAKE_CA_CERT = '-----BEGIN CERTIFICATE-----\nFAKE-CA-CERTIFICATE\n-----END CERTIFICATE-----';

const projectRoot = join(import.meta.dirname, '..');

/** A value that never appeared in any error message or log line. */
function assertNoSecret(value: string, description: string): void {
  assert.equal(value.includes(SECRET), false, `${description} must not contain the password`);
}

function fakeExecutor(rows: QueryResultRow[]): {
  executor: QueryExecutor;
  calls: { text: string; values: unknown[] | undefined }[];
} {
  const calls: { text: string; values: unknown[] | undefined }[] = [];

  return {
    calls,
    executor: {
      async query<T extends QueryResultRow>(text: string, values?: unknown[]) {
        calls.push({ text, values });
        return { rows: rows as T[] };
      },
    },
  };
}

test('a missing DATABASE_URL is a configuration error', () => {
  assert.throws(
    () => readDatabaseUrl({}),
    (error: unknown) => {
      assert.ok(error instanceof DatabaseConfigurationError);
      assert.match(error.message, /DATABASE_URL/);
      return true;
    }
  );

  assert.throws(() => readDatabaseUrl({ DATABASE_URL: '   ' }), DatabaseConfigurationError);
});

test('a NEXT_PUBLIC_ connection string is called out as a leak and never echoed', () => {
  assert.throws(
    () =>
      readDatabaseUrl({
        NEXT_PUBLIC_DATABASE_URL: `postgresql://jarvis:${SECRET}@db.example.com:5432/jarvis`,
      }),
    (error: unknown) => {
      assert.ok(error instanceof DatabaseConfigurationError);
      assert.match(error.message, /NEXT_PUBLIC_/);
      assertNoSecret(error.message, 'the error message');
      return true;
    }
  );
});

test('an invalid or non-postgres connection string is rejected without echoing it', () => {
  assert.throws(
    () => readDatabaseUrl({ DATABASE_URL: `not a url ${SECRET}` }),
    (error: unknown) => {
      assert.ok(error instanceof DatabaseConfigurationError);
      assertNoSecret(error.message, 'the error message');
      return true;
    }
  );

  assert.throws(
    () => readDatabaseUrl({ DATABASE_URL: `https://jarvis:${SECRET}@db.example.com/jarvis` }),
    (error: unknown) => {
      assert.ok(error instanceof DatabaseConfigurationError);
      assertNoSecret(error.message, 'the error message');
      return true;
    }
  );
});

test('valid postgres connection strings are accepted unchanged', () => {
  for (const url of [
    `postgresql://jarvis:${SECRET}@db.example.com:5432/jarvis`,
    `postgres://jarvis:${SECRET}@db.example.com:6543/jarvis`,
    `postgresql://jarvis:${SECRET}@localhost:5432/jarvis_test`,
  ]) {
    assert.equal(readDatabaseUrl({ DATABASE_URL: `  ${url}  ` }), url);
    assert.equal(isDatabaseConfigured({ DATABASE_URL: url }), true);
  }

  assert.equal(isDatabaseConfigured({}), false);
  assert.equal(isDatabaseConfigured({ DATABASE_URL: '  ' }), false);
});

test('the pool is small, bounded and lets short-lived processes exit', () => {
  const config = databasePoolConfig(
    `postgresql://jarvis:${SECRET}@aws-0-eu-west-1.pooler.supabase.com:6543/postgres`
  );

  assert.equal(config.max, DATABASE_POOL_MAX);
  assert.ok(DATABASE_POOL_MAX >= 1 && DATABASE_POOL_MAX <= 5);
  assert.equal(config.allowExitOnIdle, true);
  assert.equal(config.application_name, 'jarvis-web');
  assert.ok((config.connectionTimeoutMillis ?? 0) > 0);
  assert.ok((config.connectionTimeoutMillis ?? 0) <= 30_000);
  assert.ok((config.idleTimeoutMillis ?? 0) > 0);
  assert.ok((config.idleTimeoutMillis ?? 0) <= 30_000);
});

const REMOTE_URL = `postgresql://jarvis:${SECRET}@aws-0-eu-west-1.pooler.supabase.com:6543/postgres`;

test('remote connections require verified TLS and local ones do not', () => {
  const remote = databasePoolConfig(REMOTE_URL);
  assert.deepEqual(remote.ssl, { rejectUnauthorized: true });

  // `sslmode=require` is not a licence to skip verification.
  const required = databasePoolConfig(
    `postgresql://jarvis:${SECRET}@db.example.com:5432/jarvis?sslmode=require`
  );
  assert.deepEqual(required.ssl, { rejectUnauthorized: true });

  for (const host of ['localhost', '127.0.0.1', '[::1]']) {
    const local = databasePoolConfig(`postgresql://jarvis:${SECRET}@${host}:5432/jarvis_test`);
    assert.equal(local.ssl, false, `${host} should connect without TLS`);
  }

  const disabled = databasePoolConfig(
    `postgresql://jarvis:${SECRET}@db.example.com:5432/jarvis?sslmode=disable`
  );
  assert.equal(disabled.ssl, false);
});

test('a configured CA certificate is trusted without disabling TLS verification', () => {
  const env = { [DATABASE_CA_CERT_VARIABLE]: FAKE_CA_CERT };

  const withCa = databasePoolConfig(REMOTE_URL, env);
  assert.deepEqual(withCa.ssl, { rejectUnauthorized: true, ca: FAKE_CA_CERT });
  assert.equal(typeof withCa.ssl, 'object');
  if (withCa.ssl && typeof withCa.ssl === 'object') {
    assert.equal(withCa.ssl.rejectUnauthorized, true);
  }

  // The CA must not change the local or explicitly disabled cases.
  for (const host of ['localhost', '127.0.0.1', '[::1]']) {
    const local = databasePoolConfig(`postgresql://jarvis:${SECRET}@${host}:5432/jarvis_test`, env);
    assert.equal(local.ssl, false, `${host} should still connect without TLS`);
  }

  const disabled = databasePoolConfig(
    `postgresql://jarvis:${SECRET}@db.example.com:5432/jarvis?sslmode=disable`,
    env
  );
  assert.equal(disabled.ssl, false);

  // A NEXT_PUBLIC_ variant is not read by this server-only module.
  const publicOnly = databasePoolConfig(REMOTE_URL, {
    NEXT_PUBLIC_DATABASE_CA_CERT: FAKE_CA_CERT,
  });
  assert.deepEqual(publicOnly.ssl, { rejectUnauthorized: true });
});

test('queryRows returns rows and forwards parameters', async () => {
  const { executor, calls } = fakeExecutor([{ id: 1, content: 'hello' }]);
  const db = createDatabase(executor);

  const rows = await db.queryRows<{ id: number; content: string }>(
    'select id, content from jarvis.messages where user_id = $1',
    ['00000000-0000-7000-8000-00000000000a']
  );

  assert.deepEqual(rows, [{ id: 1, content: 'hello' }]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].text, 'select id, content from jarvis.messages where user_id = $1');
  assert.deepEqual(calls[0].values, ['00000000-0000-7000-8000-00000000000a']);
});

test('queryRow returns the first row or null', async () => {
  const one = createDatabase(fakeExecutor([{ ok: 1 }]).executor);
  assert.deepEqual(await one.queryRow<{ ok: number }>('select 1 as ok'), { ok: 1 });

  const none = createDatabase(fakeExecutor([]).executor);
  assert.equal(await none.queryRow('select 1 as ok'), null);
});

test('query failures are reduced to a SQLSTATE and identifiers', async () => {
  const driverError = Object.assign(new Error(`duplicate key: (email)=(${SECRET})`), {
    code: '23505',
    constraint: 'users_email_key',
    table: 'users',
    detail: `Key (email)=(${SECRET}) already exists.`,
  });

  const db = createDatabase({
    async query() {
      throw driverError;
    },
  });

  await assert.rejects(
    () => db.queryRows('insert into jarvis.users default values'),
    (error: unknown) => {
      assert.ok(error instanceof DatabaseQueryError);
      assert.equal(error.code, '23505');
      assert.equal(error.constraint, 'users_email_key');
      assert.equal(error.table, 'users');
      assertNoSecret(error.message, 'the wrapped error message');
      assert.equal(error.message.includes('duplicate key'), false);
      assert.equal(error.cause, undefined);
      return true;
    }
  );
});

test('ping reports health without leaking the failure', async () => {
  const healthy = createDatabase(fakeExecutor([{ ok: 1 }]).executor);
  assert.equal(await healthy.ping(), true);

  const logged: string[] = [];
  const original = console.error;
  console.error = (...parts: unknown[]) => logged.push(parts.join(' '));
  try {
    const unreachable = createDatabase({
      async query() {
        throw Object.assign(new Error(`connect ECONNREFUSED user=${SECRET}@db.example.com`), {
          code: 'ECONNREFUSED',
        });
      },
    });
    assert.equal(await unreachable.ping(), false);
  } finally {
    console.error = original;
  }

  assert.equal(logged.length, 1);
  assertNoSecret(logged[0], 'the log line');
  assert.match(logged[0], /ECONNREFUSED/);
});

test('safeDatabaseError never returns a driver message', () => {
  assert.equal(
    safeDatabaseError(new DatabaseConfigurationError('DATABASE_URL is not set.')),
    'DATABASE_URL is not set.'
  );

  const unknownError = new Error(
    `could not connect to postgresql://jarvis:${SECRET}@db.example.com`
  );
  const safeUnknown = safeDatabaseError(unknownError);
  assertNoSecret(safeUnknown, 'the safe error');
  assert.equal(safeUnknown, 'Database error.');

  const withCode = Object.assign(new Error(`socket closed ${SECRET}`), { code: '57P01' });
  const safeCode = safeDatabaseError(withCode);
  assertNoSecret(safeCode, 'the safe error');
  assert.match(safeCode, /57P01/);
});

test('the database module is marked server-only', () => {
  const source = readFileSync(join(projectRoot, 'lib', 'database.ts'), 'utf8');
  assert.match(source, /^import 'server-only';$/m);
});

test('no client component imports the database module or names server-only DB variables', () => {
  const files = [
    ...sourceFiles(join(projectRoot, 'app')),
    ...sourceFiles(join(projectRoot, 'components')),
  ].filter((file) => file.endsWith('.ts') || file.endsWith('.tsx'));

  const clientModules = files.filter((file) => isClientModule(readFileSync(file, 'utf8')));
  assert.ok(clientModules.length > 0, 'expected to find at least one client component');

  const offenders = clientModules.filter((file) => {
    const source = readFileSync(file, 'utf8');
    return (
      source.includes('lib/database') ||
      source.includes('DATABASE_URL') ||
      source.includes(DATABASE_CA_CERT_VARIABLE)
    );
  });

  assert.deepEqual(offenders, [], 'client components must never reach server-only database code');
});

function sourceFiles(directory: string): string[] {
  return readdirSync(directory).flatMap((entry) => {
    const path = join(directory, entry);
    if (entry === 'node_modules' || entry === '.next') return [];
    return statSync(path).isDirectory() ? sourceFiles(path) : [path];
  });
}

function isClientModule(source: string): boolean {
  const trimmed = source.trimStart();
  return trimmed.startsWith("'use client'") || trimmed.startsWith('"use client"');
}
