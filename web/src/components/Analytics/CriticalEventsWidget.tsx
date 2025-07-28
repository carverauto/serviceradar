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

import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { AlertTriangle, ShieldAlert, AlertCircle, Info, ExternalLink } from 'lucide-react';
import Link from 'next/link';
import { Event } from '@/types/events';

interface EventStats {
    critical: number;
    high: number;
    medium: number;
    low: number;
    total: number;
}

const CriticalEventsWidget: React.FC = () => {
    const { token } = useAuth();
    const [recentEvents, setRecentEvents] = useState<Event[]>([]);
    const [stats, setStats] = useState<EventStats>({
        critical: 0,
        high: 0,
        medium: 0,
        low: 0,
        total: 0
    });
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const postQuery = useCallback(async <T,>(query: string): Promise<T> => {
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify({ query, limit: 20 }),
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }

        return response.json();
    }, [token]);

    const fetchCriticalEvents = useCallback(async () => {
        try {
            setLoading(true);
            setError(null);

            // Fetch event counts and recent critical/high events in parallel
            const [
                totalEventsRes,
                criticalEventsRes,
                highEventsRes,
                mediumEventsRes,
                lowEventsRes,
                recentCriticalEventsRes
            ] = await Promise.all([
                postQuery<{ results: [{ 'count()': number }] }>('COUNT EVENTS'),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'Critical'"),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'High'"),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'Medium'"),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT EVENTS WHERE severity = 'Low'"),
                postQuery<{ results: Event[] }>("SHOW EVENTS WHERE severity IN ('Critical', 'High') ORDER BY event_timestamp DESC")
            ]);

            // Update stats
            setStats({
                total: totalEventsRes.results[0]?.['count()'] || 0,
                critical: criticalEventsRes.results[0]?.['count()'] || 0,
                high: highEventsRes.results[0]?.['count()'] || 0,
                medium: mediumEventsRes.results[0]?.['count()'] || 0,
                low: lowEventsRes.results[0]?.['count()'] || 0
            });

            // Update recent events (take top 5)
            setRecentEvents((recentCriticalEventsRes.results || []).slice(0, 5));

        } catch (err) {
            console.error('Error fetching critical events:', err);
            setError(err instanceof Error ? err.message : 'Unknown error');
        } finally {
            setLoading(false);
        }
    }, [postQuery]);

    useEffect(() => {
        fetchCriticalEvents();
        const interval = setInterval(fetchCriticalEvents, 60000); // Refresh every minute
        return () => clearInterval(interval);
    }, [fetchCriticalEvents]);

    const getSeverityIcon = (severity: string) => {
        const lowerSeverity = severity.toLowerCase();
        switch (lowerSeverity) {
            case 'critical':
                return <ShieldAlert size={14} className="text-red-600 dark:text-red-400" />;
            case 'high':
                return <AlertTriangle size={14} className="text-orange-600 dark:text-orange-400" />;
            case 'medium':
                return <AlertCircle size={14} className="text-yellow-600 dark:text-yellow-400" />;
            case 'low':
                return <Info size={14} className="text-blue-600 dark:text-blue-400" />;
            default:
                return <AlertCircle size={14} className="text-gray-600 dark:text-gray-400" />;
        }
    };

    const getSeverityColor = (severity: string) => {
        const lowerSeverity = severity.toLowerCase();
        switch (lowerSeverity) {
            case 'critical':
                return 'text-red-600 dark:text-red-400';
            case 'high':
                return 'text-orange-600 dark:text-orange-400';
            case 'medium':
                return 'text-yellow-600 dark:text-yellow-400';
            case 'low':
                return 'text-blue-600 dark:text-blue-400';
            default:
                return 'text-gray-600 dark:text-gray-400';
        }
    };

    const formatTimestamp = (timestamp: string) => {
        try {
            const date = new Date(timestamp);
            const now = new Date();
            const diffMs = now.getTime() - date.getTime();
            const diffMinutes = Math.floor(diffMs / (1000 * 60));
            const diffHours = Math.floor(diffMinutes / 60);
            const diffDays = Math.floor(diffHours / 24);

            if (diffMinutes < 1) return 'Just now';
            if (diffMinutes < 60) return `${diffMinutes}m ago`;
            if (diffHours < 24) return `${diffHours}h ago`;
            if (diffDays < 7) return `${diffDays}d ago`;
            return date.toLocaleDateString();
        } catch {
            return 'Unknown';
        }
    };

    const truncateMessage = (message: string, maxLength: number = 50) => {
        if (message.length <= maxLength) return message;
        return message.substring(0, maxLength) + '...';
    };

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Critical Events</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Critical Events</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="text-center text-red-500 dark:text-red-400">
                        <AlertTriangle className="h-8 w-8 mx-auto mb-2" />
                        <p className="text-sm">Failed to load events data</p>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
            <div className="flex justify-between items-start mb-4">
                <h3 className="font-semibold text-gray-900 dark:text-white">Critical Events</h3>
                <Link 
                    href="/events"
                    className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                    title="View all events"
                >
                    <ExternalLink size={16} />
                </Link>
            </div>
            
            <div className="flex-1">
                {/* Stats Summary Table */}
                <div className="mb-4">
                    <table className="w-full text-sm">
                        <thead>
                            <tr className="border-b border-gray-200 dark:border-gray-700">
                                <th className="text-left text-xs font-medium text-gray-600 dark:text-gray-400 py-1">Severity</th>
                                <th className="text-center text-xs font-medium text-gray-600 dark:text-gray-400 py-1">Count</th>
                                <th className="text-center text-xs font-medium text-gray-600 dark:text-gray-400 py-1">%</th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr className="border-b border-gray-100 dark:border-gray-800">
                                <td className="py-1 text-red-600 dark:text-red-400">Critical</td>
                                <td className="text-center text-red-600 dark:text-red-400 font-bold">{stats.critical}</td>
                                <td className="text-center text-red-600 dark:text-red-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.critical / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr className="border-b border-gray-100 dark:border-gray-800">
                                <td className="py-1 text-orange-600 dark:text-orange-400">High</td>
                                <td className="text-center text-orange-600 dark:text-orange-400 font-bold">{stats.high}</td>
                                <td className="text-center text-orange-600 dark:text-orange-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.high / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr className="border-b border-gray-100 dark:border-gray-800">
                                <td className="py-1 text-yellow-600 dark:text-yellow-400">Medium</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 font-bold">{stats.medium}</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.medium / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr>
                                <td className="py-1 text-blue-600 dark:text-blue-400">Low</td>
                                <td className="text-center text-blue-600 dark:text-blue-400 font-bold">{stats.low}</td>
                                <td className="text-center text-blue-600 dark:text-blue-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.low / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>

                {/* Recent Events List */}
                {recentEvents.length > 0 ? (
                    <div className="space-y-2 max-h-40 overflow-y-auto">
                        {recentEvents.map((event, index) => (
                            <div key={`${event.id}-${index}`} className="flex items-center justify-between p-2 bg-gray-50 dark:bg-gray-700/50 rounded">
                                <div className="flex items-center space-x-2 flex-1 min-w-0">
                                    <div className="flex-shrink-0">
                                        {getSeverityIcon(event.severity || 'unknown')}
                                    </div>
                                    <div className="flex-1 min-w-0">
                                        <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                                            {event.host}
                                        </div>
                                        <div className="text-xs text-gray-600 dark:text-gray-400 truncate">
                                            {truncateMessage(event.short_message)}
                                        </div>
                                        <div className={`text-xs ${getSeverityColor(event.severity || 'unknown')}`}>
                                            {event.severity || 'unknown'} • {formatTimestamp(event.event_timestamp)}
                                        </div>
                                    </div>
                                </div>
                                <Link 
                                    href={`/events?severity=${encodeURIComponent(event.severity || 'unknown')}&search=${encodeURIComponent(event.host)}`}
                                    className="flex-shrink-0 text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200 ml-2"
                                    title={`View events for ${event.host}`}
                                >
                                    <ExternalLink size={14} />
                                </Link>
                            </div>
                        ))}
                    </div>
                ) : (
                    <div className="flex-1 flex items-center justify-center text-center text-gray-600 dark:text-gray-400">
                        <div>
                            <ShieldAlert className="h-8 w-8 mx-auto mb-2 text-green-600 dark:text-green-400" />
                            <p className="text-sm">No critical events</p>
                            <p className="text-xs mt-1">All systems reporting normally</p>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default CriticalEventsWidget;