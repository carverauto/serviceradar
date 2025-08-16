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

import {NextRequest, NextResponse} from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

interface RouteProps {
  params: Promise<{ id: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params;
  const deviceId = decodeURIComponent(params.id);
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    const authHeader = req.headers.get("authorization");

    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    // Fetch latest ICMP metrics (last 1 hour) from ring buffer via existing endpoint
    const endTime = new Date();
    const startTime = new Date(endTime.getTime() - 60 * 60 * 1000); // 1 hour ago
    
    const queryParams = new URLSearchParams({
      type: 'icmp',
      start: startTime.toISOString(),
      end: endTime.toISOString()
    });

    const url = `${apiUrl}/api/devices/${encodeURIComponent(deviceId)}/metrics?${queryParams}`;
    
    const response = await fetch(url, {
      method: "GET",
      headers,
      cache: "no-store",
    });

    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;

      try {
        errorMessage = await response.text();
      } catch {
        errorMessage = `Status code: ${status}`;
      }

      return NextResponse.json(
          { error: "Failed to fetch ICMP metrics", details: errorMessage },
          { status },
      );
    }

    const metrics = await response.json() as Array<{
      name: string;
      value: string;
      type: string;
      timestamp: string;
      metadata: string;
      device_id: string;
      partition: string;
      poller_id: string;
    }>;

    // Convert TimeseriesMetric format to the format expected by ICMP indicator
    const convertedMetrics = metrics
      .sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime()) // Sort by timestamp desc
      .slice(0, 1) // Get only the latest
      .map(metric => {
        let metadata;
        try {
          metadata = JSON.parse(metric.metadata);
        } catch {
          metadata = {};
        }
        
        return {
          name: metric.name,
          value: metric.value,
          type: metric.type,
          timestamp: metric.timestamp,
          metadata: metadata,
          device_id: metric.device_id,
          partition: metric.partition,
          poller_id: metric.poller_id
        };
      });

    return NextResponse.json({ metrics: convertedMetrics });
  } catch (error) {
    console.error(`Error fetching ICMP metrics for device ${deviceId}:`, error);

    return NextResponse.json(
        { error: "Internal server error while fetching ICMP metrics" },
        { status: 500 },
    );
  }
}