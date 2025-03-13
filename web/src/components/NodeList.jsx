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

'use client';

import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import ServiceSparkline from "./ServiceSparkline";
import { Filter, ArrowUp, ArrowDown, CheckCircle, XCircle } from 'lucide-react';

// Node Card for Mobile View
const NodeCard = ({ node, serviceMetrics, handleServiceClick }) => {
  return (
      <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 mb-4 transition-colors">
        <div className="flex items-center justify-between mb-3">
          <div className="flex items-center">
            {node.is_healthy ? (
                <CheckCircle className="w-4 h-4 text-green-500 mr-2" aria-hidden="true" />
            ) : (
                <XCircle className="w-4 h-4 text-red-500 mr-2" aria-hidden="true" />
            )}
            <h3 className="font-medium text-gray-800 dark:text-gray-100">{node.node_id}</h3>
          </div>
          <span className="text-xs text-gray-500 dark:text-gray-400">
          {new Date(node.last_update).toLocaleString()}
        </span>
        </div>

        <div className="mb-3">
          <p className="text-xs font-medium text-gray-600 dark:text-gray-400 mb-1">Services:</p>
          <div className="flex flex-wrap gap-2">
            {node.services?.map((service, idx) => (
                <div
                    key={`${service.name}-${idx}`}
                    className="inline-flex items-center gap-1 cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700 p-1 rounded transition-colors"
                    onClick={() => handleServiceClick(node.node_id, service.name)}
                    role="button"
                    aria-label={`${service.name} (${service.available ? 'Online' : 'Offline'})`}
                >
                  {service.available ? (
                      <CheckCircle className="w-3 h-3 text-green-500" aria-hidden="true" />
                  ) : (
                      <XCircle className="w-3 h-3 text-red-500" aria-hidden="true" />
                  )}
                  <span className="text-sm font-medium text-gray-800 dark:text-gray-100">{service.name}</span>
                </div>
            ))}
          </div>
        </div>

        {node.services?.filter(service => service.type === 'icmp').length > 0 && (
            <div>
              <p className="text-xs font-medium text-gray-600 dark:text-gray-400 mb-1">ICMP Response Time:</p>
              <div className="space-y-2">
                {node.services
                    ?.filter((service) => service.type === 'icmp')
                    .map((service, idx) => {
                      const metricKey = `${node.node_id}-${service.name}`;
                      const metricsForService = serviceMetrics[metricKey] || [];
                      return (
                          <div key={`${service.name}-${idx}`} className="flex items-center justify-between gap-2">
                            <ServiceSparkline
                                nodeId={node.node_id}
                                serviceName={service.name}
                                initialMetrics={metricsForService}
                            />
                          </div>
                      );
                    })}
              </div>
            </div>
        )}
      </div>
  );
};

function NodeList({ initialNodes = [], serviceMetrics = {} }) {
  const router = useRouter();
  const [searchTerm, setSearchTerm] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [nodesPerPage, setNodesPerPage] = useState(10);
  const [sortBy, setSortBy] = useState('name');
  const [sortOrder, setSortOrder] = useState('asc');
  const [nodes, setNodes] = useState(initialNodes);
  const [showFilters, setShowFilters] = useState(false);

  // Update nodes when initialNodes changes
  useEffect(() => {
    setNodes(initialNodes);
  }, [initialNodes]);

  // Set up auto-refresh
  useEffect(() => {
    const refreshInterval = 10000; // 10 seconds (sync with ServiceSparkline)
    const timer = setInterval(() => {
      router.refresh(); // Trigger server-side re-fetch of nodes/page.js
    }, refreshInterval);

    return () => clearInterval(timer);
  }, [router]);

  // Adjust nodes per page based on screen size
  useEffect(() => {
    const handleResize = () => {
      if (window.innerWidth < 768) {
        setNodesPerPage(5);
      } else {
        setNodesPerPage(10);
      }
    };

    handleResize(); // Initial call
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

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
                : b.is_healthy ? 1 : -1
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

  const toggleFilters = useCallback(() => {
    setShowFilters(!showFilters);
  }, [showFilters]);

  return (
      <div className="space-y-4 transition-colors text-gray-800 dark:text-gray-100">
        {/* Header row */}
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
          <h2 className="text-xl font-bold">Nodes ({sortedNodes.length})</h2>
          <div className="flex items-center gap-2">
            <div className="relative flex-1">
              <input
                  type="text"
                  placeholder="Search nodes..."
                  className="w-full px-3 py-1 border rounded text-gray-800 dark:text-gray-200 dark:bg-gray-800 dark:border-gray-600 placeholder-gray-500 dark:placeholder-gray-400 focus:outline-none focus:ring-1 focus:ring-blue-500 transition-colors"
                  value={searchTerm}
                  onChange={(e) => setSearchTerm(e.target.value)}
                  aria-label="Search nodes"
              />
            </div>
            <button
                onClick={toggleFilters}
                className="md:hidden px-3 py-1 border rounded text-gray-800 dark:text-gray-200 dark:bg-gray-800 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
                aria-label="Filters"
                aria-expanded={showFilters}
            >
              <Filter size={16} />
            </button>
          </div>
        </div>

        {/* Filters section - always visible on desktop, toggleable on mobile */}
        {(showFilters || window.innerWidth >= 768) && (
            <div className="flex flex-col sm:flex-row sm:items-center gap-2 py-2 bg-white dark:bg-gray-800 rounded-lg shadow px-4 transition-colors">
              <label className="text-sm font-medium" id="sort-by-label">Sort by:</label>
              <select
                  value={sortBy}
                  onChange={(e) => setSortBy(e.target.value)}
                  className="px-3 py-1 border rounded text-gray-800 dark:text-gray-200 dark:bg-gray-800 dark:border-gray-600 focus:outline-none focus:ring-1 focus:ring-blue-500 transition-colors"
                  aria-labelledby="sort-by-label"
              >
                <option value="name">Name</option>
                <option value="status">Status</option>
                <option value="lastUpdate">Last Update</option>
              </select>
              <button
                  onClick={toggleSortOrder}
                  className="px-3 py-1 border rounded text-gray-800 dark:text-gray-200 dark:bg-gray-800 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
                  aria-label={`Sort ${sortOrder === 'asc' ? 'ascending' : 'descending'}`}
              >
                {sortOrder === 'asc' ? <ArrowUp size={16} /> : <ArrowDown size={16} />}
              </button>
            </div>
        )}

        {/* Content placeholder when no nodes are found */}
        {sortedNodes.length === 0 && (
            <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-8 text-center">
              <h3 className="text-xl font-semibold mb-2">No nodes found</h3>
              <p className="text-gray-500 dark:text-gray-400">
                {searchTerm ? 'Try adjusting your search criteria' : 'No nodes are currently available'}
              </p>
            </div>
        )}

        {/* Mobile View */}
        <div className="md:hidden">
          {currentNodes.map(node => (
              <NodeCard
                  key={node.node_id}
                  node={node}
                  serviceMetrics={serviceMetrics}
                  handleServiceClick={handleServiceClick}
              />
          ))}
        </div>

        {/* Desktop View */}
        <div className="hidden md:block bg-white dark:bg-gray-800 rounded-lg shadow overflow-x-auto transition-colors">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700" aria-label="Nodes and services">
            <thead className="bg-gray-50 dark:bg-gray-700">
            <tr>
              <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider w-16">Status</th>
              <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider w-48">Node</th>
              <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Services</th>
              <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider w-64">ICMP Response Time</th>
              <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider w-48">Last Update</th>
            </tr>
            </thead>
            <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
            {currentNodes.map((node) => (
                <tr key={node.node_id}>
                  <td className="px-6 py-4 whitespace-nowrap">
                    {node.is_healthy ? (
                        <span className="flex items-center" aria-label="Online">
                        <CheckCircle className="w-4 h-4 text-green-500" />
                        <span className="sr-only">Online</span>
                      </span>
                    ) : (
                        <span className="flex items-center" aria-label="Offline">
                        <XCircle className="w-4 h-4 text-red-500" />
                        <span className="sr-only">Offline</span>
                      </span>
                    )}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-800 dark:text-gray-100">{node.node_id}</td>
                  <td className="px-6 py-4">
                    <div className="flex flex-wrap gap-2">
                      {node.services?.map((service, idx) => (
                          <div
                              key={`${service.name}-${idx}`}
                              className="inline-flex items-center gap-1 cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700 p-1 rounded transition-colors"
                              onClick={() => handleServiceClick(node.node_id, service.name)}
                              role="button"
                              aria-label={`${service.name} (${service.available ? 'Online' : 'Offline'})`}
                              tabIndex={0}
                              onKeyDown={(e) => {
                                if (e.key === 'Enter' || e.key === ' ') {
                                  e.preventDefault();
                                  handleServiceClick(node.node_id, service.name);
                                }
                              }}
                          >
                            {service.available ? (
                                <CheckCircle className="w-3 h-3 text-green-500" aria-hidden="true" />
                            ) : (
                                <XCircle className="w-3 h-3 text-red-500" aria-hidden="true" />
                            )}
                            <span className="text-sm font-medium text-gray-800 dark:text-gray-100">{service.name}</span>
                          </div>
                      ))}
                    </div>
                  </td>
                  <td className="px-6 py-4">
                    {node.services
                        ?.filter((service) => service.type === 'icmp')
                        .map((service, idx) => {
                          const metricKey = `${node.node_id}-${service.name}`;
                          const metricsForService = serviceMetrics[metricKey] || [];
                          return (
                              <div key={`${service.name}-${idx}`} className="flex items-center justify-between gap-2">
                                <ServiceSparkline
                                    nodeId={node.node_id}
                                    serviceName={service.name}
                                    initialMetrics={metricsForService}
                                />
                              </div>
                          );
                        })}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                    {new Date(node.last_update).toLocaleString()}
                  </td>
                </tr>
            ))}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {pageCount > 1 && (
            <nav className="flex justify-center flex-wrap gap-2 mt-4" aria-label="Pagination">
              {[...Array(pageCount)].map((_, i) => (
                  <button
                      key={i}
                      onClick={() => setCurrentPage(i + 1)}
                      className={`px-3 py-1 rounded transition-colors ${
                          currentPage === i + 1
                              ? 'bg-blue-500 text-white'
                              : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                      }`}
                      aria-label={`Page ${i + 1}`}
                      aria-current={currentPage === i + 1 ? 'page' : undefined}
                  >
                    {i + 1}
                  </button>
              ))}
            </nav>
        )}
      </div>
  );
}

export default NodeList;