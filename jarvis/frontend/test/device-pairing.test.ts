import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';
import type { QueryResultRow } from 'pg';
import {
  type Database,
  DatabaseQueryError,
  type QueryExecutor,
  createDatabase,
} from '../lib/database.ts';
import {
  PairingValidationError,
  type RedeemDeviceInput,
  type RegisterDeviceInput,
  TOKEN_API_AUDIENCE,
  type VerifyAssertionInput,
  assertionPayload,
  createAssertionNonce,
  createPairingCode,
  issuePairingCode,
  redeemPairingCode,
  registerDevice,
  sha256Hex,
  verifyDeviceAssertion,
} from '../lib/device-pairing.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const DEVICE = '22222222-2222-4222-8222-222222222222';
const CREDENTIAL = '33333333-3333-4333-8333-333333333333';

/** A real P-256 key in exactly the shape S5.1 exports over the channel. */
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const publicKeyDer = publicKey.export({ format: 'der', type: 'spki' }) as Buffer;
const publicKeyBase64 = publicKeyDer.toString('base64');
const fingerprint = sha256Hex(publicKeyDer);

type Call = { text: string; values: unknown[] };

/** Returns each scripted response in order; an empty queue yields no rows. */
function fakeDatabase(responses: QueryResultRow[][] = []): { db: Database; calls: Call[] } {
  const calls: Call[] = [];
  let index = 0;
  const executor: QueryExecutor = {
    async query<T extends QueryResultRow>(text: string, values?: unknown[]) {
      calls.push({ text, values: values ?? [] });
      const rows = responses[index] ?? [];
      index += 1;
      return { rows: rows as T[] };
    },
  };
  return { db: createDatabase(executor), calls };
}

type FullDeviceInput = RedeemDeviceInput & VerifyAssertionInput & RegisterDeviceInput;

/** Complete valid input; individual fields are overridden to exercise failures. */
function deviceInput(overrides: Record<string, unknown> = {}): FullDeviceInput {
  const base: FullDeviceInput = {
    userId: USER,
    deviceId: DEVICE,
    publicKey: publicKeyBase64,
    fingerprint,
    platform: 'android',
    label: 'Jarvis phone',
    code: createPairingCode(),
    nonce: createAssertionNonce(),
    issuedAtMs: Date.now(),
    audience: TOKEN_API_AUDIENCE,
    signature: 'AAAAAAAA',
    maxAttempts: 10,
  };
  return { ...base, ...overrides } as FullDeviceInput;
}

test('pairing codes are random base64url and only their hash reaches storage', async () => {
  const { db, calls } = fakeDatabase([
    [{ id: 'code-1', user_id: USER, expires_at: new Date('2030-01-01T00:10:00Z') }],
  ]);

  const issued = await issuePairingCode(db, { userId: USER, ttlSeconds: 600 });

  assert.match(issued.code, /^[A-Za-z0-9_-]{32}$/);
  assert.match(issued.codeHash, /^[0-9a-f]{64}$/);
  assert.equal(sha256Hex(issued.code), issued.codeHash);
  assert.equal(issued.userId, USER);
  assert.equal(issued.expiresAt.toISOString(), '2030-01-01T00:10:00.000Z');

  assert.equal(calls.length, 1);
  assert.equal(calls[0].values[0], USER);
  assert.equal(calls[0].values[1], issued.codeHash);
  assert.equal(calls[0].values[2], 600);
  assert.equal(calls[0].text.includes(issued.code), false);
  assert.equal((calls[0].values as unknown[]).includes(issued.code), false);
});

test('issuing resolves the single account and rejects bad lifetimes', async () => {
  const { db, calls } = fakeDatabase([
    [{ id: USER }],
    [{ id: 'code-1', user_id: USER, expires_at: new Date('2030-01-01T00:00:00Z') }],
  ]);
  const issued = await issuePairingCode(db);
  assert.equal(issued.userId, USER);
  assert.equal(calls[0].text.includes('seed_initial_user'), true);

  await assert.rejects(
    () => issuePairingCode(db, { userId: USER, ttlSeconds: 0 }),
    PairingValidationError
  );
});

test('the signed payload binds the audience', () => {
  const base = {
    deviceId: DEVICE,
    nonce: createAssertionNonce(),
    issuedAtMs: 1_700_000_000_000,
  };
  const first = assertionPayload({ ...base, audience: TOKEN_API_AUDIENCE });
  const second = assertionPayload({ ...base, audience: 'another-api' });
  assert.notDeepEqual(first, second);
  assert.match(first.toString('utf8'), new RegExp(TOKEN_API_AUDIENCE));
  assert.equal(first.toString('utf8').split('\n').at(-1), TOKEN_API_AUDIENCE);
});

test('two issued codes are always different', () => {
  assert.notEqual(createPairingCode(), createPairingCode());
  assert.notEqual(createAssertionNonce(), createAssertionNonce());
});

test('redemption is one locking statement that registers device and credential', async () => {
  const { db, calls } = fakeDatabase([
    [{ outcome: 'ok', user_id: USER, credential_id: CREDENTIAL }],
  ]);
  const code = createPairingCode();

  const result = await redeemPairingCode(db, deviceInput({ code }));

  assert.deepEqual(result, {
    status: 'redeemed',
    userId: USER,
    deviceId: DEVICE,
    credentialId: CREDENTIAL,
  });
  assert.equal(calls.length, 1, 'redemption must be a single atomic statement');
  assert.match(calls[0].text, /for update/i);
  assert.equal(calls[0].values[0], sha256Hex(code));
  assert.equal(calls[0].values[3], DEVICE);
  assert.equal(calls[0].values[7], fingerprint);
  assert.equal(calls[0].text.includes(code), false);
});

test('every locked-code outcome maps to a safe result', async () => {
  for (const outcome of [
    'invalid',
    'used',
    'expired',
    'exhausted',
    'device_exists',
    'credential_exists',
  ]) {
    const { db } = fakeDatabase([[{ outcome, user_id: null, credential_id: null }]]);
    assert.deepEqual(await redeemPairingCode(db, deviceInput({ code: createPairingCode() })), {
      status: outcome,
    });
  }

  const missing = fakeDatabase([[]]);
  assert.deepEqual(
    await redeemPairingCode(missing.db, deviceInput({ code: createPairingCode() })),
    { status: 'invalid' }
  );
});

test('unique violations during redemption become conflicts, not raw errors', async () => {
  const failing = (constraint: string): Database => {
    const executor: QueryExecutor = {
      async query() {
        throw new DatabaseQueryError({ code: '23505', constraint });
      },
    };
    return createDatabase(executor);
  };

  assert.deepEqual(
    await redeemPairingCode(failing('devices_pkey'), deviceInput({ code: createPairingCode() })),
    { status: 'device_exists' }
  );
  assert.deepEqual(
    await redeemPairingCode(
      failing('device_credentials_fingerprint_unique'),
      deviceInput({ code: createPairingCode() })
    ),
    { status: 'credential_exists' }
  );
});

test('redemption and registration reject malformed keys and inputs', async () => {
  const { db, calls } = fakeDatabase();
  const code = createPairingCode();

  await assert.rejects(
    () => redeemPairingCode(db, deviceInput({ code, fingerprint: 'ab'.repeat(32) })),
    PairingValidationError
  );
  await assert.rejects(
    () => redeemPairingCode(db, deviceInput({ code, publicKey: 'AAAAAAAAAAAAAAAA' })),
    PairingValidationError
  );
  await assert.rejects(
    () => redeemPairingCode(db, deviceInput({ code, deviceId: 'not-a-uuid' })),
    PairingValidationError
  );
  await assert.rejects(
    () => redeemPairingCode(db, deviceInput({ code, label: 'x'.repeat(81) })),
    PairingValidationError
  );
  await assert.rejects(
    () => redeemPairingCode(db, deviceInput({ code, platform: 'toaster' })),
    PairingValidationError
  );
  await assert.rejects(
    () => redeemPairingCode(db, deviceInput({ code, maxAttempts: 0 })),
    PairingValidationError
  );
  await assert.rejects(
    () =>
      registerDevice(db, deviceInput({ publicKey: publicKeyBase64, fingerprint: '0'.repeat(64) })),
    PairingValidationError
  );
  assert.equal(calls.length, 0, 'validation happens before any query');
});

test('registerDevice stores the derived fingerprint and an ES256 credential', async () => {
  const { db, calls } = fakeDatabase([
    [{ credential_id: CREDENTIAL, device_id: DEVICE, user_id: USER }],
  ]);

  const result = await registerDevice(db, deviceInput());

  assert.deepEqual(result, {
    status: 'registered',
    userId: USER,
    deviceId: DEVICE,
    credentialId: CREDENTIAL,
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].values[4], fingerprint);
  assert.equal(calls[0].values[5], publicKeyBase64);
  assert.match(calls[0].text, /'ES256'/);
});

test('a valid signed assertion is verified and its replay window consumed', async () => {
  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const payloadInput = {
    deviceId: DEVICE,
    nonce,
    issuedAtMs,
    audience: TOKEN_API_AUDIENCE,
  };
  const signature = sign('sha256', assertionPayload(payloadInput), privateKey).toString('base64');
  const { db, calls } = fakeDatabase([
    [
      {
        credential_id: CREDENTIAL,
        public_key: publicKeyBase64,
        key_fingerprint: fingerprint,
        algorithm: 'ES256',
      },
    ],
    [{ id: DEVICE }],
  ]);

  const result = await verifyDeviceAssertion(db, deviceInput({ ...payloadInput, signature }), {
    now: () => issuedAtMs,
  });

  assert.deepEqual(result, {
    verified: true,
    userId: USER,
    deviceId: DEVICE,
    credentialId: CREDENTIAL,
  });
  assert.equal(calls.length, 2);
  assert.match(calls[1].text, /last_seen_at < to_timestamp/);
  assert.equal(calls[1].values[2], String(issuedAtMs));
});

test('tampered, unknown, corrupted and replayed assertions are refused', async () => {
  const base = Date.now();
  const payloadInput = {
    deviceId: DEVICE,
    nonce: createAssertionNonce(),
    issuedAtMs: base,
    audience: TOKEN_API_AUDIENCE,
  };
  const signature = sign('sha256', assertionPayload(payloadInput), privateKey).toString('base64');
  const options = { now: () => base };
  const credentialRow = [
    {
      credential_id: CREDENTIAL,
      public_key: publicKeyBase64,
      key_fingerprint: fingerprint,
      algorithm: 'ES256',
    },
  ];

  const wrongNonce = fakeDatabase([credentialRow]);
  assert.deepEqual(
    await verifyDeviceAssertion(
      wrongNonce.db,
      deviceInput({ ...payloadInput, nonce: createAssertionNonce(), signature }),
      options
    ),
    { verified: false, reason: 'bad_signature' }
  );

  const unknown = fakeDatabase([[]]);
  assert.deepEqual(
    await verifyDeviceAssertion(unknown.db, deviceInput({ ...payloadInput, signature }), options),
    { verified: false, reason: 'unknown_device' }
  );

  const replay = fakeDatabase([credentialRow, []]);
  assert.deepEqual(
    await verifyDeviceAssertion(replay.db, deviceInput({ ...payloadInput, signature }), options),
    { verified: false, reason: 'replayed' }
  );

  const corrupted = fakeDatabase([
    [
      {
        credential_id: CREDENTIAL,
        public_key: publicKeyBase64,
        key_fingerprint: '0'.repeat(64),
        algorithm: 'ES256',
      },
    ],
  ]);
  assert.deepEqual(
    await verifyDeviceAssertion(corrupted.db, deviceInput({ ...payloadInput, signature }), options),
    { verified: false, reason: 'credential_invalid' }
  );

  const stale = fakeDatabase();
  assert.deepEqual(
    await verifyDeviceAssertion(stale.db, deviceInput({ ...payloadInput, signature }), {
      now: () => base + 120_000,
    }),
    { verified: false, reason: 'expired' }
  );
  assert.equal(stale.calls.length, 0, 'stale assertions are rejected before any query');
});

test('assertion inputs are validated before touching the database', async () => {
  const { db, calls } = fakeDatabase();
  const base = Date.now();
  const payloadInput = {
    deviceId: DEVICE,
    nonce: createAssertionNonce(),
    issuedAtMs: base,
    audience: TOKEN_API_AUDIENCE,
  };
  const signature = sign('sha256', assertionPayload(payloadInput), privateKey).toString('base64');

  await assert.rejects(
    () => verifyDeviceAssertion(db, deviceInput({ ...payloadInput, signature, nonce: 'short' })),
    PairingValidationError
  );
  await assert.rejects(
    () =>
      verifyDeviceAssertion(db, deviceInput({ ...payloadInput, signature: 'not base64!' }), {
        now: () => base,
      }),
    PairingValidationError
  );
  await assert.rejects(
    () =>
      verifyDeviceAssertion(db, deviceInput({ ...payloadInput, signature, issuedAtMs: 1.5 }), {
        now: () => base,
      }),
    PairingValidationError
  );
  assert.equal(calls.length, 0);
});
