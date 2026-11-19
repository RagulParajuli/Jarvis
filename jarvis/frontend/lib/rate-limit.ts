import { createHash } from 'node:crypto';

/** Whether a caller may attempt authentication, and how long to wait if not. */
export type RateLimitDecision = {
  readonly limited: boolean;
  readonly retryAfterSeconds: number;
};

/**
 * Tracks failed access-code attempts per client.
 *
 * Implementations must be shared across server instances to be a real
 * protection on Vercel; {@link UpstashRateLimiter} provides that through
 * Upstash's REST API. {@link MemoryRateLimiter} exists for a single process and
 * is never sufficient behind more than one instance.
 */
export type AuthRateLimiter = {
  /** Looks at the current state without recording an attempt. */
  check(key: string): Promise<RateLimitDecision>;
  /** Records a failed attempt and reports the state that follows it. */
  recordFailure(key: string): Promise<RateLimitDecision>;
  /** Forgets a client's failures after a success. */
  clear(key: string): Promise<void>;
};

type LimiterOptions = {
  readonly windowSeconds: number;
  readonly maxFailures: number;
};

const KEY_PREFIX = 'jarvis:auth:fail:';

/**
 * Buckets failures by the address Vercel puts in `x-forwarded-for`.
 *
 * The address is hashed so the key store never holds raw client IPs, and the
 * access code itself is never part of the key. When every proxy header is
 * absent the callers share one bucket, which limits them more, not less.
 */
export function rateLimitKeyFor(headers: Headers): string {
  const forwarded = headers.get('x-forwarded-for');
  const address = forwarded?.split(',')[0]?.trim() || headers.get('x-real-ip')?.trim() || 'unknown';
  const digest = createHash('sha256').update(address).digest('hex').slice(0, 16);
  return `${KEY_PREFIX}${digest}`;
}

const ALLOWED: RateLimitDecision = { limited: false, retryAfterSeconds: 0 };

/** Keeps the last failures in process memory. Single instance only. */
export class MemoryRateLimiter implements AuthRateLimiter {
  private readonly windowSeconds: number;
  private readonly maxFailures: number;
  private readonly now: () => number;
  private readonly hits = new Map<string, { count: number; resetAt: number }>();

  constructor(options: LimiterOptions & { now?: () => number }) {
    this.windowSeconds = options.windowSeconds;
    this.maxFailures = options.maxFailures;
    this.now = options.now ?? Date.now;
  }

  async check(key: string): Promise<RateLimitDecision> {
    const entry = this.liveEntry(key);
    if (!entry || entry.count < this.maxFailures) return ALLOWED;
    return deny(entry.resetAt, this.now, this.windowSeconds);
  }

  async recordFailure(key: string): Promise<RateLimitDecision> {
    const now = this.now();
    this.prune(now);
    const existing = this.hits.get(key);
    const entry =
      existing && existing.resetAt > now
        ? existing
        : { count: 0, resetAt: now + this.windowSeconds * 1000 };

    entry.count += 1;
    this.hits.set(key, entry);

    if (entry.count < this.maxFailures) return ALLOWED;
    return deny(entry.resetAt, this.now, this.windowSeconds);
  }

  async clear(key: string): Promise<void> {
    this.hits.delete(key);
  }

  private liveEntry(key: string): { count: number; resetAt: number } | undefined {
    const entry = this.hits.get(key);
    if (!entry) return undefined;
    if (entry.resetAt <= this.now()) {
      this.hits.delete(key);
      return undefined;
    }
    return entry;
  }

  /** Keeps a long-running single instance from growing without bound. */
  private prune(now: number): void {
    if (this.hits.size < 10_000) return;
    for (const [key, entry] of this.hits) {
      if (entry.resetAt <= now) this.hits.delete(key);
    }
  }
}

/**
 * Counts failures in Upstash Redis over its REST API.
 *
 * This is the only implementation that protects a deployment spread over
 * several instances, because every instance sees the same counters. It uses
 * the REST protocol directly, so no extra dependency is required. Keys get a
 * TTL on every failure, which also keeps a partially applied write from
 * locking a client out permanently.
 */
export class UpstashRateLimiter implements AuthRateLimiter {
  private readonly restUrl: string;
  private readonly restToken: string;
  private readonly windowSeconds: number;
  private readonly maxFailures: number;
  private readonly fetchImpl: typeof fetch;

  constructor(
    options: LimiterOptions & {
      readonly restUrl: string;
      readonly restToken: string;
      readonly fetchImpl?: typeof fetch;
    }
  ) {
    this.restUrl = options.restUrl.replace(/\/+$/, '');
    this.restToken = options.restToken;
    this.windowSeconds = options.windowSeconds;
    this.maxFailures = options.maxFailures;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async check(key: string): Promise<RateLimitDecision> {
    const count = Number((await this.command(['GET', key])) ?? 0);
    if (!Number.isFinite(count) || count < this.maxFailures) return ALLOWED;

    const ttl = Number(await this.command(['TTL', key]));
    return { limited: true, retryAfterSeconds: ttl > 0 ? ttl : this.windowSeconds };
  }

  async recordFailure(key: string): Promise<RateLimitDecision> {
    const count = Number(await this.command(['INCR', key]));
    await this.command(['EXPIRE', key, this.windowSeconds]);

    if (!Number.isFinite(count) || count < this.maxFailures) return ALLOWED;
    return { limited: true, retryAfterSeconds: this.windowSeconds };
  }

  async clear(key: string): Promise<void> {
    await this.command(['DEL', key]);
  }

  private async command(args: (string | number)[]): Promise<unknown> {
    const response = await this.fetchImpl(this.restUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.restToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
      cache: 'no-store',
    });
    if (!response.ok) throw new Error(`Rate limit store returned ${response.status}.`);

    const payload = (await response.json()) as { result?: unknown; error?: string };
    if (payload.error) throw new Error('Rate limit store rejected a command.');
    return payload.result;
  }
}

let warnedAboutMemory = false;

/**
 * Uses Upstash when both REST settings are present.
 *
 * Without them the endpoint falls back to per-instance memory so development
 * still works, and says so once. That fallback must not be relied on in
 * production: each Vercel instance would count separately.
 */
export function createAuthRateLimiter(
  options: LimiterOptions & { readonly env?: Record<string, string | undefined> }
): AuthRateLimiter {
  const env = options.env ?? process.env;
  const restUrl = env.UPSTASH_REDIS_REST_URL?.trim();
  const restToken = env.UPSTASH_REDIS_REST_TOKEN?.trim();

  if (restUrl && restToken) {
    return new UpstashRateLimiter({
      restUrl,
      restToken,
      windowSeconds: options.windowSeconds,
      maxFailures: options.maxFailures,
    });
  }

  if (!warnedAboutMemory) {
    warnedAboutMemory = true;
    console.warn(
      'Authentication rate limiting is using per-instance memory, which is not production protection ' +
        'behind more than one instance. Set UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN ' +
        'to share failure counts across instances.'
    );
  }
  return new MemoryRateLimiter(options);
}

function deny(resetAt: number, now: () => number, fallbackSeconds: number): RateLimitDecision {
  const remaining = Math.ceil((resetAt - now()) / 1000);
  return { limited: true, retryAfterSeconds: remaining > 0 ? remaining : fallbackSeconds };
}
