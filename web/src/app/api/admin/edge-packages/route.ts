import { NextRequest, NextResponse } from "next/server";
import {
  buildAuthHeaders,
  buildCoreUrl,
  proxyJson,
  resolveAuthHeader,
} from "./helpers";

export async function GET(req: NextRequest) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const search = req.nextUrl.searchParams.toString();
  const targetUrl = buildCoreUrl(
    `/api/admin/edge-packages${search ? `?${search}` : ""}`
  );

  return proxyJson(targetUrl, {
    method: "GET",
    headers: {
      "Content-Type": "application/json",
      ...buildAuthHeaders(authHeader),
    },
  });
}

export async function POST(req: NextRequest) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const targetUrl = buildCoreUrl("/api/admin/edge-packages");
  const body = await req.text();

  return proxyJson(targetUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...buildAuthHeaders(authHeader),
    },
    body,
  });
}
