// src/app/api/nodes/[id]/history/route.ts
import { NextRequest, NextResponse } from "next/server";

// Define the expected history data structure
interface HistoryEntry {
  timestamp: string; // ISO string
  is_healthy: boolean;
  [key: string]: unknown; // Allow additional fields
}

// Define the props type for the dynamic route
interface RouteProps {
  params: Promise<{ id: string }>; // params is a Promise due to async nature
}

export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params; // Await the params Promise
  const nodeId = params.id;
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
    const authHeader = req.headers.get("authorization");
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    if (authHeader) {
      headers["Authorization"] = authHeader;
      console.log(`Forwarding history request with authorization: ${authHeader}`);
    }

    console.log(`Requesting history for node ${nodeId} from: ${apiUrl}/api/nodes/${nodeId}/history`);

    const response = await fetch(`${apiUrl}/api/nodes/${nodeId}/history`, {
      method: "GET",
      headers,
      cache: "no-store",
    });

    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;
      try {
        const errorText = await response.text();
        console.error(`History API error (${status}): ${errorText}`);
        errorMessage = errorText;
      } catch {
        errorMessage = `Status code: ${status}`;
      }
      return NextResponse.json(
          { error: "Failed to fetch history", details: errorMessage },
          { status },
      );
    }

    const data: HistoryEntry[] = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching history for node ${nodeId}:`, error);
    return NextResponse.json(
        { error: "Internal server error while fetching history" },
        { status: 500 },
    );
  }
}