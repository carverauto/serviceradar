import { NextRequest, NextResponse } from "next/server";
import {
  buildAuthHeaders,
  buildCoreUrl,
  proxyBinary,
  resolveAuthHeader,
} from "../../helpers";

type ParamsPromise = Promise<{ id: string }>;

export async function POST(
  req: NextRequest,
  context: { params: ParamsPromise }
) {
  const authHeader = resolveAuthHeader(req);
  if (!authHeader) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { id } = await context.params;
  const packageId = id?.trim();
  if (!packageId) {
    return NextResponse.json({ error: "Package ID is required" }, { status: 400 });
  }

  const targetUrl = buildCoreUrl(
    `/api/admin/edge-packages/${encodeURIComponent(packageId)}/download`
  );
  const body = await req.text();

  return proxyBinary(targetUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...buildAuthHeaders(authHeader),
    },
    body,
  });
}
