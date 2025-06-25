/*
* Copyright 2025 Carver Automation Corporation.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/
import { Suspense } from 'react';
import { cookies } from 'next/headers';
import { Poller } from '@/types/types';
import NetworkDashboard from '@/components/Network/Dashboard';
// Import new cached data function
import { getCachedPollers } from '@/lib/data';

export const metadata = {
    title: 'Network - ServiceRadar',
    description: 'Unified view of network discovery, sweeps, and SNMP data.',
};

// This function now uses the cached pollers function.
// `noStore()` has been removed.
async function fetchNetworkData(token?: string): Promise<{ pollers: Poller[] }> {
    try {
        const pollers = await getCachedPollers(token);
        return { pollers: pollers || [] };
    } catch (error) {
        console.error("Error fetching network data:", error);
        return { pollers: [] };
    }
}

export default async function NetworkPage() {
    const cookieStore = await cookies();
    const token = cookieStore.get("accessToken")?.value;
    const {pollers} = await fetchNetworkData(token);
    return (
        <div className="space-y-6">
            <Suspense fallback={<div className="text-center p-8 text-gray-400">Loading network data...</div>}>
                <NetworkDashboard initialPollers={pollers}/>
            </Suspense>
        </div>
    );
}