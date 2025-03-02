// src/components/Dashboard.jsx - Client Component
'use client';

import React from 'react';

function Dashboard({ initialData = null }) {
    // No data fetching here - just use the data passed from server component

    if (!initialData) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-4 rounded-lg text-red-600 dark:text-red-200">
                <h3 className="font-bold mb-2">Error Loading Dashboard</h3>
                <p>Could not load dashboard data</p>
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
                    {initialData?.total_nodes || 0}
                </p>
            </div>

            {/* Card 2 */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="font-bold text-gray-800 dark:text-gray-100">
                    Healthy Nodes
                </h3>
                <p className="text-2xl text-gray-700 dark:text-gray-100 mt-2">
                    {initialData?.healthy_nodes || 0}
                </p>
            </div>

            {/* Card 3 */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="font-bold text-gray-800 dark:text-gray-100">
                    Last Update
                </h3>
                <p className="text-2xl text-gray-700 dark:text-gray-100 mt-2">
                    {initialData?.last_update
                        ? new Date(initialData.last_update).toLocaleTimeString()
                        : 'N/A'}
                </p>
            </div>
        </div>
    );
}

export default Dashboard;