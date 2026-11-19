import { NextResponse } from 'next/server';
import { handleTokenRequest } from '@/lib/token-endpoint';

// don't cache the results
export const revalidate = 0;

/**
 * Mints a short-lived LiveKit token for one client.
 *
 * All decisions live in `lib/token-endpoint.ts`: access-code checks, rate
 * limiting, request validation and token TTL. This handler only adapts the
 * result, so the same logic is covered by plain tests.
 */
export async function POST(req: Request) {
  const result = await handleTokenRequest(req);
  return NextResponse.json(result.body, { status: result.status, headers: result.headers });
}
