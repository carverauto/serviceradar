import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';

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
        const duskNode = nodes.find(node =>
            node.services?.some(service => service.name === 'dusk')
        );

        if (!duskNode) {
          throw new Error('No Dusk node found');
        }

        console.log('Found Dusk node:', duskNode);

        // Get the Dusk service
        const duskService = duskNode.services.find(s => s.name === 'dusk');
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
          <div className="text-lg">Loading...</div>
        </div>
    );
  }

  if (error) {
    return (
        <div className="flex justify-center items-center h-64">
          <div className="text-red-500 text-lg">{error}</div>
        </div>
    );
  }

  const details = nodeStatus?.details || {};
  console.log('Node details:', details);

  return (
      <div className="space-y-6">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="text-lg font-semibold mb-2">Node Status</h3>
            <div className={`text-lg ${nodeStatus?.available ? 'text-green-600' : 'text-red-600'}`}>
              {nodeStatus?.available ? 'Online' : 'Offline'}
            </div>
          </div>

          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="text-lg font-semibold mb-2">Current Height</h3>
            <div className="text-lg">{details.height || 'N/A'}</div>
          </div>

          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="text-lg font-semibold mb-2">Latest Hash</h3>
            <div className="text-sm font-mono break-all">{details.hash || 'N/A'}</div>
          </div>
        </div>

        {blockHistory.length > 0 && (
            <div className="bg-white rounded-lg shadow p-6">
              <h3 className="text-lg font-semibold mb-4">Block Height History</h3>
              <div className="h-64">
                <ResponsiveContainer width="100%" height="100%">
                  <LineChart data={blockHistory}>
                    <CartesianGrid strokeDasharray="3 3" />
                    <XAxis
                        dataKey="timestamp"
                        tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                    />
                    <YAxis />
                    <Tooltip
                        labelFormatter={(ts) => new Date(ts).toLocaleString()}
                        formatter={(value, name) => [value, name === 'height' ? 'Block Height' : name]}
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