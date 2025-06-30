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

// src/components/Metrics/SystemMetricsWrapper.tsx
'use client';

import React from 'react';
import dynamic from 'next/dynamic';
import { useSearchParams } from 'next/navigation';
import DeviceAttributionBanner from './DeviceAttributionBanner';

const MultiSysmonMetrics = dynamic(() => import('./MultiSysmonMetrics'), {
    ssr: false,
    loading: () => <div className="p-8 text-center">Loading system metrics...</div>,
});

const SystemMetricsWrapper = () => {
    const searchParams = useSearchParams();
    const deviceId = searchParams.get('deviceId');
    const pollerId = searchParams.get('pollerId'); // Keep for backward compatibility
    const agentId = searchParams.get('agentId');
    
    // Use deviceId if available, otherwise fall back to pollerId for backward compatibility
    const targetId = deviceId || pollerId;
    const idType = deviceId ? 'device' : 'poller';
    
    // Debug logging
    console.log('SystemMetricsWrapper - All search params:', Array.from(searchParams.entries()));
    console.log('SystemMetricsWrapper - deviceId:', deviceId);
    console.log('SystemMetricsWrapper - pollerId:', pollerId);
    console.log('SystemMetricsWrapper - agentId:', agentId);
    console.log('SystemMetricsWrapper - targetId:', targetId, 'idType:', idType);

    if (!targetId) {
        return (
            <div className="p-8 text-center">
                <h2 className="text-xl font-semibold text-gray-800 dark:text-gray-200 mb-2">
                    Missing Device ID
                </h2>
                <p className="text-gray-600 dark:text-gray-400">
                    Please provide a deviceId parameter to view metrics.
                </p>
                <div className="mt-4 text-sm text-gray-500">
                    Current URL params: {Array.from(searchParams.entries()).map(([key, value]) => `${key}=${value}`).join(', ') || 'none'}
                </div>
            </div>
        );
    }

    return (
        <div>
            <DeviceAttributionBanner deviceId={targetId} idType={idType} />
            <MultiSysmonMetrics deviceId={targetId} idType={idType} preselectedAgentId={agentId} />
        </div>
    );
};

export default SystemMetricsWrapper;