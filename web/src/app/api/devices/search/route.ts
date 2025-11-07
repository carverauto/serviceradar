import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";
import { isDeviceSearchPlannerEnabled } from "@/config/features";

export async function POST(req: NextRequest) {
  if (!isDeviceSearchPlannerEnabled()) {
    return NextResponse.json(
      { error: "Device search planner disabled" },
      { status: 503 },
    );
  }

  const apiUrl = getInternalApiUrl();
  const apiKey = getApiKey();

  try {
    const body = await req.json();
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    const authHeader =
      req.headers.get("Authorization") || req.headers.get("authorization");
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    const response = await fetch(`${apiUrl}/api/devices/search`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      cache: "no-store",
    });

    const data = await response.json();
    return NextResponse.json(data, { status: response.status });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Unknown error occurred";
    return NextResponse.json(
      { error: "Failed to execute device search", details: message },
      { status: 500 },
    );
  }
}
