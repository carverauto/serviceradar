/*
 * Proxy to Core API: /api/kv/info
 */

import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

export async function GET(req: NextRequest) {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const kv = req.nextUrl.searchParams.get('kv_store_id') || '';
  const apiUrl = getInternalApiUrl();
  const apiKey = getApiKey();
  const url = `${apiUrl}/api/kv/info?kv_store_id=${encodeURIComponent(kv)}`;

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
    const contentType = resp.headers.get('content-type') || 'application/json';
    return new NextResponse(body, { status: resp.status, headers: { 'Content-Type': contentType } });
  } catch (e) {
    return NextResponse.json({ error: 'Failed to fetch kv info' }, { status: 500 });
  }
}
