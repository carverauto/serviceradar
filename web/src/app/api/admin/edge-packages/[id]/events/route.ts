"use server";

import { NextRequest, NextResponse } from "next/server";
import {
  buildAuthHeaders,
  buildCoreUrl,
  proxyJson,
  resolveAuthHeader,
} from "../../helpers";

export async function GET(
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

  const search = req.nextUrl.searchParams.toString();
  const targetUrl = buildCoreUrl(
    `/api/admin/edge-packages/${encodeURIComponent(packageId)}/events${
      search ? `?${search}` : ""
    }`
  );

  return proxyJson(targetUrl, {
    method: "GET",
    headers: {
      "Content-Type": "application/json",
      ...buildAuthHeaders(authHeader),
    },
  });
}
