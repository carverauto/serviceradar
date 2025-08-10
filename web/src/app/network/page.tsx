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
import NetworkDashboard from '@/components/Network/Dashboard';

export const metadata = {
    title: 'Network - ServiceRadar',
    description: 'Unified view of network discovery, sweeps, and SNMP data.',
};

export default async function NetworkPage() {
    return (
        <div className="space-y-6">
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Network</h1>
            <Suspense fallback={<div className="text-center p-8 text-gray-600 dark:text-gray-400">Loading network data...</div>}>
                <NetworkDashboard />
            </Suspense>
        </div>
    );
}