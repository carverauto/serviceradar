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
import DeviceDetail from '@/components/Devices/DeviceDetail';
import { unstable_noStore as noStore } from "next/cache";

interface DevicePageProps {
    params: Promise<{ id: string }>;
}

export async function generateMetadata({ params }: DevicePageProps) {
    const { id } = await params;
    return {
        title: `Device ${decodeURIComponent(id)} - ServiceRadar`,
        description: `View details and metrics for device ${decodeURIComponent(id)}`,
    };
}

export default async function DevicePage({ params }: DevicePageProps) {
    noStore(); // Ensure this page is always dynamically rendered to get fresh data
    
    const { id } = await params;
    const deviceId = decodeURIComponent(id);

    return (
        <div className="space-y-6">
            <div className="flex items-center justify-between">
                <h1 className="text-2xl font-bold text-gray-900 dark:text-white">
                    Device Details: {deviceId}
                </h1>
            </div>
            <Suspense fallback={
                <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                    Loading device details...
                </div>
            }>
                <DeviceDetail deviceId={deviceId} />
            </Suspense>
        </div>
    );
}