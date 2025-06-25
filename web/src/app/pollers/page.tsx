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
// Import the new cached data functions
import { getCachedPollers, getCachedPollerMetrics } from "@/lib/data";

// This function is no longer exported as it's part of the page's render logic
// It now uses the cached data fetching functions for better performance.
async function fetchPollersWithMetrics(token?: string): Promise<{
  pollers: Poller[];
  serviceMetrics: { [key: string]: ServiceMetric[] };
}> {
  try {
    const pollers = await getCachedPollers(token);
    const serviceMetrics: { [key: string]: ServiceMetric[] } = {};

    // This loop still represents an N+1 fetching pattern.
    // While React.cache will memoize requests for the same poller within a single render,
    // it's more efficient to have a backend endpoint that returns all metrics at once if possible.
    for (const poller of pollers) {
        // We only fetch metrics if there are ICMP services, as per original logic
        const icmpServices = poller.services?.filter((s) => s.type === "icmp") || [];
        if (icmpServices.length > 0) {
            try {
                const allPollerMetrics = await getCachedPollerMetrics(poller.poller_id, token);
                for (const service of icmpServices) {
                    const serviceMetricsData = allPollerMetrics.filter(
                        (m) => m.service_name === service.name,
                    );
                    const key = `${poller.poller_id}-${service.name}`;
                    serviceMetrics[key] = serviceMetricsData;
                }
            } catch (error) {
                // Log and continue if metrics for one poller fail
                console.error(`Error fetching metrics for ${poller.poller_id}:`, error);
            }
        }
    }

    return { pollers, serviceMetrics };
  } catch (error) {
    console.error("Error fetching pollers and their metrics:", error);
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
