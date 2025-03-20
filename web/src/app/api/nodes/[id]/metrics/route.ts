// src/app/api/nodes/[id]/metrics/route.ts
import { NextRequest, NextResponse } from "next/server";
import { ServiceMetric } from "@/types/types";

// Define the props type for the dynamic route
interface RouteProps {
  params: Promise<{ id: string }>; // params is a Promise due to async nature
}

// Define the response type (already present but kept for clarity)
export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params; // Await the params Promise
  const nodeId = params.id;
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
    // Get authorization header
    const authHeader = req.headers.get("authorization");

    // Create headers for backend request
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    // Add Authorization header if it exists
    if (authHeader) {
      headers["Authorization"] = authHeader;
      console.log(`Forwarding metrics request with authorization: ${authHeader}`);
    }

    console.log(`Requesting metrics for node ${nodeId} from: ${apiUrl}/api/nodes/${nodeId}/metrics`);

    // Forward request to Go API
    const response = await fetch(`${apiUrl}/api/nodes/${nodeId}/metrics`, {
      method: "GET",
      headers,
      cache: "no-store",
    });

    // Check for and handle errors
    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;

      try {
        const errorText = await response.text();
        console.error(`Metrics API error (${status}): ${errorText}`);
        errorMessage = errorText;
      } catch {
        errorMessage = `Status code: ${status}`;
      }

      // Return error response
      return NextResponse.json(
          { error: "Failed to fetch metrics", details: errorMessage },
          { status },
      );
    }

    // Return successful response
    const data: ServiceMetric[] = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching metrics for node ${nodeId}:`, error);

    return NextResponse.json(
        { error: "Internal server error while fetching metrics" },
        { status: 500 },
    );
  }
}