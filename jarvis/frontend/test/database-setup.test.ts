import assert from 'node:assert/strict';
import test from 'node:test';
import {
  DIRECT_URL_VARIABLE,
  type SetupCheck,
  describeConnection,
  environmentChecks,
  exitCodeFor,
  formatConnectionSummary,
  formatSetupReport,
} from '../lib/database-setup.ts';

const SECRET = 'sup3r-s3cret-p4ssword';
const HOST = 'db.abcdefghijklmnop.supabase.co';

const POOLED = `postgresql://jarvis:${SECRET}@${HOST}:6543/postgres`;
const DIRECT = `postgresql://jarvis:${SECRET}@${HOST}:5432/postgres`;

/** A summary, a report or a check must never carry the password, host or URL. */
function assertNoSecret(value: string, description: string): void {
  assert.equal(value.includes(SECRET), false, `${description} must not contain the password`);
  assert.equal(value.includes(HOST), false, `${description} must not contain the host`);
  assert.equal(value.includes('postgresql://'), false, `${description} must not contain a URL`);
}

function status(checks: readonly SetupCheck[], id: string) {
  return checks.find((check) => check.id === id)?.status;
}

test('connection strings are summarised without their host or password', () => {
  const env = { DATABASE_URL: POOLED, [DIRECT_URL_VARIABLE]: DIRECT };

  const pooled = describeConnection('DATABASE_URL', env);
  assert.equal(pooled.kind, 'pooled');
  assert.equal(pooled.port, 6543);
  assert.equal(pooled.database, 'postgres');
  assert.equal(pooled.tls, 'verified');

  const line = formatConnectionSummary(pooled);
  assertNoSecret(line, 'the connection summary');
  assert.match(line, /DATABASE_URL: pooled:6543\/postgres \(TLS verified\)/);

  const direct = describeConnection(DIRECT_URL_VARIABLE, env);
  assert.equal(direct.kind, 'direct');
  assert.equal(direct.port, 5432);
  assertNoSecret(formatConnectionSummary(direct), 'the connection summary');
});

test('loopback and sslmode=disable are reported as TLS off', () => {
  const local = describeConnection('DATABASE_URL', {
    DATABASE_URL: `postgresql://postgres:${SECRET}@localhost:5432/jarvis_test`,
  });
  assert.equal(local.kind, 'local');
  assert.equal(local.tls, 'disabled');

  const disabled = describeConnection('DATABASE_URL', {
    DATABASE_URL: `${POOLED}?sslmode=disable`,
  });
  assert.equal(disabled.kind, 'pooled');
  assert.equal(disabled.tls, 'disabled');

  const other = describeConnection('DATABASE_URL', {
    DATABASE_URL: `postgresql://jarvis:${SECRET}@db.internal.example.com:6432/postgres`,
  });
  assert.equal(other.kind, 'remote');
  assert.equal(other.tls, 'verified');
});

test('a healthy environment passes every environment check', () => {
  const env = { DATABASE_URL: POOLED, [DIRECT_URL_VARIABLE]: DIRECT };
  const checks = environmentChecks({
    database: describeConnection('DATABASE_URL', env),
    direct: describeConnection(DIRECT_URL_VARIABLE, env),
    env,
  });

  assert.deepEqual(
    checks.map((check) => check.status),
    ['pass', 'pass', 'pass', 'pass', 'pass']
  );
  for (const check of checks) assertNoSecret(check.detail, `the ${check.id} detail`);
});

test('an identical pair of connection strings is refused', () => {
  const env = { DATABASE_URL: POOLED, [DIRECT_URL_VARIABLE]: POOLED };
  const checks = environmentChecks({
    database: describeConnection('DATABASE_URL', env),
    direct: describeConnection(DIRECT_URL_VARIABLE, env),
    env,
  });

  assert.equal(status(checks, 'env-separate-endpoints'), 'fail');
  assert.match(formatSetupReport(checks), /identical/);
});

test('a NEXT_PUBLIC_ database variable fails the check', () => {
  const env = {
    DATABASE_URL: POOLED,
    [DIRECT_URL_VARIABLE]: DIRECT,
    NEXT_PUBLIC_DATABASE_URL: POOLED,
  };
  const checks = environmentChecks({
    database: describeConnection('DATABASE_URL', env),
    direct: describeConnection(DIRECT_URL_VARIABLE, env),
    env,
  });

  assert.equal(status(checks, 'env-no-public-variable'), 'fail');
  assertNoSecret(formatSetupReport(checks), 'the report');
});

test('runtime TLS cannot be disabled for a remote host', () => {
  const env = { DATABASE_URL: `${POOLED}?sslmode=disable`, [DIRECT_URL_VARIABLE]: DIRECT };
  const checks = environmentChecks({
    database: describeConnection('DATABASE_URL', env),
    direct: describeConnection(DIRECT_URL_VARIABLE, env),
    env,
  });

  assert.equal(status(checks, 'env-runtime-tls'), 'fail');
  assert.equal(status(checks, 'env-migrations-tls'), 'pass');
});

test('a direct runtime endpoint is a warning, not a failure', () => {
  const env = { DATABASE_URL: DIRECT, [DIRECT_URL_VARIABLE]: DIRECT };
  const checks = environmentChecks({
    database: describeConnection('DATABASE_URL', env),
    direct: describeConnection(DIRECT_URL_VARIABLE, env),
    env,
  });

  assert.equal(status(checks, 'env-runtime-pooling'), 'warn');
  assert.equal(exitCodeFor(checks.filter((check) => check.id !== 'env-separate-endpoints')), 0);
});

test('warnings do not fail the run, failures do', () => {
  const warn: SetupCheck[] = [{ id: 'x', status: 'warn', detail: 'careful' }];
  const fail: SetupCheck[] = [{ id: 'y', status: 'fail', detail: 'broken' }];

  assert.equal(exitCodeFor(warn), 0);
  assert.equal(exitCodeFor(fail), 1);
  assert.match(formatSetupReport(warn), /1 warning/);
  assert.match(formatSetupReport(fail), /1 check\(s\) failed/);
});
