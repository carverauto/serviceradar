import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

const UNAUTHORIZED = NextResponse.json(
  { error: "Unauthorized: Authentication required" },
  { status: 401 },
);

export async function POST(req: NextRequest): Promise<NextResponse> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return UNAUTHORIZED;
  }

  const search = req.nextUrl.searchParams.toString();
  const apiUrl = `${getInternalApiUrl()}/api/admin/network/discovery/snmp-polling/batch${
    search ? `?${search}` : ""
  }`;

  try {
    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": getApiKey(),
        Authorization: authHeader,
      },
      body: await req.text(),
    });

    const body = await response.text();
    const headers = new Headers();
    const contentType = response.headers.get("content-type");
    if (contentType) {
      headers.set("Content-Type", contentType);
    }
    return new NextResponse(body, { status: response.status, headers });
  } catch (error) {
    console.error("Network discovery SNMP polling batch proxy error", error);
    return NextResponse.json(
      { error: "Failed to reach core network discovery API" },
      { status: 502 },
    );
  }
}

