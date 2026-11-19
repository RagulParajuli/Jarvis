import { RoomConfiguration } from 'livekit-server-sdk';

/**
 * One answer for both a missing and an incorrect access code.
 *
 * Telling the two apart lets an attacker learn whether a code was ever
 * configured, so both cases return the same body and status.
 */
export const AUTH_REJECTED_MESSAGE = 'Access code is missing or incorrect.';

/** The server is missing its own configuration; this is not the caller's fault. */
export const AUTH_UNAVAILABLE_MESSAGE = 'Token service is not configured.';

export const RATE_LIMITED_MESSAGE = 'Too many failed attempts. Try again later.';

/** Deliberately generic: validation details are not echoed back. */
export const INVALID_REQUEST_MESSAGE = 'Invalid token request.';

/** Short-lived by default so a leaked token cannot be replayed for long. */
export const DEFAULT_TOKEN_TTL_SECONDS = 15 * 60;
const MIN_TOKEN_TTL_SECONDS = 60;
const MAX_TOKEN_TTL_SECONDS = 6 * 60 * 60;

/** Dispatch name used by `src/agent.py` and the Flutter default. */
const DEFAULT_AGENT_NAME = 'my-agent';

const MIN_RATE_LIMIT_WINDOW_SECONDS = 60;
const MAX_RATE_LIMIT_WINDOW_SECONDS = 24 * 60 * 60;
const DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 15 * 60;
const MIN_RATE_LIMIT_FAILURES = 1;
const MAX_RATE_LIMIT_FAILURES = 100;
const DEFAULT_RATE_LIMIT_FAILURES = 10;

const PARTICIPANT_NAME_MAX_LENGTH = 128;
const PARTICIPANT_METADATA_MAX_LENGTH = 2048;
const PARTICIPANT_ATTRIBUTES_MAX = 16;
const ATTRIBUTE_VALUE_MAX_LENGTH = 256;
const AGENT_METADATA_MAX_LENGTH = 1024;

const ROOM_NAME_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const PARTICIPANT_IDENTITY_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;
const ATTRIBUTE_KEY_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

/** Server-owned settings, read from the environment for every request. */
export type TokenPolicy = {
  readonly livekitUrl?: string;
  readonly apiKey?: string;
  readonly apiSecret?: string;
  /** The access code the token endpoint requires. Never leave this in a log. */
  readonly accessCode?: string;
  /** Disables access-code authentication entirely. Unsafe; default off. */
  readonly allowPublicToken: boolean;
  /** The only agent a client may ask the token to dispatch. */
  readonly agentName: string;
  readonly tokenTtlSeconds: number;
  readonly rateLimitWindowSeconds: number;
  readonly rateLimitMaxFailures: number;
};

export type TokenPolicyEnv = Record<string, string | undefined>;

/**
 * Reads the token endpoint's configuration.
 *
 * Invalid numbers fall back to the safe default rather than failing open, and
 * `ALLOW_PUBLIC_TOKEN` is only ever enabled by the exact string `true`.
 */
export function loadTokenPolicy(env: TokenPolicyEnv = process.env): TokenPolicy {
  return {
    livekitUrl: nonEmpty(env.LIVEKIT_URL),
    apiKey: nonEmpty(env.LIVEKIT_API_KEY),
    apiSecret: nonEmpty(env.LIVEKIT_API_SECRET),
    accessCode: nonEmpty(env.JARVIS_ACCESS_CODE),
    allowPublicToken: env.ALLOW_PUBLIC_TOKEN === 'true',
    agentName: nonEmpty(env.AGENT_NAME) ?? DEFAULT_AGENT_NAME,
    tokenTtlSeconds: resolveTokenTtlSeconds(env.LIVEKIT_TOKEN_TTL),
    rateLimitWindowSeconds: boundedInteger(
      env.AUTH_RATE_LIMIT_WINDOW_SECONDS,
      DEFAULT_RATE_LIMIT_WINDOW_SECONDS,
      MIN_RATE_LIMIT_WINDOW_SECONDS,
      MAX_RATE_LIMIT_WINDOW_SECONDS
    ),
    rateLimitMaxFailures: boundedInteger(
      env.AUTH_RATE_LIMIT_MAX_FAILURES,
      DEFAULT_RATE_LIMIT_FAILURES,
      MIN_RATE_LIMIT_FAILURES,
      MAX_RATE_LIMIT_FAILURES
    ),
  };
}

/**
 * Parses `LIVEKIT_TOKEN_TTL` (`15m`, `900s`, `1h`) into seconds.
 *
 * Anything missing, malformed, shorter than a minute or longer than six hours
 * resolves to the 15 minute default. Falling back to the short TTL means a typo
 * can never mint a long-lived token.
 */
export function resolveTokenTtlSeconds(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_TOKEN_TTL_SECONDS;

  const match = /^(\d{1,6})\s*([smh])$/i.exec(raw.trim());
  if (!match) return DEFAULT_TOKEN_TTL_SECONDS;

  const amount = Number(match[1]);
  const unit = match[2].toLowerCase();
  const seconds = unit === 'h' ? amount * 3600 : unit === 'm' ? amount * 60 : amount;
  if (!Number.isInteger(seconds)) return DEFAULT_TOKEN_TTL_SECONDS;
  if (seconds < MIN_TOKEN_TTL_SECONDS || seconds > MAX_TOKEN_TTL_SECONDS) {
    return DEFAULT_TOKEN_TTL_SECONDS;
  }
  return seconds;
}

/** Input that is well-formed enough to mint a token from. */
export type ParsedTokenRequest = {
  readonly roomName: string;
  readonly participantName: string;
  readonly participantIdentity: string;
  readonly participantMetadata?: string;
  readonly participantAttributes?: Record<string, string>;
  readonly roomConfig?: RoomConfiguration;
};

/** Thrown for anything the caller could have gotten right; maps to HTTP 400. */
export class TokenRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TokenRequestError';
  }
}

/**
 * Validates the client-controlled parts of the request body.
 *
 * Every value is rebuilt from primitives with the server's own rules, so a
 * client cannot smuggle extra room settings, another agent, or an oversized
 * payload into the token.
 */
export function parseTokenRequest(body: unknown, agentName: string): ParsedTokenRequest {
  if (!isRecord(body)) throw new TokenRequestError('Body must be a JSON object.');

  const roomName = parseRoomName(body.room_name);
  const participantName = parseParticipantName(body.participant_name);
  const participantIdentity = parseParticipantIdentity(body.participant_identity);
  const participantMetadata = parseParticipantMetadata(body.participant_metadata);
  const participantAttributes = parseParticipantAttributes(body.participant_attributes);
  const roomConfig = parseRoomConfig(body.room_config, agentName);

  return {
    roomName,
    participantName,
    participantIdentity,
    ...(participantMetadata !== undefined && { participantMetadata }),
    ...(participantAttributes !== undefined && { participantAttributes }),
    ...(roomConfig !== undefined && { roomConfig }),
  };
}

function parseRoomName(value: unknown): string {
  if (value === undefined) return `jarvis_${crypto.randomUUID()}`;
  if (typeof value !== 'string' || !ROOM_NAME_PATTERN.test(value)) {
    throw new TokenRequestError('room_name must be 1-128 letters, digits, "-" or "_".');
  }
  return value;
}

function parseParticipantName(value: unknown): string {
  if (value === undefined) return 'user';
  if (typeof value !== 'string') throw new TokenRequestError('participant_name must be a string.');

  const name = value.trim();
  if (name.length === 0) return 'user';
  if (name.length > PARTICIPANT_NAME_MAX_LENGTH || CONTROL_CHARACTERS.test(name)) {
    throw new TokenRequestError('participant_name is too long or contains control characters.');
  }
  return name;
}

function parseParticipantIdentity(value: unknown): string {
  if (value === undefined) return `jarvis_user_${crypto.randomUUID()}`;
  if (typeof value !== 'string' || !PARTICIPANT_IDENTITY_PATTERN.test(value)) {
    throw new TokenRequestError(
      'participant_identity must be 1-64 letters, digits, ".", ":", "-" or "_".'
    );
  }
  return value;
}

function parseParticipantMetadata(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || value.length > PARTICIPANT_METADATA_MAX_LENGTH) {
    throw new TokenRequestError(
      'participant_metadata must be a string of at most 2048 characters.'
    );
  }
  if (value.length === 0) return undefined;

  // The agent parses this as an object, so anything else would be dropped there.
  let decoded: unknown;
  try {
    decoded = JSON.parse(value);
  } catch {
    throw new TokenRequestError('participant_metadata must be valid JSON.');
  }
  if (!isRecord(decoded))
    throw new TokenRequestError('participant_metadata must be a JSON object.');
  return value;
}

function parseParticipantAttributes(value: unknown): Record<string, string> | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new TokenRequestError('participant_attributes must be an object.');

  const entries = Object.entries(value);
  if (entries.length > PARTICIPANT_ATTRIBUTES_MAX) {
    throw new TokenRequestError('participant_attributes has too many entries.');
  }

  const attributes: Record<string, string> = {};
  for (const [key, entry] of entries) {
    if (!ATTRIBUTE_KEY_PATTERN.test(key) || key === '__proto__') {
      throw new TokenRequestError('participant_attributes contains an invalid key.');
    }
    if (typeof entry !== 'string' || entry.length > ATTRIBUTE_VALUE_MAX_LENGTH) {
      throw new TokenRequestError('participant_attributes values must be short strings.');
    }
    attributes[key] = entry;
  }
  return attributes;
}

/**
 * Rebuilds the room configuration from an allowlist.
 *
 * Only a single agent dispatch, and only for this deployment's agent, survives.
 * A caller therefore cannot pick another agent, another deployment, or room
 * limits that affect everyone else in the room.
 */
function parseRoomConfig(value: unknown, agentName: string): RoomConfiguration | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new TokenRequestError('room_config must be an object.');

  const unsupported = Object.keys(value).filter((key) => key !== 'agents');
  if (unsupported.length > 0)
    throw new TokenRequestError('room_config contains unsupported fields.');

  const agents = value.agents;
  if (agents === undefined) return undefined;
  if (!Array.isArray(agents)) throw new TokenRequestError('room_config.agents must be an array.');
  if (agents.length > 1) throw new TokenRequestError('Only one agent may be dispatched.');
  if (agents.length === 0) return undefined;

  const agent = agents[0];
  if (!isRecord(agent)) throw new TokenRequestError('room_config.agents entries must be objects.');

  const agentUnsupported = Object.keys(agent).filter(
    (key) => key !== 'agent_name' && key !== 'metadata'
  );
  if (agentUnsupported.length > 0) {
    throw new TokenRequestError('room_config.agents contains unsupported fields.');
  }

  if (agent.agent_name !== agentName) {
    throw new TokenRequestError('room_config requests an agent this endpoint does not serve.');
  }

  const metadata = agent.metadata;
  if (
    metadata !== undefined &&
    (typeof metadata !== 'string' || metadata.length > AGENT_METADATA_MAX_LENGTH)
  ) {
    throw new TokenRequestError('room_config.agents metadata must be a short string.');
  }

  return RoomConfiguration.fromJson(
    {
      agents: [
        {
          agent_name: agentName,
          ...(typeof metadata === 'string' && metadata.length > 0 && { metadata }),
        },
      ],
    },
    { ignoreUnknownFields: false }
  );
}

function nonEmpty(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function boundedInteger(
  raw: string | undefined,
  fallback: number,
  min: number,
  max: number
): number {
  if (raw === undefined || raw.trim().length === 0) return fallback;
  const value = Number(raw);
  return Number.isInteger(value) && value >= min && value <= max ? value : fallback;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
