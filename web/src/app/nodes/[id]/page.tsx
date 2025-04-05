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

// src/app/nodes/[id]/page.tsx
import { Suspense } from "react";
import { cookies } from "next/headers";
import NodeDetail from "../../../components/NodeDetail";
import { Node, ServiceMetric } from "@/types/types";
import { fetchFromAPI } from "@/lib/api";
import { unstable_noStore as noStore } from "next/cache";

export const revalidate = 0;

// Define the history entry type
interface NodeHistoryEntry {
    timestamp: string;
    is_healthy: boolean;
}

// Define route params as a Promise type to match the error message
type Params = Promise<{ id: string }>;

// Define props type for the dynamic route
interface RouteProps {
    params: Params;
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
        let history: NodeHistoryEntry[] = [];
        try {
            const historyData = await fetchFromAPI<NodeHistoryEntry[]>(`/nodes/${nodeId}/history`, token);
            // Check if historyData is not null before assigning
            if (historyData) {
                history = historyData;
            }
        } catch (e) {
            console.warn(`Could not fetch history for ${nodeId}:`, e);
            // Continue without history data
        }

        return { node, metrics: metrics || [], history: history || [], error: undefined };
    } catch (error) {
        console.error(`Error fetching data for node ${nodeId}:`, error);
        return { node: undefined, metrics: [], history: [], error: (error as Error).message };
    }
}

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }) {
    const resolvedParams = await params;
    return {
        title: `Node: ${resolvedParams.id} - ServiceRadar`,
        description: `Detailed dashboard for node ${resolvedParams.id}`,
    };
}

// Update the function signature to match RouteProps
export default async function NodeDetailPage({ params }: RouteProps) {
    const resolvedParams = await params;
    const nodeId = resolvedParams.id;

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