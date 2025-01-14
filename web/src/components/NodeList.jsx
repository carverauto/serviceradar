// src/components/NodeList.jsx
import React, { useState, useEffect } from 'react';
import NodeTimeline from './NodeTimeline';

function NodeList() {
  const [nodes, setNodes] = useState([]);

  useEffect(() => {
    const fetchNodes = async () => {
      try {
        const response = await fetch('/api/nodes');
        const data = await response.json();
        setNodes(data);
      } catch (error) {
        console.error('Error fetching nodes:', error);
      }
    };

    fetchNodes();
    const interval = setInterval(fetchNodes, 10000);
    return () => clearInterval(interval);
  }, []);

  return (
      <div className="space-y-4">
        <h2 className="text-2xl font-bold">Nodes</h2>
        <div className="grid gap-4">
          {nodes.map((node) => (
              <div key={node.node_id} className="bg-white rounded-lg shadow p-6">
                <h3 className="font-bold text-lg">{node.node_id}</h3>
                <div className="mt-2">
                  <p>Status: {node.is_healthy ?
                      <span className="text-green-600">Healthy</span> :
                      <span className="text-red-600">Unhealthy</span>
                  }</p>
                  <p>Last Update: {new Date(node.last_update).toLocaleString()}</p>
                  <div className="mt-2">
                    <h4 className="font-semibold">Services:</h4>
                    <ul className="mt-1">
                      {node.services?.map((service) => (
                          <li key={service.name} className="ml-4">
                            • {service.name}: {service.available ? 'Available' : 'Unavailable'}
                          </li>
                      ))}
                    </ul>
                  </div>
                  <div className="mt-4">
                    <NodeTimeline nodeId={node.node_id} />
                  </div>
                </div>
              </div>
          ))}
        </div>
      </div>
  );
}

export default NodeList;