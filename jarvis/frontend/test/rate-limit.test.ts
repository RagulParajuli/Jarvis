import assert from 'node:assert/strict';
import test from 'node:test';
import {
  MemoryRateLimiter,
  UpstashRateLimiter,
  createAuthRateLimiter,
  rateLimitKeyFor,
} from '../lib/rate-limit.ts';

test('memory limiter allows attempts until the limit, then denies', async () => {
  let clock = 1_000;
  const limiter = new MemoryRateLimiter({
    windowSeconds: 60,
    maxFailures: 2,
    now: () => clock,
  });

  assert.equal((await limiter.check('client')).limited, false);
  assert.equal((await limiter.recordFailure('client')).limited, false);

  const secondFailure = await limiter.recordFailure('client');
  assert.equal(secondFailure.limited, true);
  assert.equal(secondFailure.retryAfterSeconds, 60);
  assert.equal((await limiter.check('client')).limited, true);

  clock += 61_000;
  assert.equal((await limiter.check('client')).limited, false);
});

test('memory limiter forgets failures after a success', async () => {
  const limiter = new MemoryRateLimiter({ windowSeconds: 60, maxFailures: 1 });

  assert.equal((await limiter.recordFailure('client')).limited, true);
  await limiter.clear('client');
  assert.equal((await limiter.check('client')).limited, false);
});

test('clients are bucketed by a hashed address, never by the code', () => {
  const first = rateLimitKeyFor(new Headers({ 'x-forwarded-for': '203.0.113.7, 70.41.3.18' }));
  const again = rateLimitKeyFor(new Headers({ 'x-forwarded-for': '203.0.113.7' }));
  const other = rateLimitKeyFor(new Headers({ 'x-forwarded-for': '203.0.113.8' }));
  const realIp = rateLimitKeyFor(new Headers({ 'x-real-ip': '203.0.113.7' }));

  assert.equal(first, again);
  assert.equal(first, realIp);
  assert.notEqual(first, other);
  assert.match(first, /^jarvis:auth:fail:[0-9a-f]{16}$/);
  assert.ok(!first.includes('203.0.113.7'));
});

test('upstash limiter counts in the shared store', async () => {
  const counts = new Map<string, number>();
  let ttl = 60;
  const calls: string[][] = [];
  let authorization: string | undefined;

  const fetchImpl = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    authorization = headers.get('Authorization') ?? undefined;

    const args = JSON.parse(String(init?.body)) as (string | number)[];
    calls.push(args.map(String));
    const [command, key, value] = args;

    let result: unknown = null;
    switch (command) {
      case 'GET':
        result = counts.get(String(key)) ?? null;
        break;
      case 'INCR':
        result = (counts.get(String(key)) ?? 0) + 1;
        counts.set(String(key), result as number);
        break;
      case 'EXPIRE':
        ttl = Number(value);
        result = 1;
        break;
      case 'TTL':
        result = ttl;
        break;
      case 'DEL':
        counts.delete(String(key));
        result = 1;
        break;
      default:
        result = null;
    }

    return new Response(JSON.stringify({ result }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }) as typeof fetch;

  const limiter = new UpstashRateLimiter({
    restUrl: 'https://redis.example.test/',
    restToken: 'secret-token',
    windowSeconds: 60,
    maxFailures: 2,
    fetchImpl,
  });

  assert.equal((await limiter.recordFailure('client')).limited, false);
  assert.equal((await limiter.recordFailure('client')).limited, true);
  assert.equal((await limiter.check('client')).limited, true);

  await limiter.clear('client');
  assert.equal((await limiter.check('client')).limited, false);

  assert.deepEqual(calls.slice(0, 3), [
    ['INCR', 'client'],
    ['EXPIRE', 'client', '60'],
    ['INCR', 'client'],
  ]);
  assert.ok(calls.some((call) => call[0] === 'DEL'));
  assert.equal(authorization, 'Bearer secret-token');
});

test('upstash limiter reports the remaining window', async () => {
  const fetchImpl = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const [command] = JSON.parse(String(init?.body)) as string[];
    const result = command === 'GET' ? 5 : command === 'TTL' ? 42 : 1;
    return new Response(JSON.stringify({ result }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }) as typeof fetch;

  const limiter = new UpstashRateLimiter({
    restUrl: 'https://redis.example.test',
    restToken: 'secret-token',
    windowSeconds: 60,
    maxFailures: 5,
    fetchImpl,
  });

  const decision = await limiter.check('client');
  assert.equal(decision.limited, true);
  assert.equal(decision.retryAfterSeconds, 42);
});

test('a distributed limiter is chosen only when it is configured', () => {
  const originalWarn = console.warn;
  console.warn = () => {};
  try {
    const distributed = createAuthRateLimiter({
      windowSeconds: 60,
      maxFailures: 5,
      env: {
        UPSTASH_REDIS_REST_URL: 'https://redis.example.test',
        UPSTASH_REDIS_REST_TOKEN: 'secret-token',
      },
    });
    assert.ok(distributed instanceof UpstashRateLimiter);

    const local = createAuthRateLimiter({ windowSeconds: 60, maxFailures: 5, env: {} });
    assert.ok(local instanceof MemoryRateLimiter);

    const incomplete = createAuthRateLimiter({
      windowSeconds: 60,
      maxFailures: 5,
      env: { UPSTASH_REDIS_REST_URL: 'https://redis.example.test' },
    });
    assert.ok(incomplete instanceof MemoryRateLimiter);
  } finally {
    console.warn = originalWarn;
  }
});
