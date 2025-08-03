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
import { AlertCircle, XCircle, AlertTriangle, Info, ExternalLink, FileText } from 'lucide-react';
import { useAuth } from '../AuthProvider';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { formatNumber } from '@/utils/formatters';

interface LogStats {
    fatal: number;
    error: number;
    warning: number;
    info: number;
    debug: number;
    total: number;
}

interface LogEntry {
    timestamp: string;
    severity_text: string;
    body: string;
    service_name?: string;
    trace_id?: string;
    span_id?: string;
}

const CriticalLogsWidget = () => {
    const { token } = useAuth();
    const router = useRouter();
    const [stats, setStats] = useState<LogStats>({
        fatal: 0,
        error: 0,
        warning: 0,
        info: 0,
        debug: 0,
        total: 0
    });
    const [recentLogs, setRecentLogs] = useState<LogEntry[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const postQuery = useCallback(async <T,>(query: string): Promise<T> => {
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify({ query, limit: 100 }),
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }

        return response.json();
    }, [token]);

    const fetchLogStats = useCallback(async () => {
        try {
            setLoading(true);
            setError(null);

            // Fetch log counts by level in parallel (using lowercase severity values)
            const [
                totalLogsRes,
                fatalLogsRes,
                errorLogsRes,
                warningLogsRes,
                infoLogsRes,
                debugLogsRes,
                recentFatalLogsRes
            ] = await Promise.all([
                postQuery<{ results: [{ 'count()': number }] }>('COUNT LOGS').catch(() => ({ results: [{ 'count()': 0 }] })),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'fatal'").catch(() => ({ results: [{ 'count()': 0 }] })),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'error'").catch(() => ({ results: [{ 'count()': 0 }] })),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'warning' OR severity_text = 'warn'").catch(() => ({ results: [{ 'count()': 0 }] })),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'info'").catch(() => ({ results: [{ 'count()': 0 }] })),
                postQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'debug'").catch(() => ({ results: [{ 'count()': 0 }] })),
                postQuery<{ results: LogEntry[] }>("SHOW LOGS WHERE severity_text IN ('fatal', 'error') ORDER BY timestamp DESC").catch(() => ({ results: [] }))
            ]);

            // Update stats
            setStats({
                total: totalLogsRes.results[0]?.['count()'] || 0,
                fatal: fatalLogsRes.results[0]?.['count()'] || 0,
                error: errorLogsRes.results[0]?.['count()'] || 0,
                warning: warningLogsRes.results[0]?.['count()'] || 0,
                info: infoLogsRes.results[0]?.['count()'] || 0,
                debug: debugLogsRes.results[0]?.['count()'] || 0
            });

            // Update recent logs (take top 5)
            setRecentLogs((recentFatalLogsRes.results || []).slice(0, 5));

        } catch (err) {
            console.error('Error fetching log stats:', err);
            setError(err instanceof Error ? err.message : 'Unknown error');
        } finally {
            setLoading(false);
        }
    }, [postQuery]);

    useEffect(() => {
        fetchLogStats();
        const interval = setInterval(fetchLogStats, 60000); // Refresh every minute
        return () => clearInterval(interval);
    }, [fetchLogStats]);

    const getLevelIcon = (level: string) => {
        switch (level?.toLowerCase()) {
            case 'critical':
            case 'fatal':
                return <XCircle size={14} className="text-red-600 dark:text-red-400" />;
            case 'error':
                return <AlertCircle size={14} className="text-orange-600 dark:text-orange-400" />;
            case 'warn':
            case 'warning':
                return <AlertTriangle size={14} className="text-yellow-600 dark:text-yellow-400" />;
            case 'info':
                return <Info size={14} className="text-blue-600 dark:text-blue-400" />;
            default:
                return <FileText size={14} className="text-gray-600 dark:text-gray-400" />;
        }
    };

    const getLevelColor = (level: string) => {
        switch (level?.toLowerCase()) {
            case 'critical':
            case 'fatal':
                return 'text-red-600 dark:text-red-400';
            case 'error':
                return 'text-orange-600 dark:text-orange-400';
            case 'warn':
            case 'warning':
                return 'text-yellow-600 dark:text-yellow-400';
            case 'info':
                return 'text-blue-600 dark:text-blue-400';
            case 'debug':
                return 'text-gray-600 dark:text-gray-400';
            default:
                return 'text-gray-600 dark:text-gray-400';
        }
    };

    const formatSeverityForDisplay = (severity: string) => {
        // Capitalize first letter for display
        return severity ? severity.charAt(0).toUpperCase() + severity.slice(1).toLowerCase() : '';
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
        if (!message || message.length <= maxLength) return message || '';
        return message.substring(0, maxLength) + '...';
    };

    const handleLogLevelClick = useCallback((level: string) => {
        let query = '';
        switch (level.toLowerCase()) {
            case 'fatal':
                query = 'show logs where severity_text = "fatal"';
                break;
            case 'error':
                query = 'show logs where severity_text = "error"';
                break;
            case 'warning':
                query = 'show logs where severity_text = "warning" or severity_text = "warn"';
                break;
            case 'info':
                query = 'show logs where severity_text = "info"';
                break;
            case 'debug':
                query = 'show logs where severity_text = "debug"';
                break;
            case 'all':
                query = 'show logs';
                break;
            default:
                query = 'show logs';
        }
        const encodedQuery = encodeURIComponent(query);
        router.push(`/query?q=${encodedQuery}`);
    }, [router]);

    const handleLogEntryClick = useCallback((log: LogEntry) => {
        if (log.trace_id) {
            const query = `show logs where trace_id = "${log.trace_id}"`;
            const encodedQuery = encodeURIComponent(query);
            router.push(`/query?q=${encodedQuery}`);
        } else {
            const query = `show logs where severity_text = "${log.severity_text}"`;
            const encodedQuery = encodeURIComponent(query);
            router.push(`/query?q=${encodedQuery}`);
        }
    }, [router]);

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Log Levels</h3>
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
                    <h3 className="font-semibold text-gray-900 dark:text-white">Log Levels</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="text-center text-red-500 dark:text-red-400">
                        <AlertTriangle className="h-8 w-8 mx-auto mb-2" />
                        <p className="text-sm">Failed to load logs data</p>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px] overflow-hidden">
            <div className="flex justify-between items-start mb-4 flex-shrink-0">
                <h3 
                    className="font-semibold text-gray-900 dark:text-white cursor-pointer hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
                    onClick={() => handleLogLevelClick('all')}
                    title="Click to view all logs"
                >
                    Critical Logs
                </h3>
                <button
                    onClick={() => {
                        const query = 'show logs where severity_text in ("fatal", "error")';
                        const encodedQuery = encodeURIComponent(query);
                        router.push(`/query?q=${encodedQuery}`);
                    }}
                    className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                    title="View critical logs (fatal + error)"
                >
                    <ExternalLink size={16} />
                </button>
            </div>
            
            <div className="flex-1 flex flex-col min-h-0">
                {/* Stats Summary Table */}
                <div className="mb-4 flex-shrink-0">
                    <table className="w-full text-sm">
                        <thead>
                            <tr className="border-b border-gray-200 dark:border-gray-700">
                                <th className="text-left text-xs font-medium text-gray-600 dark:text-gray-400 py-1">Level</th>
                                <th className="text-center text-xs font-medium text-gray-600 dark:text-gray-400 py-1">Count</th>
                                <th className="text-center text-xs font-medium text-gray-600 dark:text-gray-400 py-1">%</th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-red-50 dark:hover:bg-red-900/10 transition-colors"
                                onClick={() => handleLogLevelClick('fatal')}
                                title="Click to view fatal logs"
                            >
                                <td className="py-1 text-red-600 dark:text-red-400">Fatal</td>
                                <td className="text-center text-red-600 dark:text-red-400 font-bold">{formatNumber(stats.fatal)}</td>
                                <td className="text-center text-red-600 dark:text-red-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.fatal / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-orange-50 dark:hover:bg-orange-900/10 transition-colors"
                                onClick={() => handleLogLevelClick('error')}
                                title="Click to view error logs"
                            >
                                <td className="py-1 text-orange-600 dark:text-orange-400">Error</td>
                                <td className="text-center text-orange-600 dark:text-orange-400 font-bold">{formatNumber(stats.error)}</td>
                                <td className="text-center text-orange-600 dark:text-orange-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.error / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-yellow-50 dark:hover:bg-yellow-900/10 transition-colors"
                                onClick={() => handleLogLevelClick('warning')}
                                title="Click to view warning logs"
                            >
                                <td className="py-1 text-yellow-600 dark:text-yellow-400">Warning</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 font-bold">{formatNumber(stats.warning)}</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.warning / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-blue-50 dark:hover:bg-blue-900/10 transition-colors"
                                onClick={() => handleLogLevelClick('info')}
                                title="Click to view info logs"
                            >
                                <td className="py-1 text-blue-600 dark:text-blue-400">Info</td>
                                <td className="text-center text-blue-600 dark:text-blue-400 font-bold">{formatNumber(stats.info)}</td>
                                <td className="text-center text-blue-600 dark:text-blue-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.info / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                            <tr 
                                className="cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                                onClick={() => handleLogLevelClick('debug')}
                                title="Click to view debug logs"
                            >
                                <td className="py-1 text-gray-600 dark:text-gray-400">Debug</td>
                                <td className="text-center text-gray-600 dark:text-gray-400 font-bold">{formatNumber(stats.debug)}</td>
                                <td className="text-center text-gray-600 dark:text-gray-400 text-xs">
                                    {stats.total > 0 ? Math.round((stats.debug / stats.total) * 100) : 0}%
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>

                {/* Recent Logs List */}
                {recentLogs.length > 0 ? (
                    <div className="space-y-2 overflow-y-auto overflow-x-hidden flex-1 min-h-0">
                        {recentLogs.map((log, index) => (
                            <div 
                                key={index} 
                                className="flex items-center justify-between gap-2 p-2 bg-gray-50 dark:bg-gray-700/50 rounded cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600/50 transition-colors"
                                onClick={() => handleLogEntryClick(log)}
                                title={`Click to view ${log.trace_id ? 'related logs for this trace' : 'all ' + formatSeverityForDisplay(log.severity_text) + ' logs'}`}
                            >
                                <div className="flex items-center gap-2 min-w-0 flex-1">
                                    <div className="flex-shrink-0">
                                        {getLevelIcon(log.severity_text)}
                                    </div>
                                    <div className="min-w-0 flex-1">
                                        <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                                            {log.service_name || 'Unknown Service'}
                                        </div>
                                        <div className="text-xs text-gray-600 dark:text-gray-400 truncate">
                                            {truncateMessage(log.body)}
                                        </div>
                                        <div className={`text-xs ${getLevelColor(log.severity_text)} truncate`}>
                                            {formatSeverityForDisplay(log.severity_text)} • {formatTimestamp(log.timestamp)}
                                            {log.trace_id && <span className="ml-1 text-blue-600 dark:text-blue-400">🔗</span>}
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
                            <FileText className="h-8 w-8 mx-auto mb-2 text-green-600 dark:text-green-400" />
                            <p className="text-sm">No fatal or error logs</p>
                            <p className="text-xs mt-1">All systems logging normally</p>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default CriticalLogsWidget;