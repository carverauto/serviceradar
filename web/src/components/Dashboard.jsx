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
        <div className="bg-white rounded-lg shadow p-6">
          <h3 className="font-bold">Total Nodes</h3>
          <p className="text-2xl">{systemStatus?.total_nodes || 0}</p>
        </div>
        <div className="bg-white rounded-lg shadow p-6">
          <h3 className="font-bold">Healthy Nodes</h3>
          <p className="text-2xl">{systemStatus?.healthy_nodes || 0}</p>
        </div>
        <div className="bg-white rounded-lg shadow p-6">
          <h3 className="font-bold">Last Update</h3>
          <p className="text-2xl">
            {systemStatus?.last_update ?
                new Date(systemStatus.last_update).toLocaleTimeString() :
                'N/A'}
          </p>
        </div>
      </div>
  );
}

export default Dashboard;