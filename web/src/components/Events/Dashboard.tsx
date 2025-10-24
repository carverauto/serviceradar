'use client';

import React, { useState, useEffect, useCallback, Fragment } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Event, Pagination, EventsApiResponse } from '@/types/events';
import {
    Bell,
    ShieldAlert,
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
import ReactJson from '@/components/Common/DynamicReactJson';
import { useDebounce } from 'use-debounce';
import { cachedQuery } from '@/lib/cached-query';
import { escapeSrqlValue } from '@/lib/srql';
import { useSrqlQuery } from '@/contexts/SrqlQueryContext';
import { DEFAULT_EVENTS_QUERY } from '@/lib/srqlQueries';
import { usePathname } from 'next/navigation';

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
    <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg">
        <div className="flex items-center">
            <div className="p-2 bg-orange-100 dark:bg-gray-700/50 rounded-md mr-4 text-orange-600 dark:text-orange-400">
                {icon}
            </div>
            <div>
                <p className="text-sm text-gray-600 dark:text-gray-400">{title}</p>
                {isLoading ? (
                    <div className="h-7 w-20 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse mt-1"></div>
                ) : (
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{value}</p>
                )}
            </div>
        </div>
    </div>
);

const EventsDashboard = () => {
    const { token } = useAuth();
    const { setQuery: setSrqlQuery } = useSrqlQuery();
    const pathname = usePathname();
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
            // Use cached queries to prevent duplicates
            const last24HoursIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
            const [totalRes, criticalRes, highRes, lowRes] = await Promise.all([
                cachedQuery<{ results: [{ total: number }] }>(`in:events time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`, token || undefined, 30000),
                cachedQuery<{ results: [{ total: number }] }>(`in:events severity:Critical time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`, token || undefined, 30000),
                cachedQuery<{ results: [{ total: number }] }>(`in:events severity:High time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`, token || undefined, 30000),
                cachedQuery<{ results: [{ total: number }] }>(`in:events severity:Low time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`, token || undefined, 30000),
            ]);

            setStats({
                total: totalRes.results[0]?.total || 0,
                critical: criticalRes.results[0]?.total || 0,
                high: highRes.results[0]?.total || 0,
                low: lowRes.results[0]?.total || 0,
            });
        } catch (e) {
            console.error("Failed to fetch event stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [token]);

    const eventsViewPath = `${pathname ?? '/events'}`;

    useEffect(() => {
        setSrqlQuery(DEFAULT_EVENTS_QUERY, { origin: 'view', viewPath: eventsViewPath, viewId: 'observability:events' });
    }, [eventsViewPath, setSrqlQuery]);

    const fetchEvents = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setEventsLoading(true);
        setError(null);

        try {
            const last24HoursIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
            const queryParts = [
                'in:events',
                `time:[${last24HoursIso},]`,
                `sort:${sortBy}:${sortOrder}`,
                'limit:20'
            ];

            if (filterSeverity !== 'all') {
                queryParts.push(`severity:${filterSeverity}`);
            }

            if (debouncedSearchTerm) {
                const escapedTerm = escapeSrqlValue(debouncedSearchTerm);
                queryParts.push(`short_message:%${escapedTerm}%`);
            }

            const query = queryParts.join(' ');

            setSrqlQuery(query, { origin: 'view', viewPath: eventsViewPath, viewId: 'observability:events' });
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
    }, [postQuery, debouncedSearchTerm, filterSeverity, sortBy, sortOrder, setSrqlQuery, eventsViewPath]);

    useEffect(() => {
        // Fetch stats on mount
        fetchStats();
    }, [fetchStats]);

    useEffect(() => {
        // Fetch events when dependencies change
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
                return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
            case 'high':
                return 'bg-orange-100 dark:bg-orange-500/50 text-orange-800 dark:text-orange-200 border border-orange-300 dark:border-orange-400/60';
            case 'medium':
                return 'bg-yellow-100 dark:bg-yellow-500/50 text-yellow-800 dark:text-yellow-200 border border-yellow-300 dark:border-yellow-400/60';
            case 'low':
                return 'bg-sky-100 dark:bg-sky-600/50 text-sky-800 dark:text-sky-200 border border-sky-300 dark:border-sky-500/60';
            default:
                return 'bg-gray-100 dark:bg-gray-600/50 text-gray-800 dark:text-gray-200 border border-gray-300 dark:border-gray-500/60';
        }
    };

    const parseEventRawData = useCallback((event: Event) => {
        if (!event.raw_data) return null;

        try {
            const parsed = JSON.parse(event.raw_data);
            return parsed?.root ?? parsed;
        } catch {
            return null;
        }
    }, []);

    const parseDateCandidate = useCallback((candidate?: string) => {
        if (!candidate) return null;

        const attempt = (value: string) => {
            const parsed = new Date(value);
            return Number.isNaN(parsed.getTime()) ? null : parsed;
        };

        // First try the candidate as-is.
        const direct = attempt(candidate);
        if (direct) return direct;

        // Some OTEL payloads include fractional seconds > ms precision; trim to 3 decimals.
        if (candidate.includes('.')) {
            const trimmed = candidate.replace(/(\.\d{3})\d*(Z|[+-]\d{2}:?\d{2})?$/, '$1$2');
            const trimmedDate = attempt(trimmed);
            if (trimmedDate) return trimmedDate;
        }

        return null;
    }, []);

    const formatDate = useCallback((event: Event) => {
        const candidates: Array<string | undefined> = [
            event.event_timestamp,
            event._tp_time
        ];

        const raw = parseEventRawData(event);
        if (raw) {
            candidates.push(raw?.time);
            candidates.push(raw?.timestamp);
            candidates.push(raw?.data?.timestamp);
            candidates.push(raw?.data?.last_seen);
        }

        for (const candidate of candidates) {
            const parsed = parseDateCandidate(candidate);
            if (parsed) {
                return parsed.toLocaleString();
            }
        }

        return 'Invalid Date';
    }, [parseDateCandidate, parseEventRawData]);

    const getEventHost = useCallback((event: Event) => {
        if (event.host) return event.host;

        const raw = parseEventRawData(event);
        if (raw) {
            const hostCandidate =
                raw?.data?.source_ip ||
                raw?.data?.host ||
                raw?.source_ip ||
                raw?.host;
            if (hostCandidate) {
                return hostCandidate;
            }
        }

        return 'Unknown';
    }, [parseEventRawData]);

    const TableHeader = ({
                             aKey,
                             label
                         }: {
        aKey: SortableKeys;
        label: string
    }) => (
        <th
            scope="col"
            className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider cursor-pointer"
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
                    icon={<Bell className="h-6 w-6 text-orange-600 dark:text-gray-300" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="Critical"
                    value={stats.critical.toLocaleString()}
                    icon={<ShieldAlert className="h-6 w-6 text-red-400" />}
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

            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                <div className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-200 dark:border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Search events..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>

                    <div className="flex items-center gap-4">
                        <label htmlFor="severityFilter" className="text-sm text-gray-700 dark:text-gray-300">
                            Severity:
                        </label>
                        <select
                            id="severityFilter"
                            value={filterSeverity}
                            onChange={(e) => setFilterSeverity(e.target.value as 'all' | 'Low' | 'Medium' | 'High' | 'Critical')}
                            className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
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
                    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                        <thead className="bg-gray-100 dark:bg-gray-800/50">
                        <tr>
                            <th scope="col" className="w-12"></th>
                            <TableHeader aKey="event_timestamp" label="Timestamp" />
                            <TableHeader aKey="severity" label="Severity" />
                            <TableHeader aKey="host" label="Host" />
                            <th
                                scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider"
                            >
                                Message
                            </th>
                        </tr>
                        </thead>

                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                        {eventsLoading ? (
                            <tr>
                                <td colSpan={5} className="text-center p-8">
                                    <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                                </td>
                            </tr>
                        ) : error ? (
                            <tr>
                                <td colSpan={5} className="text-center p-8 text-red-500 dark:text-red-400">
                                    <AlertCircle className="mx-auto h-6 w-6 mb-2" />
                                    {error}
                                </td>
                            </tr>
                        ) : events.length === 0 ? (
                            <tr>
                                <td colSpan={5} className="text-center p-8 text-gray-600 dark:text-gray-400">
                                    No events found.
                                </td>
                            </tr>
                        ) : (
                            events.map(event => (
                                <Fragment key={event.id}>
                                    <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                        <td className="pl-4">
                                            <button
                                                onClick={() => setExpandedRow(expandedRow === event.id ? null : event.id)}
                                                className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-400"
                                            >
                                                {expandedRow === event.id ? (
                                                    <ChevronDown className="h-5 w-5" />
                                                ) : (
                                                    <ChevronRight className="h-5 w-5" />
                                                )}
                                            </button>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                            {formatDate(event)}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                        <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSeverityBadge(event.severity || 'unknown')}`}>
                          {event.severity || 'unknown'}
                        </span>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                            {getEventHost(event)}
                                        </td>
                                        <td
                                            className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 font-mono max-w-lg truncate"
                                            title={event.short_message}
                                        >
                                            {event.short_message}
                                        </td>
                                    </tr>

                                    {expandedRow === event.id && (
                                        <tr className="bg-gray-100 dark:bg-gray-800/50">
                                            <td colSpan={5} className="p-0">
                                                <div className="p-4">
                                                    <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
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
                    <div className="p-4 flex items-center justify-between border-t border-gray-200 dark:border-gray-700">
                        <button
                            onClick={() => fetchEvents(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || eventsLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchEvents(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || eventsLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
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
