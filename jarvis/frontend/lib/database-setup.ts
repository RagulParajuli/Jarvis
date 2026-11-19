import 'server-only';
import {
  DATABASE_URL_VARIABLE,
  type Database,
  DatabaseQueryError,
  isLoopbackHost,
  readConnectionUrl,
  safeDatabaseError,
} from './database.ts';

/**
 * Read-only checks for a Supabase development database.
 *
 * These exist so that "did I point the app at the right project, and did the
 * migrations apply?" can be answered without opening a SQL console. Everything
 * here is a `select`: no inserts, no updates, no DDL, no `db push`.
 *
 * Nothing in this module prints a connection string. Connection details are
 * reduced to a variable name, the port, the database name and whether TLS is
 * verified; the host and the password are never included in a summary, a check
 * or a report.
 */

/** Direct connection, used by the Supabase CLI and local tooling only. */
export const DIRECT_URL_VARIABLE = 'DIRECT_URL';

/** Supabase's transaction pooler. The right target for serverless runtimes. */
const TRANSACTION_POOLER_PORT = 6543;

/** Direct Postgres and the session pooler both listen on this port. */
const DIRECT_PORT = 5432;

/** Minimum PostgreSQL version the schema needs (column-list `ON DELETE SET NULL`). */
const MINIMUM_SERVER_VERSION_NUM = 150000;

/** Tables every migration set must leave behind. */
const EXPECTED_TABLES = [
  'jarvis.users',
  'jarvis.devices',
  'jarvis.device_credentials',
  'jarvis.pairing_codes',
  'jarvis.device_challenges',
  'jarvis.conversations',
  'jarvis.messages',
  'jarvis.conversation_summaries',
  'jarvis.memories',
] as const;

/** Functions the application and the deletion rules depend on. */
const EXPECTED_FUNCTIONS = [
  'jarvis.set_updated_at()',
  'jarvis.allocate_message_seq(uuid,uuid)',
  'jarvis.delete_memory(uuid,uuid,boolean)',
  'jarvis.purge_deleted_memories(interval)',
  'jarvis.seed_initial_user()',
] as const;

/** Roles Supabase ships with. They must hold no privileges on `jarvis`. */
const SUPABASE_CLIENT_ROLES = ['anon', 'authenticated', 'service_role'] as const;

export type SetupStatus = 'pass' | 'warn' | 'fail';

export type SetupCheck = {
  readonly id: string;
  readonly status: SetupStatus;
  readonly detail: string;
};

/** How a connection string is expected to be used. */
export type ConnectionKind = 'local' | 'pooled' | 'direct' | 'remote';

/** A connection string reduced to facts that are safe to print. */
export type ConnectionSummary = {
  readonly variable: string;
  readonly kind: ConnectionKind;
  readonly port: number | null;
  readonly database: string;
  readonly tls: 'verified' | 'disabled';
};

/**
 * Summarises a connection string without revealing it.
 *
 * The host is deliberately dropped: on Supabase it contains the project ref,
 * which is not a credential but is not needed to verify a setup either. The
 * port and database name are enough to tell the pooled endpoint from the direct
 * one and to catch a typo in the database name.
 */
export function describeConnection(
  variable: string,
  env: Record<string, string | undefined> = process.env
): ConnectionSummary {
  const raw = readConnectionUrl(variable, env);
  const url = new URL(raw);
  const port = url.port ? Number(url.port) : null;
  const local = isLoopbackHost(url.hostname);

  return {
    variable,
    kind: connectionKind(port, local),
    port,
    database: url.pathname.replace(/^\//, '') || '(default)',
    tls: local || url.searchParams.get('sslmode') === 'disable' ? 'disabled' : 'verified',
  };
}

function connectionKind(port: number | null, local: boolean): ConnectionKind {
  if (local) return 'local';
  if (port === TRANSACTION_POOLER_PORT) return 'pooled';
  if (port === DIRECT_PORT) return 'direct';
  return 'remote';
}

/** One line that is safe to print, for example `DATABASE_URL: pooled:6543/postgres`. */
export function formatConnectionSummary(summary: ConnectionSummary): string {
  const endpoint = `${summary.kind}:${summary.port ?? 'default'}/${summary.database}`;
  const tls = summary.tls === 'verified' ? 'TLS verified' : 'TLS off';
  return `${summary.variable}: ${endpoint} (${tls})`;
}

/**
 * Checks that need no connection: variable hygiene and endpoint roles.
 *
 * `DATABASE_URL` must be the pooled endpoint the application uses, and
 * `DIRECT_URL` must be the separate direct endpoint migrations use. Pointing
 * both at the same string means migrations are running through the pooler,
 * which is exactly what the split is meant to prevent.
 */
export function environmentChecks(options: {
  readonly database: ConnectionSummary;
  readonly direct: ConnectionSummary;
  readonly env?: Record<string, string | undefined>;
}): SetupCheck[] {
  const env = options.env ?? process.env;
  const databaseUrl = env[DATABASE_URL_VARIABLE]?.trim();
  const directUrl = env[DIRECT_URL_VARIABLE]?.trim();

  const checks: SetupCheck[] = [];

  const publicVariable = env.NEXT_PUBLIC_DATABASE_URL?.trim();
  checks.push({
    id: 'env-no-public-variable',
    status: publicVariable ? 'fail' : 'pass',
    detail: publicVariable
      ? 'NEXT_PUBLIC_DATABASE_URL is set. Remove it: NEXT_PUBLIC_ values are inlined into browser bundles.'
      : 'No NEXT_PUBLIC_ database variable is set.',
  });

  checks.push({
    id: 'env-separate-endpoints',
    status: databaseUrl && directUrl && databaseUrl === directUrl ? 'fail' : 'pass',
    detail:
      databaseUrl && directUrl && databaseUrl === directUrl
        ? 'DATABASE_URL and DIRECT_URL are identical. Runtime must use the pooled endpoint and migrations the direct one.'
        : 'Runtime and migration connection strings are separate.',
  });

  const runtimeIsDirect = options.database.kind === 'direct';
  checks.push({
    id: 'env-runtime-pooling',
    status: runtimeIsDirect ? 'warn' : 'pass',
    detail: runtimeIsDirect
      ? 'DATABASE_URL uses port 5432 (direct or session pooler). The transaction pooler on 6543 is the safer choice for serverless.'
      : `DATABASE_URL uses the ${options.database.kind} endpoint.`,
  });

  checks.push({
    id: 'env-runtime-tls',
    status:
      options.database.kind !== 'local' && options.database.tls === 'disabled' ? 'fail' : 'pass',
    detail:
      options.database.kind !== 'local' && options.database.tls === 'disabled'
        ? 'DATABASE_URL disables TLS for a remote host. Remove sslmode=disable; Supabase requires TLS.'
        : 'DATABASE_URL uses verified TLS (or a loopback host).',
  });

  checks.push({
    id: 'env-migrations-tls',
    status: options.direct.kind !== 'local' && options.direct.tls === 'disabled' ? 'warn' : 'pass',
    detail:
      options.direct.kind !== 'local' && options.direct.tls === 'disabled'
        ? 'DIRECT_URL disables TLS for a remote host. Migrations will run over plaintext; remove sslmode=disable.'
        : 'DIRECT_URL uses verified TLS (or a loopback host).',
  });

  return checks;
}

/**
 * Checks that read the database.
 *
 * `admin` is expected to be a direct connection (migrations, catalog queries)
 * and `runtime` the pooled connection the application uses. Both are only read.
 */
export async function databaseChecks(options: {
  readonly admin: Database;
  readonly runtime: Database;
  readonly expectedMigrations: readonly string[];
}): Promise<SetupCheck[]> {
  const { admin, runtime, expectedMigrations } = options;

  const checks: SetupCheck[] = [];

  // One probe first: if the direct endpoint is unreachable, every later check
  // would fail with the same message, so say it once and stop.
  let serverRows: { version_num: number; role_name: string; database_name: string }[];
  try {
    serverRows = await admin.queryRows<{
      version_num: number;
      role_name: string;
      database_name: string;
    }>(
      `/* check:server-version */
       select current_setting('server_version_num')::int as version_num,
              current_user as role_name,
              current_database() as database_name`
    );
  } catch (error) {
    return [
      {
        id: 'admin-connection',
        status: 'fail',
        detail:
          `Could not reach the direct endpoint (${safeDatabaseError(error)}). ` +
          'Check DIRECT_URL, the database password, and that the project is not paused.',
      },
    ];
  }

  const server = await runCheck('server-version', async () => {
    const row = serverRows[0];
    if (!row) throw new Error('the version query returned no rows');

    const detail = `PostgreSQL ${row.version_num} as ${row.role_name} on ${row.database_name}.`;
    return row.version_num >= MINIMUM_SERVER_VERSION_NUM
      ? { status: 'pass' as const, detail }
      : {
          status: 'fail' as const,
          detail: `${detail} Version ${MINIMUM_SERVER_VERSION_NUM} or newer is required.`,
        };
  });
  checks.push(server);

  checks.push(
    await runCheck('migrations-applied', async () => {
      let applied: string[];
      try {
        const rows = await admin.queryRows<{ version: string }>(
          `/* check:migrations */
         select version from supabase_migrations.schema_migrations order by version`
        );
        applied = rows.map((row) => row.version);
      } catch (error) {
        if (error instanceof DatabaseQueryError && isMissingRelation(error)) {
          return {
            status: 'fail',
            detail:
              'supabase_migrations.schema_migrations does not exist. No migration has been applied with the Supabase CLI yet.',
          };
        }
        throw error;
      }

      const missing = expectedMigrations.filter((version) => !applied.includes(version));
      const unknown = applied.filter((version) => !expectedMigrations.includes(version));

      if (missing.length > 0) {
        return {
          status: 'fail',
          detail: `${missing.length} migration(s) not applied: ${missing.join(', ')}.`,
        };
      }

      if (unknown.length > 0) {
        return {
          status: 'warn',
          detail: `The database has ${unknown.length} migration(s) this checkout does not: ${unknown.join(', ')}.`,
        };
      }

      return { status: 'pass', detail: `All ${expectedMigrations.length} migrations are applied.` };
    })
  );

  checks.push(
    await runCheck('schema-objects', async () => {
      const rows = await admin.queryRows<{
        missing_tables: string[] | null;
        missing_functions: string[] | null;
      }>(
        `/* check:objects */
       select
         (select array_agg(t.name order by t.name)
            from unnest($1::text[]) as t(name)
           where to_regclass(t.name) is null) as missing_tables,
         (select array_agg(f.name order by f.name)
            from unnest($2::text[]) as f(name)
           where to_regprocedure(f.name) is null) as missing_functions`,
        [[...EXPECTED_TABLES], [...EXPECTED_FUNCTIONS]]
      );

      const row = rows[0];
      const missingTables = row?.missing_tables ?? [];
      const missingFunctions = row?.missing_functions ?? [];
      const missing = [...missingTables, ...missingFunctions];

      return missing.length === 0
        ? {
            status: 'pass',
            detail: `${EXPECTED_TABLES.length} tables and ${EXPECTED_FUNCTIONS.length} functions are present.`,
          }
        : { status: 'fail', detail: `Missing objects: ${missing.join(', ')}.` };
    })
  );

  checks.push(
    await runCheck('rls-enabled', async () => {
      const rows = await admin.queryRows<{
        table_count: number;
        tables_without_rls: string[] | null;
      }>(
        `/* check:rls */
       select count(*)::int as table_count,
              coalesce(array_agg(c.relname::text order by c.relname) filter (where not c.relrowsecurity), '{}') as tables_without_rls
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'jarvis' and c.relkind = 'r'`
      );

      const row = rows[0];
      const withoutRls = row?.tables_without_rls ?? [];
      if (!row || row.table_count < EXPECTED_TABLES.length) {
        return {
          status: 'fail',
          detail: `Only ${row?.table_count ?? 0} table(s) found in the jarvis schema; expected ${EXPECTED_TABLES.length}.`,
        };
      }

      return withoutRls.length === 0
        ? {
            status: 'pass',
            detail: `Row level security is enabled on all ${row.table_count} tables.`,
          }
        : {
            status: 'fail',
            detail: `Row level security is disabled on: ${withoutRls.join(', ')}.`,
          };
    })
  );

  checks.push(
    await runCheck('client-roles-denied', async () => {
      const rows = await admin.queryRows<{
        role_count: number;
        schema_grants: number;
        table_grants: number;
        function_grants: number;
        public_schema_grants: number;
        public_table_grants: number;
        public_function_grants: number;
      }>(
        `/* check:client-roles */
       with client_roles as (
         select oid, rolname from pg_roles where rolname = any ($1::text[])
       ), tables as (
         select c.oid from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'jarvis' and c.relkind = 'r'
       ), routines as (
         select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'jarvis'
       )
       select
         (select count(*)::int from client_roles) as role_count,
         (select count(*)::int from client_roles r
           where has_schema_privilege(r.oid, 'jarvis', 'USAGE')) as schema_grants,
         (select count(*)::int from client_roles r, tables t
           where has_table_privilege(r.oid, t.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')) as table_grants,
         (select count(*)::int from client_roles r, routines f
           where has_function_privilege(r.oid, f.oid, 'EXECUTE')) as function_grants,
         (select count(*)::int from pg_namespace n,
                 aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
           where n.nspname = 'jarvis' and a.grantee = 0) as public_schema_grants,
         (select count(*)::int from pg_class c
           join pg_namespace n on n.oid = c.relnamespace,
                 aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
           where n.nspname = 'jarvis' and c.relkind = 'r' and a.grantee = 0) as public_table_grants,
         (select count(*)::int from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace,
                 aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
           where n.nspname = 'jarvis' and a.grantee = 0) as public_function_grants`,
        [[...SUPABASE_CLIENT_ROLES]]
      );

      const row = rows[0];
      if (!row) throw new Error('the privilege query returned no rows');

      const granted = row.schema_grants + row.table_grants + row.function_grants;
      const grantedToPublic =
        row.public_schema_grants + row.public_table_grants + row.public_function_grants;

      if (granted > 0) {
        return {
          status: 'fail',
          detail: `Supabase client roles hold ${granted} privilege(s) on the jarvis schema (schema ${row.schema_grants}, tables ${row.table_grants}, functions ${row.function_grants}).`,
        };
      }

      if (grantedToPublic > 0) {
        return {
          status: 'fail',
          detail: `PUBLIC holds ${grantedToPublic} privilege(s) on the jarvis schema (schema ${row.public_schema_grants}, tables ${row.public_table_grants}, functions ${row.public_function_grants}).`,
        };
      }

      if (row.role_count < SUPABASE_CLIENT_ROLES.length) {
        return {
          status: 'warn',
          detail: `Only ${row.role_count} of ${SUPABASE_CLIENT_ROLES.length} Supabase client roles exist; this may not be a Supabase database.`,
        };
      }

      return {
        status: 'pass',
        detail: 'anon, authenticated, service_role and PUBLIC hold no privileges on jarvis.',
      };
    })
  );

  checks.push(
    await runCheck('seed-account', async () => {
      const rows = await admin.queryRows<{ users: number }>(
        `/* check:seed */
       select count(*)::int as users from jarvis.users`
      );
      const users = rows[0]?.users ?? 0;

      if (users === 1) return { status: 'pass', detail: 'Exactly one account row exists.' };
      if (users === 0) {
        return {
          status: 'fail',
          detail:
            'No account row exists. Re-run the seed migration or call jarvis.seed_initial_user().',
        };
      }
      return {
        status: 'fail',
        detail: `${users} account rows exist; this deployment expects exactly one.`,
      };
    })
  );

  checks.push(
    await runCheck('runtime-connect', async () => {
      const rows = await runtime.queryRows<{
        role_name: string;
        database_name: string;
      }>(
        `/* check:runtime */
       select current_user as role_name, current_database() as database_name`
      );
      const row = rows[0];
      if (!row) throw new Error('the runtime connection query returned no rows');

      return {
        status: 'pass',
        detail: `Pooled connection works: ${row.role_name} on ${row.database_name}.`,
      };
    })
  );

  checks.push(
    await runCheck('runtime-read', async () => {
      const rows = await runtime.queryRows<{ users: number }>(
        `/* check:runtime-read */
       select count(*)::int as users from jarvis.users`
      );
      const users = rows[0]?.users ?? 0;

      return users >= 1
        ? {
            status: 'pass',
            detail: `The pooled connection can read jarvis.users (${users} row(s)).`,
          }
        : {
            status: 'fail',
            detail:
              'The pooled connection reads no rows from jarvis.users. Check the database name and the seed migration.',
          };
    })
  );

  return checks;
}

async function runCheck(
  id: string,
  run: () => Promise<{ status: SetupStatus; detail: string }>
): Promise<SetupCheck> {
  try {
    return { id, ...(await run()) };
  } catch (error) {
    return { id, status: 'fail', detail: `Check could not run: ${safeDatabaseError(error)}` };
  }
}

/** `42P01` undefined_table, `3F000` invalid_schema_name. */
function isMissingRelation(error: DatabaseQueryError): boolean {
  return error.code === '42P01' || error.code === '3F000';
}

/** A plain-text report. Every value in it came from a summary or a check. */
export function formatSetupReport(checks: readonly SetupCheck[]): string {
  const lines = checks.map(
    (check) => `[${check.status.toUpperCase().padEnd(4)}] ${check.id} — ${check.detail}`
  );
  const failures = checks.filter((check) => check.status === 'fail').length;
  const warnings = checks.filter((check) => check.status === 'warn').length;

  const summary =
    failures === 0
      ? `Setup looks good: ${checks.length} check(s) passed${warnings > 0 ? `, ${warnings} warning(s)` : ''}.`
      : `${failures} check(s) failed${warnings > 0 ? `, ${warnings} warning(s)` : ''}.`;

  return [...lines, '', summary].join('\n');
}

/** `1` when any check failed, so a shell can stop on it. Warnings are not failures. */
export function exitCodeFor(checks: readonly SetupCheck[]): number {
  return checks.some((check) => check.status === 'fail') ? 1 : 0;
}
