"use server";

import { NextRequest, NextResponse } from "next/server";
import {
  buildAuthHeaders,
  buildCoreUrl,
  proxyJson,
  resolveAuthHeader,
} from "../../helpers";

export async function POST(
  req: NextRequest,
  { params }: { params: { id: string } }
) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const packageId = params.id?.trim();
  if (!packageId) {
    return NextResponse.json({ error: "Package ID is required" }, { status: 400 });
  }

  const targetUrl = buildCoreUrl(
    `/api/admin/edge-packages/${encodeURIComponent(packageId)}/revoke`
  );
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
