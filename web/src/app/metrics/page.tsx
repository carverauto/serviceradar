// src/app/metrics/page.tsx
import { Suspense } from 'react';
import SystemMetricsWrapper from '@/components/Metrics/SystemMetricsWrapper';
import Link from 'next/link';

export const metadata = {
    title: 'System Metrics - ServiceRadar',
    description: 'System monitoring metrics dashboard',
};

export default function MetricsPage() {
    return (
        <div className="space-y-6">
            <div className="flex justify-between items-center">
                <h1 className="text-2xl font-bold text-gray-900 dark:text-white">System Metrics</h1>
                <Link href="/dashboard" className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-200 flex items-center">
                    <span className="mr-2">←</span> Back to Dashboard
                </Link>
            </div>
            <Suspense fallback={<div>Loading system metrics...</div>}>
                <SystemMetricsWrapper />
            </Suspense>
        </div>
    );
}