// web/src/components/NodeList.jsx
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

  // Helper function to format JSON details for better display
  const formatBlockDetails = (message) => {
    try {
      const details = JSON.parse(message);
      return (
          <div className="grid grid-cols-2 gap-2 text-sm">
            <div>Height: <span className="text-blue-600">{details.height}</span></div>
            <div>Hash: <span className="font-mono text-xs break-all">{details.hash}</span></div>
            <div>Last Seen: {new Date(details.last_seen).toLocaleString()}</div>
            <div>Timestamp: {new Date(details.timestamp).toLocaleString()}</div>
          </div>
      );
    } catch (e) {
      return message;
    }
  };

  // Helper function to get service details
  const getServiceDetails = (service) => {
    switch (service.type) {
      case 'process':
        return `Monitoring process: ${service.details || service.message || service.name}`;
      case 'port':
        return `Monitoring port: ${service.port || (service.details && service.details.port) || '22'}`;
      case 'grpc':
        if (service.message) {
          return formatBlockDetails(service.message);
        }
        return null;
      default:
        return service.message || null;
    }
  };

  return (
      <div className="space-y-4">
        <h2 className="text-2xl font-bold">Nodes</h2>
        <div className="grid gap-4">
          {nodes.map((node) => (
              <div key={node.node_id} className="bg-white rounded-lg shadow p-6">
                <div className="flex items-center justify-between">
                  <h3 className="font-bold text-lg">{node.node_id}</h3>
                  <span className={`px-3 py-1 rounded-full text-sm ${
                      node.is_healthy
                          ? 'bg-green-100 text-green-800'
                          : 'bg-red-100 text-red-800'
                  }`}>
                {node.is_healthy ? 'Healthy' : 'Unhealthy'}
              </span>
                </div>

                <div className="mt-2 text-sm text-gray-600">
                  Last Update: {new Date(node.last_update).toLocaleString()}
                </div>

                <div className="mt-4">
                  <h4 className="font-semibold mb-2">Services:</h4>
                  <div className="space-y-2">
                    {node.services?.map((service) => (
                        <div
                            key={`${service.name}-${service.type}`}
                            className="bg-gray-50 p-3 rounded-lg"
                        >
                          <div className="flex items-center gap-2">
                            <div className={`w-2 h-2 rounded-full ${
                                service.available ? 'bg-green-500' : 'bg-red-500'
                            }`}></div>

                            <span className="font-medium">
                        {service.name || (service.type === 'port' ? 'SSH' : 'Unknown')}
                      </span>

                            <span className="text-sm text-gray-500">
                        ({service.type === 'process' && 'Process Monitor'}
                              {service.type === 'port' && 'Port Check'}
                              {service.type === 'grpc' && 'External Service'})
                      </span>

                            <span className={`text-sm ${
                                service.available ? 'text-green-600' : 'text-red-600'
                            }`}>
                        {service.available ? 'Available' : 'Unavailable'}
                      </span>
                          </div>

                          <div className="mt-2 ml-4 text-gray-600">
                            {getServiceDetails(service)}
                          </div>
                        </div>
                    ))}
                  </div>
                </div>

                <div className="mt-4">
                  <NodeTimeline nodeId={node.node_id} />
                </div>
              </div>
          ))}
        </div>
      </div>
  );
}

export default NodeList;