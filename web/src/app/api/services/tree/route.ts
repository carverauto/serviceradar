/*
 * Proxy to Core API: /api/services/tree
 */

import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

export async function GET(req: NextRequest) {
  let authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    const cookieToken = req.cookies.get('accessToken')?.value;
    if (cookieToken) {
      authHeader = `Bearer ${cookieToken}`;
    } else {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }
  }
  const apiUrl = getInternalApiUrl();
  const apiKey = getApiKey();
  const search = req.nextUrl.searchParams.toString();
  const url = `${apiUrl}/api/services/tree${search ? `?${search}` : ''}`;
  try {
    const resp = await fetch(url, {
      method: 'GET',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
        'Authorization': authHeader,
      },
    });
    const body = await resp.text();
    return new NextResponse(body, { status: resp.status, headers: { 'Content-Type': 'application/json' } });
  } catch (e) {
    return NextResponse.json({ error: 'Failed to fetch services tree' }, { status: 500 });
  }
}
