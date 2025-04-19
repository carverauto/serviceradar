'use client';

import React from 'react';
import dynamic from 'next/dynamic';

// Dynamically import the EnvMetricsDemo to avoid any server/client hydration issues
const EnvMetricsDemo = dynamic(() => import('./EnvMetricsDemo'), {
    ssr: false,
    loading: () => <div className="p-8 text-center">Loading environment metrics...</div>
});

const EnvironmentMetricsWrapper = () => {
    return <EnvMetricsDemo />;
};

export default EnvironmentMetricsWrapper;