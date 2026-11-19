import {
  type KeyObject,
  createHash,
  createPublicKey,
  randomBytes,
  verify as verifySignature,
} from 'node:crypto';
import 'server-only';
import { type Database, DatabaseQueryError } from './database.ts';

/**
 * Server-side trusted-device pairing primitives.
 *
 * This module deliberately stops at the database/service layer. It does not
 * expose routes, mint tokens, or decide who is authenticated: a caller that
 * knows the account id drives these functions. No private key and no plaintext
 * pairing code ever reaches this layer's storage.
 */

/** 24 random bytes = 32 base64url characters, for codes and assertion nonces. */
const TOKEN_BYTES = 24;

/**
 * The only audience a device challenge may be issued for.
 *
 * The HTTP layer sets this itself; a client never chooses the audience it signs.
 */
export const TOKEN_API_AUDIENCE = 'jarvis-token-api-v1';

/** Defaults a caller can override; the expiry/attempt caps match the schema. */
export const DEFAULT_PAIRING_TTL_SECONDS = 600;
export const DEFAULT_MAX_PAIRING_ATTEMPTS = 10;
export const DEFAULT_ASSERTION_MAX_AGE_MS = 60_000;
export const DEFAULT_ASSERTION_FUTURE_SKEW_MS = 2_000;

/** Challenges are short-lived: a captured assertion must not stay useful. */
export const DEFAULT_CHALLENGE_TTL_SECONDS = 120;
const MAX_CHALLENGE_TTL_SECONDS = 600;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEX_64_PATTERN = /^[0-9a-f]{64}$/;
const BASE64URL_32_PATTERN = /^[A-Za-z0-9_-]{32}$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
const PLATFORMS = ['android', 'ios', 'windows', 'macos', 'linux', 'web'] as const;

export type DevicePlatform = (typeof PLATFORMS)[number];

/** Bad caller input. Messages are generic: no key material or codes are echoed. */
export class PairingValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PairingValidationError';
  }
}

/** A code that has been issued. `code` is shown to the user exactly once. */
export type IssuedPairingCode = {
  readonly code: string;
  readonly codeHash: string;
  readonly userId: string;
  readonly expiresAt: Date;
};

export type IssuePairingCodeOptions = {
  /** Account the code belongs to. Defaults to the single seeded account. */
  readonly userId?: string;
  readonly ttlSeconds?: number;
};

type RedeemFailureStatus =
  | 'invalid'
  | 'used'
  | 'expired'
  | 'exhausted'
  | 'device_exists'
  | 'credential_exists';

/** Outcome of an atomic redemption attempt. */
export type RedeemResult =
  | {
      readonly status: 'redeemed';
      readonly userId: string;
      readonly deviceId: string;
      readonly credentialId: string;
    }
  | { readonly status: RedeemFailureStatus };

export type RedeemDeviceInput = {
  readonly code: string;
  /** Expected account. A code belonging to another account is never redeemed. */
  readonly userId?: string;
  readonly deviceId: string;
  readonly publicKey: string;
  readonly fingerprint: string;
  readonly platform: DevicePlatform;
  readonly label: string;
  readonly maxAttempts?: number;
};

/** Outcome of a standalone device registration. */
export type RegisterResult =
  | {
      readonly status: 'registered';
      readonly userId: string;
      readonly deviceId: string;
      readonly credentialId: string;
    }
  | { readonly status: 'device_exists' | 'credential_exists' };

export type RegisterDeviceInput = {
  readonly userId: string;
  readonly deviceId: string;
  readonly publicKey: string;
  readonly fingerprint: string;
  readonly platform: DevicePlatform;
  readonly label: string;
};

/** Exact bytes a device signs. Kept here so a future client can reproduce them. */
export type AssertionPayload = {
  readonly deviceId: string;
  readonly nonce: string;
  readonly issuedAtMs: number;
  /** Server-owned API audience; the signature binds the assertion to one API. */
  readonly audience: string;
};

/** A challenge handed to one device. Only `challenge` ever leaves the server. */
export type IssuedChallenge = {
  readonly challenge: string;
  readonly nonceHash: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly audience: string;
  readonly expiresAt: Date;
};

export type IssueChallengeInput = {
  readonly deviceId: string;
  /** Account the device belongs to. Defaults to the single seeded account. */
  readonly userId?: string;
  readonly audience?: string;
  readonly ttlSeconds?: number;
};

export type ChallengeResult =
  | { readonly status: 'consumed'; readonly userId: string; readonly deviceId: string }
  | {
      readonly status:
        | 'invalid'
        | 'wrong_device'
        | 'wrong_audience'
        | 'used'
        | 'expired'
        | 'unknown_device';
    };

export type ConsumeChallengeInput = {
  readonly nonce: string;
  readonly deviceId: string;
  readonly userId?: string;
  readonly audience?: string;
};

export type VerifyAssertionInput = AssertionPayload & {
  /** Base64 DER ECDSA signature (the default of Android's SHA256withECDSA). */
  readonly signature: string;
  readonly userId?: string;
};

export type VerifyAssertionOptions = {
  readonly now?: () => number;
  readonly maxAgeMs?: number;
  readonly futureSkewMs?: number;
};

export type AssertionResult =
  | {
      readonly verified: true;
      readonly userId: string;
      readonly deviceId: string;
      readonly credentialId: string;
    }
  | {
      readonly verified: false;
      readonly reason:
        | 'expired'
        | 'unknown_device'
        | 'credential_invalid'
        | 'bad_signature'
        | 'replayed';
    };

/** SHA-256 hex of a code or DER key. No algorithm agility here by design. */
export function sha256Hex(value: string | Buffer): string {
  return createHash('sha256').update(value).digest('hex');
}

/** Fresh random one-time code. Returned to the caller, never stored as-is. */
export function createPairingCode(): string {
  return randomBytes(TOKEN_BYTES).toString('base64url');
}

/** Fresh random challenge for an assertion. A future route hands this to a device. */
export function createAssertionNonce(): string {
  return randomBytes(TOKEN_BYTES).toString('base64url');
}

/**
 * Versioned, newline-delimited payload signed by the device. No trailing
 * newline; fields are the lowercased device UUID, the challenge nonce, the
 * issue time as an integer number of milliseconds since the epoch, and the
 * server-owned audience. Binding the audience stops a signature for one API
 * being replayed against another.
 */
export function assertionPayload(payload: AssertionPayload): Buffer {
  return Buffer.from(
    [
      'jarvis-device-assertion-v1',
      payload.deviceId.toLowerCase(),
      payload.nonce,
      String(payload.issuedAtMs),
      payload.audience,
    ].join('\n'),
    'utf8'
  );
}

/** Resolves the account, using the single seeded account unless one is given. */
export async function resolveAccountId(db: Database, userId?: string): Promise<string> {
  if (userId !== undefined) {
    assertUuid(userId, 'userId');
    return userId;
  }
  const row = await db.queryRow<{ id: string }>('select jarvis.seed_initial_user() as id');
  if (!row || !UUID_PATTERN.test(row.id)) {
    throw new PairingValidationError('The account could not be resolved.');
  }
  return row.id;
}

/**
 * Issues a short-lived challenge for a trusted device.
 *
 * The composite foreign key proves the device belongs to the account, and the
 * `insert ... select` only produces a row for a trusted device with one active
 * ES256 credential. Only the SHA-256 digest is stored; the plaintext is returned
 * to the caller exactly once.
 */
export async function issueDeviceChallenge(
  db: Database,
  input: IssueChallengeInput
): Promise<IssuedChallenge> {
  assertUuid(input.deviceId, 'deviceId');
  const ttlSeconds = input.ttlSeconds ?? DEFAULT_CHALLENGE_TTL_SECONDS;
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 1 || ttlSeconds > MAX_CHALLENGE_TTL_SECONDS) {
    throw new PairingValidationError('The challenge lifetime is out of range.');
  }
  assertAudience(input.audience ?? TOKEN_API_AUDIENCE);

  const userId = await resolveAccountId(db, input.userId);
  const challenge = createAssertionNonce();
  const nonceHash = sha256Hex(challenge);
  const audience = input.audience ?? TOKEN_API_AUDIENCE;

  const row = await db.queryRow<{
    id: string;
    user_id: string;
    device_id: string;
    expires_at: Date | string;
  }>(
    `insert into jarvis.device_challenges (user_id, device_id, nonce_hash, audience, expires_at)
     select d.user_id, d.id, $3, $4, now() + make_interval(secs => $5)
       from jarvis.devices d
      where d.id = $2::uuid
        and d.user_id = $1::uuid
        and d.status = 'trusted'
        and exists (
            select 1 from jarvis.device_credentials c
             where c.device_id = d.id
               and c.user_id = d.user_id
               and c.retired_at is null
               and c.algorithm = 'ES256'
        )
     returning id, user_id, device_id, expires_at`,
    [userId, input.deviceId, nonceHash, audience, ttlSeconds]
  );
  if (!row) throw new PairingValidationError('The trusted device is unavailable.');

  const expiresAt = row.expires_at instanceof Date ? row.expires_at : new Date(row.expires_at);
  return {
    challenge,
    nonceHash,
    userId: row.user_id,
    deviceId: row.device_id,
    audience,
    expiresAt,
  };
}

/**
 * Consumes a challenge exactly once.
 *
 * One locking statement reads the challenge, checks the account, device,
 * audience, expiry and consumed flag from that one snapshot, and conditionally
 * sets `consumed_at`. A concurrent submission waits on the row lock and then
 * sees the consumed flag, so at most one caller can succeed.
 */
export async function consumeDeviceChallenge(
  db: Database,
  input: ConsumeChallengeInput
): Promise<ChallengeResult> {
  assertCode(input.nonce, BASE64URL_32_PATTERN, 'nonce');
  assertUuid(input.deviceId, 'deviceId');
  const audience = input.audience ?? TOKEN_API_AUDIENCE;
  assertAudience(audience);

  const userId = await resolveAccountId(db, input.userId);
  const row = await db.queryRow<{ outcome: string; consumed_id: string | null }>(CONSUME_SQL, [
    userId,
    input.deviceId,
    sha256Hex(input.nonce),
    audience,
  ]);

  const outcome = row?.outcome ?? 'invalid';
  // A winner that lost the conditional UPDATE after a lock wait is a replay.
  if (outcome === 'ok') {
    if (!row?.consumed_id) return { status: 'used' };
    return { status: 'consumed', userId, deviceId: input.deviceId };
  }
  return { status: outcome as Exclude<ChallengeResult['status'], 'consumed'> };
}

const CONSUME_SQL = `
with input as (
    select $1::uuid as user_id, $2::uuid as device_id, $3::text as nonce_hash, $4::text as audience
),
locked as (
    select dc.id, dc.user_id, dc.device_id, dc.audience, dc.expires_at, dc.consumed_at
      from jarvis.device_challenges dc
      join input i on i.nonce_hash = dc.nonce_hash
      for update of dc
),
device as (
    select d.id
      from jarvis.devices d
     where d.id = (select device_id from input)
       and d.user_id = (select user_id from input)
       and d.status = 'trusted'
       and exists (
           select 1 from jarvis.device_credentials c
            where c.device_id = d.id
              and c.user_id = d.user_id
              and c.retired_at is null
              and c.algorithm = 'ES256'
       )
),
decision as (
    select
        case
            when l.id is null then 'invalid'
            when l.user_id <> (select user_id from input)
              or l.device_id <> (select device_id from input) then 'wrong_device'
            when l.audience <> (select audience from input) then 'wrong_audience'
            when l.consumed_at is not null then 'used'
            when l.expires_at <= now() then 'expired'
            when not exists (select 1 from device) then 'unknown_device'
            else 'ok'
        end as outcome,
        l.id as challenge_id
      from input
      left join locked l on true
),
consumed as (
    update jarvis.device_challenges dc
       set consumed_at = now()
      from decision d
     where dc.id = d.challenge_id
       and d.outcome = 'ok'
    returning dc.id
)
select d.outcome as outcome, (select id from consumed) as consumed_id
  from decision d
`;

/** Issues a code and stores only its hash. The plaintext is returned once. */
export async function issuePairingCode(
  db: Database,
  options: IssuePairingCodeOptions = {}
): Promise<IssuedPairingCode> {
  const ttlSeconds = options.ttlSeconds ?? DEFAULT_PAIRING_TTL_SECONDS;
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 1 || ttlSeconds > 86_400) {
    throw new PairingValidationError('The pairing code lifetime is out of range.');
  }

  const userId = await resolveAccountId(db, options.userId);
  const code = createPairingCode();
  const codeHash = sha256Hex(code);

  const row = await db.queryRow<{ id: string; user_id: string; expires_at: Date | string }>(
    `insert into jarvis.pairing_codes (user_id, code_hash, expires_at)
     select $1::uuid, $2, now() + make_interval(secs => $3)
     returning id, user_id, expires_at`,
    [userId, codeHash, ttlSeconds]
  );
  if (!row) throw new PairingValidationError('The pairing code could not be issued.');

  const expiresAt = row.expires_at instanceof Date ? row.expires_at : new Date(row.expires_at);
  return { code, codeHash, userId: row.user_id, expiresAt };
}

/**
 * Redeems a code and registers the device and its credential atomically.
 *
 * A single data-modifying CTE locks the code row (`FOR UPDATE`), decides the
 * outcome from that one snapshot, increments the attempt counter for every
 * still-live attempt, and only on success inserts the device/credential and
 * marks the code used. There is no transaction API in `Database`, so this one
 * statement is what makes redemption all-or-nothing under concurrency.
 */
export async function redeemPairingCode(
  db: Database,
  input: RedeemDeviceInput
): Promise<RedeemResult> {
  const maxAttempts = input.maxAttempts ?? DEFAULT_MAX_PAIRING_ATTEMPTS;
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 1000) {
    throw new PairingValidationError('The attempt limit is out of range.');
  }
  assertCode(input.code);
  assertUuid(input.deviceId, 'deviceId');
  assertLabel(input.label);
  assertPlatform(input.platform);
  const { fingerprint } = parseEs256PublicKey(input.publicKey, input.fingerprint);

  const userId = await resolveAccountId(db, input.userId);

  try {
    const row = await db.queryRow<{
      outcome: string;
      user_id: string;
      credential_id: string | null;
    }>(REDEEM_SQL, [
      sha256Hex(input.code),
      userId,
      maxAttempts,
      input.deviceId,
      input.label,
      input.platform,
      input.publicKey,
      fingerprint,
    ]);

    if (!row) return { status: 'invalid' };
    if (row.outcome !== 'ok') return { status: row.outcome as RedeemFailureStatus };
    if (!row.credential_id) return { status: 'invalid' };

    return {
      status: 'redeemed',
      userId: row.user_id,
      deviceId: input.deviceId,
      credentialId: row.credential_id,
    };
  } catch (error) {
    const conflict = conflictOutcome(error);
    if (conflict) return { status: conflict };
    throw error;
  }
}

const REDEEM_SQL = `
with input as (
    select $1::text as code_hash
),
locked as (
    select pc.id, pc.user_id, pc.attempts, pc.used_at, pc.expires_at
      from jarvis.pairing_codes pc
      join input i on i.code_hash = pc.code_hash
      for update of pc
),
decision as (
    select
        case
            when l.id is null then 'invalid'
            when l.user_id <> $2::uuid then 'invalid'
            when l.used_at is not null then 'used'
            when l.expires_at <= now() then 'expired'
            when l.attempts >= $3 then 'exhausted'
            when exists (select 1 from jarvis.devices d where d.id = $4::uuid) then 'device_exists'
            when exists (select 1 from jarvis.device_credentials c where c.key_fingerprint = $8) then 'credential_exists'
            else 'ok'
        end as outcome,
        l.id as code_id,
        l.user_id
      from input
      left join locked l on true
),
redeemable as (
    select code_id, user_id, outcome
      from decision
     where outcome in ('ok', 'device_exists', 'credential_exists')
),
new_device as (
    insert into jarvis.devices (id, user_id, label, platform, status, paired_at)
    select $4::uuid, r.user_id, $5, $6, 'trusted', now()
      from redeemable r
     where r.outcome = 'ok'
    returning id, user_id
),
new_credential as (
    insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key, algorithm)
    select nd.id, nd.user_id, $8, $7, 'ES256'
      from new_device nd
    returning id, device_id, user_id
),
updated_code as (
    update jarvis.pairing_codes pc
       set attempts = pc.attempts + 1,
           used_at = case when (select id from new_credential) is not null then now() else pc.used_at end,
           consumed_by_device_id = coalesce(
               (select device_id from new_credential), pc.consumed_by_device_id
           )
      from redeemable r
     where pc.id = r.code_id
    returning pc.id
)
select
    d.outcome as outcome,
    d.user_id as user_id,
    (select id from new_credential) as credential_id
  from decision d
`;

/** Registers a device and its one active ES256 credential in one statement. */
export async function registerDevice(
  db: Database,
  input: RegisterDeviceInput
): Promise<RegisterResult> {
  assertUuid(input.userId, 'userId');
  assertUuid(input.deviceId, 'deviceId');
  assertLabel(input.label);
  assertPlatform(input.platform);
  const { fingerprint } = parseEs256PublicKey(input.publicKey, input.fingerprint);

  try {
    const row = await db.queryRow<{ credential_id: string; device_id: string; user_id: string }>(
      `with new_device as (
           insert into jarvis.devices (id, user_id, label, platform, status, paired_at)
           values ($1::uuid, $2::uuid, $3, $4, 'trusted', now())
           returning id, user_id
       ),
       new_credential as (
           insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key, algorithm)
           select nd.id, nd.user_id, $5, $6, 'ES256'
             from new_device nd
           returning id, device_id, user_id
       )
       select nc.id as credential_id, nc.device_id, nc.user_id
         from new_credential nc`,
      [input.deviceId, input.userId, input.label, input.platform, fingerprint, input.publicKey]
    );
    if (!row) return { status: 'credential_exists' };
    return {
      status: 'registered',
      userId: row.user_id,
      deviceId: row.device_id,
      credentialId: row.credential_id,
    };
  } catch (error) {
    const conflict = conflictOutcome(error);
    if (conflict) return { status: conflict };
    throw error;
  }
}

/**
 * Verifies a signed assertion and atomically consumes its nonce window.
 *
 * Freshness (`issuedAtMs`) bounds how old a captured assertion may be, and the
 * monotonic `last_seen_at` update is the replay guard: a timestamp that is not
 * strictly newer than the last accepted one cannot update the row, so the same
 * signature can never be accepted twice. The row lock in that UPDATE serialises
 * concurrent replays.
 */
export async function verifyDeviceAssertion(
  db: Database,
  input: VerifyAssertionInput,
  options: VerifyAssertionOptions = {}
): Promise<AssertionResult> {
  assertUuid(input.deviceId, 'deviceId');
  assertCode(input.nonce, BASE64URL_32_PATTERN, 'nonce');
  if (!Number.isSafeInteger(input.issuedAtMs)) {
    throw new PairingValidationError('The assertion timestamp is invalid.');
  }
  assertCode(input.signature, BASE64_PATTERN, 'signature');
  const signature = Buffer.from(input.signature, 'base64');
  if (signature.length < 8 || signature.length > 256) {
    throw new PairingValidationError('The assertion signature is malformed.');
  }

  const maxAgeMs = options.maxAgeMs ?? DEFAULT_ASSERTION_MAX_AGE_MS;
  const futureSkewMs = options.futureSkewMs ?? DEFAULT_ASSERTION_FUTURE_SKEW_MS;
  const nowMs = (options.now ?? Date.now)();
  if (!Number.isFinite(maxAgeMs) || !Number.isFinite(futureSkewMs)) {
    throw new PairingValidationError('The assertion freshness window is invalid.');
  }
  if (input.issuedAtMs > nowMs + futureSkewMs || nowMs - input.issuedAtMs > maxAgeMs) {
    return { verified: false, reason: 'expired' };
  }

  const userId = await resolveAccountId(db, input.userId);
  const credential = await db.queryRow<{
    credential_id: string;
    public_key: string;
    key_fingerprint: string;
    algorithm: string;
  }>(
    `select c.id as credential_id, c.public_key, c.key_fingerprint, c.algorithm
       from jarvis.device_credentials c
       join jarvis.devices d on d.id = c.device_id and d.user_id = c.user_id
      where c.device_id = $1::uuid
        and c.user_id = $2::uuid
        and c.retired_at is null
        and d.status = 'trusted'`,
    [input.deviceId, userId]
  );
  if (!credential || credential.algorithm !== 'ES256') {
    return { verified: false, reason: 'unknown_device' };
  }

  // A stored key must still be the ES256 SPKI its fingerprint describes.
  let storedKey: ParsedPublicKey;
  try {
    storedKey = parseEs256PublicKey(credential.public_key, credential.key_fingerprint);
  } catch {
    return { verified: false, reason: 'credential_invalid' };
  }

  let signatureValid: boolean;
  try {
    signatureValid = verifySignature('sha256', assertionPayload(input), storedKey.key, signature);
  } catch {
    return { verified: false, reason: 'bad_signature' };
  }
  if (!signatureValid) return { verified: false, reason: 'bad_signature' };

  const consumed = await db.queryRow<{ id: string }>(
    `update jarvis.devices
        set last_seen_at = to_timestamp($3::bigint / 1000.0)
      where id = $1::uuid
        and user_id = $2::uuid
        and status = 'trusted'
        and (last_seen_at is null or last_seen_at < to_timestamp($3::bigint / 1000.0))
      returning id`,
    [input.deviceId, userId, String(input.issuedAtMs)]
  );
  if (!consumed) return { verified: false, reason: 'replayed' };

  return {
    verified: true,
    userId,
    deviceId: input.deviceId,
    credentialId: credential.credential_id,
  };
}

type ParsedPublicKey = {
  readonly key: KeyObject;
  readonly der: Buffer;
  readonly fingerprint: string;
};

/**
 * Parses the public format produced by S5.1: base64 of DER X.509
 * SubjectPublicKeyInfo for an EC P-256 key. Rejects other encodings and curves.
 * The fingerprint is recomputed from the DER and must match the supplied one.
 */
function parseEs256PublicKey(publicKey: string, expectedFingerprint: string): ParsedPublicKey {
  if (typeof publicKey !== 'string' || publicKey.length < 16 || publicKey.length > 4096) {
    throw new PairingValidationError('The public key is malformed.');
  }
  if (publicKey.length % 4 !== 0 || !BASE64_PATTERN.test(publicKey)) {
    throw new PairingValidationError('The public key is not valid base64.');
  }
  assertCode(expectedFingerprint, HEX_64_PATTERN, 'fingerprint');

  const der = Buffer.from(publicKey, 'base64');
  if (der.toString('base64') !== publicKey) {
    throw new PairingValidationError('The public key is not canonical base64.');
  }

  let key: KeyObject;
  try {
    key = createPublicKey({ key: der, format: 'der', type: 'spki' });
  } catch {
    throw new PairingValidationError('The public key is not DER SubjectPublicKeyInfo.');
  }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw new PairingValidationError('The public key must be an EC P-256 key.');
  }
  // Android emits canonical SPKI; reject a DER that only parses after re-encoding.
  const canonical = key.export({ format: 'der', type: 'spki' }) as Buffer;
  if (!canonical.equals(der)) {
    throw new PairingValidationError('The public key DER is not canonical.');
  }

  const fingerprint = sha256Hex(der);
  if (fingerprint !== expectedFingerprint) {
    throw new PairingValidationError('The public key fingerprint does not match.');
  }
  return { key, der, fingerprint };
}

function assertUuid(value: string, field: string): void {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw new PairingValidationError(`The ${field} is not a valid UUID.`);
  }
}

function assertCode(value: string, pattern: RegExp = BASE64URL_32_PATTERN, field = 'code'): void {
  if (typeof value !== 'string' || value.length < 1 || value.length > 512 || !pattern.test(value)) {
    throw new PairingValidationError(`The ${field} is malformed.`);
  }
}

function assertLabel(label: string): void {
  const length = typeof label === 'string' ? label.trim().length : 0;
  if (length < 1 || length > 80) {
    throw new PairingValidationError('The device label is out of range.');
  }
}

function assertPlatform(platform: string): void {
  if (!PLATFORMS.includes(platform as DevicePlatform)) {
    throw new PairingValidationError('The device platform is unknown.');
  }
}

/** Audiences are short server-owned identifiers, never free-form client input. */
function assertAudience(audience: string): void {
  if (
    typeof audience !== 'string' ||
    !/^[A-Za-z0-9_.:-]{1,64}$/.test(audience) ||
    audience !== TOKEN_API_AUDIENCE
  ) {
    throw new PairingValidationError('The challenge audience is unknown.');
  }
}

type ConflictStatus = 'device_exists' | 'credential_exists';

/** Maps the schema's unique violations to a caller-safe conflict. */
function conflictOutcome(error: unknown): ConflictStatus | null {
  if (!(error instanceof DatabaseQueryError)) return null;
  if (error.constraint === 'devices_pkey' || error.constraint === 'devices_id_user_unique') {
    return 'device_exists';
  }
  if (
    error.constraint === 'device_credentials_fingerprint_unique' ||
    error.constraint === 'device_credentials_one_active_per_device'
  ) {
    return 'credential_exists';
  }
  return null;
}
