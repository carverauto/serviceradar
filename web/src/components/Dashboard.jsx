/*-
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