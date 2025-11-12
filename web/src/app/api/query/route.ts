// src/app/api/query/route.ts
import { NextRequest, NextResponse } from "next/server";
import {
  getInternalSrqlUrl,
  getInternalApiUrl,
  getApiKey,
  isAuthEnabled,
} from "@/lib/config";
import { isDeviceSearchPlannerEnabled } from "@/config/features";

const DEVICE_PLANNER_STREAMS = new Set(["devices", "device", "device_inventory"]);
const AGGREGATION_PATTERN = /\bstats\s*:/i;

function extractPrimaryStream(rawQuery: unknown): string | null {
  if (typeof rawQuery !== "string") {
    return null;
  }

  const inMatch = rawQuery.match(/\bin:([^\s]+)/i);
  if (!inMatch) {
    return null;
  }

  let stream = inMatch[1]?.trim();
  if (!stream) {
    return null;
  }

  stream = stream.replace(/^[("'`]+/, "").replace(/[)"'`]+$/, "");

  const firstCandidate = stream.split(/[|,]/)[0]?.trim();
  if (!firstCandidate) {
    return null;
  }

  const normalized = firstCandidate.toLowerCase();
  return normalized.length > 0 ? normalized : null;
}

function shouldUseDevicePlanner(query: unknown): boolean {
  if (typeof query !== "string") {
    return false;
  }

  if (AGGREGATION_PATTERN.test(query)) {
    return false;
  }

  const stream = extractPrimaryStream(query);
  if (!stream) {
    return false;
  }
  return DEVICE_PLANNER_STREAMS.has(stream);
}

export async function POST(req: NextRequest) {
  const apiKey = getApiKey();
  const srqlUrl = getInternalSrqlUrl();
  const apiUrl = getInternalApiUrl();
  const authEnabled = isAuthEnabled();

  try {
    const body = await req.json();
    const { query } = body;

    if (!query) {
      return NextResponse.json({ error: "Query is required" }, { status: 400 });
    }

    const authHeader = req.headers.get("Authorization") || req.headers.get("authorization");
    const cookieHeader = req.headers.get("cookie");
    const headersToSrql: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };
    const headersToPlanner: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    if (authHeader) {
      headersToSrql["Authorization"] = authHeader;
      headersToPlanner["Authorization"] = authHeader;
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
    if (cookieHeader) {
      headersToSrql["Cookie"] = cookieHeader;
      headersToPlanner["Cookie"] = cookieHeader;
    }

    const plannerEnabled = isDeviceSearchPlannerEnabled();
    if (plannerEnabled && shouldUseDevicePlanner(query)) {
      const plannerRequest = {
        query,
        mode: typeof body.mode === "string" ? body.mode : "auto",
        filters: typeof body.filters === "object" && body.filters !== null ? body.filters : {},
        pagination: {
          limit: typeof body.limit === "number" ? body.limit : body.pagination?.limit,
          offset: typeof body.offset === "number" ? body.offset : body.pagination?.offset ?? 0,
          cursor: typeof body.cursor === "string" ? body.cursor : body.pagination?.cursor ?? "",
          direction:
            typeof body.direction === "string"
              ? body.direction
              : body.pagination?.direction ?? "",
        },
      };

      try {
        const plannerResponse = await fetch(`${apiUrl}/api/devices/search`, {
          method: "POST",
          headers: headersToPlanner,
          cache: "no-store",
          body: JSON.stringify(plannerRequest),
        });

        if (plannerResponse.ok) {
          const plannerPayload = await plannerResponse.json();
          const {
            engine,
            diagnostics,
            pagination,
            results,
            raw_results: rawResults,
          } = plannerPayload ?? {};

          const normalizedResults =
            engine === "srql" && Array.isArray(rawResults) ? rawResults : results ?? [];

          return NextResponse.json({
            results: normalizedResults,
            pagination: pagination ?? {},
            engine,
            diagnostics,
          });
        }

        if (
          plannerResponse.status === 404 ||
          plannerResponse.status === 503 ||
          plannerResponse.status >= 500
        ) {
          console.warn(
            `[API Query Route] Planner unavailable (status ${plannerResponse.status}); falling back to SRQL`,
          );
        } else {
          const errorPayload =
            plannerResponse.headers.get("content-type")?.includes("application/json")
              ? await plannerResponse.json()
              : {
                  error: `Planner request failed (${plannerResponse.status})`,
                  details: await plannerResponse.text(),
                };
          return NextResponse.json(errorPayload, { status: plannerResponse.status });
        }
      } catch (plannerError) {
        console.warn(
          "[API Query Route] Planner request failed, falling back to SRQL",
          plannerError,
        );
      }
    }

    const backendResponse = await fetch(`${srqlUrl}/api/query`, {
      method: "POST",
      headers: headersToSrql,
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
