// src/app/nodes/[id]/page.tsx
import { Suspense } from "react";
import { cookies } from "next/headers";
import NodeDetail from "../../../components/NodeDetail";
import { Node, ServiceMetric } from "@/types/types";
import { fetchFromAPI } from "@/lib/api";
import { unstable_noStore as noStore } from "next/cache";

export const revalidate = 0;

interface RouteProps {
    params: Promise<{ id: string }>;
}

async function fetchNodeData(nodeId: string, token?: string) {
    noStore();
    try {
        // Fetch node information
        const nodes = await fetchFromAPI<Node[]>("/nodes", token);
        if (!nodes) throw new Error("Failed to fetch nodes");

        const node = nodes.find(n => n.node_id === nodeId);
        if (!node) throw new Error(`Node ${nodeId} not found`);

        // Fetch metrics for this node
        const metrics = await fetchFromAPI<ServiceMetric[]>(`/nodes/${nodeId}/metrics`, token);

        // Fetch history data if available
        let history = [];
        try {
            history = await fetchFromAPI<any[]>(`/nodes/${nodeId}/history`, token);
        } catch (e) {
            console.warn(`Could not fetch history for ${nodeId}:`, e);
            // Continue without history data
        }

        return { node, metrics: metrics || [], history: history || [] };
    } catch (error) {
        console.error(`Error fetching data for node ${nodeId}:`, error);
        return { error: (error as Error).message };
    }
}

export async function generateMetadata({ params }: { params: { id: string }}) {
    return {
        title: `Node: ${params.id} - ServiceRadar`,
        description: `Detailed dashboard for node ${params.id}`,
    };
}

export default async function NodeDetailPage(props: RouteProps) {
    const params = await props.params;
    const nodeId = params.id;

    const cookieStore = await cookies();
    const token = cookieStore.get("accessToken")?.value;

    const { node, metrics, history, error } = await fetchNodeData(nodeId, token);

    return (
        <div>
            <Suspense
                fallback={
                    <div className="flex justify-center items-center h-64">
                        <div className="text-lg text-gray-600 dark:text-gray-300">
                            Loading node details...
                        </div>
                    </div>
                }
            >
                <NodeDetail
                    node={node}
                    metrics={metrics}
                    history={history}
                    error={error}
                />
            </Suspense>
        </div>
    );
}