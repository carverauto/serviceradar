import { Suspense } from 'react';
import SystemMetricsWrapper from '@/components/Metrics/SystemMetricsWrapper';
import ApiQueryClient from '@/components/APIQueryClient';

export default function HomePage() {
  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold mb-4">Welcome to ServiceRadar</h1>
      <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
        <h2 className="text-xl font-semibold mb-4">System Metrics</h2>
        <Suspense fallback={<div className="p-4 text-center">Loading charts...</div>}>
          <SystemMetricsWrapper />
        </Suspense>
      </div>
      <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
        <h2 className="text-xl font-semibold mb-4">Run SRQL Query</h2>
        <Suspense fallback={<div className="p-4 text-center">Loading query tool...</div>}>
          <ApiQueryClient />
        </Suspense>
      </div>
    </div>
  );
}
