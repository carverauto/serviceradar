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

// src/app/pollers/page.tsx

import { Suspense } from "react";
import { cookies } from "next/headers";
import { ServiceMetric, Poller } from "@/types/types";
import PollerDashboard from "@/components/PollerDashboard";

export const revalidate = 0;

async function fetchPollersWithMetrics(token?: string): Promise<{
  pollers: Poller[];
  serviceMetrics: { [key: string]: ServiceMetric[] };
}> {
  try {
    // For server-side fetches in production
    let baseUrl;
    let pollersUrl;

    if (typeof window === "undefined") {
      // Server-side context - need absolute URL
      baseUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

      // Ensure URL has protocol
      if (!baseUrl.startsWith('http')) {
        baseUrl = `http://${baseUrl}`;
      }

      pollersUrl = `${baseUrl}/api/pollers`;
    } else {
      // Client-side context - can use relative URL
      pollersUrl = "/api/pollers";
    }

    const apiKey = process.env.API_KEY || "";

    const pollersResponse = await fetch(pollersUrl, {
      headers: {
        "X-API-Key": apiKey,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      cache: "no-store",
    });

    if (!pollersResponse.ok) {
      throw new Error(`Pollers API request failed: ${pollersResponse.status}`);
    }

    const pollers: Poller[] = await pollersResponse.json();
    const serviceMetrics: { [key: string]: ServiceMetric[] } = {};

    for (const poller of pollers) {
      const icmpServices =
          poller.services?.filter((s) => s.type === "icmp") || [];

      if (icmpServices.length > 0) {
        try {
          // Use the same baseUrl construct for metrics
          const metricsUrl = `${baseUrl}/api/pollers/${poller.poller_id}/metrics`;

          const metricsResponse = await fetch(
              metricsUrl,
              {
                headers: {
                  "X-API-Key": apiKey,
                  ...(token ? { Authorization: `Bearer ${token}` } : {}),
                },
                cache: "no-store",
              },
          );

          if (!metricsResponse.ok) {
            continue;
          }

          const allPollerMetrics: ServiceMetric[] = await metricsResponse.json();

          for (const service of icmpServices) {
            const serviceMetricsData = allPollerMetrics.filter(
                (m) => m.service_name === service.name,
            );
            const key = `${poller.poller_id}-${service.name}`;
            serviceMetrics[key] = serviceMetricsData;
          }
        } catch (error) {
          console.error(`Error fetching metrics for ${poller.poller_id}:`, error);
        }
      }
    }

    return { pollers: pollers, serviceMetrics };
  } catch (error) {
    console.error("Error fetching pollers:", error);
    return { pollers: [], serviceMetrics: {} };
  }
}

export default async function PollersPage() {
  const cookieStore = await cookies(); // Await cookies()
  const token = cookieStore.get("accessToken")?.value;
  const { pollers, serviceMetrics } = await fetchPollersWithMetrics(token);

  return (
    <div>
      <Suspense
        fallback={
          <div className="flex justify-center items-center h-64">
            <div className="text-lg text-gray-600 dark:text-gray-300">
              Loading pollers...
            </div>
          </div>
        }
      >
        <PollerDashboard initialPollers={pollers} serviceMetrics={serviceMetrics} />
      </Suspense>
    </div>
  );
}
