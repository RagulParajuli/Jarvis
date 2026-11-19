/**
 * Verifies a Supabase development database, read-only.
 *
 * Run it from `frontend/` after putting `DATABASE_URL` and `DIRECT_URL` in
 * `.env.local`:
 *
 *   pnpm db:verify --development
 *
 * It never writes: every statement is a `select`. It never prints a connection
 * string, a host or a password — only the variable name, the endpoint kind
 * (pooled/direct), the port, the database name and whether TLS is verified.
 *
 * The `--development` flag is required so that this cannot be pointed at a
 * production project by muscle memory. There is no way to verify "this is not
 * production" from inside Postgres, so the flag is an explicit acknowledgement.
 */
import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Pool } from 'pg';
import {
  DIRECT_URL_VARIABLE,
  databaseChecks,
  describeConnection,
  environmentChecks,
  exitCodeFor,
  formatConnectionSummary,
  formatSetupReport,
} from '../lib/database-setup.ts';
import {
  closeDatabasePool,
  createDatabase,
  databasePoolConfig,
  getDatabase,
  readConnectionUrl,
  safeDatabaseError,
} from '../lib/database.ts';

const MIGRATION_FILE = /^(\d{14})_[a-z0-9_]+\.sql$/;

async function main(): Promise<number> {
  if (!process.argv.includes('--development')) {
    console.error(
      'Refusing to run without --development.\n' +
        'These checks connect to a real database. Only run them against a Supabase\n' +
        'development project:\n\n' +
        '  pnpm db:verify --development\n'
    );
    return 2;
  }

  const expectedMigrations = expectedMigrationVersions();
  const database = describeConnection('DATABASE_URL');
  const direct = describeConnection(DIRECT_URL_VARIABLE);

  console.log('Jarvis database setup check (read-only, no rows are written)');
  console.log(formatConnectionSummary(database));
  console.log(formatConnectionSummary(direct));
  console.log('');

  const envChecks = environmentChecks({ database, direct });
  if (envChecks.some((check) => check.status === 'fail')) {
    console.log(formatSetupReport(envChecks));
    return 1;
  }

  const directUrl = readConnectionUrl(DIRECT_URL_VARIABLE);
  const adminPool = new Pool({
    ...databasePoolConfig(directUrl),
    max: 1,
    application_name: 'jarvis-verify',
  });
  const admin = createDatabase(adminPool, () => adminPool.end());
  const runtime = getDatabase();

  try {
    const checks = [
      ...envChecks,
      ...(await databaseChecks({ admin, runtime, expectedMigrations })),
    ];
    console.log(formatSetupReport(checks));
    return exitCodeFor(checks);
  } finally {
    await adminPool.end().catch(() => undefined);
    await closeDatabasePool().catch(() => undefined);
  }
}

/** The 14-digit versions this checkout expects, in apply order. */
function expectedMigrationVersions(): string[] {
  const directory = fileURLToPath(new URL('../../supabase/migrations', import.meta.url));
  const versions = readdirSync(directory)
    .map((name) => MIGRATION_FILE.exec(name)?.[1])
    .filter((version): version is string => version !== undefined)
    .sort();

  if (versions.length === 0) {
    throw new Error(`No migration files found in ${directory}.`);
  }

  return versions;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error: unknown) => {
    console.error(`Verification could not start: ${safeDatabaseError(error)}`);
    process.exitCode = 1;
  });
