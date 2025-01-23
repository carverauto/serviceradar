import React, { useState, useEffect } from 'react';
import NodeTimeline from './NodeTimeline';
import NetworkSweepView from "./NetworkSweepView.jsx";

function NodeList() {
  const [nodes, setNodes] = useState([]);
  const [filteredNodes, setFilteredNodes] = useState([]);
  const [searchTerm, setSearchTerm] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [nodesPerPage] = useState(10);
  const [sortBy, setSortBy] = useState('status'); // 'status', 'name', 'lastUpdate'
  const [sortOrder, setSortOrder] = useState('asc');
  const [expandedNode, setExpandedNode] = useState(null);
  const [viewMode, setViewMode] = useState('grid'); // 'grid' or 'table'

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

  useEffect(() => {
    let results = [...nodes];

    // Apply search filter
    if (searchTerm) {
      results = results.filter(node =>
          node.node_id.toLowerCase().includes(searchTerm.toLowerCase()) ||
          node.services?.some(service =>
              service.name.toLowerCase().includes(searchTerm.toLowerCase())
          )
      );
    }

    // Apply sorting
    results.sort((a, b) => {
      let comparison = 0;

      switch (sortBy) {
        case 'status':
          comparison = (b.is_healthy === a.is_healthy) ? 0 : b.is_healthy ? 1 : -1;
          break;
        case 'name':
          // Extract last octet for IP address comparison
          const aMatch = a.node_id.match(/(\d+)$/);
          const bMatch = b.node_id.match(/(\d+)$/);
          if (aMatch && bMatch) {
            comparison = parseInt(aMatch[1]) - parseInt(bMatch[1]);
          } else {
            comparison = a.node_id.localeCompare(b.node_id);
          }
          break;
        case 'lastUpdate':
          comparison = new Date(b.last_update) - new Date(a.last_update);
          break;
        default:
          comparison = 0;
      }
      return sortOrder === 'asc' ? comparison : -comparison;
    });

    setFilteredNodes(results);
  }, [nodes, searchTerm, sortBy, sortOrder]);

  const toggleSortOrder = () => {
    setSortOrder(prev => prev === 'asc' ? 'desc' : 'asc');
  };

  const pageCount = Math.ceil(filteredNodes.length / nodesPerPage);
  const currentNodes = filteredNodes.slice(
      (currentPage - 1) * nodesPerPage,
      currentPage * nodesPerPage
  );

  const ServiceStatus = ({ service }) => (
      <div className="inline-flex items-center gap-1 bg-gray-50 rounded px-2 py-1 text-sm">
            <span className={`w-1.5 h-1.5 rounded-full ${
                service.available ? 'bg-green-500' : 'bg-red-500'
            }`} />
        <span className="font-medium">{service.name || 'unknown'}</span>
        <span className="text-gray-500">({service.type})</span>
      </div>
  );

  return (
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-bold">Nodes ({filteredNodes.length})</h2>
          <div className="flex gap-4">
            <input
                type="text"
                placeholder="Search nodes..."
                className="px-3 py-1 border rounded"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
            />
            <select
                value={sortBy}
                onChange={(e) => setSortBy(e.target.value)}
                className="px-3 py-1 border rounded"
            >
              <option value="status">Sort by Status</option>
              <option value="name">Sort by Name</option>
              <option value="lastUpdate">Sort by Last Update</option>
            </select>
            <button
                onClick={toggleSortOrder}
                className="px-3 py-1 border rounded"
            >
              {sortOrder === 'asc' ? '↑' : '↓'}
            </button>
            <div className="flex gap-2">
              <button
                  onClick={() => setViewMode('grid')}
                  className={`px-3 py-1 rounded ${viewMode === 'grid' ? 'bg-blue-500 text-white' : 'bg-gray-100'}`}
              >
                Grid
              </button>
              <button
                  onClick={() => setViewMode('table')}
                  className={`px-3 py-1 rounded ${viewMode === 'table' ? 'bg-blue-500 text-white' : 'bg-gray-100'}`}
              >
                Table
              </button>
              <button
                  onClick={() => setViewMode('network')}
                  className={`px-3 py-1 rounded ${viewMode === 'network' ? 'bg-blue-500 text-white' : 'bg-gray-100'}`}
              >
                Network View
              </button>
            </div>
          </div>
        </div>

        {viewMode === 'network' && (
            <div className="space-y-4">
              {currentNodes.map((node) => {
                const sweepService = node.services?.find(s => s.type === 'sweep');
                if (!sweepService) return null;

                console.log('Found sweep service:', { nodeId: node.node_id, service: sweepService });

                return (
                    <NetworkSweepView
                        key={`${node.node_id}-sweep`}
                        nodeId={node.node_id}
                        service={sweepService}
                    />
                );
              })}
            </div>
        )}

        {viewMode === 'grid' ? (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {currentNodes.map((node) => (
                  <div
                      key={node.node_id}
                      className="bg-white rounded-lg shadow p-4 cursor-pointer hover:shadow-md transition-shadow"
                      onClick={() => setExpandedNode(expandedNode === node.node_id ? null : node.node_id)}
                  >
                    <div className="flex items-center justify-between mb-2">
                      <div className="flex items-center gap-2">
                        <div className={`w-2 h-2 rounded-full ${
                            node.is_healthy ? 'bg-green-500' : 'bg-red-500'
                        }`} />
                        <h3 className="font-medium text-sm">{node.node_id}</h3>
                      </div>
                      <span className="text-xs text-gray-500">
                                    {new Date(node.last_update).toLocaleString()}
                                </span>
                    </div>

                    <div className="flex flex-wrap gap-2">
                      {node.services?.map((service, idx) => (
                          <ServiceStatus key={`${service.name}-${idx}`} service={service} />
                      ))}
                    </div>

                    {expandedNode === node.node_id && (
                        <div className="mt-4">
                          <NodeTimeline nodeId={node.node_id} />
                        </div>
                    )}
                  </div>
              ))}
            </div>
        ) : (
            <div className="bg-white rounded-lg shadow overflow-x-auto">
              <table className="min-w-full divide-y divide-gray-200">
                <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Status</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Node</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Services</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Last Update</th>
                </tr>
                </thead>
                <tbody className="bg-white divide-y divide-gray-200">
                {currentNodes.map((node) => (
                    <tr
                        key={node.node_id}
                        onClick={() => setExpandedNode(expandedNode === node.node_id ? null : node.node_id)}
                        className="hover:bg-gray-50 cursor-pointer"
                    >
                      <td className="px-6 py-4 whitespace-nowrap">
                        <div className={`w-2 h-2 rounded-full ${
                            node.is_healthy ? 'bg-green-500' : 'bg-red-500'
                        }`} />
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap text-sm font-medium">
                        {node.node_id}
                      </td>
                      <td className="px-6 py-4">
                        <div className="flex flex-wrap gap-2">
                          {node.services?.map((service, idx) => (
                              <ServiceStatus key={`${service.name}-${idx}`} service={service} />
                          ))}
                        </div>
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                        {new Date(node.last_update).toLocaleString()}
                      </td>
                    </tr>
                ))}
                </tbody>
              </table>
            </div>
        )}

        {pageCount > 1 && (
            <div className="flex justify-center gap-2 mt-4">
              {[...Array(pageCount)].map((_, i) => (
                  <button
                      key={i}
                      onClick={() => setCurrentPage(i + 1)}
                      className={`px-3 py-1 rounded ${
                          currentPage === i + 1 ? 'bg-blue-500 text-white' : 'bg-gray-100'
                      }`}
                  >
                    {i + 1}
                  </button>
              ))}
            </div>
        )}
      </div>
  );
}

export default NodeList;