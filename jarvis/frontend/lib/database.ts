import { Pool, type PoolConfig, type QueryResultRow } from 'pg';
import 'server-only';

/**
 * Server-only PostgreSQL access for Jarvis.
 *
 * Everything in this module runs on the server: route handlers, server
 * components and scripts. The `server-only` import above makes Next.js fail the
 * build if a client component ever imports it, which is the build-time half of
 * "database credentials never reach the browser". The other half is that the
 * connection string lives in `DATABASE_URL` and the optional CA certificate in
 * `DATABASE_CA_CERT`, never in a `NEXT_PUBLIC_` variable.
 *
 * The connection string is read per process, not per request, and is never
 * included in an error, a log line or a response. Errors are reduced to a
 * SQLSTATE and identifier names before they leave this module.
 */

/** Connection string variable. Never prefix it with `NEXT_PUBLIC_`. */
export const DATABASE_URL_VARIABLE = 'DATABASE_URL';

/** Optional PEM CA certificate used to verify remote TLS. Server-only. */
export const DATABASE_CA_CERT_VARIABLE = 'DATABASE_CA_CERT';

/**
 * Ceiling for one process.
 *
 * Vercel may run many instances of a function, so the total number of database
 * connections is `instances * DATABASE_POOL_MAX`. Keeping it small and pointing
 * `DATABASE_URL` at the pooled Supavisor endpoint (transaction mode, port 6543)
 * is what keeps that total inside the database's limit.
 */
export const DATABASE_POOL_MAX = 3;

/** Idle clients are closed quickly; serverless instances are short-lived. */
const POOL_IDLE_TIMEOUT_MS = 10_000;

/** A connect attempt that takes longer than this fails instead of hanging a request. */
const POOL_CONNECTION_TIMEOUT_MS = 10_000;

/** The server is missing its own configuration; this is not a caller's fault. */
export class DatabaseConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DatabaseConfigurationError';
  }
}

/**
 * A query failed.
 *
 * The message is deliberately generic. Only a SQLSTATE and identifier names
 * (constraint, table, column) are carried over, because PostgreSQL's own message
 * can quote row values and node's connection errors can quote the host.
 */
export class DatabaseQueryError extends Error {
  readonly code?: string;
  readonly constraint?: string;
  readonly table?: string;
  readonly column?: string;

  constructor(details: { code?: string; constraint?: string; table?: string; column?: string }) {
    super('Database query failed.');
    this.name = 'DatabaseQueryError';
    this.code = details.code;
    this.constraint = details.constraint;
    this.table = details.table;
    this.column = details.column;
  }
}

/** The minimal surface these helpers need, so tests can supply a fake. */
export type QueryExecutor = {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: unknown[]
  ): Promise<{ rows: T[] }>;
};

/** Typed helpers bound to one executor. */
export type Database = {
  /** Runs a parameterised query and returns its rows. */
  queryRows<T extends QueryResultRow>(text: string, values?: readonly unknown[]): Promise<T[]>;
  /** Runs a parameterised query and returns the first row, or `null`. */
  queryRow<T extends QueryResultRow>(text: string, values?: readonly unknown[]): Promise<T | null>;
  /** Resolves to `false` instead of throwing when the database is unreachable. */
  ping(): Promise<boolean>;
  /** Releases this executor's connections. Safe to call more than once. */
  close(): Promise<void>;
};

/**
 * Reads and validates `DATABASE_URL` without ever echoing its value.
 *
 * A `NEXT_PUBLIC_` variant is called out explicitly: those values are inlined
 * into the browser bundle, so its presence is a leak even if it is unused.
 */
export function readDatabaseUrl(env: Record<string, string | undefined> = process.env): string {
  const raw = env[DATABASE_URL_VARIABLE]?.trim();
  const browserExposed = env.NEXT_PUBLIC_DATABASE_URL?.trim();

  if (!raw) {
    if (browserExposed) {
      throw new DatabaseConfigurationError(
        'DATABASE_URL is not set, but NEXT_PUBLIC_DATABASE_URL is. Remove the NEXT_PUBLIC_ variable ' +
          '(its value is inlined into browser bundles) and set DATABASE_URL instead.'
      );
    }

    throw new DatabaseConfigurationError(
      `${DATABASE_URL_VARIABLE} is not set. Configure it as a server-only environment variable.`
    );
  }

  return readConnectionUrl(DATABASE_URL_VARIABLE, env);
}

/**
 * Reads and validates any PostgreSQL connection variable without echoing it.
 *
 * `DATABASE_URL` and the optional `DATABASE_CA_CERT` are read by the
 * application. `DIRECT_URL` is read by local tooling (the Supabase CLI and the
 * setup verification script), never by application code.
 */
export function readConnectionUrl(
  variable: string,
  env: Record<string, string | undefined> = process.env
): string {
  const raw = env[variable]?.trim();

  if (!raw) {
    throw new DatabaseConfigurationError(
      `${variable} is not set. Configure it as a server-only environment variable.`
    );
  }

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new DatabaseConfigurationError(
      `${variable} is not a valid URL. It must look like postgresql://user:password@host:port/database.`
    );
  }

  if (url.protocol !== 'postgres:' && url.protocol !== 'postgresql:') {
    throw new DatabaseConfigurationError(
      `${variable} must start with postgres:// or postgresql://.`
    );
  }

  return raw;
}

/** Whether a connection string is configured, without validating or revealing it. */
export function isDatabaseConfigured(
  env: Record<string, string | undefined> = process.env
): boolean {
  return (env[DATABASE_URL_VARIABLE]?.trim().length ?? 0) > 0;
}

/**
 * Pool settings for a serverless deployment.
 *
 * `max` is small, idle clients are reaped, connect attempts are bounded, and
 * `allowExitOnIdle` lets short-lived scripts finish instead of waiting for the
 * pool's idle timer. Callers must not call `pool.end()` per request: the pool is
 * cached across invocations on purpose.
 */
export function databasePoolConfig(
  connectionString: string,
  env: Record<string, string | undefined> = process.env
): PoolConfig {
  return {
    connectionString,
    max: DATABASE_POOL_MAX,
    idleTimeoutMillis: POOL_IDLE_TIMEOUT_MS,
    connectionTimeoutMillis: POOL_CONNECTION_TIMEOUT_MS,
    allowExitOnIdle: true,
    application_name: 'jarvis-web',
    ssl: sslFor(connectionString, env),
  };
}

/**
 * Requires verified TLS for anything that is not a local database.
 *
 * Verification stays on. Plain `sslmode=require` is intentionally not treated
 * as "skip verification": an unverified TLS connection is still interceptable.
 * When the runtime's trust store does not contain the server's CA, an optional
 * server-only `DATABASE_CA_CERT` adds that CA without disabling verification.
 */
function sslFor(
  connectionString: string,
  env: Record<string, string | undefined>
): PoolConfig['ssl'] {
  const url = new URL(connectionString);

  if (url.searchParams.get('sslmode') === 'disable') return false;
  if (isLoopbackHost(url.hostname)) return false;

  const ca = env[DATABASE_CA_CERT_VARIABLE]?.trim();

  return {
    rejectUnauthorized: true,
    ...(ca ? { ca } : {}),
  };
}

/** Loopback hosts run on the developer's machine, so TLS is neither needed nor offered. */
export function isLoopbackHost(hostname: string): boolean {
  const host = hostname.toLowerCase();
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';
}

/**
 * Builds the typed helpers over any executor.
 *
 * Tests pass a fake executor; the app passes the shared pool.
 */
export function createDatabase(
  executor: QueryExecutor,
  close: () => Promise<void> = async () => {}
): Database {
  async function queryRows<T extends QueryResultRow>(
    text: string,
    values: readonly unknown[] = []
  ): Promise<T[]> {
    try {
      const result = await executor.query<T>(text, [...values]);
      return result.rows;
    } catch (error) {
      throw toQueryError(error);
    }
  }

  return {
    queryRows,
    async queryRow<T extends QueryResultRow>(
      text: string,
      values: readonly unknown[] = []
    ): Promise<T | null> {
      const rows = await queryRows<T>(text, values);
      return rows[0] ?? null;
    },
    async ping(): Promise<boolean> {
      try {
        await queryRows('select 1 as ok');
        return true;
      } catch (error) {
        // The safe form never contains the connection string.
        console.error(`Database health check failed: ${safeDatabaseError(error)}`);
        return false;
      }
    },
    close,
  };
}

/**
 * A per-process pool, cached on `globalThis`.
 *
 * Module state is enough in a long-running server, but Next.js can re-evaluate
 * a module during development, and Vercel reuses an instance for several
 * invocations. Caching on `globalThis` means one pool per process instead of one
 * per request or per reload.
 */
type PoolGlobal = typeof globalThis & { __jarvisDatabasePool?: Pool };

export function getDatabasePool(): Pool {
  const globalCache = globalThis as PoolGlobal;

  if (!globalCache.__jarvisDatabasePool) {
    const pool = new Pool(databasePoolConfig(readDatabaseUrl()));

    // An idle client can fail (for example when the pooler drops it). Without a
    // listener that error would crash the process, so it is logged safely and
    // the next query opens a fresh connection.
    pool.on('error', (error) => {
      console.error(`Idle database connection failed: ${safeDatabaseError(error)}`);
    });

    globalCache.__jarvisDatabasePool = pool;
  }

  return globalCache.__jarvisDatabasePool;
}

/** Cleared so the next `getDatabase()` builds a fresh handle after a close. */
let cachedDatabase: Database | undefined;

/** Closes and forgets the cached pool. For tests and graceful shutdown only. */
export async function closeDatabasePool(): Promise<void> {
  const globalCache = globalThis as PoolGlobal;
  const pool = globalCache.__jarvisDatabasePool;
  globalCache.__jarvisDatabasePool = undefined;
  cachedDatabase = undefined;

  if (pool) await pool.end();
}

/** The app-facing handle. Connect lazily so importing this module has no side effects. */
export function getDatabase(): Database {
  cachedDatabase ??= createDatabase(getDatabasePool(), closeDatabasePool);
  return cachedDatabase;
}

/**
 * The subset of an error that is safe to log.
 *
 * Unknown errors are reduced to a code, never their message, because messages
 * can contain the connection string, host addresses or row values.
 */
export function safeDatabaseError(error: unknown): string {
  if (error instanceof DatabaseConfigurationError) return error.message;

  if (error instanceof DatabaseQueryError) {
    const parts = [error.message];
    if (error.code) parts.push(`code ${error.code}`);
    if (error.constraint) parts.push(`constraint ${error.constraint}`);
    return parts.join(' ');
  }

  const code = readCode(error);
  return code ? `Database error (code ${code}).` : 'Database error.';
}

function toQueryError(error: unknown): DatabaseQueryError {
  return new DatabaseQueryError({
    code: readCode(error),
    constraint: readIdentifier(error, 'constraint'),
    table: readIdentifier(error, 'table'),
    column: readIdentifier(error, 'column'),
  });
}

/** PostgreSQL SQLSTATEs and node error codes share a safe character set. */
function readCode(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null) return undefined;
  const code = (error as { code?: unknown }).code;
  return typeof code === 'string' && /^[0-9A-Z_]{5,32}$/.test(code) ? code : undefined;
}

/** Identifier names are schema metadata, not user data. */
function readIdentifier(error: unknown, key: string): string | undefined {
  if (typeof error !== 'object' || error === null) return undefined;
  const value = (error as Record<string, unknown>)[key];
  return typeof value === 'string' && /^[A-Za-z0-9_.$-]{1,64}$/.test(value) ? value : undefined;
}
