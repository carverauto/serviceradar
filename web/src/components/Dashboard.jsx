// src/components/Dashboard.jsx
import React, { useState, useEffect } from 'react';

function Dashboard() {
    const [systemStatus, setSystemStatus] = useState(null);

    useEffect(() => {
        const fetchStatus = async () => {
            try {
                const response = await fetch('/api/status');
                const data = await response.json();
                setSystemStatus(data);
            } catch (error) {
                console.error('Error fetching status:', error);
            }
        };

        fetchStatus();
        const interval = setInterval(fetchStatus, 10000);
        return () => clearInterval(interval);
    }, []);

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
