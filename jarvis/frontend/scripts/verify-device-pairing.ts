/**
 * Development-only integration check for the S5.2 pairing primitives.
 *
 * Unlike `verify-database-setup.ts`, this script WRITES. It exercises the real
 * redemption CTE and replay guard against an already-migrated database using
 * temporary rows with freshly generated UUIDs, then deletes exactly those rows.
 *
 * Run from `frontend/` with both acknowledgement flags:
 *
 *   NODE_EXTRA_CA_CERTS=/path/to/prod-ca-2021.crt \
 *     pnpm db:verify-pairing --development --write
 *
 * `--development` is the same explicit acknowledgement the read-only verifier
 * requires: PostgreSQL cannot tell a development project from a production one.
 * `--write` additionally acknowledges that temporary rows are created. Set
 * NODE_EXTRA_CA_CERTS to the official Supabase root CA if it is not already in
 * Node's trust store; TLS verification is never disabled here.
 *
 * Nothing printed by this script contains a connection string, a host, a
 * plaintext pairing code, a key, a signature or a password. Database errors are
 * reduced with `safeDatabaseError` before they reach the console.
 */
import { type KeyObject, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describeConnection, formatConnectionSummary } from '../lib/database-setup.ts';
import {
  DATABASE_URL_VARIABLE,
  closeDatabasePool,
  getDatabase,
  safeDatabaseError,
} from '../lib/database.ts';
import {
  TOKEN_API_AUDIENCE,
  assertionPayload,
  consumeDeviceChallenge,
  createAssertionNonce,
  issueDeviceChallenge,
  issuePairingCode,
  redeemPairingCode,
  registerDevice,
  sha256Hex,
  verifyDeviceAssertion,
} from '../lib/device-pairing.ts';

type Outcome = { readonly ok: boolean; readonly detail: string };

const MIGRATION_FILE = /^(\d{14})_[a-z0-9_]+\.sql$/;

function acceptable(label: string, ok: boolean, detail: string): Outcome {
  return { ok, detail: `${label}: ${detail}` };
}

async function main(): Promise<number> {
  if (!process.argv.includes('--development') || !process.argv.includes('--write')) {
    console.error(
      'Refusing to run. This writes temporary rows to a real database.\n' +
        'Pass both --development (you confirm this is a development project) and\n' +
        '--write (you confirm temporary rows may be created and deleted):\n\n' +
        '  pnpm db:verify-pairing --development --write\n'
    );
    return 2;
  }

  console.log('Jarvis device-pairing integration check (temporary rows, cleaned up at the end)');
  console.log(formatConnectionSummary(describeConnection(DATABASE_URL_VARIABLE)));
  console.log('');

  // Fail before any write if the target is not the expected migrated schema.
  const expectedMigrations = expectedMigrationVersions();
  const db = getDatabase();

  const codeHashes: string[] = [];
  const deviceIds: string[] = [];
  const challengeHashes: string[] = [];
  const results: Outcome[] = [];
  let preflightFailed = false;

  try {
    const migrated = await db.queryRow<{ applied: number; missing: number }>(
      `select
         (select count(*) from supabase_migrations.schema_migrations where version = any($1::text[]))::int as applied,
         (select count(*) from unnest($1::text[]) as v(version)
            where not exists (select 1 from supabase_migrations.schema_migrations m where m.version = v.version))::int as missing`,
      [expectedMigrations]
    );
    const users = await db.queryRow<{ count: number }>(
      'select count(*)::int as count from jarvis.users'
    );
    const account = await db.queryRow<{ id: string }>(
      'select id from jarvis.users order by created_at limit 1'
    );

    if (!migrated || migrated.applied !== expectedMigrations.length || migrated.missing !== 0) {
      results.push(
        acceptable(
          'preflight',
          false,
          `expected ${expectedMigrations.length} migrations, found ${migrated?.applied ?? 0} with ${migrated?.missing ?? 'unknown'} missing`
        )
      );
      preflightFailed = true;
    } else if (users?.count !== 1 || !account) {
      results.push(
        acceptable('preflight', false, `expected exactly one account, found ${users?.count ?? 0}`)
      );
      preflightFailed = true;
    } else {
      results.push(
        acceptable('preflight', true, `${expectedMigrations.length} migrations, one account`)
      );
    }

    if (!preflightFailed) {
      const userId = account!.id;
      results.push(await checkSingleUseAndOwnership(db, userId, codeHashes, deviceIds));
      results.push(await checkConcurrentRedemption(db, userId, codeHashes, deviceIds));
      results.push(await checkAssertionReplay(db, userId, deviceIds));
      results.push(await checkConcurrentReplay(db, userId, deviceIds));
      results.push(await checkExpiry(db, userId, codeHashes, deviceIds));
      results.push(await checkAttemptLimit(db, userId, codeHashes, deviceIds));
      results.push(await checkChallengeSingleUse(db, userId, deviceIds, challengeHashes));
      results.push(await checkChallengeConcurrency(db, userId, deviceIds, challengeHashes));
      results.push(await checkChallengeWrongDevice(db, userId, deviceIds, challengeHashes));
      results.push(await checkChallengeExpiry(db, userId, deviceIds, challengeHashes));
    }
  } catch (error) {
    results.push(acceptable('unexpected', false, safeDatabaseError(error)));
  } finally {
    results.push(await cleanup(db, codeHashes, deviceIds, challengeHashes));
  }

  for (const result of results) {
    console.log(`[${result.ok ? 'PASS' : 'FAIL'}] ${result.detail}`);
  }
  const failed = results.filter((result) => !result.ok).length;
  console.log(`\n${failed} check(s) failed.`);
  return failed === 0 ? 0 : 1;
}

/** One full redemption, a second attempt on the same code, and a foreign account. */
async function checkSingleUseAndOwnership(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  codeHashes: string[],
  deviceIds: string[]
): Promise<Outcome> {
  const code = await issuePairingCode(db, { userId, ttlSeconds: 600 });
  codeHashes.push(code.codeHash);

  const first = newIdentity();
  const second = newIdentity();
  deviceIds.push(first.deviceId, second.deviceId);

  const redeemed = await redeemPairingCode(db, { ...first, code: code.code, userId });
  if (redeemed.status !== 'redeemed') {
    return acceptable(
      'single-use + ownership',
      false,
      `first redemption returned ${redeemed.status}`
    );
  }
  const reused = await redeemPairingCode(db, { ...second, code: code.code, userId });
  if (reused.status !== 'used') {
    return acceptable(
      'single-use + ownership',
      false,
      `second redemption returned ${reused.status}`
    );
  }

  // A real code owned by the account must be refused to a different account.
  const owned = await issuePairingCode(db, { userId, ttlSeconds: 600 });
  codeHashes.push(owned.codeHash);
  const foreign = await redeemPairingCode(db, {
    ...second,
    code: owned.code,
    userId: randomUUID(),
  });
  if (foreign.status !== 'invalid') {
    return acceptable(
      'single-use + ownership',
      false,
      `foreign-account redemption returned ${foreign.status}`
    );
  }
  const foreignState = await db.queryRow<{ used: boolean; attempts: number }>(
    `select used_at is not null as used, attempts from jarvis.pairing_codes where code_hash = $1`,
    [owned.codeHash]
  );
  if (!foreignState || foreignState.used || foreignState.attempts !== 0) {
    return acceptable('single-use + ownership', false, 'foreign attempt changed the code row');
  }

  const state = await db.queryRow<{ used: boolean; consumer: string | null }>(
    `select used_at is not null as used, consumed_by_device_id::text as consumer
       from jarvis.pairing_codes where code_hash = $1`,
    [code.codeHash]
  );
  const devices = await db.queryRows<{ id: string }>(
    'select id from jarvis.devices where id = any($1::uuid[])',
    [[first.deviceId, second.deviceId]]
  );
  const ok =
    state?.used === true &&
    state.consumer === first.deviceId &&
    devices.length === 1 &&
    devices[0]?.id === first.deviceId;
  return acceptable(
    'single-use + ownership',
    ok,
    ok ? 'redeemed once, second use refused, foreign account refused' : 'stored state did not match'
  );
}

/** Two simultaneous redemptions of one code must not both succeed. */
async function checkConcurrentRedemption(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  codeHashes: string[],
  deviceIds: string[]
): Promise<Outcome> {
  const code = await issuePairingCode(db, { userId, ttlSeconds: 600 });
  codeHashes.push(code.codeHash);
  const left = newIdentity();
  const right = newIdentity();
  deviceIds.push(left.deviceId, right.deviceId);

  const [a, b] = await Promise.all([
    redeemPairingCode(db, { ...left, code: code.code, userId }),
    redeemPairingCode(db, { ...right, code: code.code, userId }),
  ]);
  const statuses = [a.status, b.status].sort();
  if (statuses[0] !== 'redeemed' || statuses[1] !== 'used') {
    return acceptable('concurrent redemption', false, `statuses were ${a.status} and ${b.status}`);
  }

  const devices = await db.queryRows<{ id: string }>(
    'select id from jarvis.devices where id = any($1::uuid[])',
    [[left.deviceId, right.deviceId]]
  );
  const ok = devices.length === 1;
  return acceptable(
    'concurrent redemption',
    ok,
    ok ? 'exactly one redemption succeeded' : `${devices.length} devices were created`
  );
}

/** An accepted signed assertion must be refused when submitted again. */
async function checkAssertionReplay(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  deviceIds: string[]
): Promise<Outcome> {
  const device = newIdentity();
  deviceIds.push(device.deviceId);
  const registered = await registerDevice(db, { ...device, userId });
  if (registered.status !== 'registered') {
    return acceptable('assertion replay', false, `registration returned ${registered.status}`);
  }

  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const signature = sign(
    'sha256',
    assertionPayload({
      deviceId: device.deviceId,
      nonce,
      issuedAtMs,
      audience: TOKEN_API_AUDIENCE,
    }),
    device.privateKey
  ).toString('base64');
  const input = {
    deviceId: device.deviceId,
    nonce,
    issuedAtMs,
    signature,
    userId,
    audience: TOKEN_API_AUDIENCE,
  };

  const first = await verifyDeviceAssertion(db, input);
  if (!first.verified) {
    return acceptable('assertion replay', false, `first verification returned ${first.reason}`);
  }
  const replay = await verifyDeviceAssertion(db, input);
  if (replay.verified || replay.reason !== 'replayed') {
    return acceptable(
      'assertion replay',
      false,
      `replay returned ${replay.verified ? 'verified' : replay.reason}`
    );
  }

  const state = await db.queryRow<{ seen: boolean }>(
    'select last_seen_at is not null as seen from jarvis.devices where id = $1',
    [device.deviceId]
  );
  return acceptable(
    'assertion replay',
    state?.seen === true,
    state?.seen === true
      ? 'accepted once, replay refused, high-water mark stored'
      : 'no replay guard stored'
  );
}

/** Two simultaneous submissions of one signed assertion must not both verify. */
async function checkConcurrentReplay(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  deviceIds: string[]
): Promise<Outcome> {
  const device = newIdentity();
  deviceIds.push(device.deviceId);
  const registered = await registerDevice(db, { ...device, userId });
  if (registered.status !== 'registered') {
    return acceptable('concurrent replay', false, `registration returned ${registered.status}`);
  }

  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const signature = sign(
    'sha256',
    assertionPayload({
      deviceId: device.deviceId,
      nonce,
      issuedAtMs,
      audience: TOKEN_API_AUDIENCE,
    }),
    device.privateKey
  ).toString('base64');
  const input = {
    deviceId: device.deviceId,
    nonce,
    issuedAtMs,
    signature,
    userId,
    audience: TOKEN_API_AUDIENCE,
  };

  const [a, b] = await Promise.all([
    verifyDeviceAssertion(db, input),
    verifyDeviceAssertion(db, input),
  ]);
  const verified = [a, b].filter((result) => result.verified).length;
  const replayed = [a, b].filter(
    (result) => !result.verified && result.reason === 'replayed'
  ).length;
  const ok = verified === 1 && replayed === 1;
  return acceptable(
    'concurrent replay',
    ok,
    ok
      ? 'exactly one concurrent assertion verified, the other replayed'
      : `${verified} verified, ${replayed} replayed`
  );
}

/** A code issued a second ago must no longer be redeemable. */
async function checkExpiry(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  codeHashes: string[],
  deviceIds: string[]
): Promise<Outcome> {
  const code = await issuePairingCode(db, { userId, ttlSeconds: 1 });
  codeHashes.push(code.codeHash);
  const device = newIdentity();
  deviceIds.push(device.deviceId);
  await new Promise((resolve) => setTimeout(resolve, 1300));

  const result = await redeemPairingCode(db, { ...device, code: code.code, userId });
  const devices = await db.queryRows<{ id: string }>(
    'select id from jarvis.devices where id = any($1::uuid[])',
    [[device.deviceId]]
  );
  const ok = result.status === 'expired' && devices.length === 0;
  return acceptable(
    'expiry',
    ok,
    ok ? 'expired code refused' : `status ${result.status}, devices ${devices.length}`
  );
}

/** A still-live code can only be attempted a bounded number of times. */
async function checkAttemptLimit(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  codeHashes: string[],
  deviceIds: string[]
): Promise<Outcome> {
  const existing = newIdentity();
  deviceIds.push(existing.deviceId);
  const registered = await registerDevice(db, { ...existing, userId });
  if (registered.status !== 'registered') {
    return acceptable('attempt limit', false, `setup registration returned ${registered.status}`);
  }

  const code = await issuePairingCode(db, { userId, ttlSeconds: 600 });
  codeHashes.push(code.codeHash);
  const other = newIdentity();
  const input = { ...other, code: code.code, userId, maxAttempts: 2 };

  const first = await redeemPairingCode(db, { ...input, deviceId: existing.deviceId });
  const second = await redeemPairingCode(db, { ...input, deviceId: existing.deviceId });
  const third = await redeemPairingCode(db, { ...input, deviceId: existing.deviceId });
  const ok =
    first.status === 'device_exists' &&
    second.status === 'device_exists' &&
    third.status === 'exhausted';
  return acceptable(
    'attempt limit',
    ok,
    ok
      ? 'attempts capped after the configured limit'
      : `statuses ${first.status}/${second.status}/${third.status}`
  );
}

/** One challenge is accepted once; a second submission is refused. */
async function checkChallengeSingleUse(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  deviceIds: string[],
  challengeHashes: string[]
): Promise<Outcome> {
  const device = newIdentity();
  deviceIds.push(device.deviceId);
  const registered = await registerDevice(db, { ...device, userId });
  if (registered.status !== 'registered') {
    return acceptable(
      'challenge single-use',
      false,
      `setup registration returned ${registered.status}`
    );
  }

  const issued = await issueDeviceChallenge(db, { userId, deviceId: device.deviceId });
  challengeHashes.push(issued.nonceHash);
  const first = await consumeDeviceChallenge(db, {
    userId,
    deviceId: device.deviceId,
    nonce: issued.challenge,
  });
  const second = await consumeDeviceChallenge(db, {
    userId,
    deviceId: device.deviceId,
    nonce: issued.challenge,
  });
  if (first.status !== 'consumed' || second.status !== 'used') {
    return acceptable(
      'challenge single-use',
      false,
      `statuses were ${first.status} and ${second.status}`
    );
  }

  const state = await db.queryRow<{ consumed: boolean; audience: string }>(
    `select consumed_at is not null as consumed, audience
       from jarvis.device_challenges where nonce_hash = $1`,
    [issued.nonceHash]
  );
  const ok = state?.consumed === true && state.audience === TOKEN_API_AUDIENCE;
  return acceptable(
    'challenge single-use',
    ok,
    ok ? 'consumed once and bound to the token audience' : 'stored challenge state did not match'
  );
}

/** Two simultaneous submissions of one challenge must not both succeed. */
async function checkChallengeConcurrency(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  deviceIds: string[],
  challengeHashes: string[]
): Promise<Outcome> {
  const device = newIdentity();
  deviceIds.push(device.deviceId);
  const registered = await registerDevice(db, { ...device, userId });
  if (registered.status !== 'registered') {
    return acceptable(
      'challenge concurrency',
      false,
      `setup registration returned ${registered.status}`
    );
  }

  const issued = await issueDeviceChallenge(db, { userId, deviceId: device.deviceId });
  challengeHashes.push(issued.nonceHash);
  const input = { userId, deviceId: device.deviceId, nonce: issued.challenge };
  const [a, b] = await Promise.all([
    consumeDeviceChallenge(db, input),
    consumeDeviceChallenge(db, input),
  ]);
  const statuses = [a.status, b.status].sort();
  const ok = statuses[0] === 'consumed' && statuses[1] === 'used';
  return acceptable(
    'challenge concurrency',
    ok,
    ok
      ? 'exactly one concurrent consumption succeeded'
      : `statuses were ${a.status} and ${b.status}`
  );
}

/** A challenge issued for one device cannot be consumed by another. */
async function checkChallengeWrongDevice(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  deviceIds: string[],
  challengeHashes: string[]
): Promise<Outcome> {
  const owner = newIdentity();
  const other = newIdentity();
  deviceIds.push(owner.deviceId, other.deviceId);
  for (const device of [owner, other]) {
    const registered = await registerDevice(db, { ...device, userId });
    if (registered.status !== 'registered') {
      return acceptable(
        'challenge wrong device',
        false,
        `setup registration returned ${registered.status}`
      );
    }
  }

  const issued = await issueDeviceChallenge(db, { userId, deviceId: owner.deviceId });
  challengeHashes.push(issued.nonceHash);
  const foreign = await consumeDeviceChallenge(db, {
    userId,
    deviceId: other.deviceId,
    nonce: issued.challenge,
  });
  const stillFresh = await consumeDeviceChallenge(db, {
    userId,
    deviceId: owner.deviceId,
    nonce: issued.challenge,
  });
  const ok = foreign.status === 'wrong_device' && stillFresh.status === 'consumed';
  return acceptable(
    'challenge wrong device',
    ok,
    ok
      ? 'another device was refused and the owner could still consume it'
      : `${foreign.status} then ${stillFresh.status}`
  );
}

/** A challenge issued for a short lifetime is refused after it passes. */
async function checkChallengeExpiry(
  db: Awaited<ReturnType<typeof getDatabase>>,
  userId: string,
  deviceIds: string[],
  challengeHashes: string[]
): Promise<Outcome> {
  const device = newIdentity();
  deviceIds.push(device.deviceId);
  const registered = await registerDevice(db, { ...device, userId });
  if (registered.status !== 'registered') {
    return acceptable(
      'challenge expiry',
      false,
      `setup registration returned ${registered.status}`
    );
  }

  const issued = await issueDeviceChallenge(db, {
    userId,
    deviceId: device.deviceId,
    ttlSeconds: 1,
  });
  challengeHashes.push(issued.nonceHash);
  await new Promise((resolve) => setTimeout(resolve, 1300));

  const result = await consumeDeviceChallenge(db, {
    userId,
    deviceId: device.deviceId,
    nonce: issued.challenge,
  });
  return acceptable(
    'challenge expiry',
    result.status === 'expired',
    result.status === 'expired' ? 'expired challenge refused' : `status ${result.status}`
  );
}

type Identity = {
  readonly deviceId: string;
  readonly publicKey: string;
  readonly fingerprint: string;
  readonly platform: 'android';
  readonly label: string;
  readonly privateKey: KeyObject;
};

/** Fresh P-256 identity in the exact base64 DER SPKI form S5.1 exports. */
function newIdentity(): Identity {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const der = publicKey.export({ format: 'der', type: 'spki' }) as Buffer;
  return {
    deviceId: randomUUID(),
    publicKey: der.toString('base64'),
    fingerprint: sha256Hex(der),
    platform: 'android',
    label: 'Integration check',
    privateKey,
  };
}

/** Deletes only rows whose identifiers were generated by this run. */
async function cleanup(
  db: Awaited<ReturnType<typeof getDatabase>>,
  codeHashes: string[],
  deviceIds: string[],
  challengeHashes: string[]
): Promise<Outcome> {
  const failures: string[] = [];
  const statements: { name: string; text: string; values: unknown[] }[] = [
    {
      name: 'device challenges',
      text: 'delete from jarvis.device_challenges where nonce_hash = any($1::text[])',
      values: [challengeHashes],
    },
    {
      name: 'pairing codes',
      text: 'delete from jarvis.pairing_codes where code_hash = any($1::text[])',
      values: [codeHashes],
    },
    {
      name: 'credentials',
      text: 'delete from jarvis.device_credentials where device_id = any($1::uuid[])',
      values: [deviceIds],
    },
    {
      name: 'devices',
      text: 'delete from jarvis.devices where id = any($1::uuid[])',
      values: [deviceIds],
    },
  ];

  for (const statement of statements) {
    const ids = statement.values[0] as unknown[];
    if (ids.length === 0) continue;
    try {
      await db.queryRows(statement.text, statement.values);
    } catch (error) {
      failures.push(`${statement.name}: ${safeDatabaseError(error)}`);
    }
  }

  if (codeHashes.length === 0 && deviceIds.length === 0 && challengeHashes.length === 0) {
    return acceptable('cleanup', true, 'nothing to remove');
  }

  try {
    const remaining = await db.queryRow<{ codes: number; devices: number; challenges: number }>(
      `select
         (select count(*) from jarvis.pairing_codes where code_hash = any($1::text[]))::int as codes,
         (select count(*) from jarvis.devices where id = any($2::uuid[]))::int as devices,
         (select count(*) from jarvis.device_challenges where nonce_hash = any($3::text[]))::int as challenges`,
      [codeHashes, deviceIds, challengeHashes]
    );
    const ok =
      failures.length === 0 &&
      remaining?.codes === 0 &&
      remaining.devices === 0 &&
      remaining.challenges === 0;
    return acceptable(
      'cleanup',
      ok,
      ok
        ? `${codeHashes.length} code(s), ${deviceIds.length} device(s) and ${challengeHashes.length} challenge(s) removed`
        : `${failures.length} delete failure(s), ${remaining?.codes ?? '?'} code(s), ${remaining?.devices ?? '?'} device(s) and ${remaining?.challenges ?? '?'} challenge(s) left`
    );
  } catch (error) {
    return acceptable('cleanup', false, safeDatabaseError(error));
  }
}

/** The 14-digit versions this checkout expects, in apply order. */
function expectedMigrationVersions(): string[] {
  const directory = fileURLToPath(new URL('../../supabase/migrations', import.meta.url));
  const versions = readdirSync(directory)
    .map((name) => MIGRATION_FILE.exec(name)?.[1])
    .filter((version): version is string => version !== undefined)
    .sort();
  if (versions.length === 0) throw new Error('No migration files found.');
  return versions;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error: unknown) => {
    console.error(`Verification could not start: ${safeDatabaseError(error)}`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closeDatabasePool().catch(() => undefined);
  });
