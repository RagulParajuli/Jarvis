import { NextResponse } from 'next/server';
import { handleChallengeRequest } from '@/lib/device-endpoint';

// Challenges are one-time secrets: never cache the response.
export const revalidate = 0;

/** Issues a short-lived, one-time challenge to a trusted device. */
export async function POST(req: Request) {
  const result = await handleChallengeRequest(req);
  return NextResponse.json(result.body, { status: result.status, headers: result.headers });
}
