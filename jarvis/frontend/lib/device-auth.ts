import 'server-only';
import { type Database, getDatabase } from './database.ts';
import {
  TOKEN_API_AUDIENCE,
  type VerifyAssertionOptions,
  consumeDeviceChallenge,
  verifyDeviceAssertion,
} from './device-pairing.ts';

/** The fields a device supplies to authenticate a token request. */
export type DeviceAssertionInput = {
  readonly deviceId: string;
  readonly nonce: string;
  readonly issuedAtMs: number;
  readonly signature: string;
};

export type DeviceAuthentication = { readonly verified: boolean };

/**
 * Verifies a device assertion and consumes its one-time challenge.
 *
 * The audience is inserted here, never read from the request, so the bytes the
 * device signed and the challenge stored in the database both bind to this API.
 * Signature and timestamp checks happen first; the challenge is then consumed
 * in one atomic operation before the caller is allowed to mint a token.
 */
export async function authenticateDevice(
  db: Database,
  input: DeviceAssertionInput,
  options: VerifyAssertionOptions = {}
): Promise<DeviceAuthentication> {
  const payload = {
    deviceId: input.deviceId,
    nonce: input.nonce,
    issuedAtMs: input.issuedAtMs,
    audience: TOKEN_API_AUDIENCE,
  };

  const verified = await verifyDeviceAssertion(
    db,
    { ...payload, signature: input.signature },
    options
  );
  if (!verified.verified) return { verified: false };

  const consumed = await consumeDeviceChallenge(db, {
    userId: verified.userId,
    deviceId: verified.deviceId,
    nonce: input.nonce,
    audience: TOKEN_API_AUDIENCE,
  });
  return { verified: consumed.status === 'consumed' };
}

/** The default authenticator used by the token route. */
export function defaultDeviceAuthenticator(
  input: DeviceAssertionInput,
  options?: VerifyAssertionOptions
): Promise<DeviceAuthentication> {
  return authenticateDevice(getDatabase(), input, options);
}
