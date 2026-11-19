import { NextResponse } from 'next/server';
import { handlePairingIssueRequest } from '@/lib/device-endpoint';

// A pairing code is shown once: never cache the response.
export const revalidate = 0;

/** Issues a one-time pairing code for enrolment. */
export async function POST(req: Request) {
  const result = await handlePairingIssueRequest(req);
  return NextResponse.json(result.body, { status: result.status, headers: result.headers });
}
