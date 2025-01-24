import React, { useState, useEffect, useMemo, useCallback } from 'react';
import NodeTimeline from './NodeTimeline';
import NetworkSweepView from './NetworkSweepView.jsx';
import _ from 'lodash';

function NodeList() {
  const [nodes, setNodes] = useState([]);
  const [searchTerm, setSearchTerm] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [nodesPerPage] = useState(10);
  const [sortBy, setSortBy] = useState('name');
  const [sortOrder, setSortOrder] = useState('asc');
  const [expandedNode, setExpandedNode] = useState(null);
  const [viewMode, setViewMode] = useState('grid');

  // Sort nodes by name (extracts numeric suffix for sorting)
  const sortNodesByName = useCallback((a, b) => {
    const aMatch = a.node_id.match(/(\d+)$/);
    const bMatch = b.node_id.match(/(\d+)$/);
    if (aMatch && bMatch) {
      return parseInt(aMatch[1]) - parseInt(bMatch[1]);
    }
    return a.node_id.localeCompare(b.node_id);
  }, []);

  // Sort services alphabetically by name
  const sortNodeServices = useCallback((services) => {
    return services?.sort((a, b) => a.name.localeCompare(b.name)) || [];
  }, []);

  // Memoized sorted and filtered nodes
  const sortedNodes = useMemo(() => {
    let results = nodes.map((node) => ({
      ...node,
      services: sortNodeServices(node.services),
    }));

    // Filter nodes based on search term
    if (searchTerm) {
      results = results.filter(
          (node) =>
              node.node_id.toLowerCase().includes(searchTerm.toLowerCase()) ||
              node.services?.some((service) =>
                  service.name.toLowerCase().includes(searchTerm.toLowerCase())
              )
      );
    }

    // Sort nodes based on the selected criteria
    let sortedResults = [...results];
    switch (sortBy) {
      case 'status':
        sortedResults.sort((a, b) =>
            b.is_healthy === a.is_healthy
                ? sortNodesByName(a, b)
                : b.is_healthy
                    ? 1
                    : -1
        );
        break;
      case 'name':
        sortedResults.sort(sortNodesByName);
        break;
      case 'lastUpdate':
        sortedResults.sort((a, b) => {
          const timeCompare = new Date(b.last_update) - new Date(a.last_update);
          return timeCompare === 0 ? sortNodesByName(a, b) : timeCompare;
        });
        break;
      default:
        break;
    }

    // Reverse the order if sortOrder is 'desc'
    if (sortOrder === 'desc') {
      sortedResults.reverse();
    }

    return sortedResults;
  }, [nodes, searchTerm, sortBy, sortOrder, sortNodesByName, sortNodeServices]);

  // Memoized paginated nodes
  const currentNodes = useMemo(() => {
    const indexOfLastNode = currentPage * nodesPerPage;
    const indexOfFirstNode = indexOfLastNode - nodesPerPage;
    return sortedNodes.slice(indexOfFirstNode, indexOfLastNode);
  }, [currentPage, nodesPerPage, sortedNodes]);

  // Memoized total page count
  const pageCount = useMemo(
      () => Math.ceil(sortedNodes.length / nodesPerPage),
      [sortedNodes, nodesPerPage]
  );

  // Fetch nodes with polling
  useEffect(() => {
    const fetchNodes = async () => {
      try {
        console.log('Fetching nodes...'); // Debugging
        const response = await fetch('/api/nodes');
        const newData = await response.json();

        // Log the fetched data
        console.log('Fetched nodes:', newData);

        // Sort nodes immediately after fetching
        const sortedData = newData.sort(sortNodesByName);

        // Log the sorted data
        console.log('Sorted nodes:', sortedData);

        // Only update state if data has changed
        setNodes((prevNodes) => {
          if (!_.isEqual(prevNodes, sortedData)) {
            console.log('Updating nodes state'); // Debugging
            return sortedData;
          }
          return prevNodes;
        });
      } catch (error) {
        console.error('Error fetching nodes:', error);
      }
    };

    fetchNodes(); // Fetch immediately on mount
    const interval = setInterval(fetchNodes, 10000); // Poll every 10 seconds

    // Cleanup interval on unmount
    return () => {
      console.log('Cleaning up interval'); // Debugging
      clearInterval(interval);
    };
  }, [sortNodesByName]);

  // Toggle sort order between 'asc' and 'desc'
  const toggleSortOrder = useCallback(() => {
    setSortOrder((prev) => (prev === 'asc' ? 'desc' : 'asc'));
  }, []);

  // Service status component
  const ServiceStatus = useCallback(({ service }) => (
      <div className="inline-flex items-center gap-1 bg-gray-50 rounded px-2 py-1 text-sm">
      <span
          className={`w-1.5 h-1.5 rounded-full ${
              service.available ? 'bg-green-500' : 'bg-red-500'
          }`}
      />
        <span className="font-medium">{service.name || 'unknown'}</span>
        <span className="text-gray-500">({service.type})</span>
      </div>
  ), []);

  return (
      <div className="space-y-4">
        {/* Header with search, sort, and view controls */}
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-bold">Nodes ({sortedNodes.length})</h2>
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
              <option value="name">Sort by Name</option>
              <option value="status">Sort by Status</option>
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
                  className={`px-3 py-1 rounded ${
                      viewMode === 'grid' ? 'bg-blue-500 text-white' : 'bg-gray-100'
                  }`}
              >
                Grid
              </button>
              <button
                  onClick={() => setViewMode('table')}
                  className={`px-3 py-1 rounded ${
                      viewMode === 'table' ? 'bg-blue-500 text-white' : 'bg-gray-100'
                  }`}
              >
                Table
              </button>
              <button
                  onClick={() => setViewMode('network')}
                  className={`px-3 py-1 rounded ${
                      viewMode === 'network' ? 'bg-blue-500 text-white' : 'bg-gray-100'
                  }`}
              >
                Network View
              </button>
            </div>
          </div>
        </div>

        {/* Network View */}
        {viewMode === 'network' && (
            <div className="space-y-4">
              {currentNodes.map((node) => {
                const sweepService = node.services?.find((s) => s.type === 'sweep');
                if (!sweepService) return null;

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

        {/* Grid View */}
        {viewMode === 'grid' ? (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {currentNodes.map((node) => (
                  <div
                      key={node.node_id}
                      className="bg-white rounded-lg shadow p-4 cursor-pointer hover:shadow-md transition-shadow"
                      onClick={() =>
                          setExpandedNode(expandedNode === node.node_id ? null : node.node_id)
                      }
                  >
                    <div className="flex items-center justify-between mb-2">
                      <div className="flex items-center gap-2">
                        <div
                            className={`w-2 h-2 rounded-full ${
                                node.is_healthy ? 'bg-green-500' : 'bg-red-500'
                            }`}
                        />
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
            // Table View
            <div className="bg-white rounded-lg shadow overflow-x-auto">
              <table className="min-w-full divide-y divide-gray-200">
                <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Status
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Node
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Services
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Last Update
                  </th>
                </tr>
                </thead>
                <tbody className="bg-white divide-y divide-gray-200">
                {currentNodes.map((node) => (
                    <tr
                        key={node.node_id}
                        onClick={() =>
                            setExpandedNode(expandedNode === node.node_id ? null : node.node_id)
                        }
                        className="hover:bg-gray-50 cursor-pointer"
                    >
                      <td className="px-6 py-4 whitespace-nowrap">
                        <div
                            className={`w-2 h-2 rounded-full ${
                                node.is_healthy ? 'bg-green-500' : 'bg-red-500'
                            }`}
                        />
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

        {/* Pagination */}
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