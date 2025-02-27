// src/components/Dashboard.jsx
'use client';

import React from 'react';
import { useAPIData } from '@/lib/api';

function Dashboard({ initialData = null }) {
    // Use improved API client with caching - refresh every 30 seconds instead of 10
    const { data: systemStatus, error, isLoading } = useAPIData('/api/status', initialData, 30000);

    if (isLoading && !systemStatus) {
        return (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                {[...Array(3)].map((_, i) => (
                    <div key={i} className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 animate-pulse">
                        <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/3 mb-4"></div>
                        <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-1/4"></div>
                    </div>
                ))}
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-4 rounded-lg text-red-600 dark:text-red-200">
                <h3 className="font-bold mb-2">Error Loading Dashboard</h3>
                <p>{error}</p>
            </div>
        );
    }

    return (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {/* Card 1 */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="font-bold text-gray-800 dark:text-gray-100">
                    Total Nodes
                </h3>
                <p className="text-2xl text-gray-700 dark:text-gray-100 mt-2">
                    {systemStatus?.total_nodes || 0}
                </p>
            </div>

            {/* Card 2 */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="font-bold text-gray-800 dark:text-gray-100">
                    Healthy Nodes
                </h3>
                <p className="text-2xl text-gray-700 dark:text-gray-100 mt-2">
                    {systemStatus?.healthy_nodes || 0}
                </p>
            </div>

            {/* Card 3 */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="font-bold text-gray-800 dark:text-gray-100">
                    Last Update
                </h3>
                <p className="text-2xl text-gray-700 dark:text-gray-100 mt-2">
                    {systemStatus?.last_update
                        ? new Date(systemStatus.last_update).toLocaleTimeString()
                        : 'N/A'}
                </p>
            </div>
        </div>
    );
}

export default Dashboard;