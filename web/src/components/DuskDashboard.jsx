// src/components/DuskDashboard.jsx
import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';

function DuskDashboard() {
  const [nodeStatus, setNodeStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [nodeId, setNodeId] = useState(null);
  const [error, setError] = useState(null);

  // Watch for nodeStatus changes (Debug logging)
  useEffect(() => {
    console.log('Node status updated:', nodeStatus);
    if (nodeStatus?.Services) {
      console.log('Dusk service:', nodeStatus.Services.find(s => s.Name === 'dusk'));
    }
  }, [nodeStatus]);

  // Update the node finding logic in the useEffect
  useEffect(() => {
    const findDuskNode = async () => {
      console.log('Fetching nodes list...');
      try {
        const response = await fetch('/api/nodes');
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }
        const data = await response.json();
        console.log('Available nodes:', data);

        // Detailed logging of the first node's services
        if (data && data[0]) {
          console.log('First node services:', data[0].services);
          data[0].services?.forEach((service, index) => {
            console.log(`Service ${index}:`, service);
          });
        }

        // Look for a node with Dusk service
        const duskNode = data.find(node => {
          console.log('Checking node services:', node.services);
          const hasDusk = node.services?.some(service => {
            console.log('Checking service:', service);
            return service.name === 'dusk' || service.Name === 'dusk';
          });
          console.log('Has Dusk service:', hasDusk);
          return hasDusk;
        });

        console.log('Found Dusk node:', duskNode);

        if (duskNode) {
          setNodeId(duskNode.node_id);
          console.log('Set node ID to:', duskNode.node_id);
        } else {
          console.log('No Dusk node found in data:', data);
          setError('No Dusk node found in the nodes list');
        }
      } catch (error) {
        console.error('Error fetching nodes:', error);
        setError(error.message);
      } finally {
        setLoading(false);
      }
    };

    findDuskNode();
    const interval = setInterval(findDuskNode, 10000);
    return () => clearInterval(interval);
  }, []);

  // Then fetch specific node data
  useEffect(() => {
    if (!nodeId) return;

    const fetchData = async () => {
      console.log(`Fetching data for node: ${nodeId}`);
      try {
        const response = await fetch(`/api/nodes/${nodeId}`);
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }
        const data = await response.json();
        console.log('Received node data:', data);
        setNodeStatus(data);
      } catch (error) {
        console.error('Error fetching node data:', error);
        setError(error.message);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
    const interval = setInterval(fetchData, 10000);
    return () => clearInterval(interval);
  }, [nodeId]);

  if (loading) {
    return (
        <div className="flex flex-col items-center justify-center h-96">
          <p className="text-lg mb-4">Loading...</p>
          <p className="text-sm text-gray-500">Node ID: {nodeId || 'None'}</p>
        </div>
    );
  }

  if (error) {
    return (
        <div className="flex flex-col items-center justify-center h-96">
          <p className="text-lg text-red-500 mb-4">Error: {error}</p>
          <p className="text-sm text-gray-500">Node ID: {nodeId || 'None'}</p>
        </div>
    );
  }

  const duskService = nodeStatus?.services?.find(s => s.name === 'dusk');
  const blockData = duskService?.details ?
      (typeof duskService.details === 'string' ?
          JSON.parse(duskService.details) :
          duskService.details) : null;

  return (
      <div className="space-y-4">
        {/* Status Overview */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="font-bold">Status</h3>
            <p className="text-2xl">{duskService?.Available ? 'Healthy' : 'Unhealthy'}</p>
          </div>
          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="font-bold">Block Height</h3>
            <p className="text-2xl">{blockData?.Height || 'N/A'}</p>
          </div>
          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="font-bold">Last Update</h3>
            <p className="text-2xl">
              {nodeStatus?.LastUpdate ?
                  new Date(nodeStatus.LastUpdate).toLocaleTimeString() :
                  'N/A'}
            </p>
          </div>
          <div className="bg-white rounded-lg shadow p-6">
            <h3 className="font-bold">Uptime</h3>
            <p className="text-2xl">{nodeStatus?.UpTime || 'N/A'}</p>
          </div>
        </div>

        {/* Block Height Chart */}
        <div className="bg-white rounded-lg shadow p-6">
          <h3 className="font-bold mb-4">Block Height History</h3>
          <div className="h-80">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart
                  data={blockData?.blockHistory || []}
                  margin={{ top: 5, right: 30, left: 20, bottom: 5 }}
              >
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis
                    dataKey="timestamp"
                    tickFormatter={(time) => new Date(time).toLocaleTimeString()}
                />
                <YAxis />
                <Tooltip
                    labelFormatter={(label) => new Date(label).toLocaleString()}
                />
                <Legend />
                <Line
                    type="monotone"
                    dataKey="height"
                    stroke="#8884d8"
                    dot={false}
                />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>
  );
}

export default DuskDashboard;