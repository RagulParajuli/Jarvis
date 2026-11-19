import { AccessToken, type VideoGrant } from 'livekit-server-sdk';
import {
  type AuthHttpOptions,
  type AuthHttpResult,
  authLimiterFor,
  checkAccessCode,
  errorResponse,
  guardRateLimit,
  rateLimitedResponse,
} from './auth-http.ts';
import { defaultDeviceAuthenticator } from './device-auth.ts';
import { rateLimitKeyFor } from './rate-limit.ts';
import {
  AUTH_REJECTED_MESSAGE,
  INVALID_REQUEST_MESSAGE,
  type ParsedTokenRequest,
  TokenRequestError,
  loadTokenPolicy,
  parseTokenRequest,
} from './token-policy.ts';

/** What the route hands back to `NextResponse.json`. */
export type TokenEndpointResult = AuthHttpResult;

/** Server-verified shape of the optional device assertion in the request body. */
export type DeviceAssertionCredentials = {
  readonly deviceId: string;
  readonly nonce: string;
  readonly issuedAtMs: number;
  readonly signature: string;
};

export type DeviceAuthenticator = (
  input: DeviceAssertionCredentials
) => Promise<{ readonly verified: boolean }>;

export type TokenEndpointOptions = AuthHttpOptions & {
  /** Injectable so route tests can supply a fake without a database. */
  readonly deviceAuthenticator?: DeviceAuthenticator;
};

/**
 * Handles one token request without depending on Next.js.
 *
 * Keeping the decision logic here means the 401/429/400/200 behaviour can be
 * exercised with a plain `Request`, while the route handler only adapts the
 * result to `NextResponse`.
 */
export async function handleTokenRequest(
  req: Request,
  options: TokenEndpointOptions = {}
): Promise<TokenEndpointResult> {
  const policy = options.policy ?? loadTokenPolicy(options.env);
  const limiter = options.limiter ?? authLimiterFor(policy, options.env);
  const key = rateLimitKeyFor(req.headers);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, INVALID_REQUEST_MESSAGE);
  }

  const assertion = parseDeviceAssertion(body);

  if (assertion.supplied) {
    // A supplied assertion is the only authentication attempt: an invalid one
    // is never allowed to fall through to the access code.
    const blocked = await authorizeDevice(req, assertion, limiter, key, options);
    if (blocked) return blocked;
  } else if (!policy.allowPublicToken) {
    const denied = await checkAccessCode(req, policy, limiter, key);
    if (denied) return denied;
  }

  const { apiKey, apiSecret, livekitUrl } = policy;
  if (!livekitUrl || !apiKey || !apiSecret) {
    return errorResponse(503, 'Token service is not configured.');
  }

  try {
    const parsed = parseTokenRequest(body, policy.agentName);
    const participantToken = await createParticipantToken(parsed, {
      apiKey,
      apiSecret,
      ttlSeconds: policy.tokenTtlSeconds,
    });

    return {
      status: 200,
      body: {
        server_url: livekitUrl,
        room_name: parsed.roomName,
        participant_name: parsed.participantName,
        participant_token: participantToken,
      },
      headers: { 'Cache-Control': 'no-store' },
    };
  } catch (error) {
    if (error instanceof TokenRequestError) return errorResponse(400, INVALID_REQUEST_MESSAGE);

    // No request body, code, challenge or token is ever logged.
    console.error(
      'Token generation failed:',
      error instanceof Error ? error.message : 'unknown error'
    );
    return errorResponse(
      500,
      'Unable to create a LiveKit connection. Check the server configuration.'
    );
  }
}

type ParsedAssertion =
  | { readonly supplied: false }
  | { readonly supplied: true; readonly value?: DeviceAssertionCredentials };

/**
 * Reads the optional `device_assertion` object. Unknown or malformed fields
 * count as a supplied-but-invalid assertion, never as "no assertion".
 */
function parseDeviceAssertion(body: unknown): ParsedAssertion {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return { supplied: false };
  const raw = (body as Record<string, unknown>).device_assertion;
  if (raw === undefined) return { supplied: false };
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return { supplied: true };

  const value = raw as Record<string, unknown>;
  const { device_id, nonce, issued_at_ms, signature } = value;
  if (
    typeof device_id !== 'string' ||
    device_id.length === 0 ||
    device_id.length > 64 ||
    typeof nonce !== 'string' ||
    nonce.length === 0 ||
    nonce.length > 128 ||
    !Number.isSafeInteger(issued_at_ms) ||
    typeof signature !== 'string' ||
    signature.length === 0 ||
    signature.length > 512
  ) {
    return { supplied: true };
  }
  return {
    supplied: true,
    value: {
      deviceId: device_id,
      nonce,
      issuedAtMs: issued_at_ms as number,
      signature,
    },
  };
}

async function authorizeDevice(
  req: Request,
  assertion: Extract<ParsedAssertion, { supplied: true }>,
  limiter: ReturnType<typeof authLimiterFor>,
  key: string,
  options: TokenEndpointOptions
): Promise<AuthHttpResult | null> {
  // A caller already over the limit gets the same answer for a right or wrong
  // assertion, so retries cannot be used to keep guessing.
  const before = await guardRateLimit(() => limiter.check(key));
  if (before?.limited) return rateLimitedResponse(before.retryAfterSeconds);

  let verified = false;
  if (assertion.value) {
    try {
      const authenticator = options.deviceAuthenticator ?? defaultDeviceAuthenticator;
      const result = await authenticator(assertion.value);
      verified = result.verified === true;
    } catch {
      // A database or parsing failure is a failed authentication, never a pass.
      verified = false;
    }
  }

  if (!verified) {
    const after = await guardRateLimit(() => limiter.recordFailure(key));
    if (after?.limited) return rateLimitedResponse(after.retryAfterSeconds);
    return errorResponse(401, AUTH_REJECTED_MESSAGE);
  }

  await guardRateLimit(() => limiter.clear(key));
  return null;
}

async function createParticipantToken(
  parsed: ParsedTokenRequest,
  credentials: { apiKey: string; apiSecret: string; ttlSeconds: number }
): Promise<string> {
  const token = new AccessToken(credentials.apiKey, credentials.apiSecret, {
    identity: parsed.participantIdentity,
    name: parsed.participantName,
    ttl: credentials.ttlSeconds,
    ...(parsed.participantMetadata !== undefined && { metadata: parsed.participantMetadata }),
    ...(parsed.participantAttributes !== undefined && { attributes: parsed.participantAttributes }),
  });

  const grant: VideoGrant = {
    room: parsed.roomName,
    roomJoin: true,
    canPublish: true,
    canPublishData: true,
    canSubscribe: true,
  };
  token.addGrant(grant);

  if (parsed.roomConfig) token.roomConfig = parsed.roomConfig;

  return token.toJwt();
}
