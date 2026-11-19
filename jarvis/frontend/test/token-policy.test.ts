import assert from 'node:assert/strict';
import test from 'node:test';
import {
  DEFAULT_TOKEN_TTL_SECONDS,
  TokenRequestError,
  loadTokenPolicy,
  parseTokenRequest,
  resolveTokenTtlSeconds,
} from '../lib/token-policy.ts';

test('a missing TTL uses the short default', () => {
  assert.equal(DEFAULT_TOKEN_TTL_SECONDS, 15 * 60);
  assert.equal(resolveTokenTtlSeconds(undefined), 15 * 60);
  assert.equal(resolveTokenTtlSeconds(''), 15 * 60);
});

test('a configured TTL is honoured', () => {
  assert.equal(resolveTokenTtlSeconds('5m'), 5 * 60);
  assert.equal(resolveTokenTtlSeconds('900s'), 900);
  assert.equal(resolveTokenTtlSeconds('1h'), 60 * 60);
  assert.equal(resolveTokenTtlSeconds(' 2m '), 120);
});

test('a malformed or unsafe TTL falls back to the default', () => {
  assert.equal(resolveTokenTtlSeconds('15 minutes'), DEFAULT_TOKEN_TTL_SECONDS);
  assert.equal(resolveTokenTtlSeconds('soon'), DEFAULT_TOKEN_TTL_SECONDS);
  assert.equal(resolveTokenTtlSeconds('30s'), DEFAULT_TOKEN_TTL_SECONDS);
  assert.equal(resolveTokenTtlSeconds('7h'), DEFAULT_TOKEN_TTL_SECONDS);
  assert.equal(resolveTokenTtlSeconds('-5m'), DEFAULT_TOKEN_TTL_SECONDS);
});

test('public token access is off unless exactly enabled', () => {
  assert.equal(loadTokenPolicy({}).allowPublicToken, false);
  assert.equal(loadTokenPolicy({ ALLOW_PUBLIC_TOKEN: '' }).allowPublicToken, false);
  assert.equal(loadTokenPolicy({ ALLOW_PUBLIC_TOKEN: 'TRUE' }).allowPublicToken, false);
  assert.equal(loadTokenPolicy({ ALLOW_PUBLIC_TOKEN: '1' }).allowPublicToken, false);
  assert.equal(loadTokenPolicy({ ALLOW_PUBLIC_TOKEN: 'true' }).allowPublicToken, true);
});

test('rate limiting is bounded and configurable', () => {
  const defaults = loadTokenPolicy({});
  assert.equal(defaults.rateLimitMaxFailures, 10);
  assert.equal(defaults.rateLimitWindowSeconds, 15 * 60);

  const configured = loadTokenPolicy({
    AUTH_RATE_LIMIT_MAX_FAILURES: '3',
    AUTH_RATE_LIMIT_WINDOW_SECONDS: '60',
  });
  assert.equal(configured.rateLimitMaxFailures, 3);
  assert.equal(configured.rateLimitWindowSeconds, 60);

  assert.equal(loadTokenPolicy({ AUTH_RATE_LIMIT_MAX_FAILURES: 'lots' }).rateLimitMaxFailures, 10);
  assert.equal(loadTokenPolicy({ AUTH_RATE_LIMIT_MAX_FAILURES: '0' }).rateLimitMaxFailures, 10);
  assert.equal(
    loadTokenPolicy({ AUTH_RATE_LIMIT_WINDOW_SECONDS: '-1' }).rateLimitWindowSeconds,
    900
  );
});

test('the agent name defaults to the deployed dispatch name', () => {
  assert.equal(loadTokenPolicy({}).agentName, 'my-agent');
  assert.equal(loadTokenPolicy({ AGENT_NAME: ' other-agent ' }).agentName, 'other-agent');
});

test('a request with no optional fields gets safe defaults', () => {
  const parsed = parseTokenRequest({}, 'my-agent');

  assert.match(parsed.roomName, /^jarvis_[0-9a-f-]{36}$/);
  assert.match(parsed.participantIdentity, /^jarvis_user_[0-9a-f-]{36}$/);
  assert.equal(parsed.participantName, 'user');
  assert.equal(parsed.participantMetadata, undefined);
  assert.equal(parsed.participantAttributes, undefined);
  assert.equal(parsed.roomConfig, undefined);
});

test('a well-formed request keeps the values the clients send', () => {
  const parsed = parseTokenRequest(
    {
      room_name: 'jarvis_test_1',
      participant_name: 'Alice',
      participant_identity: 'jarvis_user_1',
      participant_metadata: JSON.stringify({ platform: 'android', capabilities: ['open_url'] }),
      participant_attributes: { plan: 'free' },
      room_config: { agents: [{ agent_name: 'my-agent', metadata: '{"mode":"voice"}' }] },
    },
    'my-agent'
  );

  assert.equal(parsed.roomName, 'jarvis_test_1');
  assert.equal(parsed.participantName, 'Alice');
  assert.equal(parsed.participantIdentity, 'jarvis_user_1');
  assert.equal(
    parsed.participantMetadata,
    JSON.stringify({ platform: 'android', capabilities: ['open_url'] })
  );
  assert.deepEqual(parsed.participantAttributes, { plan: 'free' });
  assert.equal(parsed.roomConfig?.agents.length, 1);
  assert.equal(parsed.roomConfig?.agents[0].agentName, 'my-agent');
  assert.equal(parsed.roomConfig?.agents[0].metadata, '{"mode":"voice"}');
});

test('invalid room names are rejected', () => {
  for (const roomName of ['has space', 'slash/name', 'a'.repeat(129), 'emoji-😀', '']) {
    assert.throws(() => parseTokenRequest({ room_name: roomName }, 'my-agent'), TokenRequestError);
  }
  assert.throws(() => parseTokenRequest({ room_name: 42 }, 'my-agent'), TokenRequestError);
});

test('invalid participant identities and names are rejected', () => {
  for (const identity of ['has space', 'slash/name', 'a'.repeat(65), '']) {
    assert.throws(
      () => parseTokenRequest({ participant_identity: identity }, 'my-agent'),
      TokenRequestError
    );
  }
  assert.throws(
    () => parseTokenRequest({ participant_name: 'a'.repeat(129) }, 'my-agent'),
    TokenRequestError
  );
  assert.throws(
    () => parseTokenRequest({ participant_name: 'bad\nname' }, 'my-agent'),
    TokenRequestError
  );
});

test('participant metadata must be a JSON object of bounded size', () => {
  assert.throws(
    () => parseTokenRequest({ participant_metadata: 'not json' }, 'my-agent'),
    TokenRequestError
  );
  assert.throws(
    () => parseTokenRequest({ participant_metadata: '["array"]' }, 'my-agent'),
    TokenRequestError
  );
  assert.throws(
    () =>
      parseTokenRequest(
        { participant_metadata: JSON.stringify({ big: 'a'.repeat(4096) }) },
        'my-agent'
      ),
    TokenRequestError
  );
  assert.throws(
    () => parseTokenRequest({ participant_metadata: { platform: 'android' } }, 'my-agent'),
    TokenRequestError
  );
});

test('participant attributes are restricted to short string pairs', () => {
  assert.throws(
    () => parseTokenRequest({ participant_attributes: { plan: 1 } }, 'my-agent'),
    TokenRequestError
  );
  assert.throws(
    () => parseTokenRequest({ participant_attributes: { 'bad key': 'x' } }, 'my-agent'),
    TokenRequestError
  );
  assert.throws(
    () => parseTokenRequest({ participant_attributes: { ['__proto__']: 'x' } }, 'my-agent'),
    TokenRequestError
  );
  const many = Object.fromEntries(Array.from({ length: 17 }, (_, index) => [`k${index}`, 'v']));
  assert.throws(
    () => parseTokenRequest({ participant_attributes: many }, 'my-agent'),
    TokenRequestError
  );
});

test('room configuration cannot request another agent', () => {
  assert.throws(
    () =>
      parseTokenRequest({ room_config: { agents: [{ agent_name: 'someone-else' }] } }, 'my-agent'),
    TokenRequestError
  );
});

test('room configuration cannot dispatch several agents', () => {
  assert.throws(
    () =>
      parseTokenRequest(
        { room_config: { agents: [{ agent_name: 'my-agent' }, { agent_name: 'my-agent' }] } },
        'my-agent'
      ),
    TokenRequestError
  );
});

test('room configuration cannot carry room settings or deployment routing', () => {
  assert.throws(
    () =>
      parseTokenRequest(
        { room_config: { agents: [{ agent_name: 'my-agent' }], max_participants: 1000 } },
        'my-agent'
      ),
    TokenRequestError
  );
  assert.throws(
    () =>
      parseTokenRequest(
        { room_config: { agents: [{ agent_name: 'my-agent', deployment: 'other' }] } },
        'my-agent'
      ),
    TokenRequestError
  );
  assert.throws(
    () =>
      parseTokenRequest(
        { room_config: { agents: [{ agent_name: 'my-agent', restart_policy: 'JRP_NEVER' }] } },
        'my-agent'
      ),
    TokenRequestError
  );
  assert.throws(() => parseTokenRequest({ room_config: [] }, 'my-agent'), TokenRequestError);
  assert.throws(
    () =>
      parseTokenRequest(
        { room_config: { agents: [{ agent_name: 'my-agent', metadata: 5 }] } },
        'my-agent'
      ),
    TokenRequestError
  );
});

test('the request body itself must be an object', () => {
  for (const body of [null, [], 'text', 42]) {
    assert.throws(() => parseTokenRequest(body, 'my-agent'), TokenRequestError);
  }
});
