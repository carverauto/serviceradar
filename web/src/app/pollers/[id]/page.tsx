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

// src/app/pollers/[id]/page.tsx
import { Suspense } from "react";
import { cookies } from "next/headers";
import PollerDetail from "../../../components/PollerDetail";
import { Poller, ServiceMetric } from "@/types/types";
import { fetchFromAPI } from "@/lib/api";
import { unstable_noStore as noStore } from "next/cache";

export const revalidate = 0;

// Define the history entry type
interface PollerHistoryEntry {
    timestamp: string;
    is_healthy: boolean;
}

// Define route params as a Promise type to match the error message
type Params = Promise<{ id: string }>;

// Define props type for the dynamic route
interface RouteProps {
    params: Params;
}

async function fetchPollerData(pollerId: string, token?: string) {
    noStore();
    try {
        // Fetch poller information
        const pollers = await fetchFromAPI<Poller[]>("/pollers", token);
        if (!pollers) throw new Error("Failed to fetch pollers");

        const poller = pollers.find(n => n.poller_id === pollerId);
        if (!poller) throw new Error(`Poller ${pollerId} not found`);

        // Fetch metrics for this poller
        const metrics = await fetchFromAPI<ServiceMetric[]>(`/pollers/${pollerId}/metrics`, token);

        // Fetch history data if available
        let history: PollerHistoryEntry[] = [];
        try {
            const historyData = await fetchFromAPI<PollerHistoryEntry[]>(`/pollers/${pollerId}/history`, token);
            // Check if historyData is not null before assigning
            if (historyData) {
                history = historyData;
            }
        } catch (e) {
            console.warn(`Could not fetch history for ${pollerId}:`, e);
            // Continue without history data
        }

        return { poller: poller, metrics: metrics || [], history: history || [], error: undefined };
    } catch (error) {
        console.error(`Error fetching data for poller ${pollerId}:`, error);
        return { poller: undefined, metrics: [], history: [], error: (error as Error).message };
    }
}

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }) {
    const resolvedParams = await params;
    return {
        title: `Poller: ${resolvedParams.id} - ServiceRadar`,
        description: `Detailed dashboard for poller ${resolvedParams.id}`,
    };
}

export default async function PollerDetailPage({ params }: RouteProps) {
    const resolvedParams = await params;
    const pollerId = resolvedParams.id;

    const cookieStore = await cookies();
    const token = cookieStore.get("accessToken")?.value;

    const { poller: poller, metrics, history, error } = await fetchPollerData(pollerId, token);

    return (
        <div>
            <Suspense
                fallback={
                    <div className="flex justify-center items-center h-64">
                        <div className="text-lg text-gray-600 dark:text-gray-300">
                            Loading poller details...
                        </div>
                    </div>
                }
            >
                <PollerDetail
                    poller={poller}
                    metrics={metrics}
                    history={history}
                    error={error}
                />
            </Suspense>
        </div>
    );
}