"use server";

import { NextRequest, NextResponse } from "next/server";
import { Buffer } from "node:buffer";
import { getApiKey, getInternalApiUrl } from "@/lib/config";

export function resolveAuthHeader(req: NextRequest): string | null {
  const header = req.headers.get("Authorization");
  if (header?.startsWith("Bearer ")) {
    return header;
  }
  const cookieToken = req.cookies.get("accessToken")?.value;
  if (cookieToken) {
    return `Bearer ${cookieToken}`;
  }
  return null;
}

export function buildCoreUrl(path: string): string {
  const apiUrl = getInternalApiUrl();
  if (path.startsWith("/")) {
    return `${apiUrl}${path}`;
  }
  return `${apiUrl}/${path}`;
}

export async function proxyJson(
  targetUrl: string,
  init: RequestInit
): Promise<NextResponse> {
  try {
    const resp = await fetch(targetUrl, init);
    const body = await resp.text();
    const contentType =
      resp.headers.get("Content-Type") ?? "application/json; charset=utf-8";
    return new NextResponse(body, {
      status: resp.status,
      headers: {
        "Content-Type": contentType,
      },
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Failed to contact Core API";
    return NextResponse.json(
      { error: message },
      { status: 502 }
    );
  }
}

export async function proxyBinary(
  targetUrl: string,
  init: RequestInit
): Promise<NextResponse> {
  try {
    const resp = await fetch(targetUrl, init);
    const buffer = await resp.arrayBuffer();
    const response = new NextResponse(Buffer.from(buffer), {
      status: resp.status,
    });

    // Pass through important headers
    const headersToForward = [
      "Content-Type",
      "Content-Disposition",
      "Cache-Control",
      "X-Edge-Package-ID",
      "X-Edge-Poller-ID",
    ];
    headersToForward.forEach((header) => {
      const value = resp.headers.get(header);
      if (value) {
        response.headers.set(header, value);
      }
    });

    if (!response.headers.has("Content-Type")) {
      response.headers.set("Content-Type", "application/octet-stream");
    }

    return response;
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Failed to contact Core API";
    return NextResponse.json(
      { error: message },
      { status: 502 }
    );
  }
}

export function buildAuthHeaders(authHeader: string): HeadersInit {
  return {
    Authorization: authHeader,
    "X-API-Key": getApiKey(),
  };
}
