'use client';

import React, { useState, useEffect, useCallback, Fragment } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Event, Pagination, EventsApiResponse } from '@/types/events';
import {
    Bell,
    ShieldExclamation,
    AlertTriangle as AlertTriangleIcon,
    ChevronDown,
    ChevronRight,
    Search,
    Loader2,
    AlertCircle,
    ArrowUp,
    ArrowDown,
    Activity
} from 'lucide-react';
import ReactJson from '@microlink/react-json-view';
import { useDebounce } from 'use-debounce';

type SortableKeys = 'event_timestamp' | 'host' | 'severity';

const StatCard = ({
                      title,
                      value,
                      icon,
                      isLoading
                  }: {
    title: string;
    value: string | number;
    icon: React.ReactNode;
    isLoading: boolean
}) => (
    <div className="bg-[#25252e] border border-gray-700 p-4 rounded-lg">
        <div className="flex items-center">
            <div className="p-2 bg-gray-700/50 rounded-md mr-4">
                {icon}
            </div>
            <div>
                <p className="text-sm text-gray-400">{title}</p>
                {isLoading ? (
                    <div className="h-7 w-20 bg-gray-700 rounded-md animate-pulse mt-1"></div>
                ) : (
                    <p className="text-2xl font-bold text-white">{value}</p>
                )}
            </div>
        </div>
    </div>
);

const EventsDashboard = () => {
    const { token } = useAuth();
    const [events, setEvents] = useState<Event[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [stats, setStats] = useState({
        total: 0,
        critical: 0,
        high: 0,
        low: 0
    });
    const [statsLoading, setStatsLoading] = useState(true);
    const [eventsLoading, setEventsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [filterSeverity, setFilterSeverity] = useState<'all' | 'Low' | 'Medium' | 'High' | 'Critical'>('all');
    const [sortBy, setSortBy] = useState<SortableKeys>('event_timestamp');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const postQuery = useCallback(async <T,>(
        query: string,
        cursor?: string,
        direction?: 'next' | 'prev'
    ): Promise<T> => {
        const body: Record<string, unknown> = {
            query,
            limit: 20
        };

        if (cursor) body.cursor = cursor;
        if (direction) body.direction = direction;

        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify(body),
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }

        return response.json();
    }, [token]);

    const fetchStats = useCallback(async () => {
        setStatsLoading(true);

        try {
            const [totalRes, criticalRes, highRes, lowRes] = await Promise.all([
                postQuery<{ results: [{ 'count()': number }] }>('COUNT EVENTS'),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'Critical'"),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'High'"),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'Low'"),
            ]);

            setStats({
                total: totalRes.results[0]?.['count()'] || 0,
                critical: criticalRes.results[0]?.['count()'] || 0,
                high: highRes.results[0]?.['count()'] || 0,
                low: lowRes.results[0]?.['count()'] || 0,
            });
        } catch (e) {
            console.error("Failed to fetch event stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [postQuery]);

    const fetchEvents = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setEventsLoading(true);
        setError(null);

        try {
            let query = 'SHOW EVENTS';
            const whereClauses: string[] = [];

            if (debouncedSearchTerm) {
                whereClauses.push(`(short_message LIKE '%${debouncedSearchTerm}%' OR host LIKE '%${debouncedSearchTerm}%')`);
            }

            if (filterSeverity !== 'all') {
                whereClauses.push(`severity = '${filterSeverity}'`);
            }

            if (whereClauses.length > 0) {
                query += ` WHERE ${whereClauses.join(' AND ')}`;
            }

            query += ` ORDER BY ${sortBy} ${sortOrder.toUpperCase()}`;

            const data = await postQuery<EventsApiResponse>(query, cursor, direction);
            setEvents(data.results || []);
            setPagination(data.pagination || null);
        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
            setEvents([]);
            setPagination(null);
        } finally {
            setEventsLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, filterSeverity, sortBy, sortOrder]);

    useEffect(() => {
        fetchStats();
    }, [fetchStats]);

    useEffect(() => {
        fetchEvents();
    }, [fetchEvents]);

    const handleSort = (key: SortableKeys) => {
        if (sortBy === key) {
            setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc');
        } else {
            setSortBy(key);
            setSortOrder('desc');
        }
    };

    const getSeverityBadge = (severity: string) => {
        const lowerSeverity = severity.toLowerCase();

        switch (lowerSeverity) {
            case 'critical':
                return 'bg-red-600/50 text-red-200 border border-red-500/60';
            case 'high':
                return 'bg-orange-500/50 text-orange-200 border border-orange-400/60';
            case 'medium':
                return 'bg-yellow-500/50 text-yellow-200 border border-yellow-400/60';
            case 'low':
                return 'bg-sky-600/50 text-sky-200 border border-sky-500/60';
            default:
                return 'bg-gray-600/50 text-gray-200 border border-gray-500/60';
        }
    };

    const formatDate = (dateString: string) => {
        try {
            return new Date(dateString).toLocaleString();
        } catch {
            return 'Invalid Date';
        }
    };

    const TableHeader = ({
                             aKey,
                             label
                         }: {
        aKey: SortableKeys;
        label: string
    }) => (
        <th
            scope="col"
            className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider cursor-pointer"
            onClick={() => handleSort(aKey)}
        >
            <div className="flex items-center">
                {label}
                {sortBy === aKey && (
                    sortOrder === 'asc' ? (
                        <ArrowUp className="ml-1 h-3 w-3" />
                    ) : (
                        <ArrowDown className="ml-1 h-3 w-3" />
                    )
                )}
            </div>
        </th>
    );

    return (
        <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                <StatCard
                    title="Total Events"
                    value={stats.total.toLocaleString()}
                    icon={<Bell className="h-6 w-6 text-gray-300" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="Critical"
                    value={stats.critical.toLocaleString()}
                    icon={<ShieldExclamation className="h-6 w-6 text-red-400" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="High"
                    value={stats.high.toLocaleString()}
                    icon={<AlertTriangleIcon className="h-6 w-6 text-orange-400" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="Low"
                    value={stats.low.toLocaleString()}
                    icon={<Activity className="h-6 w-6 text-sky-400" />}
                    isLoading={statsLoading}
                />
            </div>

            <div className="bg-[#25252e] border border-gray-700 rounded-lg shadow-lg">
                <div className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Search events..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-600 rounded-lg bg-[#1C1B22] text-white focus:ring-violet-500 focus:border-violet-500"
                        />
                    </div>

                    <div className="flex items-center gap-4">
                        <label htmlFor="severityFilter" className="text-sm text-gray-300">
                            Severity:
                        </label>
                        <select
                            id="severityFilter"
                            value={filterSeverity}
                            onChange={(e) => setFilterSeverity(e.target.value as any)}
                            className="border border-gray-600 rounded-lg bg-[#1C1B22] text-white px-3 py-2 focus:ring-violet-500 focus:border-violet-500"
                        >
                            <option value="all">All</option>
                            <option value="Critical">Critical</option>
                            <option value="High">High</option>
                            <option value="Medium">Medium</option>
                            <option value="Low">Low</option>
                        </select>
                    </div>
                </div>

                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-700">
                        <thead className="bg-gray-800/50">
                        <tr>
                            <th scope="col" className="w-12"></th>
                            <TableHeader aKey="event_timestamp" label="Timestamp" />
                            <TableHeader aKey="severity" label="Severity" />
                            <TableHeader aKey="host" label="Host" />
                            <th
                                scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider"
                            >
                                Message
                            </th>
                        </tr>
                        </thead>

                        <tbody className="bg-[#25252e] divide-y divide-gray-700">
                        {eventsLoading ? (
                            <tr>
                                <td colSpan={5} className="text-center p-8">
                                    <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                                </td>
                            </tr>
                        ) : error ? (
                            <tr>
                                <td colSpan={5} className="text-center p-8 text-red-400">
                                    <AlertCircle className="mx-auto h-6 w-6 mb-2" />
                                    {error}
                                </td>
                            </tr>
                        ) : events.length === 0 ? (
                            <tr>
                                <td colSpan={5} className="text-center p-8 text-gray-400">
                                    No events found.
                                </td>
                            </tr>
                        ) : (
                            events.map(event => (
                                <Fragment key={event.id}>
                                    <tr className="hover:bg-gray-700/30">
                                        <td className="pl-4">
                                            <button
                                                onClick={() => setExpandedRow(expandedRow === event.id ? null : event.id)}
                                                className="p-1 rounded-full hover:bg-gray-600"
                                            >
                                                {expandedRow === event.id ? (
                                                    <ChevronDown className="h-5 w-5" />
                                                ) : (
                                                    <ChevronRight className="h-5 w-5" />
                                                )}
                                            </button>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
                                            {formatDate(event.event_timestamp)}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                        <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSeverityBadge(event.severity)}`}>
                          {event.severity}
                        </span>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
                                            {event.host}
                                        </td>
                                        <td
                                            className="px-6 py-4 whitespace-nowrap text-sm text-gray-300 font-mono max-w-lg truncate"
                                            title={event.short_message}
                                        >
                                            {event.short_message}
                                        </td>
                                    </tr>

                                    {expandedRow === event.id && (
                                        <tr className="bg-gray-800/50">
                                            <td colSpan={5} className="p-0">
                                                <div className="p-4">
                                                    <h4 className="text-md font-semibold text-white mb-2">
                                                        Raw Event Data
                                                    </h4>
                                                    <ReactJson
                                                        src={JSON.parse(event.raw_data)}
                                                        theme="pop"
                                                        collapsed={false}
                                                        displayDataTypes={false}
                                                        enableClipboard={true}
                                                        style={{
                                                            padding: '1rem',
                                                            borderRadius: '0.375rem',
                                                            backgroundColor: '#1C1B22',
                                                            maxHeight: '400px',
                                                            overflowY: 'auto'
                                                        }}
                                                    />
                                                </div>
                                            </td>
                                        </tr>
                                    )}
                                </Fragment>
                            ))
                        )}
                        </tbody>
                    </table>
                </div>

                {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                    <div className="p-4 flex items-center justify-between border-t border-gray-700">
                        <button
                            onClick={() => fetchEvents(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || eventsLoading}
                            className="px-4 py-2 bg-gray-700 text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchEvents(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || eventsLoading}
                            className="px-4 py-2 bg-gray-700 text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Next
                        </button>
                    </div>
                )}
            </div>
        </div>
    );
};

export default EventsDashboard;