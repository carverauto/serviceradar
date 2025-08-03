'use client';

import React, { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import { Activity, Clock, BarChart3, Link as LinkIcon } from 'lucide-react';
import LogsDashboard from '@/components/Logs/Dashboard';
import TracesDashboard from '@/components/Observability/TracesDashboard';
import MetricsDashboard from '@/components/Observability/MetricsDashboard';
import CorrelationDashboard from '@/components/Observability/CorrelationDashboard';

type TabType = 'logs' | 'traces' | 'metrics' | 'correlation';

const tabs = [
    { id: 'logs' as TabType, label: 'Logs', icon: Activity, description: 'View application logs and events' },
    { id: 'traces' as TabType, label: 'Traces', icon: Clock, description: 'Analyze distributed traces and spans' },
    { id: 'metrics' as TabType, label: 'Metrics', icon: BarChart3, description: 'Monitor performance metrics' },
    { id: 'correlation' as TabType, label: 'Correlation', icon: LinkIcon, description: 'Cross-reference observability data' },
];

export default function ObservabilityPage() {
    const searchParams = useSearchParams();
    const [activeTab, setActiveTab] = useState<TabType>('traces');

    useEffect(() => {
        const tabParam = searchParams.get('tab') as TabType;
        if (tabParam && ['logs', 'traces', 'metrics', 'correlation'].includes(tabParam)) {
            setActiveTab(tabParam);
        }
    }, [searchParams]);

    const renderTabContent = () => {
        const traceId = searchParams.get('trace_id');
        
        switch (activeTab) {
            case 'logs':
                return <LogsDashboard />;
            case 'traces':
                return <TracesDashboard />;
            case 'metrics':
                return <MetricsDashboard />;
            case 'correlation':
                return <CorrelationDashboard initialTraceId={traceId || undefined} />;
            default:
                return <TracesDashboard />;
        }
    };

    return (
        <div className="p-6 max-w-full">
            <div className="mb-6">
                <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Observability</h1>
                <p className="text-gray-600 dark:text-gray-400 mt-2">
                    Unified view of logs, traces, and metrics for comprehensive observability
                </p>
            </div>

            {/* Tab Navigation */}
            <div className="mb-6">
                <div className="border-b border-gray-200 dark:border-gray-700">
                    <nav className="-mb-px flex space-x-8" aria-label="Tabs">
                        {tabs.map((tab) => {
                            const isActive = activeTab === tab.id;
                            return (
                                <button
                                    key={tab.id}
                                    onClick={() => setActiveTab(tab.id)}
                                    className={`group inline-flex items-center py-4 px-1 border-b-2 font-medium text-sm ${
                                        isActive
                                            ? 'border-orange-500 text-orange-600 dark:text-orange-400'
                                            : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300 dark:text-gray-400 dark:hover:text-gray-300'
                                    }`}
                                    aria-current={isActive ? 'page' : undefined}
                                >
                                    <tab.icon
                                        className={`-ml-0.5 mr-2 h-5 w-5 ${
                                            isActive
                                                ? 'text-orange-500 dark:text-orange-400'
                                                : 'text-gray-400 group-hover:text-gray-500 dark:group-hover:text-gray-300'
                                        }`}
                                        aria-hidden="true"
                                    />
                                    <span>{tab.label}</span>
                                </button>
                            );
                        })}
                    </nav>
                </div>
                
                {/* Tab Description */}
                <div className="mt-3">
                    <p className="text-sm text-gray-600 dark:text-gray-400">
                        {tabs.find(tab => tab.id === activeTab)?.description}
                    </p>
                </div>
            </div>

            {/* Tab Content */}
            <div className="mt-6">
                {renderTabContent()}
            </div>
        </div>
    );
}