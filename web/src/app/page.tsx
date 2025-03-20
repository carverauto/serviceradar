import { cookies } from "next/headers";
import { fetchFromAPI } from "@/lib/api";
import { SystemStatus, Node } from "@/types";
import { unstable_noStore as noStore } from "next/cache";
import DashboardWrapper from "@/components/DashboardWrapper";
import { Suspense } from "react";

async function fetchStatus(token?: string): Promise<SystemStatus | null> {
  noStore();
  try {
    const statusData = await fetchFromAPI<SystemStatus>("/status", token);
    if (!statusData) throw new Error("Failed to fetch status");

    const nodesData = await fetchFromAPI<Node[]>("/nodes", token);
    if (!nodesData) throw new Error("Failed to fetch nodes");

    // Calculate service statistics (unchanged)
    let totalServices = 0;
    let offlineServices = 0;
    let totalResponseTime = 0;
    let servicesWithResponseTime = 0;

    nodesData.forEach((node: Node) => {
      if (node.services && Array.isArray(node.services)) {
        totalServices += node.services.length;
        node.services.forEach((service) => {
          if (!service.available) offlineServices++;
          if (service.type === "icmp" && service.details) {
            try {
              const details =
                typeof service.details === "string"
                  ? JSON.parse(service.details)
                  : service.details;
              if (details && details.response_time) {
                totalResponseTime += details.response_time;
                servicesWithResponseTime++;
              }
            } catch (e) {
              console.error("Error parsing service details:", e);
            }
          }
        });
      }
    });

    const avgResponseTime =
      servicesWithResponseTime > 0
        ? totalResponseTime / servicesWithResponseTime
        : 0;

    return {
      ...statusData,
      service_stats: {
        total_services: totalServices,
        offline_services: offlineServices,
        avg_response_time: avgResponseTime,
      },
    };
  } catch (error) {
    console.error("Error fetching status:", error);
    return null;
  }
}

export default async function HomePage() {
  const cookieStore = await cookies();
  const token = cookieStore.get("accessToken")?.value;
  const initialData = await fetchStatus(token);

  return (
    <div>
      <h1 className="text-2xl font-bold mb-6">Dashboard</h1>
      <Suspense fallback={<div>Loading dashboard...</div>}>
        <DashboardWrapper initialData={initialData} />
      </Suspense>
    </div>
  );
}
