// src/app/api/auth/refresh/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
    // Parse the request body to get the refresh token
    const body = await req.json();
    const refreshToken = body.refresh_token || body.refreshToken;

    if (!refreshToken) {
      return NextResponse.json(
        { error: "Missing refresh token" },
        { status: 400 },
      );
    }

    // Forward to your Go API with API key
    const response = await fetch(`${apiUrl}/auth/refresh`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(
        `Token refresh failed with status ${response.status}: ${errorText}`,
      );

      return NextResponse.json(
        { error: "Token refresh failed", details: errorText },
        { status: response.status },
      );
    }

    // Forward the successful response
    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error("Token refresh error:", error);
    return NextResponse.json(
      { error: "Internal server error during token refresh" },
      { status: 500 },
    );
  }
}
