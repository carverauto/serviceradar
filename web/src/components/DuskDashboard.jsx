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

import React, { useState, useEffect } from 'react';
import {
  LineChart,
  CartesianGrid,
  ResponsiveContainer,
} from 'recharts';

const DuskDashboard = () => {
  const [nodeStatus, setNodeStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [blockHistory, setBlockHistory] = useState([]);

  useEffect(() => {
    const fetchData = async () => {
      try {
        // Fetch nodes list
        const nodesResponse = await fetch('/api/nodes');
        if (!nodesResponse.ok) throw new Error('Failed to fetch nodes');
        const nodes = await nodesResponse.json();

        console.log('Fetched nodes:', nodes);

        // Find the Dusk node
        const duskNode = nodes.find((node) =>
            node.services?.some((service) => service.name === 'dusk')
        );

        if (!duskNode) {
          throw new Error('No Dusk node found');
        }

        console.log('Found Dusk node:', duskNode);

        // Get the Dusk service
        const duskService = duskNode.services.find((s) => s.name === 'dusk');
        console.log('Dusk service:', duskService);

        setNodeStatus(duskService);

        // Try to parse block history from details
        if (duskService?.details?.history) {
          setBlockHistory(duskService.details.history);
        }

        setLoading(false);
      } catch (err) {
        console.error('Error fetching data:', err);
        setError(err.message);
        setLoading(false);
      }
    };

    fetchData();
    const interval = setInterval(fetchData, 10000);
    return () => clearInterval(interval);
  }, []);

  if (loading) {
    return (
        <div className="flex justify-center items-center h-64">
          <div className="text-lg dark:text-gray-100 transition-colors">
            Loading...
          </div>
        </div>
    );
  }

  if (error) {
    return (
        <div className="flex justify-center items-center h-64">
          <div className="text-red-500 dark:text-red-400 text-lg transition-colors">
            {error}
          </div>
        </div>
    );
  }

  const details = nodeStatus?.details || {};

  return (
      <div className="space-y-6 transition-colors">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {/* Card 1: Node Status */}
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
              Node Status
            </h3>
            <div
                className={`text-lg transition-colors ${
                    nodeStatus?.available
                        ? 'text-green-600 dark:text-green-400'
                        : 'text-red-600 dark:text-red-400'
                }`}
            >
              {nodeStatus?.available ? 'Online' : 'Offline'}
            </div>
          </div>

          {/* Card 2: Current Height */}
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
              Current Height
            </h3>
            <div className="text-lg text-gray-800 dark:text-gray-100">
              {details.height || 'N/A'}
            </div>
          </div>

          {/* Card 3: Latest Hash */}
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
              Latest Hash
            </h3>
            <div className="text-sm font-mono break-all text-gray-700 dark:text-gray-200">
              {details.hash || 'N/A'}
            </div>
          </div>
        </div>

        {/* Block History Chart */}
        {blockHistory.length > 0 && (
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
              <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">
                Block Height History
              </h3>
              <div className="h-64">
                <ResponsiveContainer width="100%" height="100%">
                  <LineChart data={blockHistory}>
                    <CartesianGrid
                        strokeDasharray="3 3"
                        // Optionally adjust stroke color for dark mode
                        stroke="#ccc"
                    />
                    <XAxis
                        dataKey="timestamp"
                        tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                        // For dark mode, consider override. Recharts doesn't read tailwind classes directly.
                    />
                    <YAxis />
                    <Tooltip
                        labelFormatter={(ts) => new Date(ts).toLocaleString()}
                        formatter={(value, name) => [
                          value,
                          name === 'height' ? 'Block Height' : name,
                        ]}
                    />
                    <Legend />
                    <Line
                        type="monotone"
                        dataKey="height"
                        stroke="#8884d8"
                        dot={false}
                        name="Block Height"
                    />
                  </LineChart>
                </ResponsiveContainer>
              </div>
            </div>
        )}
      </div>
  );
};

export default DuskDashboard;
