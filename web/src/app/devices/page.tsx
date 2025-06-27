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

import { Suspense } from 'react';
import DevicesDashboard from '@/components/Devices/Dashboard';
import { unstable_noStore as noStore } from "next/cache";

export const metadata = {
    title: 'Devices - ServiceRadar',
    description: 'View and manage all discovered devices in your network.',
};

// This page is a server component that passes control to a client component.
// The client component will handle all data fetching and user interaction.
export default function DevicesPage() {
    noStore(); // Ensure this page is always dynamically rendered to get fresh data

    return (
        <div className="space-y-6">
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Device Inventory</h1>
            <Suspense fallback={<div className="text-center p-8 text-gray-600 dark:text-gray-400">Loading device inventory...</div>}>
                <DevicesDashboard />
            </Suspense>
        </div>
    );
}