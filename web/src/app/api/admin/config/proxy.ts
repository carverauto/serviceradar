/*
 * Shared proxy implementation for admin config routes.
 */

import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

type ParamsPromise = Promise<{ service: string }>;
type Method = "GET" | "PUT" | "DELETE";

const UNAUTHORIZED = NextResponse.json(
  { error: "Unauthorized: Authentication required" },
  { status: 401 },
);

function buildUpstreamUrl(req: NextRequest, service: string): string {
  const params = new URLSearchParams(req.nextUrl.searchParams);

  // Normalize legacy kvStore query parameter if present.
  if (!params.has("kv_store_id") && params.has("kvStore")) {
    const legacy = params.get("kvStore");
    if (legacy) {
      params.set("kv_store_id", legacy);
    } else {
      params.delete("kvStore");
    }
  }

  const query = params.toString();
  const base = `${getInternalApiUrl()}/api/admin/config/${service}`;
  return query ? `${base}?${query}` : base;
}

async function forwardRequest(
  method: Method,
  req: NextRequest,
  upstreamUrl: string,
  authHeader: string,
): Promise<NextResponse> {
  const headers = new Headers({
    "X-API-Key": getApiKey(),
    Authorization: authHeader,
  });
  const contentType = req.headers.get("Content-Type");
  if (contentType) {
    headers.set("Content-Type", contentType);
  }

  const init: RequestInit = {
    method,
    headers,
    body: undefined,
  };

  if (method === "PUT") {
    init.body = await req.text();
  }

  try {
    const resp = await fetch(upstreamUrl, init);
    const body = await resp.text();
    const responseHeaders = new Headers();
    const respContentType = resp.headers.get("content-type");
    if (respContentType) {
      responseHeaders.set("Content-Type", respContentType);
    }
    return new NextResponse(body, {
      status: resp.status,
      headers: responseHeaders,
    });
  } catch (error) {
    console.error("Admin config proxy error", error);
    return NextResponse.json(
      { error: "Failed to reach core admin config API" },
      { status: 502 },
    );
  }
}

export async function proxyConfigRequest(
  method: Method,
  req: NextRequest,
  { params }: { params: ParamsPromise },
): Promise<NextResponse> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return UNAUTHORIZED;
  }

  const { service } = await params;
  const upstreamUrl = buildUpstreamUrl(req, service);
  return forwardRequest(method, req, upstreamUrl, authHeader);
}
