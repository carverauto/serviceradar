// src/app/api/nodes/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function GET(req: NextRequest) {
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
    // Get the authorization header if it exists
    const authHeader = req.headers.get("Authorization");

    // Create headers with API key
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    // Add Authorization header if present
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    // Forward to your Go API
    const response = await fetch(`${apiUrl}/api/nodes`, {
      headers,
    });

    if (!response.ok) {
      console.error(`Nodes API failed with status ${response.status}`);
      const errorText = await response.text();
      console.error(`Error details: ${errorText}`);

      return NextResponse.json(
        { error: "Failed to fetch nodes" },
        { status: response.status },
      );
    }

    // Forward the successful response
    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error("Error fetching nodes:", error);

    return NextResponse.json(
      { error: "Internal server error while fetching nodes" },
      { status: 500 },
    );
  }
}
