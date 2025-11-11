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

import React, { useMemo, useCallback } from 'react';
import { AlertTriangle, ShieldAlert, AlertCircle, Info, ExternalLink } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useAnalytics } from '@/contexts/AnalyticsContext';
import { Event } from '@/types/events';
import { formatNumber } from '@/utils/formatters';
import { escapeSrqlValue } from '@/lib/srql';
import { formatMessagePreview } from '@/utils/messagePreview';


const CriticalEventsWidget: React.FC = () => {
    const router = useRouter();
    const { data: analyticsData, loading, error } = useAnalytics();
    
    const { stats, recentEvents } = useMemo(() => {
        if (!analyticsData) {
            return {
                stats: { critical: 0, high: 0, medium: 0, low: 0, total: 0 },
                recentEvents: []
            };
        }
        
        const stats = {
            total: analyticsData.totalEvents,
            critical: analyticsData.criticalEvents,
            high: analyticsData.highEvents,
            medium: analyticsData.mediumEvents,
            low: analyticsData.lowEvents
        };
        
        const recentEvents = (analyticsData.recentCriticalEvents as Event[] || []).slice(0, 5);
        
        return { stats, recentEvents };
    }, [analyticsData]);

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

    const formatEventMessage = (message?: string | null) =>
        formatMessagePreview(message, { fallback: 'No additional details' });

    const handleEventSeverityClick = useCallback((severity: string) => {
        const eventWindowStart = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const baseClauses = ['in:events', `time:[${eventWindowStart},]`, 'sort:event_timestamp:desc', 'limit:100'];
        const normalized = severity.toLowerCase();
        if (['critical', 'high', 'medium', 'low'].includes(normalized)) {
            baseClauses.push(`severity:${normalized.charAt(0).toUpperCase()}${normalized.slice(1)}`);
        }
        const query = baseClauses.join(' ');
        router.push(`/query?q=${encodeURIComponent(query)}`);
    }, [router]);

    const handleEventEntryClick = useCallback((event: Event) => {
        const eventWindowStart = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const clauses = ['in:events', `time:[${eventWindowStart},]`, 'sort:event_timestamp:desc', 'limit:100'];
        if (event.host) {
            clauses.push(`host:"${escapeSrqlValue(event.host)}"`);
        }
        if (event.severity) {
            clauses.push(`severity:${event.severity}`);
        }
        const query = clauses.join(' ');
        router.push(`/query?q=${encodeURIComponent(query)}`);
    }, [router]);

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
                <h3 
                    className="font-semibold text-gray-900 dark:text-white cursor-pointer hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
                    onClick={() => handleEventSeverityClick('all')}
                    title="Click to view all events"
                >
                    Critical Events
                </h3>
                <button
                    onClick={() => {
                        const eventWindowStart = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
                        const query = `in:events severity:(Critical,High) time:[${eventWindowStart},] sort:event_timestamp:desc limit:100`;
                        router.push(`/query?q=${encodeURIComponent(query)}`);
                    }}
                    className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                    title="View critical events (Critical + High)"
                >
                    <ExternalLink size={16} />
                </button>
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
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-red-50 dark:hover:bg-red-900/10 transition-colors"
                                onClick={() => handleEventSeverityClick('critical')}
                                title="Click to view critical events"
                            >
                                <td className="py-1 text-red-600 dark:text-red-400">Critical</td>
                                <td className="text-center text-red-600 dark:text-red-400 font-bold">{formatNumber(stats.critical)}</td>
                                <td className="text-center text-red-600 dark:text-red-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.critical / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-orange-50 dark:hover:bg-orange-900/10 transition-colors"
                                onClick={() => handleEventSeverityClick('high')}
                                title="Click to view high severity events"
                            >
                                <td className="py-1 text-orange-600 dark:text-orange-400">High</td>
                                <td className="text-center text-orange-600 dark:text-orange-400 font-bold">{formatNumber(stats.high)}</td>
                                <td className="text-center text-orange-600 dark:text-orange-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.high / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-yellow-50 dark:hover:bg-yellow-900/10 transition-colors"
                                onClick={() => handleEventSeverityClick('medium')}
                                title="Click to view medium severity events"
                            >
                                <td className="py-1 text-yellow-600 dark:text-yellow-400">Medium</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 font-bold">{formatNumber(stats.medium)}</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.medium / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="cursor-pointer hover:bg-blue-50 dark:hover:bg-blue-900/10 transition-colors"
                                onClick={() => handleEventSeverityClick('low')}
                                title="Click to view low severity events"
                            >
                                <td className="py-1 text-blue-600 dark:text-blue-400">Low</td>
                                <td className="text-center text-blue-600 dark:text-blue-400 font-bold">{formatNumber(stats.low)}</td>
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
                            <div 
                                key={`${event.id}-${index}`} 
                                className="flex items-center justify-between p-2 bg-gray-50 dark:bg-gray-700/50 rounded cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600/50 transition-colors"
                                onClick={() => handleEventEntryClick(event)}
                                title={`Click to view related events for ${event.host} with ${event.severity} severity`}
                            >
                                <div className="flex items-center space-x-2 flex-1 min-w-0">
                                    <div className="flex-shrink-0">
                                        {getSeverityIcon(event.severity || 'unknown')}
                                    </div>
                                    <div className="flex-1 min-w-0">
                                        <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                                            {event.host}
                                        </div>
                                        <div className="text-xs text-gray-600 dark:text-gray-400 truncate">
                                            {formatEventMessage(event.short_message)}
                                        </div>
                                        <div className={`text-xs ${getSeverityColor(event.severity || 'unknown')}`}>
                                            {event.severity || 'unknown'} • {formatTimestamp(event.event_timestamp)}
                                            {event.id && <span className="ml-1 text-blue-600 dark:text-blue-400">🔗</span>}
                                        </div>
                                    </div>
                                </div>
                                <div className="flex-shrink-0 text-blue-600 dark:text-blue-400 opacity-70">
                                    <ExternalLink size={14} />
                                </div>
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
