/*
 * Copyright 2025 Carver Automation Corporation.
 */

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
    const backendUrl =
      process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";
    const apiKey = process.env.API_KEY || "";

    const nodesResponse = await fetch("http://localhost:3000/api/nodes", {
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
          const metricsResponse = await fetch(
            `${backendUrl}/api/nodes/${node.node_id}/metrics`,
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
