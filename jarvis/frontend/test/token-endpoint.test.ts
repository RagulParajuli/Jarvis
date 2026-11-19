import assert from 'node:assert/strict';
import test from 'node:test';
import type { AuthRateLimiter } from '../lib/rate-limit.ts';
import { MemoryRateLimiter } from '../lib/rate-limit.ts';
import { handleTokenRequest } from '../lib/token-endpoint.ts';
import {
  AUTH_REJECTED_MESSAGE,
  INVALID_REQUEST_MESSAGE,
  RATE_LIMITED_MESSAGE,
  type TokenPolicy,
} from '../lib/token-policy.ts';

const ACCESS_CODE = 'test-access-code';

function policy(overrides: Partial<TokenPolicy> = {}): TokenPolicy {
  return {
    livekitUrl: 'wss://jarvis-test.livekit.cloud',
    apiKey: 'test-api-key',
    apiSecret: 'test-api-secret',
    accessCode: ACCESS_CODE,
    allowPublicToken: false,
    agentName: 'my-agent',
    tokenTtlSeconds: 15 * 60,
    rateLimitWindowSeconds: 15 * 60,
    rateLimitMaxFailures: 10,
    ...overrides,
  };
}

function limiter(maxFailures = 10): AuthRateLimiter {
  return new MemoryRateLimiter({ windowSeconds: 15 * 60, maxFailures });
}

function tokenRequest(options: { code?: string; body?: unknown; ip?: string } = {}): Request {
  const headers = new Headers({
    'Content-Type': 'application/json',
    'x-forwarded-for': options.ip ?? '203.0.113.7',
  });
  if (options.code !== undefined) headers.set('X-Jarvis-Access-Code', options.code);

  return new Request('https://jarvis.test/api/token', {
    method: 'POST',
    headers,
    body: JSON.stringify(options.body ?? {}),
  });
}

type JwtPayload = {
  sub?: string;
  name?: string;
  exp: number;
  nbf: number;
  metadata?: string;
  video?: { room?: string; roomJoin?: boolean };
  roomConfig?: { agents?: { agentName?: string; metadata?: string }[] };
};

function decodeJwt(token: unknown): JwtPayload {
  assert.equal(typeof token, 'string');
  const segment = (token as string).split('.')[1];
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8')) as JwtPayload;
}

test('a missing code and a wrong code get the same 401', async () => {
  const missing = await handleTokenRequest(tokenRequest(), {
    policy: policy(),
    limiter: limiter(),
  });
  const wrong = await handleTokenRequest(tokenRequest({ code: 'wrong-code' }), {
    policy: policy(),
    limiter: limiter(),
  });

  assert.equal(missing.status, 401);
  assert.equal(wrong.status, 401);
  assert.deepEqual(missing.body, wrong.body);
  assert.equal(missing.body.error, AUTH_REJECTED_MESSAGE);
});

test('excessive failures return 429 and keep out a correct code', async () => {
  const limited = limiter(3);
  const options = { policy: policy({ rateLimitMaxFailures: 3 }), limiter: limited };

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const response = await handleTokenRequest(tokenRequest({ code: 'wrong-code' }), options);
    assert.equal(response.status, 401);
  }

  const blocked = await handleTokenRequest(tokenRequest({ code: 'wrong-code' }), options);
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.error, RATE_LIMITED_MESSAGE);
  assert.ok(Number(blocked.headers['Retry-After']) > 0);

  const correctWhileBlocked = await handleTokenRequest(
    tokenRequest({ code: ACCESS_CODE }),
    options
  );
  assert.equal(correctWhileBlocked.status, 429);
});

test('failures from different clients are counted separately', async () => {
  const shared = limiter(2);
  const options = { policy: policy({ rateLimitMaxFailures: 2 }), limiter: shared };

  await handleTokenRequest(tokenRequest({ code: 'wrong-code', ip: '198.51.100.1' }), options);
  await handleTokenRequest(tokenRequest({ code: 'wrong-code', ip: '198.51.100.1' }), options);

  const otherClient = await handleTokenRequest(
    tokenRequest({ code: 'wrong-code', ip: '198.51.100.2' }),
    options
  );
  assert.equal(otherClient.status, 401);
});

test('a successful authentication issues a token for the requested room', async () => {
  const metadata = JSON.stringify({ platform: 'android', capabilities: ['open_url'] });
  const response = await handleTokenRequest(
    tokenRequest({
      code: ACCESS_CODE,
      body: {
        room_name: 'jarvis_test_room',
        participant_name: 'Alice',
        participant_identity: 'jarvis_user_1',
        participant_metadata: metadata,
        room_config: { agents: [{ agent_name: 'my-agent' }] },
      },
    }),
    { policy: policy(), limiter: limiter() }
  );

  assert.equal(response.status, 200);
  assert.equal(response.body.server_url, 'wss://jarvis-test.livekit.cloud');
  assert.equal(response.body.room_name, 'jarvis_test_room');
  assert.equal(response.body.participant_name, 'Alice');

  const payload = decodeJwt(response.body.participant_token);
  assert.equal(payload.sub, 'jarvis_user_1');
  assert.equal(payload.name, 'Alice');
  assert.equal(payload.metadata, metadata);
  assert.equal(payload.video?.room, 'jarvis_test_room');
  assert.equal(payload.video?.roomJoin, true);
  assert.equal(payload.roomConfig?.agents?.[0]?.agentName, 'my-agent');
});

test('a success clears the earlier failures for that client', async () => {
  const options = { policy: policy({ rateLimitMaxFailures: 2 }), limiter: limiter(2) };

  assert.equal(
    (await handleTokenRequest(tokenRequest({ code: 'wrong-code' }), options)).status,
    401
  );
  assert.equal(
    (await handleTokenRequest(tokenRequest({ code: ACCESS_CODE }), options)).status,
    200
  );

  // The budget is back to two attempts, so one more miss is still a 401.
  assert.equal(
    (await handleTokenRequest(tokenRequest({ code: 'wrong-code' }), options)).status,
    401
  );
});

test('the default token lifetime is short', async () => {
  const response = await handleTokenRequest(tokenRequest({ code: ACCESS_CODE }), {
    policy: policy(),
    limiter: limiter(),
  });

  const payload = decodeJwt(response.body.participant_token);
  assert.equal(payload.exp - payload.nbf, 15 * 60);
});

test('the token lifetime follows the configured setting', async () => {
  for (const ttlSeconds of [120, 3600]) {
    const response = await handleTokenRequest(tokenRequest({ code: ACCESS_CODE }), {
      policy: policy({ tokenTtlSeconds: ttlSeconds }),
      limiter: limiter(),
    });

    const payload = decodeJwt(response.body.participant_token);
    assert.equal(payload.exp - payload.nbf, ttlSeconds);
  }
});

test('invalid room configuration is rejected without minting a token', async () => {
  const invalidBodies = [
    { room_name: 'bad/room' },
    { participant_identity: 'bad identity' },
    { participant_metadata: 'not json' },
    { room_config: { agents: [{ agent_name: 'someone-else' }] } },
    { room_config: { agents: [{ agent_name: 'my-agent' }, { agent_name: 'my-agent' }] } },
    { room_config: { agents: [{ agent_name: 'my-agent' }], max_participants: 999 } },
    { room_config: { agents: [{ agent_name: 'my-agent', deployment: 'other' }] } },
  ];

  for (const body of invalidBodies) {
    const response = await handleTokenRequest(tokenRequest({ code: ACCESS_CODE, body }), {
      policy: policy(),
      limiter: limiter(),
    });

    assert.equal(response.status, 400, `expected 400 for ${JSON.stringify(body)}`);
    assert.equal(response.body.error, INVALID_REQUEST_MESSAGE);
    assert.equal(response.body.participant_token, undefined);
  }
});

test('a malformed JSON body is rejected', async () => {
  const response = await handleTokenRequest(
    new Request('https://jarvis.test/api/token', {
      method: 'POST',
      headers: { 'X-Jarvis-Access-Code': ACCESS_CODE, 'Content-Type': 'application/json' },
      body: '{ not json',
    }),
    { policy: policy(), limiter: limiter() }
  );

  assert.equal(response.status, 400);
  assert.equal(response.body.error, INVALID_REQUEST_MESSAGE);
});

test('the endpoint refuses to run without an access code configured', async () => {
  const response = await handleTokenRequest(tokenRequest(), {
    policy: policy({ accessCode: undefined }),
    limiter: limiter(),
  });

  assert.equal(response.status, 503);
  assert.equal(response.body.participant_token, undefined);
});

test('the endpoint refuses to run without LiveKit credentials', async () => {
  const response = await handleTokenRequest(tokenRequest({ code: ACCESS_CODE }), {
    policy: policy({ apiSecret: undefined }),
    limiter: limiter(),
  });

  assert.equal(response.status, 503);
  assert.equal(response.body.participant_token, undefined);
});

test('public mode still validates the request body', async () => {
  const response = await handleTokenRequest(
    tokenRequest({ body: { room_config: { agents: [{ agent_name: 'someone-else' }] } } }),
    { policy: policy({ accessCode: undefined, allowPublicToken: true }), limiter: limiter() }
  );

  assert.equal(response.status, 400);
});

test('a rate limit store outage does not block valid authentication', async () => {
  const failing: AuthRateLimiter = {
    check: async () => {
      throw new Error('store down');
    },
    recordFailure: async () => {
      throw new Error('store down');
    },
    clear: async () => {
      throw new Error('store down');
    },
  };

  const response = await handleTokenRequest(tokenRequest({ code: ACCESS_CODE }), {
    policy: policy(),
    limiter: failing,
  });

  assert.equal(response.status, 200);
  assert.equal(typeof response.body.participant_token, 'string');
});
