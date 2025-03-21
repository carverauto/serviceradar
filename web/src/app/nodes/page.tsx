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

// src/app/nodes/page.tsx

import { Suspense } from "react";
import { cookies } from "next/headers";
import NodeList from "../../components/NodeList";
import { ServiceMetric, Node } from "@/types/types";

export const revalidate = 0;

async function fetchNodesWithMetrics(token?: string): Promise<{
  nodes: Node[];
  serviceMetrics: { [key: string]: ServiceMetric[] };
}> {
  try {
    // For server-side fetches in production
    let baseUrl;
    let nodesUrl;

    if (typeof window === "undefined") {
      // Server-side context - need absolute URL
      baseUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

      // Ensure URL has protocol
      if (!baseUrl.startsWith('http')) {
        baseUrl = `http://${baseUrl}`;
      }

      nodesUrl = `${baseUrl}/api/nodes`;
    } else {
      // Client-side context - can use relative URL
      nodesUrl = "/api/nodes";
    }

    const apiKey = process.env.API_KEY || "";

    const nodesResponse = await fetch(nodesUrl, {
      headers: {
        "X-API-Key": apiKey,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      cache: "no-store",
    });

    if (!nodesResponse.ok) {
      throw new Error(`Nodes API request failed: ${nodesResponse.status}`);
    }

    const nodes: Node[] = await nodesResponse.json();
    const serviceMetrics: { [key: string]: ServiceMetric[] } = {};

    for (const node of nodes) {
      const icmpServices =
          node.services?.filter((s) => s.type === "icmp") || [];

      if (icmpServices.length > 0) {
        try {
          // Use the same baseUrl construct for metrics
          const metricsUrl = `${baseUrl}/api/nodes/${node.node_id}/metrics`;

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

          const allNodeMetrics: ServiceMetric[] = await metricsResponse.json();

          for (const service of icmpServices) {
            const serviceMetricsData = allNodeMetrics.filter(
                (m) => m.service_name === service.name,
            );
            const key = `${node.node_id}-${service.name}`;
            serviceMetrics[key] = serviceMetricsData;
          }
        } catch (error) {
          console.error(`Error fetching metrics for ${node.node_id}:`, error);
        }
      }
    }

    return { nodes, serviceMetrics };
  } catch (error) {
    console.error("Error fetching nodes:", error);
    return { nodes: [], serviceMetrics: {} };
  }
}

export default async function NodesPage() {
  const cookieStore = await cookies(); // Await cookies()
  const token = cookieStore.get("accessToken")?.value;
  const { nodes, serviceMetrics } = await fetchNodesWithMetrics(token);

  return (
    <div>
      <Suspense
        fallback={
          <div className="flex justify-center items-center h-64">
            <div className="text-lg text-gray-600 dark:text-gray-300">
              Loading nodes...
            </div>
          </div>
        }
      >
        <NodeList initialNodes={nodes} serviceMetrics={serviceMetrics} />
      </Suspense>
    </div>
  );
}
