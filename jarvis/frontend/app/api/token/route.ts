import {
  AccessToken,
  type AccessTokenOptions,
  RoomConfiguration,
  type VideoGrant,
} from 'livekit-server-sdk';
import { NextResponse } from 'next/server';
import { timingSafeEqual } from 'node:crypto';

type ConnectionDetails = {
  server_url: string;
  room_name: string;
  participant_name: string;
  participant_token: string;
};

// NOTE: you are expected to define the following environment variables in `.env.local`:
const API_KEY = process.env.LIVEKIT_API_KEY;
const API_SECRET = process.env.LIVEKIT_API_SECRET;
const LIVEKIT_URL = process.env.LIVEKIT_URL;

// don't cache the results
export const revalidate = 0;

export async function POST(req: Request) {
  const allowPublicToken = process.env.ALLOW_PUBLIC_TOKEN === 'true';
  if (!allowPublicToken) {
    const expectedAccessCode = process.env.JARVIS_ACCESS_CODE;
    if (!expectedAccessCode) {
      return NextResponse.json(
        { error: 'Token service is not configured. Set JARVIS_ACCESS_CODE or ALLOW_PUBLIC_TOKEN=true.' },
        { status: 503, headers: { 'Cache-Control': 'no-store' } }
      );
    }

    const suppliedAccessCode = req.headers.get('X-Jarvis-Access-Code');
    const expectedBuffer = Buffer.from(expectedAccessCode);
    const suppliedBuffer = Buffer.from(suppliedAccessCode ?? '');
    if (
      !suppliedAccessCode ||
      expectedBuffer.length !== suppliedBuffer.length ||
      !timingSafeEqual(expectedBuffer, suppliedBuffer)
    ) {
      return NextResponse.json(
        { error: suppliedAccessCode ? 'Access code is incorrect.' : 'Access code is required.' },
        { status: 401, headers: { 'Cache-Control': 'no-store' } }
      );
    }
  }

  try {
    if (LIVEKIT_URL === undefined) {
      throw new Error('LIVEKIT_URL is not defined');
    }
    if (API_KEY === undefined) {
      throw new Error('LIVEKIT_API_KEY is not defined');
    }
    if (API_SECRET === undefined) {
      throw new Error('LIVEKIT_API_SECRET is not defined');
    }

    // Parse room config from request body.
    const body = await req.json();
    const roomConfig = body?.room_config
      ? RoomConfiguration.fromJson(body.room_config, { ignoreUnknownFields: true })
      : new RoomConfiguration();

    const roomName =
      typeof body?.room_name === 'string' && body.room_name.trim()
        ? body.room_name.trim()
        : `jarvis_${crypto.randomUUID()}`;
    const participantName =
      typeof body?.participant_name === 'string' && body.participant_name.trim()
        ? body.participant_name.trim()
        : 'user';
    const participantIdentity =
      typeof body?.participant_identity === 'string' && body.participant_identity.trim()
        ? body.participant_identity.trim()
        : `jarvis_user_${crypto.randomUUID()}`;

    const participantToken = await createParticipantToken(
      {
        identity: participantIdentity,
        name: participantName,
        ...(typeof body?.participant_metadata === 'string' && {
          metadata: body.participant_metadata,
        }),
        ...(body?.participant_attributes && { attributes: body.participant_attributes }),
      },
      roomName,
      roomConfig
    );

    // Return connection details
    const data: ConnectionDetails = {
      server_url: LIVEKIT_URL,
      room_name: roomName,
      participant_name: participantName,
      participant_token: participantToken,
    };
    const headers = new Headers({
      'Cache-Control': 'no-store',
    });
    return NextResponse.json(data, { headers });
  } catch (error) {
    console.error('Token generation failed:', error);
    return NextResponse.json(
      { error: 'Unable to create a LiveKit connection. Check the server configuration.' },
      { status: 500, headers: { 'Cache-Control': 'no-store' } }
    );
  }
}

function createParticipantToken(
  userInfo: AccessTokenOptions,
  roomName: string,
  roomConfig: RoomConfiguration | undefined
): Promise<string> {
  const at = new AccessToken(API_KEY, API_SECRET, {
    ...userInfo,
    ttl: '15m',
  });
  const grant: VideoGrant = {
    room: roomName,
    roomJoin: true,
    canPublish: true,
    canPublishData: true,
    canSubscribe: true,
  };
  at.addGrant(grant);

  if (roomConfig) {
    at.roomConfig = roomConfig;
  }

  return at.toJwt();
}
