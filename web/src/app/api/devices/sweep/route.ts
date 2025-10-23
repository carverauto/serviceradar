/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// src/app/api/devices/sweep/route.ts
import {NextRequest, NextResponse} from "next/server";
import { getInternalSrqlUrl, getApiKey } from "@/lib/config";
import { SWEEP_DEVICES_QUERY } from "@/lib/srqlQueries";
import { normalizeTimestampString } from "@/utils/traceTimestamp";

interface PaginationData {
  next_cursor: string | null;
  prev_cursor: string | null;
  limit: number | null;
}

const TIMESTAMP_FIELDS = [
  "timestamp",
  "_tp_time",
  "last_seen",
  "first_seen",
  "created_at",
  "updated_at",
  "observed_at",
  "last_checked",
];

function normalizeTimestampValue(value: unknown): string | undefined {
  if (typeof value === "string") {
    const normalized = normalizeTimestampString(value);
    if (normalized) {
      return normalized;
    }

    const numeric = Number(value);
    if (!Number.isNaN(numeric)) {
      return normalizeTimestampValue(numeric);
    }
  }

  if (typeof value === "number" && Number.isFinite(value)) {
    // Heuristically treat values < 10^12 as seconds since epoch.
    const millis = value > 1_000_000_000_000 ? value : value * 1000;
    try {
      return new Date(millis).toISOString();
    } catch {
      return undefined;
    }
  }

  return undefined;
}

function normalizeResultTimestamps(result: Record<string, unknown>): Record<string, unknown> {
  const normalized: Record<string, unknown> = { ...result };

  for (const field of TIMESTAMP_FIELDS) {
    if (field in normalized) {
      const candidate = normalized[field];
      const replacement = normalizeTimestampValue(candidate);
      if (replacement) {
        normalized[field] = replacement;
      }
    }
  }

  return normalized;
}

function coerceCursor(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function coerceLimit(value: unknown, fallback: number | null): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return fallback;
}

function normalizePagination(
  rawPagination: unknown,
  fallbackNext: unknown,
  fallbackPrev: unknown,
  fallbackLimit: number,
): PaginationData {
  if (rawPagination && typeof rawPagination === "object") {
    const paginationObj = rawPagination as Record<string, unknown>;
    return {
      next_cursor: coerceCursor(
        paginationObj.next_cursor ?? (paginationObj.nextCursor as unknown),
      ),
      prev_cursor: coerceCursor(
        paginationObj.prev_cursor ?? (paginationObj.prevCursor as unknown),
      ),
      limit: coerceLimit(
        paginationObj.limit ?? (paginationObj.page_size as unknown),
        fallbackLimit,
      ),
    };
  }

  return {
    next_cursor: coerceCursor(fallbackNext),
    prev_cursor: coerceCursor(fallbackPrev),
    limit: coerceLimit(fallbackLimit, fallbackLimit),
  };
}

export async function GET(req: NextRequest) {
  const apiKey = getApiKey();
  const srqlUrl = getInternalSrqlUrl();

  try {
    // Get pagination parameters from query string
    const searchParams = req.nextUrl.searchParams;
    const limit = parseInt(searchParams.get("limit") || "100");
    const cursor = searchParams.get("cursor") || "";
    const direction = searchParams.get("direction") || "next";

    // Get authorization header
    const authHeader = req.headers.get("authorization");
    const cookieHeader = req.headers.get("cookie");

    // Create headers for backend request
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    // Add Authorization header if it exists
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }
    if (cookieHeader) {
      headers["Cookie"] = cookieHeader;
    }

    // Query the devices using SRQL syntax with proper pagination
    const query = SWEEP_DEVICES_QUERY;
    
    // Build request body with pagination
    const requestBody: {
      query: string;
      limit: number;
      cursor?: string;
      direction?: string;
    } = { 
      query,
      limit
    };
    
    if (cursor) {
      requestBody.cursor = cursor;
      requestBody.direction = direction;
    }
    
    // Forward request to Go API query endpoint
    const response = await fetch(
        `${srqlUrl}/api/query`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(requestBody),
          cache: "no-store",
        },
    );

    // Check for and handle errors
    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;

      try {
        errorMessage = await response.text();
      } catch {
        errorMessage = `Status code: ${status}`;
      }

      return NextResponse.json(
          { error: "Failed to fetch sweep host states", details: errorMessage },
          { status },
      );
    }

    // Return successful response
    const data = await response.json();
    const normalizedResults = Array.isArray(data?.results)
      ? data.results.map((entry: unknown) => {
        if (!entry || typeof entry !== "object") {
          return entry;
        }
        return normalizeResultTimestamps(entry as Record<string, unknown>);
      })
      : data?.results;

    const normalizedPagination = normalizePagination(
      data?.pagination,
      data?.next_cursor,
      data?.prev_cursor,
      limit,
    );

    return NextResponse.json({
      ...data,
      ...(typeof data === "object" && data !== null ? {} : { results: normalizedResults }),
      results: normalizedResults,
      pagination: normalizedPagination,
    });
  } catch (error) {
    console.error("Error in sweep API:", error);
    return NextResponse.json(
        { error: "Internal server error while fetching sweep host states", details: String(error) },
        { status: 500 },
    );
  }
}
