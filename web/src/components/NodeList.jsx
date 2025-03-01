// src/components/NodeList.jsx
'use client';

import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import ServiceSparkline from "./ServiceSparkline";

function NodeList({ initialNodes = [] }) {
  const router = useRouter();
  const [searchTerm, setSearchTerm] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [nodesPerPage] = useState(10);
  const [sortBy, setSortBy] = useState('name');
  const [sortOrder, setSortOrder] = useState('asc');
  // Use initialNodes directly instead of fetching
  const [nodes, setNodes] = useState(initialNodes);

  // Add auto-refresh functionality
  useEffect(() => {
    // Update from new props when initialNodes changes
    setNodes(initialNodes);
  }, [initialNodes]);

  // Optional: Add page refresh
  useEffect(() => {
    const interval = setInterval(() => {
      router.refresh(); // Trigger server-side refetch
    }, 30000); // Every 30 seconds

    return () => clearInterval(interval);
  }, [router]);

  const sortNodesByName = useCallback((a, b) => {
    const aMatch = a.node_id.match(/(\d+)$/);
    const bMatch = b.node_id.match(/(\d+)$/);
    if (aMatch && bMatch) {
      return parseInt(aMatch[1]) - parseInt(bMatch[1]);
    }
    return a.node_id.localeCompare(b.node_id);
  }, []);

  const sortNodeServices = useCallback((services) => {
    return services?.sort((a, b) => a.name.localeCompare(b.name)) || [];
  }, []);

  const sortedNodes = useMemo(() => {
    if (!nodes || nodes.length === 0) return [];

    let results = nodes.map((node) => ({
      ...node,
      services: sortNodeServices(node.services),
    }));

    if (searchTerm) {
      results = results.filter(
          (node) =>
              node.node_id.toLowerCase().includes(searchTerm.toLowerCase()) ||
              node.services?.some((service) =>
                  service.name.toLowerCase().includes(searchTerm.toLowerCase())
              )
      );
    }

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
    }

    if (sortOrder === 'desc') {
      sortedResults.reverse();
    }

    return sortedResults;
  }, [nodes, searchTerm, sortBy, sortOrder, sortNodesByName, sortNodeServices]);

  const currentNodes = useMemo(() => {
    const indexOfLastNode = currentPage * nodesPerPage;
    const indexOfFirstNode = indexOfLastNode - nodesPerPage;
    return sortedNodes.slice(indexOfFirstNode, indexOfLastNode);
  }, [currentPage, nodesPerPage, sortedNodes]);

  const pageCount = useMemo(
      () => Math.ceil(sortedNodes.length / nodesPerPage),
      [sortedNodes, nodesPerPage]
  );

  const handleServiceClick = (nodeId, serviceName) => {
    router.push(`/service/${nodeId}/${serviceName}`);
  };

  const toggleSortOrder = useCallback(() => {
    setSortOrder((prev) => (prev === 'asc' ? 'desc' : 'asc'));
  }, []);

  // Regular Component Content
  return (
      <div className="space-y-4 transition-colors text-gray-800 dark:text-gray-100">
        {/* Header row */}
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-bold">Nodes ({sortedNodes.length})</h2>
          <div className="flex gap-4">
            <input
                type="text"
                placeholder="Search nodes..."
                className="px-3 py-1 border rounded text-gray-800 dark:text-gray-200
                   dark:bg-gray-800 dark:border-gray-600
                   placeholder-gray-500 dark:placeholder-gray-400
                   focus:outline-none focus:ring-1 focus:ring-blue-500 transition-colors"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
            />
            <select
                value={sortBy}
                onChange={(e) => setSortBy(e.target.value)}
                className="px-3 py-1 border rounded text-gray-800 dark:text-gray-200
                   dark:bg-gray-800 dark:border-gray-600
                   focus:outline-none focus:ring-1 focus:ring-blue-500 transition-colors"
            >
              <option value="name">Sort by Name</option>
              <option value="status">Sort by Status</option>
              <option value="lastUpdate">Sort by Last Update</option>
            </select>
            <button
                onClick={toggleSortOrder}
                className="px-3 py-1 border rounded text-gray-800 dark:text-gray-200
                   dark:bg-gray-800 dark:border-gray-600
                   hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              {sortOrder === 'asc' ? '↑' : '↓'}
            </button>
          </div>
        </div>

        {/* Content placeholder when no nodes are found */}
        {sortedNodes.length === 0 && (
            <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-8 text-center">
              <h3 className="text-xl font-semibold mb-2">No nodes found</h3>
              <p className="text-gray-500 dark:text-gray-400">
                {searchTerm ? 'Try adjusting your search criteria' : 'No nodes are currently available'}
              </p>
            </div>
        )}

        {/* Main content */}
        {renderTableView()}

        {/* Pagination */}
        {pageCount > 1 && (
            <div className="flex justify-center gap-2 mt-4">
              {[...Array(pageCount)].map((_, i) => (
                  <button
                      key={i}
                      onClick={() => setCurrentPage(i + 1)}
                      className={`px-3 py-1 rounded transition-colors ${
                          currentPage === i + 1
                              ? 'bg-blue-500 text-white'
                              : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                      }`}
                  >
                    {i + 1}
                  </button>
              ))}
            </div>
        )}
      </div>
  );

  function renderTableView() {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-x-auto transition-colors">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className="bg-gray-50 dark:bg-gray-700">
            <tr>
              <th
                  className="px-6 py-3 text-left text-xs font-medium
                         text-gray-500 dark:text-gray-300 uppercase tracking-wider w-16"
              >
                Status
              </th>
              <th
                  className="px-6 py-3 text-left text-xs font-medium
                         text-gray-500 dark:text-gray-300 uppercase tracking-wider w-48"
              >
                Node
              </th>
              <th
                  className="px-6 py-3 text-left text-xs font-medium
                         text-gray-500 dark:text-gray-300 uppercase tracking-wider"
              >
                Services
              </th>
              <th
                  className="px-6 py-3 text-left text-xs font-medium
                         text-gray-500 dark:text-gray-300 uppercase tracking-wider w-64"
              >
                ICMP Response Time
              </th>
              <th
                  className="px-6 py-3 text-left text-xs font-medium
                         text-gray-500 dark:text-gray-300 uppercase tracking-wider w-48"
              >
                Last Update
              </th>
            </tr>
            </thead>
            <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
            {currentNodes.map((node) => (
                <tr key={node.node_id}>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <div
                        className={`w-2 h-2 rounded-full ${
                            node.is_healthy ? 'bg-green-500' : 'bg-red-500'
                        }`}
                    />
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-800 dark:text-gray-100">
                    {node.node_id}
                  </td>
                  <td className="px-6 py-4">
                    <div className="flex flex-wrap gap-2">
                      {node.services?.map((service, idx) => (
                          <div
                              key={`${service.name}-${idx}`}
                              className="inline-flex items-center gap-1 cursor-pointer
                             hover:bg-gray-100 dark:hover:bg-gray-700 p-1 rounded transition-colors"
                              onClick={() =>
                                  handleServiceClick(node.node_id, service.name)
                              }
                          >
                        <span
                            className={`w-1.5 h-1.5 rounded-full ${
                                service.available ? 'bg-green-500' : 'bg-red-500'
                            }`}
                        />
                            <span className="text-sm font-medium text-gray-800 dark:text-gray-100">
                          {service.name}
                        </span>
                          </div>
                      ))}
                    </div>
                  </td>
                  <td className="px-6 py-4">
                    {node.services
                        ?.filter((service) => service.type === 'icmp')
                        .map((service, idx) => (
                            <div
                                key={`${service.name}-${idx}`}
                                className="flex items-center justify-between gap-2"
                            >
                              <ServiceSparkline
                                  nodeId={node.node_id}
                                  serviceName={service.name}
                                  // Pass the metrics directly from node.metrics, making sure it exists
                                  initialMetrics={node.metrics ? node.metrics[service.name] || [] : []}
                              />
                            </div>
                        ))}
                  </td>
                 <td className="px-6 py-4 whitespace-nowrap text-sm
                           text-gray-500 dark:text-gray-400"
                  >
                    {new Date(node.last_update).toLocaleString()}
                  </td>
                </tr>
            ))}
            </tbody>
          </table>
        </div>
    );
  }
}

export default NodeList;