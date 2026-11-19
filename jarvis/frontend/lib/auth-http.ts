import { timingSafeEqual } from 'node:crypto';
import { type AuthRateLimiter, createAuthRateLimiter } from './rate-limit.ts';
import {
  AUTH_REJECTED_MESSAGE,
  RATE_LIMITED_MESSAGE,
  type TokenPolicy,
  type TokenPolicyEnv,
} from './token-policy.ts';

/**
 * The HTTP pieces shared by the token route and the device routes.
 *
 * Keeping one limiter and one access-code comparison behind this module means
 * the new endpoints cannot accidentally use a weaker gate than `/api/token`.
 * Nothing here echoes a supplied code, key or signature.
 */
export type AuthHttpResult = {
  readonly status: number;
  readonly body: Record<string, unknown>;
  readonly headers: Record<string, string>;
};

export type AuthHttpOptions = {
  readonly policy?: TokenPolicy;
  readonly limiter?: AuthRateLimiter;
  readonly env?: TokenPolicyEnv;
};

export const NO_STORE = { 'Cache-Control': 'no-store' } as const;

let sharedLimiter: AuthRateLimiter | undefined;

/** One limiter per process, shared by every auth endpoint. */
export function authLimiterFor(policy: TokenPolicy, env?: TokenPolicyEnv): AuthRateLimiter {
  sharedLimiter ??= createAuthRateLimiter({
    windowSeconds: policy.rateLimitWindowSeconds,
    maxFailures: policy.rateLimitMaxFailures,
    env,
  });
  return sharedLimiter;
}

let warnedAboutStore = false;

/** A store outage must not take the endpoints down; fail open, but say so once. */
export async function guardRateLimit<T>(action: () => Promise<T>): Promise<T | undefined> {
  try {
    return await action();
  } catch {
    if (!warnedAboutStore) {
      warnedAboutStore = true;
      console.warn(
        'Rate limit store is unavailable; authentication attempts are not being counted.'
      );
    }
    return undefined;
  }
}

/** Constant-time comparison of an access code. Generic to missing and wrong. */
export function accessCodeMatches(supplied: string, expected: string): boolean {
  if (supplied.length === 0) return false;

  const suppliedBuffer = Buffer.from(supplied);
  const expectedBuffer = Buffer.from(expected);
  return (
    suppliedBuffer.length === expectedBuffer.length &&
    timingSafeEqual(suppliedBuffer, expectedBuffer)
  );
}

/**
 * Runs the access-code gate, including rate limiting.
 *
 * Returns a ready error result when the request is denied, or `null` when the
 * code is valid. A caller already over the limit is refused before its code is
 * compared, so retries cannot be used to keep guessing.
 */
export async function checkAccessCode(
  req: Request,
  policy: TokenPolicy,
  limiter: AuthRateLimiter,
  key: string
): Promise<AuthHttpResult | null> {
  if (!policy.accessCode) return errorResponse(503, 'Token service is not configured.');

  const before = await guardRateLimit(() => limiter.check(key));
  if (before?.limited) return rateLimitedResponse(before.retryAfterSeconds);

  const supplied = req.headers.get('X-Jarvis-Access-Code') ?? '';
  if (!accessCodeMatches(supplied, policy.accessCode)) {
    const after = await guardRateLimit(() => limiter.recordFailure(key));
    if (after?.limited) return rateLimitedResponse(after.retryAfterSeconds);
    return errorResponse(401, AUTH_REJECTED_MESSAGE);
  }

  await guardRateLimit(() => limiter.clear(key));
  return null;
}

export function rateLimitedResponse(retryAfterSeconds: number): AuthHttpResult {
  return {
    status: 429,
    body: { error: RATE_LIMITED_MESSAGE },
    headers: { ...NO_STORE, 'Retry-After': String(Math.max(1, retryAfterSeconds)) },
  };
}

export function errorResponse(status: number, error: string): AuthHttpResult {
  return { status, body: { error }, headers: NO_STORE };
}
