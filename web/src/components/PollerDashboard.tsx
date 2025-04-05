'use client';

import React, {useState, useEffect, useMemo, useCallback} from 'react';
import {
    Server,
    AlertCircle,
    CheckCircle,
    ChevronDown,
    ChevronUp,
    AlertTriangle,
    Clock,
    Zap,
    Search,
    ArrowUpDown,
    Settings,
    Layers
} from 'lucide-react';
import { useRouter } from 'next/navigation';
import { Node, ServiceMetric, Service } from "@/types/types";

interface PollerDashboardProps {
    initialNodes: Node[];
    serviceMetrics: { [key: string]: ServiceMetric[] };
}

interface TransformedPoller {
    id: string;
    name: string;
    status: 'healthy' | 'warning' | 'critical';
    lastUpdate: string;
    responseTrend: number[];
    responseTrendRaw: ServiceMetric[];
    servicesCount: {
        total: number;
        healthy: number;
        warning: number;
        critical: number;
    };
    serviceGroups: {
        name: string;
        count: number;
        healthy: number;
        services: Service[];
    }[];
    services: Service[];
    tags: string[];
    rawNode: Node;
}

const PollerDashboard: React.FC<PollerDashboardProps> = ({
                                                             initialNodes = [],
                                                             serviceMetrics = {}
                                                         }) => {
    const [nodes, setNodes] = useState<Node[]>(initialNodes);
    const [expandedPoller, setExpandedPoller] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState<string>('');
    const [filterStatus, setFilterStatus] = useState<string>('all');
    const [sortBy, setSortBy] = useState<"name" | "status" | "lastUpdate">("name");
    const [sortOrder, setSortOrder] = useState<"asc" | "desc">("asc");
    const router = useRouter();

    // Update nodes when initialNodes changes from server
    useEffect(() => {
        setNodes(initialNodes);
    }, [initialNodes]);

    // Set up auto-refresh
    useEffect(() => {
        const refreshInterval = 10000; // 10 seconds
        const timer = setInterval(() => {
            router.refresh(); // Trigger server-side re-fetch
        }, refreshInterval);

        return () => clearInterval(timer);
    }, [router]);

    const sortPollers = useCallback((a: TransformedPoller, b: TransformedPoller): number => {
        switch (sortBy) {
            case "name":
                return sortOrder === "asc"
                    ? a.name.localeCompare(b.name)
                    : b.name.localeCompare(a.name);
            case "status":
                // Sort by status priority: critical > warning > healthy
                const statusPriority = { critical: 0, warning: 1, healthy: 2 };
                const diff = statusPriority[a.status] - statusPriority[b.status];
                return sortOrder === "asc" ? diff : -diff;
            case "lastUpdate":
                const dateA = new Date(a.lastUpdate).getTime();
                const dateB = new Date(b.lastUpdate).getTime();
                return sortOrder === "asc" ? dateA - dateB : dateB - dateA;
            default:
                return 0;
        }
    }, [sortBy, sortOrder]);

    // Group services by their type
    const groupServicesByType = (services: Service[] = []): { [key: string]: Service[] } => {
        const groups: { [key: string]: Service[] } = {};

        services.forEach(service => {
            // Determine best group for this service
            let groupName = 'Other';

            // Network-related services
            if (['icmp', 'sweep', 'network_sweep'].includes(service.type)) {
                groupName = 'Network';
            }
            // Database services
            else if (['mysql', 'postgres', 'mongodb', 'redis'].includes(service.name.toLowerCase())) {
                groupName = 'Databases';
            }
            // Monitoring/agent services
            else if (['snmp', 'serviceradar-agent'].includes(service.type) || service.name.includes('agent')) {
                groupName = 'Monitoring';
            }
            // Application services (examples based on your code)
            else if (['dusk', 'rusk', 'grpc', 'rperf-checker'].includes(service.name)) {
                groupName = 'Applications';
            }
            // Security services
            else if (['ssh', 'SSL'].includes(service.name)) {
                groupName = 'Security';
            }

            if (!groups[groupName]) {
                groups[groupName] = [];
            }
            groups[groupName].push(service);
        });

        return groups;
    };

    // Transform nodes data to dashboard format
    const transformedPollers = useMemo((): TransformedPoller[] => {
        return nodes.map(node => {
            // Calculate service counts
            const totalServices = node.services?.length || 0;
            const healthyServices = node.services?.filter(s => s.available).length || 0;

            // Calculate services with warnings (you can define your own warning criteria)
            // This example counts services that have details with warning flags or high response times
            let warningServices = 0;
            let criticalServices = 0;

            node.services?.forEach(service => {
                if (!service.available) {
                    criticalServices++;
                } else if (service.details && typeof service.details !== 'string') {
                    const details = service.details;
                    // Example criteria: Response time over 100ms but service is still available
                    if (details.response_time && details.response_time > 100000000 && service.available) {
                        warningServices++;
                    }
                }
            });

            // Determine overall status
            let status: 'healthy' | 'warning' | 'critical' = 'healthy';
            if (criticalServices > 0) {
                status = 'critical';
            } else if (warningServices > 0) {
                status = 'warning';
            }

            // Extract ICMP metrics for this node
            let icmpMetrics: ServiceMetric[] = [];
            let responseTrend: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

            // Find metrics for any ICMP service
            const icmpService = node.services?.find(s => s.type === 'icmp');
            if (icmpService) {
                const metricKey = `${node.node_id}-${icmpService.name}`;
                if (serviceMetrics[metricKey]) {
                    icmpMetrics = serviceMetrics[metricKey];
                    // Convert to milliseconds and take last 10 points if available
                    responseTrend = icmpMetrics
                        .slice(Math.max(0, icmpMetrics.length - 10))
                        .map(m => m.response_time / 1000000);
                }
            }

            // Group services by type
            const servicesByType = groupServicesByType(node.services);

            // Create service groups
            const serviceGroups = Object.entries(servicesByType).map(([name, services]) => ({
                name,
                count: services.length,
                healthy: services.filter(s => s.available).length,
                services
            }));

            // Generate tags based on node and services
            const tags: string[] = [];

            // Basic tag: is node healthy?
            tags.push(node.is_healthy ? 'healthy' : 'unhealthy');

            // Add tags based on service types
            if (servicesByType['Network']) tags.push('network-services');
            if (servicesByType['Databases']) tags.push('database-services');
            if (servicesByType['Applications']) tags.push('applications');

            // Add other meaningful tags you might derive from your data
            if (node.node_id.includes('dev')) tags.push('development');
            if (node.node_id.includes('prod')) tags.push('production');

            // Region tags (example)
            if (node.node_id.includes('east')) tags.push('east-region');
            if (node.node_id.includes('west')) tags.push('west-region');

            return {
                id: node.node_id,
                name: node.node_id,
                status,
                lastUpdate: new Date(node.last_update).toLocaleString(),
                responseTrend,
                responseTrendRaw: icmpMetrics,
                servicesCount: {
                    total: totalServices,
                    healthy: healthyServices,
                    warning: warningServices,
                    critical: criticalServices
                },
                serviceGroups,
                services: node.services || [],
                tags,
                rawNode: node
            };
        });
    }, [nodes, serviceMetrics]);

    // Filter and sort pollers
    const filteredPollers = useMemo(() => {
        return [...transformedPollers]
            .filter(poller => {
                const matchesSearch =
                    poller.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
                    poller.tags.some(tag => tag.toLowerCase().includes(searchTerm.toLowerCase())) ||
                    poller.services.some(service => service.name.toLowerCase().includes(searchTerm.toLowerCase()));

                const matchesStatus =
                    filterStatus === 'all' ||
                    (filterStatus === 'healthy' && poller.status === 'healthy') ||
                    (filterStatus === 'warning' && poller.status === 'warning') ||
                    (filterStatus === 'critical' && poller.status === 'critical');

                return matchesSearch && matchesStatus;
            })
            .sort(sortPollers);
    }, [transformedPollers, searchTerm, filterStatus, sortPollers]);

    const toggleExpand = (pollerId: string) => {
        if (expandedPoller === pollerId) {
            setExpandedPoller(null);
        } else {
            setExpandedPoller(pollerId);
        }
    };

    const toggleSortOrder = () => {
        setSortOrder(prev => prev === "asc" ? "desc" : "asc");
    };

    const getStatusIcon = (status: string) => {
        switch (status) {
            case 'healthy':
                return <CheckCircle className="h-5 w-5 text-green-500" />;
            case 'warning':
                return <AlertTriangle className="h-5 w-5 text-yellow-500" />;
            case 'critical':
                return <AlertCircle className="h-5 w-5 text-red-500" />;
            default:
                return <AlertCircle className="h-5 w-5 text-gray-500" />;
        }
    };

    // Navigate to service details page
    const handleServiceClick = (nodeId: string, serviceName: string) => {
        router.push(`/service/${nodeId}/${serviceName}`);
    };

    // Navigate to node details page
    const viewDetailedDashboard = (nodeId: string) => {
        router.push(`/nodes/${nodeId}`);
    };

    // Simple sparkline component to visualize response time trends
    const SimpleSparkline = ({ data, status }: { data: number[], status: string }) => {
        if (!data.length || data.every(d => d === 0)) {
            return <div className="text-xs text-gray-500">No data</div>;
        }

        const max = Math.max(...data);
        const min = Math.min(...data);
        const range = max - min || 1; // Avoid division by zero
        const height = 30;
        const width = 100;

        let strokeColor = "#4ADE80"; // green for healthy
        if (status === 'warning') strokeColor = "#FACC15"; // yellow
        if (status === 'critical') strokeColor = "#EF4444"; // red

        const points = data.map((value, index) => {
            const x = (index / (data.length - 1)) * width;
            const normalizedValue = (value - min) / range;
            const y = height - (normalizedValue * height * 0.8) - (height * 0.1); // Keep within 10-90% of height
            return `${x},${y}`;
        }).join(' ');

        return (
            <div>
                <svg width={width} height={height} className="overflow-visible">
                    <polyline
                        points={points}
                        fill="none"
                        stroke={strokeColor}
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    />
                    {/* Draw dots at data points */}
                    {data.map((value, index) => {
                        const x = (index / (data.length - 1)) * width;
                        const normalizedValue = (value - min) / range;
                        const y = height - (normalizedValue * height * 0.8) - (height * 0.1);
                        return (
                            <circle
                                key={index}
                                cx={x}
                                cy={y}
                                r="1.5"
                                fill={strokeColor}
                            />
                        );
                    })}
                </svg>
            </div>
        );
    };

    return (
        <div className="p-4 bg-gray-50 dark:bg-gray-900">
            <div className="max-w-7xl mx-auto">
                <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-6 gap-3">
                    <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Nodes ({filteredPollers.length})</h1>
                    <div className="flex flex-col md:flex-row items-start md:items-center gap-3">
                        <div className="relative">
                            <input
                                type="text"
                                placeholder="Search nodes or services..."
                                className="pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:ring-blue-500 focus:border-blue-500 w-full md:w-auto"
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                            />
                            <Search className="absolute left-3 top-2.5 h-5 w-5 text-gray-400" />
                        </div>

                        <div className="flex items-center space-x-2">
                            <select
                                value={sortBy}
                                onChange={(e) => setSortBy(e.target.value as "name" | "status" | "lastUpdate")}
                                className="border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 px-3 py-2 focus:ring-blue-500 focus:border-blue-500"
                            >
                                <option value="name">Name</option>
                                <option value="status">Status</option>
                                <option value="lastUpdate">Last Update</option>
                            </select>

                            <button
                                onClick={toggleSortOrder}
                                className="p-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
                                aria-label={`Sort ${sortOrder === "asc" ? "ascending" : "descending"}`}
                            >
                                <ArrowUpDown className="h-5 w-5" />
                            </button>

                            <select
                                value={filterStatus}
                                onChange={(e) => setFilterStatus(e.target.value)}
                                className="border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 px-3 py-2 focus:ring-blue-500 focus:border-blue-500"
                            >
                                <option value="all">All Status</option>
                                <option value="healthy">Healthy</option>
                                <option value="warning">Warning</option>
                                <option value="critical">Critical</option>
                            </select>
                        </div>
                    </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    {filteredPollers.map(poller => (
                        <div
                            key={poller.id}
                            className={`bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden transition-all duration-200 ${
                                expandedPoller === poller.id ? 'ring-2 ring-blue-500' : ''
                            }`}
                        >
                            {/* Header section */}
                            <div
                                className="p-4 flex justify-between items-center cursor-pointer"
                                onClick={() => toggleExpand(poller.id)}
                            >
                                <div className="flex items-center">
                                    {getStatusIcon(poller.status)}
                                    <h3 className="ml-2 font-semibold text-gray-900 dark:text-white truncate">{poller.name}</h3>
                                </div>
                                <div className="flex items-center space-x-2">
                  <span className="text-sm text-gray-500 dark:text-gray-400 hidden md:inline-block">
                    {poller.servicesCount.healthy} / {poller.servicesCount.total} Services Healthy
                  </span>
                                    {expandedPoller === poller.id ?
                                        <ChevronUp className="h-5 w-5 text-gray-500" /> :
                                        <ChevronDown className="h-5 w-5 text-gray-500" />
                                    }
                                </div>
                            </div>

                            {/* Basic stats row - always visible */}
                            <div className="px-4 pb-4 pt-0 grid grid-cols-1 sm:grid-cols-3 gap-4">
                                <div className="flex flex-col">
                                    <span className="text-xs text-gray-500 dark:text-gray-400">Response Time Trend</span>
                                    <div className="flex items-center mt-1">
                                        <SimpleSparkline data={poller.responseTrend} status={poller.status} />
                                        <span className="ml-2 text-sm font-medium text-gray-900 dark:text-gray-100">
                      {poller.responseTrend.length > 0
                          ? `${poller.responseTrend[poller.responseTrend.length - 1].toFixed(1)}ms`
                          : 'N/A'}
                    </span>
                                    </div>
                                </div>

                                <div className="flex flex-col">
                                    <span className="text-xs text-gray-500 dark:text-gray-400">Services Status</span>
                                    <div className="flex items-center mt-1 space-x-2">
                                        <div className="flex items-center">
                                            <div className="h-3 w-3 rounded-full bg-green-500 mr-1"></div>
                                            <span className="text-xs">{poller.servicesCount.healthy}</span>
                                        </div>
                                        <div className="flex items-center">
                                            <div className="h-3 w-3 rounded-full bg-yellow-500 mr-1"></div>
                                            <span className="text-xs">{poller.servicesCount.warning}</span>
                                        </div>
                                        <div className="flex items-center">
                                            <div className="h-3 w-3 rounded-full bg-red-500 mr-1"></div>
                                            <span className="text-xs">{poller.servicesCount.critical}</span>
                                        </div>
                                    </div>
                                </div>

                                <div className="flex flex-col">
                                    <span className="text-xs text-gray-500 dark:text-gray-400">Last Updated</span>
                                    <div className="flex items-center mt-1">
                                        <Clock className="h-4 w-4 text-gray-500 mr-1" />
                                        <span className="text-xs text-gray-900 dark:text-gray-100">{poller.lastUpdate}</span>
                                    </div>
                                </div>
                            </div>

                            {/* Tags - always visible */}
                            <div className="px-4 pb-4">
                                <div className="flex flex-wrap gap-2">
                                    {poller.tags.map(tag => (
                                        <span
                                            key={tag}
                                            className="px-2 py-1 text-xs rounded-full bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"
                                        >
                      {tag}
                    </span>
                                    ))}
                                </div>
                            </div>

                            {/* Expanded section with service details */}
                            {expandedPoller === poller.id && (
                                <div className="px-4 py-4 border-t border-gray-200 dark:border-gray-700">
                                    {/* Service Groups */}
                                    {poller.serviceGroups.length > 0 && (
                                        <div>
                                            <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-3 flex items-center">
                                                <Layers className="h-4 w-4 mr-1" />
                                                Service Groups
                                            </h4>
                                            <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                                                {poller.serviceGroups.map(group => (
                                                    <div
                                                        key={group.name}
                                                        className="bg-gray-50 dark:bg-gray-700 p-3 rounded-lg"
                                                    >
                                                        <div className="flex justify-between items-center mb-2">
                                                            <h5 className="font-medium text-gray-900 dark:text-gray-100">{group.name}</h5>
                                                            <span className="text-sm text-gray-500 dark:text-gray-400">
                                {group.healthy} / {group.count} healthy
                              </span>
                                                        </div>
                                                        <div className="w-full bg-gray-200 dark:bg-gray-600 rounded-full h-2 mb-2">
                                                            <div
                                                                className="bg-green-500 h-2 rounded-full"
                                                                style={{ width: `${(group.healthy / (group.count || 1)) * 100}%` }}
                                                            ></div>
                                                        </div>
                                                        <div className="flex flex-wrap gap-1 mt-2">
                                                            {group.services.map(service => (
                                                                <div
                                                                    key={service.name}
                                                                    onClick={() => handleServiceClick(poller.id, service.name)}
                                                                    className={`px-2 py-1 text-xs rounded cursor-pointer flex items-center ${
                                                                        service.available ?
                                                                            'bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-200' :
                                                                            'bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200'
                                                                    }`}
                                                                >
                                                                    {service.available ?
                                                                        <CheckCircle className="h-3 w-3 mr-1" /> :
                                                                        <AlertCircle className="h-3 w-3 mr-1" />
                                                                    }
                                                                    {service.name}
                                                                </div>
                                                            ))}
                                                        </div>
                                                    </div>
                                                ))}
                                            </div>
                                        </div>
                                    )}

                                    {/* Individual Services section */}
                                    <div>
                                        <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-3 flex items-center">
                                            <Settings className="h-4 w-4 mr-1" />
                                            Services
                                        </h4>
                                        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
                                            {poller.services.map(service => (
                                                <div
                                                    key={service.name}
                                                    onClick={() => handleServiceClick(poller.id, service.name)}
                                                    className="bg-gray-50 dark:bg-gray-700 p-2 rounded cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors"
                                                >
                                                    <div className="flex items-center justify-between mb-1">
                                                        <span className="font-medium text-sm text-gray-900 dark:text-gray-100 truncate">{service.name}</span>
                                                        {service.available ?
                                                            <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0" /> :
                                                            <AlertCircle className="h-4 w-4 text-red-500 flex-shrink-0" />
                                                        }
                                                    </div>
                                                    <span className="text-xs text-gray-500 dark:text-gray-400">{service.type}</span>
                                                </div>
                                            ))}
                                        </div>
                                    </div>

                                    <div className="mt-4 flex justify-end">
                                        <button
                                            className="px-4 py-2 bg-blue-500 hover:bg-blue-600 text-white rounded-lg flex items-center transition-colors"
                                            onClick={(e) => {
                                                e.stopPropagation();
                                                viewDetailedDashboard(poller.id);
                                            }}
                                        >
                                            <Zap className="h-4 w-4 mr-2" />
                                            View Detailed Dashboard
                                        </button>
                                    </div>
                                </div>
                            )}
                        </div>
                    ))}
                </div>

                {filteredPollers.length === 0 && (
                    <div className="text-center py-12 bg-white dark:bg-gray-800 rounded-lg shadow-md">
                        <Server className="h-12 w-12 mx-auto text-gray-400" />
                        <h3 className="mt-2 text-lg font-medium text-gray-900 dark:text-white">No nodes found</h3>
                        <p className="mt-1 text-gray-500 dark:text-gray-400">Try adjusting your search or filters</p>
                    </div>
                )}
            </div>
        </div>
    );
};

export default PollerDashboard;