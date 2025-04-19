// src/components/Metrics/SystemMetricsWrapper.tsx
'use client';

import React from 'react';
import dynamic from 'next/dynamic';
import { useSearchParams } from 'next/navigation';

const SystemMetrics = dynamic(() => import('./system-metrics'), {
    ssr: false,
    loading: () => <div className="p-8 text-center">Loading system metrics...</div>,
});

const SystemMetricsWrapper = () => {
    const searchParams = useSearchParams();
    const pollerId = searchParams.get('pollerId') || 'poller-01'; // Fallback to 'poller-01' if not provided

    return <SystemMetrics pollerId={pollerId} />;
};

export default SystemMetricsWrapper;