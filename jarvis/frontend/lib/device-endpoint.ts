import {
  type AuthHttpOptions,
  type AuthHttpResult,
  authLimiterFor,
  checkAccessCode,
  errorResponse,
  guardRateLimit,
  rateLimitedResponse,
} from './auth-http.ts';
import { type Database, getDatabase } from './database.ts';
import {
  PairingValidationError,
  issueDeviceChallenge,
  issuePairingCode,
  redeemPairingCode,
} from './device-pairing.ts';
import { rateLimitKeyFor } from './rate-limit.ts';
import { type TokenPolicy, loadTokenPolicy } from './token-policy.ts';

/**
 * HTTP adapters for the device endpoints.
 *
 * They only parse and validate, then delegate to the service layer in
 * `device-pairing.ts`. Every response is `no-store`, every error is generic,
 * and plaintext codes/challenges appear only in the success response body.
 */
export type DeviceEndpointOptions = AuthHttpOptions & {
  readonly db?: Database;
};

const INVALID_MESSAGE = 'Invalid device request.';
const PAIRING_REJECTED_MESSAGE = 'Pairing code is invalid or expired.';
const ALREADY_PAIRED_MESSAGE = 'This device is already paired.';

type Context = {
  readonly db: Database;
  readonly limiter: ReturnType<typeof authLimiterFor>;
  readonly key: string;
  readonly policy: TokenPolicy;
};

function contextFor(options: DeviceEndpointOptions, req: Request): Context {
  const policy: TokenPolicy = options.policy ?? loadTokenPolicy(options.env);
  return {
    db: options.db ?? getDatabase(),
    limiter: options.limiter ?? authLimiterFor(policy, options.env),
    key: rateLimitKeyFor(req.headers),
    policy,
  };
}

/**
 * Issues a challenge to an already trusted device, without an access code.
 *
 * The device id alone is not a credential: `issueDeviceChallenge` only inserts
 * for a trusted device with one active ES256 credential, binds the row to that
 * device's account and audience, and returns a hash-only, short-lived nonce.
 * The plaintext is useless without the registered private key. Every rejection
 * is generic and counted by the shared limiter, so probing cannot reveal why a
 * device was refused.
 */
export async function handleChallengeRequest(
  req: Request,
  options: DeviceEndpointOptions = {}
): Promise<AuthHttpResult> {
  const ctx = contextFor(options, req);
  const before = await guardRateLimit(() => ctx.limiter.check(ctx.key));
  if (before?.limited) return rateLimitedResponse(before.retryAfterSeconds);

  const body = await readJsonObject(req);
  if (!body || !onlyKeys(body, ['device_id']) || typeof body.device_id !== 'string') {
    return record(ctx, 400, INVALID_MESSAGE);
  }

  let issued;
  try {
    issued = await issueDeviceChallenge(ctx.db, {
      deviceId: body.device_id as string,
    });
  } catch (error) {
    if (error instanceof PairingValidationError) return record(ctx, 400, INVALID_MESSAGE);
    throw error;
  }

  await guardRateLimit(() => ctx.limiter.clear(ctx.key));
  return {
    status: 200,
    body: {
      challenge: issued.challenge,
      audience: issued.audience,
      expires_at: issued.expiresAt.toISOString(),
    },
    headers: { 'Cache-Control': 'no-store' },
  };
}

/** Issues a one-time pairing code. Requires the access code. */
export async function handlePairingIssueRequest(
  req: Request,
  options: DeviceEndpointOptions = {}
): Promise<AuthHttpResult> {
  const ctx = contextFor(options, req);
  const denied = await checkAccessCode(req, ctx.policy, ctx.limiter, ctx.key);
  if (denied) return denied;

  const body = await readJsonObject(req);
  if (!body || !onlyKeys(body, ['ttl_seconds'])) return record(ctx, 400, INVALID_MESSAGE);

  const ttlSeconds = body.ttl_seconds;
  if (
    ttlSeconds !== undefined &&
    (!Number.isInteger(ttlSeconds) || (ttlSeconds as number) < 1 || (ttlSeconds as number) > 86_400)
  ) {
    return record(ctx, 400, INVALID_MESSAGE);
  }

  try {
    const issued = await issuePairingCode(ctx.db, {
      ...(ttlSeconds !== undefined && { ttlSeconds: ttlSeconds as number }),
    });
    return {
      status: 200,
      body: { code: issued.code, expires_at: issued.expiresAt.toISOString() },
      headers: { 'Cache-Control': 'no-store' },
    };
  } catch (error) {
    if (error instanceof PairingValidationError) return record(ctx, 400, INVALID_MESSAGE);
    throw error;
  }
}

/**
 * Redeems a pairing code. The code itself is the bootstrap credential, so no
 * access code is needed here, but failures are still rate limited per client.
 */
export async function handlePairingRedeemRequest(
  req: Request,
  options: DeviceEndpointOptions = {}
): Promise<AuthHttpResult> {
  const ctx = contextFor(options, req);
  const before = await guardRateLimit(() => ctx.limiter.check(ctx.key));
  if (before?.limited) return rateLimitedResponse(before.retryAfterSeconds);

  const body = await readJsonObject(req);
  if (
    !body ||
    !onlyKeys(body, ['code', 'device_id', 'public_key', 'fingerprint', 'platform', 'label']) ||
    !allStrings(body, ['code', 'device_id', 'public_key', 'fingerprint', 'platform', 'label'])
  ) {
    return record(ctx, 400, INVALID_MESSAGE);
  }

  let result;
  try {
    result = await redeemPairingCode(ctx.db, {
      code: body.code as string,
      deviceId: body.device_id as string,
      publicKey: body.public_key as string,
      fingerprint: body.fingerprint as string,
      platform: body.platform as 'android',
      label: body.label as string,
    });
  } catch (error) {
    if (error instanceof PairingValidationError) return record(ctx, 400, INVALID_MESSAGE);
    throw error;
  }

  if (result.status === 'redeemed') {
    await guardRateLimit(() => ctx.limiter.clear(ctx.key));
    return {
      status: 200,
      body: { status: 'paired', device_id: result.deviceId },
      headers: { 'Cache-Control': 'no-store' },
    };
  }
  if (result.status === 'device_exists' || result.status === 'credential_exists') {
    return errorResponse(409, ALREADY_PAIRED_MESSAGE);
  }
  if (result.status === 'invalid' || result.status === 'used' || result.status === 'expired') {
    return record(ctx, 401, PAIRING_REJECTED_MESSAGE);
  }
  return record(ctx, 401, PAIRING_REJECTED_MESSAGE);
}

/** Records one failed device request and returns a safe error response. */
async function record(ctx: Context, status: number, message: string): Promise<AuthHttpResult> {
  const after = await guardRateLimit(() => ctx.limiter.recordFailure(ctx.key));
  if (after?.limited) return rateLimitedResponse(after.retryAfterSeconds);
  return errorResponse(status, message);
}

async function readJsonObject(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body: unknown = await req.json();
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return null;
    return body as Record<string, unknown>;
  } catch {
    return null;
  }
}

function onlyKeys(body: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(body).every((key) => allowed.includes(key));
}

function allStrings(body: Record<string, unknown>, fields: readonly string[]): boolean {
  return fields.every((field) => typeof body[field] === 'string');
}
