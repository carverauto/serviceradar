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
import AgentIdentificationNote from './AgentIdentificationNote';

const SystemMetrics = dynamic(() => import('./system-metrics'), {
    ssr: false,
    loading: () => <div className="p-8 text-center">Loading system metrics...</div>,
});

const SystemMetricsWrapper = () => {
    const searchParams = useSearchParams();
    const pollerId = searchParams.get('pollerId') || 'poller-01'; // Fallback to 'poller-01' if not provided

    return (
        <div>
            <AgentIdentificationNote />
            <DeviceAttributionBanner pollerId={pollerId} />
            <SystemMetrics pollerId={pollerId} />
        </div>
    );
};

export default SystemMetricsWrapper;