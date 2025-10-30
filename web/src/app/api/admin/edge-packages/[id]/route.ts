import { NextRequest, NextResponse } from "next/server";
import {
  buildAuthHeaders,
  buildCoreUrl,
  proxyJson,
  resolveAuthHeader,
} from "../helpers";

type RouteParams = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(req: NextRequest, { params }: RouteParams) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { id } = await params;
  const packageId = id?.trim();
  if (!packageId) {
    return NextResponse.json({ error: "Package ID is required" }, { status: 400 });
  }

  const targetUrl = buildCoreUrl(`/api/admin/edge-packages/${encodeURIComponent(packageId)}`);

  return proxyJson(targetUrl, {
    method: "GET",
    headers: {
      "Content-Type": "application/json",
      ...buildAuthHeaders(authHeader),
    },
  });
}

export async function DELETE(req: NextRequest, { params }: RouteParams) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { id } = await params;
  const packageId = id?.trim();
  if (!packageId) {
    return NextResponse.json({ error: "Package ID is required" }, { status: 400 });
  }

  const targetUrl = buildCoreUrl(`/api/admin/edge-packages/${encodeURIComponent(packageId)}`);

  return proxyJson(targetUrl, {
    method: "DELETE",
    headers: {
      ...buildAuthHeaders(authHeader),
    },
  });
}
