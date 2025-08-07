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

import React, { useMemo } from 'react';
import { useAnalytics } from '@/contexts/AnalyticsContext';
import { BarChart3, TrendingUp, Clock, Activity, ExternalLink } from 'lucide-react';
import Link from 'next/link';
import { formatNumber, formatDuration, formatPercentage } from '@/utils/formatters';


interface SlowSpan {
    trace_id: string;
    service_name: string;
    span_name: string;
    duration_ms: number;
    timestamp: string;
}

const ObservabilityWidget = () => {
    const { data: analyticsData, loading, error } = useAnalytics();
    
    const { stats, recentSlowSpans } = useMemo(() => {
        if (!analyticsData) {
            return {
                stats: { totalMetrics: 0, totalTraces: 0, avgDuration: 0, errorRate: 0, slowSpans: 0 },
                recentSlowSpans: []
            };
        }

        const totalMetrics = analyticsData.totalMetrics;
        const totalErrors = analyticsData.errorMetrics;
        const totalTraces = analyticsData.totalTraces;
        const slowSpans = analyticsData.slowMetrics;
        
        // Calculate average duration - for now use 0, can be enhanced later
        const avgDuration = 0;
        
        const stats = {
            totalMetrics,
            totalTraces,
            avgDuration,
            errorRate: totalMetrics > 0 ? totalErrors / totalMetrics : 0,
            slowSpans
        };

        const recentSlowSpans = (analyticsData.recentSlowSpans as SlowSpan[] || []).slice(0, 3);
        
        return { stats, recentSlowSpans };
    }, [analyticsData]);

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Observability</h3>
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
                    <h3 className="font-semibold text-gray-900 dark:text-white">Observability</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="text-center text-red-500 dark:text-red-400">
                        <Activity className="h-8 w-8 mx-auto mb-2" />
                        <p className="text-sm">Failed to load observability data</p>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px] overflow-hidden">
            <div className="flex justify-between items-start mb-4 flex-shrink-0">
                <div className="flex items-center">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Observability</h3>
                    {stats.totalMetrics > 0 && (
                        <div className="w-2 h-2 bg-green-500 rounded-full ml-2"></div>
                    )}
                </div>
                <Link 
                    href="/observability"
                    className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                    title="View observability dashboard"
                >
                    <ExternalLink size={16} />
                </Link>
            </div>
            
            <div className="flex-1 flex flex-col min-h-0">
                {/* Key Metrics Grid */}
                <div className="mb-3 flex-shrink-0">
                    <div className="grid grid-cols-2 gap-3">
                        <Link 
                            href="/observability?tab=metrics"
                            className="text-center p-2 bg-blue-50 dark:bg-blue-900/20 rounded-lg border border-blue-200 dark:border-blue-800 hover:bg-blue-100 dark:hover:bg-blue-900/30 transition-colors cursor-pointer"
                        >
                            <div className="flex items-center justify-center mb-1">
                                <BarChart3 className="h-4 w-4 text-blue-600 dark:text-blue-400 mr-1" />
                                <span className="text-xs text-blue-600 dark:text-blue-400 font-medium">Metrics</span>
                            </div>
                            <div className="text-lg font-bold text-blue-800 dark:text-blue-200">
                                {formatNumber(stats.totalMetrics)}
                            </div>
                        </Link>
                        
                        <Link 
                            href="/observability?tab=traces"
                            className="text-center p-2 bg-green-50 dark:bg-green-900/20 rounded-lg border border-green-200 dark:border-green-800 hover:bg-green-100 dark:hover:bg-green-900/30 transition-colors cursor-pointer"
                        >
                            <div className="flex items-center justify-center mb-1">
                                <Activity className="h-4 w-4 text-green-600 dark:text-green-400 mr-1" />
                                <span className="text-xs text-green-600 dark:text-green-400 font-medium">Traces</span>
                            </div>
                            <div className="text-lg font-bold text-green-800 dark:text-green-200">
                                {formatNumber(stats.totalTraces)}
                            </div>
                        </Link>
                    </div>
                </div>

                {/* Performance Metrics */}
                <div className="mb-3 flex-shrink-0 space-y-2">
                    <div className="flex justify-between items-center">
                        <div className="flex items-center">
                            <Clock className="h-3 w-3 text-purple-600 dark:text-purple-400 mr-1" />
                            <span className="text-xs text-gray-600 dark:text-gray-400">Avg Duration</span>
                        </div>
                        <span className="text-sm font-semibold text-purple-700 dark:text-purple-300">
                            {formatDuration(stats.avgDuration)}
                        </span>
                    </div>
                    
                    <div className="flex justify-between items-center">
                        <div className="flex items-center">
                            <TrendingUp className="h-3 w-3 text-red-600 dark:text-red-400 mr-1" />
                            <span className="text-xs text-gray-600 dark:text-gray-400">Error Rate</span>
                        </div>
                        <span className="text-sm font-semibold text-red-700 dark:text-red-300">
                            {formatPercentage(stats.errorRate)}
                        </span>
                    </div>
                    
                    <div className="flex justify-between items-center">
                        <div className="flex items-center">
                            <Activity className="h-3 w-3 text-orange-600 dark:text-orange-400 mr-1" />
                            <span className="text-xs text-gray-600 dark:text-gray-400">Slow Spans</span>
                        </div>
                        <span className="text-sm font-semibold text-orange-700 dark:text-orange-300">
                            {formatNumber(stats.slowSpans)}
                        </span>
                    </div>
                </div>

                {/* Recent Slow Spans List */}
                {recentSlowSpans.length > 0 ? (
                    <div className="flex-1 flex flex-col min-h-0">
                        <h4 className="text-xs font-medium text-gray-600 dark:text-gray-400 mb-2 flex-shrink-0">Recent Slow Spans</h4>
                        <div className="space-y-1 overflow-y-auto overflow-x-hidden flex-1 min-h-0">
                            {recentSlowSpans.map((span, index) => (
                                <Link
                                    key={`${span.trace_id}-${index}`}
                                    href={`/observability?tab=correlation&trace_id=${span.trace_id}`}
                                    className="block p-2 bg-red-50 dark:bg-red-900/20 rounded border border-red-200 dark:border-red-800 hover:bg-red-100 dark:hover:bg-red-900/30 transition-colors"
                                >
                                    <div className="flex items-center justify-between">
                                        <div className="min-w-0 flex-1">
                                            <div className="text-xs font-medium text-red-800 dark:text-red-200 truncate">
                                                {span.service_name || 'Unknown Service'}
                                            </div>
                                            <div className="text-xs text-red-600 dark:text-red-400 truncate">
                                                {span.span_name || 'Unknown Span'}
                                            </div>
                                        </div>
                                        <div className="text-xs font-semibold text-red-700 dark:text-red-300 ml-2">
                                            {formatDuration(span.duration_ms)}
                                        </div>
                                    </div>
                                </Link>
                            ))}
                        </div>
                    </div>
                ) : (
                    <div className="flex-1 flex items-center justify-center text-center text-gray-600 dark:text-gray-400">
                        <div>
                            <Activity className="h-8 w-8 mx-auto mb-2 text-green-600 dark:text-green-400" />
                            <p className="text-sm">No slow spans</p>
                            <p className="text-xs mt-1">Performance is good</p>
                        </div>
                    </div>
                )}


            </div>
        </div>
    );
};

export default ObservabilityWidget;