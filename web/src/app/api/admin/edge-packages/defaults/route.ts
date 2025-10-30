import { NextRequest, NextResponse } from "next/server";

import {
  buildAuthHeaders,
  buildCoreUrl,
  proxyJson,
  resolveAuthHeader,
} from "../helpers";

export async function GET(req: NextRequest) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const targetUrl = buildCoreUrl("/api/admin/edge-packages/defaults");

  return proxyJson(targetUrl, {
    method: "GET",
    headers: buildAuthHeaders(authHeader),
  });
}
