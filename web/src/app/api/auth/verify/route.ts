// src/app/api/auth/verify/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function GET(req: NextRequest) {
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
    // Get the token from the Authorization header
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return NextResponse.json({ error: "Missing token" }, { status: 401 });
    }

    const token = authHeader.substring(7);

    // Forward to your Go API with API key to verify the token
    const response = await fetch(`${apiUrl}/api/status`, {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-API-Key": apiKey,
      },
    });

    if (!response.ok) {
      // Forward the error from the API
      const errorText = await response.text();
      return NextResponse.json(
        { error: "Token verification failed", details: errorText },
        { status: response.status },
      );
    }

    // Token is valid, return success
    return NextResponse.json({ verified: true });
  } catch (error) {
    console.error("Token verification error:", error);
    return NextResponse.json(
      { error: "Internal server error during token verification" },
      { status: 500 },
    );
  }
}
