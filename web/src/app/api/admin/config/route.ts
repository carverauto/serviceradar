import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

export async function GET(req: NextRequest): Promise<NextResponse> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return NextResponse.json(
      { error: "Unauthorized: Authentication required" },
      { status: 401 },
    );
  }

  const apiUrl = `${getInternalApiUrl()}/api/admin/config`;

  try {
    const response = await fetch(apiUrl, {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": getApiKey(),
        Authorization: authHeader,
      },
    });

    const body = await response.text();
    const headers = new Headers();
    const contentType = response.headers.get("content-type");
    if (contentType) {
      headers.set("Content-Type", contentType);
    }

    return new NextResponse(body, {
      status: response.status,
      headers,
    });
  } catch (error) {
    console.error("Admin config list proxy error", error);
    return NextResponse.json(
      { error: "Failed to reach core admin config API" },
      { status: 502 },
    );
  }
}
