import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';
import type { QueryResultRow } from 'pg';
import { type Database, type QueryExecutor, createDatabase } from '../lib/database.ts';
import { authenticateDevice } from '../lib/device-auth.ts';
import {
  handleChallengeRequest,
  handlePairingIssueRequest,
  handlePairingRedeemRequest,
} from '../lib/device-endpoint.ts';
import {
  TOKEN_API_AUDIENCE,
  assertionPayload,
  createAssertionNonce,
  sha256Hex,
} from '../lib/device-pairing.ts';
import { MemoryRateLimiter } from '../lib/rate-limit.ts';
import { handleTokenRequest } from '../lib/token-endpoint.ts';
import { AUTH_REJECTED_MESSAGE, RATE_LIMITED_MESSAGE } from '../lib/token-policy.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const DEVICE = '22222222-2222-4222-8222-222222222222';
const CREDENTIAL = '33333333-3333-4333-8333-333333333333';
const ACCESS_CODE = 'test-access-code';
const INVALID_DEVICE_MESSAGE = 'Invalid device request.';

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

function options(db: Database) {
  return {
    db,
    policy: policy(),
    limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 10 }),
  };
}

function post(url: string, body: unknown, withCode = true): Request {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'x-forwarded-for': '203.0.113.7',
  };
  if (withCode) headers['X-Jarvis-Access-Code'] = ACCESS_CODE;
  return new Request(url, { method: 'POST', headers, body: JSON.stringify(body) });
}

function policy() {
  return {
    livekitUrl: 'wss://jarvis-test.livekit.cloud',
    apiKey: 'test-api-key',
    apiSecret: 'test-api-secret',
    accessCode: ACCESS_CODE,
    allowPublicToken: false,
    agentName: 'my-agent',
    tokenTtlSeconds: 900,
    rateLimitWindowSeconds: 900,
    rateLimitMaxFailures: 10,
  };
}

test('the challenge endpoint returns the plaintext once without an access code', async () => {
  const { db, calls } = fakeDatabase([
    [{ id: USER }],
    [
      {
        id: 'challenge-1',
        user_id: USER,
        device_id: DEVICE,
        expires_at: new Date('2030-01-01T00:02:00Z'),
      },
    ],
  ]);

  const result = await handleChallengeRequest(
    post('https://jarvis.test/api/device/challenge', { device_id: DEVICE }, false),
    options(db)
  );

  assert.equal(result.status, 200);
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.equal(result.body.audience, TOKEN_API_AUDIENCE);
  assert.equal(result.body.expires_at, '2030-01-01T00:02:00.000Z');
  assert.match(result.body.challenge as string, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(sha256Hex(result.body.challenge as string), calls[1].values[2]);
  assert.equal(calls[1].text.includes(result.body.challenge as string), false);
});

test('the challenge endpoint rejects malformed bodies before touching the database', async () => {
  const { db, calls } = fakeDatabase();
  // Even a correct access code is ignored: only the device id is read.
  for (const body of [{}, { device_id: DEVICE, extra: true }, { device_id: 42 }, [], 'not json']) {
    const invalid = await handleChallengeRequest(
      post('https://jarvis.test/api/device/challenge', body, false),
      options(db)
    );
    assert.equal(invalid.status, 400);
    assert.equal(invalid.body.error, INVALID_DEVICE_MESSAGE);
  }
  assert.equal(calls.length, 0);
});

test('unknown, pending and revoked devices get one generic challenge error', async () => {
  // The insert ... select returns no row unless the device is trusted with an
  // active ES256 credential, so every non-trusted state reaches the same path.
  const { db, calls } = fakeDatabase([[{ id: USER }], []]);
  const stillTrustedOnly = /status = 'trusted'/;

  const first = await handleChallengeRequest(
    post('https://jarvis.test/api/device/challenge', { device_id: DEVICE }, false),
    options(db)
  );
  assert.equal(first.status, 400);
  assert.equal(first.body.error, INVALID_DEVICE_MESSAGE);
  assert.equal(first.body.challenge, undefined);
  assert.match(calls[1].text, stillTrustedOnly);
  assert.match(calls[1].text, /retired_at is null/);
  assert.match(calls[1].text, /algorithm = 'ES256'/);

  // A second lookup is indistinguishable from the first.
  const second = await handleChallengeRequest(
    post('https://jarvis.test/api/device/challenge', { device_id: DEVICE }, false),
    options(db)
  );
  assert.equal(second.status, 400);
  assert.equal(second.body.error, first.body.error);
  assert.equal(second.body.challenge, undefined);
});

test('challenge issuance never returns a token', async () => {
  const { db } = fakeDatabase([
    [{ id: USER }],
    [
      {
        id: 'challenge-2',
        user_id: USER,
        device_id: DEVICE,
        expires_at: new Date('2030-01-01T00:02:00Z'),
      },
    ],
  ]);

  const result = await handleChallengeRequest(
    post('https://jarvis.test/api/device/challenge', { device_id: DEVICE }, false),
    options(db)
  );

  assert.equal(result.status, 200);
  assert.deepEqual(Object.keys(result.body).sort(), ['audience', 'challenge', 'expires_at']);
  assert.equal(result.body.participant_token, undefined);
  assert.equal(result.body.server_url, undefined);
  assert.equal(result.body.room_name, undefined);
});

test('repeated failed challenge requests are rate limited', async () => {
  const { db } = fakeDatabase([[{ id: USER }], []]);
  const shared = {
    ...options(db),
    limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 2 }),
  };
  const url = 'https://jarvis.test/api/device/challenge';

  const first = await handleChallengeRequest(post(url, { device_id: DEVICE }, false), shared);
  assert.equal(first.status, 400);
  const blocked = await handleChallengeRequest(post(url, { device_id: DEVICE }, false), shared);
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.error, RATE_LIMITED_MESSAGE);
  assert.equal(blocked.body.challenge, undefined);
});

test('the pairing-code endpoint issues a code and rejects malformed requests', async () => {
  const expiresAt = new Date('2030-01-01T00:10:00Z');
  const { db, calls } = fakeDatabase([
    [{ id: USER }],
    [{ id: 'code-1', user_id: USER, code_hash: 'hash', expires_at: expiresAt }],
  ]);

  const issued = await handlePairingIssueRequest(
    post('https://jarvis.test/api/device/pairing', { ttl_seconds: 600 }),
    options(db)
  );
  assert.equal(issued.status, 200);
  assert.equal(issued.headers['Cache-Control'], 'no-store');
  assert.equal(issued.body.expires_at, expiresAt.toISOString());
  assert.match(issued.body.code as string, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(calls[1].values[1], sha256Hex(issued.body.code as string));

  const invalid = await handlePairingIssueRequest(
    post('https://jarvis.test/api/device/pairing', { ttl_seconds: 0 }),
    options(db)
  );
  assert.equal(invalid.status, 400);
});

const redeemBody = {
  code: createAssertionNonce(),
  device_id: DEVICE,
  public_key: publicKeyBase64,
  fingerprint,
  platform: 'android',
  label: 'Jarvis phone',
};

test('redemption registers a trusted device and refuses replayed or exhausted codes', async () => {
  const good = fakeDatabase([
    [{ id: USER }],
    [{ outcome: 'ok', user_id: USER, credential_id: CREDENTIAL }],
  ]);
  const paired = await handlePairingRedeemRequest(
    post('https://jarvis.test/api/device/pairing/redeem', redeemBody, false),
    options(good.db)
  );
  assert.equal(paired.status, 200);
  assert.equal(paired.body.status, 'paired');
  assert.equal(paired.body.device_id, DEVICE);

  for (const outcome of ['used', 'expired', 'invalid', 'exhausted']) {
    const db = fakeDatabase([[{ id: USER }], [{ outcome, user_id: null, credential_id: null }]]);
    const result = await handlePairingRedeemRequest(
      post('https://jarvis.test/api/device/pairing/redeem', redeemBody, false),
      options(db.db)
    );
    assert.equal(result.status, 401);
    assert.equal(result.body.participant_token, undefined);
  }

  const conflict = fakeDatabase([
    [{ id: USER }],
    [{ outcome: 'device_exists', user_id: null, credential_id: null }],
  ]);
  assert.equal(
    (
      await handlePairingRedeemRequest(
        post('https://jarvis.test/api/device/pairing/redeem', redeemBody, false),
        options(conflict.db)
      )
    ).status,
    409
  );
});

test('redemption validates the body before touching the database', async () => {
  const { db, calls } = fakeDatabase();
  for (const body of [
    { ...redeemBody, code: 'short' },
    { ...redeemBody, platform: 'toaster' },
    { ...redeemBody, public_key: 42 },
    { ...redeemBody, unexpected: true },
  ]) {
    const result = await handlePairingRedeemRequest(
      post('https://jarvis.test/api/device/pairing/redeem', body, false),
      options(db)
    );
    assert.equal(result.status, 400);
  }
  assert.equal(calls.length, 0);
});

test('repeated failed redemptions are rate limited', async () => {
  const { db } = fakeDatabase([
    [{ id: USER }],
    [{ outcome: 'invalid', user_id: null, credential_id: null }],
  ]);
  const shared = {
    db,
    limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 2 }),
  };
  const first = await handlePairingRedeemRequest(
    post('https://jarvis.test/api/device/pairing/redeem', redeemBody, false),
    shared
  );
  assert.equal(first.status, 401);
  const blocked = await handlePairingRedeemRequest(
    post('https://jarvis.test/api/device/pairing/redeem', redeemBody, false),
    shared
  );
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.error, RATE_LIMITED_MESSAGE);
});

const credentialRow = [
  {
    credential_id: CREDENTIAL,
    public_key: publicKeyBase64,
    key_fingerprint: fingerprint,
    algorithm: 'ES256',
  },
];

test('an expired or replayed challenge from the open endpoint still fails authentication', async () => {
  const { db: issuingDb } = fakeDatabase([
    [{ id: USER }],
    [
      {
        id: 'challenge-3',
        user_id: USER,
        device_id: DEVICE,
        expires_at: new Date('2030-01-01T00:02:00Z'),
      },
    ],
  ]);
  const issued = await handleChallengeRequest(
    post('https://jarvis.test/api/device/challenge', { device_id: DEVICE }, false),
    options(issuingDb)
  );
  assert.equal(issued.status, 200);

  const nonce = issued.body.challenge as string;
  const issuedAtMs = Date.now();
  const signature = sign(
    'sha256',
    assertionPayload({
      deviceId: DEVICE,
      nonce,
      issuedAtMs,
      audience: TOKEN_API_AUDIENCE,
    }),
    privateKey
  ).toString('base64');

  for (const outcome of ['expired', 'used']) {
    const { db } = fakeDatabase([
      [{ id: USER }],
      credentialRow,
      [{ id: DEVICE }],
      [{ outcome, consumed_id: null }],
    ]);
    const verified = await authenticateDevice(
      db,
      { deviceId: DEVICE, nonce, issuedAtMs, signature },
      { now: () => issuedAtMs }
    );
    assert.deepEqual(verified, { verified: false });
  }
});

function assertionBody(signature: string, nonce: string, issuedAtMs: number) {
  return {
    device_assertion: {
      device_id: DEVICE,
      nonce,
      issued_at_ms: issuedAtMs,
      signature,
    },
    room_name: 'jarvis_test_room',
    participant_name: 'Alice',
    participant_identity: 'jarvis_user_1',
  };
}

test('a valid device assertion mints a token and consumes its challenge', async () => {
  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const payload = {
    deviceId: DEVICE,
    nonce,
    issuedAtMs,
    audience: TOKEN_API_AUDIENCE,
  };
  const signature = sign('sha256', assertionPayload(payload), privateKey).toString('base64');
  const { db, calls } = fakeDatabase([
    [{ id: USER }],
    credentialRow,
    [{ id: DEVICE }],
    [{ outcome: 'ok', consumed_id: 'challenge-1' }],
  ]);

  const response = await handleTokenRequest(
    post('https://jarvis.test/api/token', assertionBody(signature, nonce, issuedAtMs)),
    {
      policy: policy(),
      limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 10 }),
      deviceAuthenticator: (input) => authenticateDevice(db, input, { now: () => issuedAtMs }),
    }
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers['Cache-Control'], 'no-store');
  assert.equal(typeof response.body.participant_token, 'string');
  assert.equal(calls.length, 4);
});

test('an invalid assertion is rejected without falling back to the access code', async () => {
  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const signature = sign('sha256', Buffer.from('other message'), privateKey).toString('base64');
  const request = post(
    'https://jarvis.test/api/token',
    assertionBody(signature, nonce, issuedAtMs)
  );

  const response = await handleTokenRequest(request, {
    policy: policy(),
    limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 10 }),
    deviceAuthenticator: async () => ({ verified: false }),
  });

  assert.equal(response.status, 401);
  assert.equal(response.body.error, AUTH_REJECTED_MESSAGE);
  assert.equal(response.body.participant_token, undefined);
});

test('a revoked device or replayed challenge cannot mint a token', async () => {
  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const signature = sign(
    'sha256',
    assertionPayload({
      deviceId: DEVICE,
      nonce,
      issuedAtMs,
      audience: TOKEN_API_AUDIENCE,
    }),
    privateKey
  ).toString('base64');
  const body = assertionBody(signature, nonce, issuedAtMs);

  const revoked = fakeDatabase([[{ id: USER }], []]);
  assert.equal(
    (
      await handleTokenRequest(post('https://jarvis.test/api/token', body), {
        policy: policy(),
        limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 10 }),
        deviceAuthenticator: (input) =>
          authenticateDevice(revoked.db, input, { now: () => issuedAtMs }),
      })
    ).status,
    401
  );

  const replay = fakeDatabase([
    [{ id: USER }],
    credentialRow,
    [{ id: DEVICE }],
    [{ outcome: 'used', consumed_id: null }],
  ]);
  assert.equal(
    (
      await handleTokenRequest(post('https://jarvis.test/api/token', body), {
        policy: policy(),
        limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 10 }),
        deviceAuthenticator: (input) =>
          authenticateDevice(replay.db, input, { now: () => issuedAtMs }),
      })
    ).status,
    401
  );
});

test('an assertion signed for another audience is refused', async () => {
  const nonce = createAssertionNonce();
  const issuedAtMs = Date.now();
  const signature = sign(
    'sha256',
    assertionPayload({
      deviceId: DEVICE,
      nonce,
      issuedAtMs,
      audience: 'another-api',
    }),
    privateKey
  ).toString('base64');
  const { db } = fakeDatabase([[{ id: USER }], credentialRow]);

  const response = await handleTokenRequest(
    post('https://jarvis.test/api/token', assertionBody(signature, nonce, issuedAtMs)),
    {
      policy: policy(),
      limiter: new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 10 }),
      deviceAuthenticator: (input) => authenticateDevice(db, input, { now: () => issuedAtMs }),
    }
  );

  assert.equal(response.status, 401);
  assert.equal(response.body.participant_token, undefined);
});

test('device-assertion failures are rate limited like access-code failures', async () => {
  const shared = new MemoryRateLimiter({ windowSeconds: 900, maxFailures: 2 });
  const options = {
    policy: policy(),
    limiter: shared,
    deviceAuthenticator: async () => ({ verified: false }),
  };
  const nonce = createAssertionNonce();
  const body = assertionBody('AAAAAAAA', nonce, Date.now());

  const first = await handleTokenRequest(post('https://jarvis.test/api/token', body), options);
  assert.equal(first.status, 401);
  const blocked = await handleTokenRequest(post('https://jarvis.test/api/token', body), options);
  assert.equal(blocked.status, 429);
});
