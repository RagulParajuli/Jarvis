import { NextResponse } from 'next/server';
import { handlePairingRedeemRequest } from '@/lib/device-endpoint';

// Redemption consumes a secret and registers a credential: never cache it.
export const revalidate = 0;

/** Redeems a pairing code and registers a device with its ES256 key. */
export async function POST(req: Request) {
  const result = await handlePairingRedeemRequest(req);
  return NextResponse.json(result.body, { status: result.status, headers: result.headers });
}
