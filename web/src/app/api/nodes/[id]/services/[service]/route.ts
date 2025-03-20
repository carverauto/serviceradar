// src/app/api/nodes/[id]/services/[service]/route.ts
import { NextRequest, NextResponse } from "next/server";
import { Service } from "@/types/types";

export async function GET(req: NextRequest, { params }) {
  const nodeId = params.id;
  const serviceName = params.service;
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
      console.log(`Forwarding service details request with authorization: ${authHeader}`);
    }

    console.log(`Requesting service details for ${nodeId}/${serviceName} from: ${apiUrl}/api/nodes/${nodeId}/services/${serviceName}`);

    // Forward request to Go API
    const response = await fetch(
        `${apiUrl}/api/nodes/${nodeId}/services/${serviceName}`,
        {
          method: "GET",
          headers,
          cache: "no-store",
        },
    );

    // Check for and handle errors
    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;

      try {
        const errorText = await response.text();
        console.error(`Service details API error (${status}): ${errorText}`);
        errorMessage = errorText;
      } catch {
        errorMessage = `Status code: ${status}`;
      }

      return NextResponse.json(
          { error: "Failed to fetch service details", details: errorMessage },
          { status },
      );
    }

    // Return successful response
    const data: Service = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching service ${serviceName} for node ${nodeId}:`, error);

    return NextResponse.json(
        { error: "Internal server error while fetching service details" },
        { status: 500 },
    );
  }
}