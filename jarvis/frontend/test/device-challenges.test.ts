import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';
import type { QueryResultRow } from 'pg';
import { type Database, type QueryExecutor, createDatabase } from '../lib/database.ts';
import { authenticateDevice } from '../lib/device-auth.ts';
import {
  PairingValidationError,
  TOKEN_API_AUDIENCE,
  assertionPayload,
  consumeDeviceChallenge,
  issueDeviceChallenge,
  sha256Hex,
} from '../lib/device-pairing.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const DEVICE = '22222222-2222-4222-8222-222222222222';
const CREDENTIAL = '33333333-3333-4333-8333-333333333333';
const CHALLENGE_ID = '44444444-4444-4444-8444-444444444444';

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const publicKeyDer = publicKey.export({ format: 'der', type: 'spki' }) as Buffer;
const publicKeyBase64 = publicKeyDer.toString('base64');
const fingerprint = sha256Hex(publicKeyDer);

type Call = { text: string; values: unknown[] };

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

function signedAssertion(options: {
  nonce: string;
  issuedAtMs: number;
  audience?: string;
  deviceId?: string;
}) {
  const payload = {
    deviceId: options.deviceId ?? DEVICE,
    nonce: options.nonce,
    issuedAtMs: options.issuedAtMs,
    audience: options.audience ?? TOKEN_API_AUDIENCE,
  };
  return {
    payload,
    signature: sign('sha256', assertionPayload(payload), privateKey).toString('base64'),
  };
}

const credentialRow = [
  {
    credential_id: CREDENTIAL,
    public_key: publicKeyBase64,
    key_fingerprint: fingerprint,
    algorithm: 'ES256',
  },
];

const consumedRow = [{ outcome: 'ok', consumed_id: CHALLENGE_ID }];

test('a challenge is random, stored only as a hash, and bound to device and audience', async () => {
  const expiresAt = new Date('2030-01-01T00:02:00Z');
  const { db, calls } = fakeDatabase([
    [{ id: CHALLENGE_ID, user_id: USER, device_id: DEVICE, expires_at: expiresAt }],
  ]);

  const issued = await issueDeviceChallenge(db, { userId: USER, deviceId: DEVICE });

  assert.match(issued.challenge, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(issued.nonceHash, sha256Hex(issued.challenge));
  assert.equal(issued.audience, TOKEN_API_AUDIENCE);
  assert.equal(issued.userId, USER);
  assert.equal(issued.deviceId, DEVICE);
  assert.equal(issued.expiresAt.toISOString(), expiresAt.toISOString());

  assert.equal(calls.length, 1);
  assert.match(calls[0].text, /jarvis\.device_challenges/);
  assert.match(calls[0].text, /status = 'trusted'/);
  assert.equal(calls[0].values[0], USER);
  assert.equal(calls[0].values[1], DEVICE);
  assert.equal(calls[0].values[2], issued.nonceHash);
  assert.equal(calls[0].values[3], TOKEN_API_AUDIENCE);
  assert.equal(calls[0].text.includes(issued.challenge), false);
  assert.equal((calls[0].values as unknown[]).includes(issued.challenge), false);
});

test('two challenges and their lifetimes are validated before a query', async () => {
  const row = [{ id: CHALLENGE_ID, user_id: USER, device_id: DEVICE, expires_at: new Date() }];
  const { db, calls } = fakeDatabase([row, row]);
  const first = await issueDeviceChallenge(db, { userId: USER, deviceId: DEVICE });
  const second = await issueDeviceChallenge(db, { userId: USER, deviceId: DEVICE });
  assert.notEqual(first.challenge, second.challenge);

  await assert.rejects(
    () => issueDeviceChallenge(db, { userId: USER, deviceId: DEVICE, ttlSeconds: 0 }),
    PairingValidationError
  );
  await assert.rejects(
    () => issueDeviceChallenge(db, { userId: USER, deviceId: 'not-a-uuid' }),
    PairingValidationError
  );
  await assert.rejects(
    () => issueDeviceChallenge(db, { userId: USER, deviceId: DEVICE, audience: 'other-api' }),
    PairingValidationError
  );
  assert.equal(calls.length, 2);
});

test('consumption is one locking statement that checks ownership, audience and expiry', async () => {
  const nonce = 'a'.repeat(32);
  const { db, calls } = fakeDatabase([consumedRow]);

  const result = await consumeDeviceChallenge(db, {
    userId: USER,
    deviceId: DEVICE,
    nonce,
  });

  assert.deepEqual(result, { status: 'consumed', userId: USER, deviceId: DEVICE });
  assert.equal(calls.length, 1);
  assert.match(calls[0].text, /for update/i);
  assert.match(calls[0].text, /consumed_at is not null/);
  assert.match(calls[0].text, /expires_at <= now\(\)/);
  assert.match(calls[0].text, /audience/);
  assert.equal(calls[0].values[0], USER);
  assert.equal(calls[0].values[1], DEVICE);
  assert.equal(calls[0].values[2], sha256Hex(nonce));
  assert.equal(calls[0].values[3], TOKEN_API_AUDIENCE);
  assert.equal(calls[0].text.includes(nonce), false);
});

test('every failed consumption outcome is mapped to a safe status', async () => {
  const nonce = 'b'.repeat(32);
  for (const outcome of ['wrong_device', 'wrong_audience', 'used', 'expired', 'unknown_device']) {
    const { db } = fakeDatabase([[{ outcome, consumed_id: null }]]);
    assert.deepEqual(await consumeDeviceChallenge(db, { userId: USER, deviceId: DEVICE, nonce }), {
      status: outcome,
    });
  }
  const missing = fakeDatabase([[]]);
  assert.deepEqual(
    await consumeDeviceChallenge(missing.db, { userId: USER, deviceId: DEVICE, nonce }),
    { status: 'invalid' }
  );

  // A lock winner without the conditional update is a concurrent replay.
  const raced = fakeDatabase([[{ outcome: 'ok', consumed_id: null }]]);
  assert.deepEqual(
    await consumeDeviceChallenge(raced.db, { userId: USER, deviceId: DEVICE, nonce }),
    { status: 'used' }
  );
});

test('concurrent submissions of one challenge allow exactly one success', async () => {
  const { db, calls } = fakeDatabase([
    [{ outcome: 'ok', consumed_id: CHALLENGE_ID }],
    [{ outcome: 'ok', consumed_id: null }],
  ]);
  const input = { userId: USER, deviceId: DEVICE, nonce: 'c'.repeat(32) };

  const results = await Promise.all([
    consumeDeviceChallenge(db, input),
    consumeDeviceChallenge(db, input),
  ]);

  assert.equal(results.filter((result) => result.status === 'consumed').length, 1);
  assert.equal(results.filter((result) => result.status === 'used').length, 1);
  assert.equal(calls.length, 2);
  for (const call of calls) assert.match(call.text, /for update/i);
});

test('device authentication consumes the challenge only after a valid signature', async () => {
  const nonce = 'd'.repeat(32);
  const issuedAtMs = Date.now();
  const { signature } = signedAssertion({ nonce, issuedAtMs });
  const { db, calls } = fakeDatabase([
    [{ id: USER }],
    credentialRow,
    [{ id: DEVICE }],
    consumedRow,
  ]);

  const result = await authenticateDevice(
    db,
    { deviceId: DEVICE, nonce, issuedAtMs, signature },
    { now: () => issuedAtMs }
  );

  assert.deepEqual(result, { verified: true });
  assert.equal(calls.length, 4);
  assert.match(calls[3].text, /jarvis\.device_challenges/);
});

test('an invalid signature or wrong audience never reaches challenge consumption', async () => {
  const nonce = 'e'.repeat(32);
  const issuedAtMs = Date.now();
  const bad = sign('sha256', Buffer.from('other message'), privateKey).toString('base64');
  const badDb = fakeDatabase([[{ id: USER }], credentialRow]);
  assert.deepEqual(
    await authenticateDevice(
      badDb.db,
      { deviceId: DEVICE, nonce, issuedAtMs, signature: bad },
      { now: () => issuedAtMs }
    ),
    { verified: false }
  );
  assert.equal(badDb.calls.length, 2);

  const { signature } = signedAssertion({ nonce, issuedAtMs, audience: 'another-api' });
  const wrongAudience = fakeDatabase([[{ id: USER }], credentialRow]);
  assert.deepEqual(
    await authenticateDevice(
      wrongAudience.db,
      { deviceId: DEVICE, nonce, issuedAtMs, signature },
      { now: () => issuedAtMs }
    ),
    { verified: false }
  );
  assert.equal(wrongAudience.calls.length, 2);
});

test('a revoked or unknown device cannot consume a challenge', async () => {
  const nonce = 'f'.repeat(32);
  const issuedAtMs = Date.now();
  const { signature } = signedAssertion({ nonce, issuedAtMs });
  const revoked = fakeDatabase([[{ id: USER }], []]);

  const result = await authenticateDevice(
    revoked.db,
    { deviceId: DEVICE, nonce, issuedAtMs, signature },
    { now: () => issuedAtMs }
  );

  assert.deepEqual(result, { verified: false });
  assert.equal(revoked.calls.length, 2);
});

test('a replayed or expired challenge is refused after signature verification', async () => {
  const nonce = '0'.repeat(32);
  const issuedAtMs = Date.now();
  const { signature } = signedAssertion({ nonce, issuedAtMs });

  const replay = fakeDatabase([
    [{ id: USER }],
    credentialRow,
    [{ id: DEVICE }],
    [{ outcome: 'used', consumed_id: null }],
  ]);
  assert.deepEqual(
    await authenticateDevice(
      replay.db,
      { deviceId: DEVICE, nonce, issuedAtMs, signature },
      { now: () => issuedAtMs }
    ),
    { verified: false }
  );

  const expired = fakeDatabase([
    [{ id: USER }],
    credentialRow,
    [{ id: DEVICE }],
    [{ outcome: 'expired', consumed_id: null }],
  ]);
  assert.deepEqual(
    await authenticateDevice(
      expired.db,
      { deviceId: DEVICE, nonce, issuedAtMs, signature },
      { now: () => issuedAtMs }
    ),
    { verified: false }
  );
});
