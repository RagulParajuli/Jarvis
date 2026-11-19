import assert from 'node:assert/strict';
import test from 'node:test';
import type { QueryResultRow } from 'pg';
import {
  type SetupCheck,
  databaseChecks,
  exitCodeFor,
  formatSetupReport,
} from '../lib/database-setup.ts';
import { createDatabase } from '../lib/database.ts';

const SECRET = 'sup3r-s3cret-p4ssword';
const MIGRATIONS = ['20261118120000', '20261118120100'];

type RowSource = Record<string, QueryResultRow[] | Error>;

/**
 * A fake executor keyed by the `check:<id>` tag each query carries, so a test
 * can answer per check without a database.
 */
function fakeDatabase(rows: RowSource) {
  return createDatabase({
    async query<T extends QueryResultRow>(text: string) {
      const id = /check:([a-z-]+)/.exec(text)?.[1];
      if (!id) throw new Error(`query has no check tag: ${text.slice(0, 40)}`);

      const value = rows[id];
      if (value instanceof Error) throw value;
      if (!value) throw new Error(`no fake rows for check ${id}`);

      return { rows: value as T[] };
    },
  });
}

function healthyRows(): RowSource {
  return {
    'server-version': [{ version_num: 160003, role_name: 'postgres', database_name: 'postgres' }],
    migrations: MIGRATIONS.map((version) => ({ version })),
    objects: [{ missing_tables: [], missing_functions: [] }],
    rls: [{ table_count: 9, tables_without_rls: [] }],
    'client-roles': [
      {
        role_count: 3,
        schema_grants: 0,
        table_grants: 0,
        function_grants: 0,
        public_schema_grants: 0,
        public_table_grants: 0,
        public_function_grants: 0,
      },
    ],
    seed: [{ users: 1 }],
    runtime: [{ role_name: 'postgres', database_name: 'postgres' }],
    'runtime-read': [{ users: 1 }],
  };
}

async function run(rows: RowSource): Promise<SetupCheck[]> {
  return databaseChecks({
    admin: fakeDatabase(rows),
    runtime: fakeDatabase(rows),
    expectedMigrations: MIGRATIONS,
  });
}

function find(checks: readonly SetupCheck[], id: string): SetupCheck {
  const check = checks.find((candidate) => candidate.id === id);
  assert.ok(check, `expected a ${id} check`);
  return check;
}

test('a migrated, locked-down development database passes every check', async () => {
  const checks = await run(healthyRows());

  assert.deepEqual(
    checks.map((check) => check.status),
    ['pass', 'pass', 'pass', 'pass', 'pass', 'pass', 'pass', 'pass']
  );
  assert.equal(exitCodeFor(checks), 0);

  const report = formatSetupReport(checks);
  assert.match(report, /All 2 migrations are applied/);
  assert.match(report, /Pooled connection works/);
  assert.equal(report.includes(SECRET), false);
});

test('an unreachable direct endpoint is reported once and stops the run', async () => {
  const rows = healthyRows();
  rows['server-version'] = Object.assign(
    new Error(`connect ECONNREFUSED postgresql://jarvis:${SECRET}@db.example.com:5432/postgres`),
    { code: 'ECONNREFUSED' }
  );

  const checks = await run(rows);
  assert.equal(checks.length, 1);
  assert.equal(checks[0].id, 'admin-connection');
  assert.equal(checks[0].status, 'fail');
  assert.match(checks[0].detail, /DIRECT_URL/);
  assert.equal(checks[0].detail.includes(SECRET), false);
  assert.equal(exitCodeFor(checks), 1);
});

test('an older server version fails with the required minimum', async () => {
  const rows = healthyRows();
  rows['server-version'] = [
    { version_num: 140000, role_name: 'postgres', database_name: 'postgres' },
  ];

  const check = find(await run(rows), 'server-version');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /150000/);
});

test('unapplied migrations are named', async () => {
  const rows = healthyRows();
  rows.migrations = [{ version: MIGRATIONS[0] }];

  const check = find(await run(rows), 'migrations-applied');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, new RegExp(MIGRATIONS[1]));
});

test('a missing migration history table is explained, not dumped', async () => {
  const rows = healthyRows();
  rows.migrations = Object.assign(
    new Error(`relation "supabase_migrations.schema_migrations" does not exist`),
    {
      code: '42P01',
    }
  );

  const check = find(await run(rows), 'migrations-applied');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /Supabase CLI/);
  assert.equal(check.detail.includes('relation "'), false);
});

test('unknown remote migrations are a warning', async () => {
  const rows = healthyRows();
  rows.migrations = [...MIGRATIONS.map((version) => ({ version })), { version: '20270101000000' }];

  const check = find(await run(rows), 'migrations-applied');
  assert.equal(check.status, 'warn');
  assert.match(check.detail, /20270101000000/);
});

test('missing tables and functions are listed', async () => {
  const rows = healthyRows();
  rows.objects = [
    {
      missing_tables: ['jarvis.memories'],
      missing_functions: ['jarvis.delete_memory(uuid,uuid,boolean)'],
    },
  ];

  const check = find(await run(rows), 'schema-objects');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /jarvis\.memories/);
  assert.match(check.detail, /jarvis\.delete_memory/);
});

test('the schema check expects the device-challenge table', async () => {
  const rows = healthyRows();
  const objectQueries: (readonly unknown[] | undefined)[] = [];
  const db = createDatabase({
    async query<T extends QueryResultRow>(text: string, values?: unknown[]) {
      const id = /check:([a-z-]+)/.exec(text)?.[1] ?? '';
      if (id === 'objects') objectQueries.push(values);
      return { rows: (rows[id] ?? []) as T[] };
    },
  });

  const checks = await databaseChecks({ admin: db, runtime: db, expectedMigrations: MIGRATIONS });
  assert.equal(find(checks, 'schema-objects').status, 'pass');
  assert.ok(
    objectQueries.some((values) => (values?.[0] as string[])?.includes('jarvis.device_challenges')),
    'jarvis.device_challenges must be part of the expected schema'
  );
});

test('row level security must be enabled everywhere', async () => {
  const rows = healthyRows();
  rows.rls = [{ table_count: 9, tables_without_rls: ['jarvis.memories'] }];

  const check = find(await run(rows), 'rls-enabled');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /jarvis\.memories/);
});

test('the rls check receives a real array from the driver', async () => {
  const healthy = healthyRows();

  const db = createDatabase({
    async query<T extends QueryResultRow>(text: string) {
      const id = /check:([a-z-]+)/.exec(text)?.[1] ?? '';
      if (id === 'rls') {
        // Emulate node-postgres parsing the aggregate: name[] (OID 1003) has no
        // parser, so it comes back as the raw literal "{}" and .join() would
        // throw; text[] (OID 1009) is parsed into an actual array.
        const tables_without_rls = text.includes('c.relname::text') ? [] : '{}';
        return { rows: [{ table_count: 9, tables_without_rls }] as unknown as T[] };
      }
      return { rows: (healthy[id] ?? []) as T[] };
    },
  });

  const checks = await databaseChecks({ admin: db, runtime: db, expectedMigrations: MIGRATIONS });
  const rls = find(checks, 'rls-enabled');
  assert.equal(rls.status, 'pass', `rls check failed with: ${rls.detail}`);
  assert.match(rls.detail, /all 9 tables/);
  assert.equal(rls.detail.includes('Database error'), false);
});

test('a client role privilege fails the check', async () => {
  const rows = healthyRows();
  rows['client-roles'] = [
    {
      role_count: 3,
      schema_grants: 1,
      table_grants: 0,
      function_grants: 0,
      public_schema_grants: 0,
      public_table_grants: 0,
      public_function_grants: 0,
    },
  ];

  const check = find(await run(rows), 'client-roles-denied');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /client roles hold 1 privilege/);
});

test('PUBLIC execute on a function fails the check', async () => {
  const rows = healthyRows();
  rows['client-roles'] = [
    {
      role_count: 3,
      schema_grants: 0,
      table_grants: 0,
      function_grants: 0,
      public_schema_grants: 0,
      public_table_grants: 0,
      public_function_grants: 1,
    },
  ];

  const check = find(await run(rows), 'client-roles-denied');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /PUBLIC holds 1 privilege/);
});

test('the seed account must exist exactly once', async () => {
  const empty = healthyRows();
  empty.seed = [{ users: 0 }];
  assert.equal(find(await run(empty), 'seed-account').status, 'fail');

  const duplicated = healthyRows();
  duplicated.seed = [{ users: 2 }];
  const check = find(await run(duplicated), 'seed-account');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /2 account rows/);
});

test('a runtime failure is reported without the driver message', async () => {
  const rows = healthyRows();
  rows['runtime-read'] = Object.assign(
    new Error(`connect ECONNREFUSED postgresql://jarvis:${SECRET}@db.example.com`),
    { code: 'ECONNREFUSED' }
  );

  const check = find(await run(rows), 'runtime-read');
  assert.equal(check.status, 'fail');
  assert.match(check.detail, /ECONNREFUSED/);
  assert.equal(check.detail.includes(SECRET), false);
  assert.equal(formatSetupReport([check]).includes(SECRET), false);
});

test('a role_count below three is a warning, not a failure', async () => {
  const rows = healthyRows();
  rows['client-roles'] = [
    {
      role_count: 0,
      schema_grants: 0,
      table_grants: 0,
      function_grants: 0,
      public_schema_grants: 0,
      public_table_grants: 0,
      public_function_grants: 0,
    },
  ];

  const check = find(await run(rows), 'client-roles-denied');
  assert.equal(check.status, 'warn');
  assert.match(check.detail, /not be a Supabase database/);
});
