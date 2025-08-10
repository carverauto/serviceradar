// src/app/api/query/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";
  const authEnabled = process.env.AUTH_ENABLED === "true";

  try {
    const body = await req.json();
    const { query } = body;

    if (!query) {
      return NextResponse.json({ error: "Query is required" }, { status: 400 });
    }

    const authHeader = req.headers.get("Authorization");
    const headersToBackend: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    if (authHeader) {
      headersToBackend["Authorization"] = authHeader;
    } else if (authEnabled) {
      // Authorization is required when authentication is enabled, but the
      // incoming request didn't include a token. Middleware should catch
      // most cases where the access token cookie is missing, so log here
      // in case the request bypassed it.
      console.warn(
        "[API Query Route] Authorization header is missing from the incoming request.",
      );
      // Depending on how strict AUTH_ENABLED is, you might return 401 here,
      // but the Go backend will likely do it if it's missing.
    }

    const backendResponse = await fetch(`${apiUrl}/api/query`, {
      method: "POST",
      headers: headersToBackend,
      body: JSON.stringify(body),
      cache: "no-store",
    });

    if (!backendResponse.ok) {
      let errorData;
      const contentType = backendResponse.headers.get("content-type");
      if (contentType && contentType.includes("application/json")) {
        errorData = await backendResponse.json();
      } else {
        const textError = await backendResponse.text();
        errorData = {
          error: "Backend returned non-JSON error response",
          details: textError.substring(0, 500),
        };
      }

      return NextResponse.json(
        errorData || { error: "Failed to execute query on backend" },
        { status: backendResponse.status },
      );
    }

    const responseData = await backendResponse.json();
    return NextResponse.json(responseData);
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : "Internal server error";
    return NextResponse.json(
      {
        error: "Internal server error processing query",
        details: errorMessage,
      },
      { status: 500 },
    );
  }
}
