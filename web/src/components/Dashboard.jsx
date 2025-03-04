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

// src/components/Dashboard.jsx - Client Component
'use client';

import React, { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { CircleDot, Server, Rss, ArrowRight, Clock, Monitor, Activity } from 'lucide-react';
import Link from 'next/link';

function Dashboard({ initialData = null }) {
    const router = useRouter();
    const [data, setData] = useState(initialData);
    const [stats, setStats] = useState({
        totalServices: 0,
        offlineServices: 0,
        responseTime: 0
    });

    useEffect(() => {
        if (initialData?.service_stats) {
            setStats({
                totalServices: initialData.service_stats.total_services || 0,
                offlineServices: initialData.service_stats.offline_services || 0,
                responseTime: initialData.service_stats.avg_response_time || 0
            });
        }
    }, [initialData]);

    const navigateToNodes = () => {
        router.push('/nodes');
    };

    if (!initialData) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-4 rounded-lg text-red-600 dark:text-red-200">
                <h3 className="font-bold mb-2">Error Loading Dashboard</h3>
                <p>Could not load dashboard data</p>
            </div>
        );
    }

    // Calculate percentage of healthy nodes
    const healthPercentage = initialData.total_nodes > 0
        ? Math.round((initialData.healthy_nodes / initialData.total_nodes) * 100)
        : 0;

    // Calculate percentage of available services
    const serviceHealthPercentage = stats.totalServices > 0
        ? Math.round(((stats.totalServices - stats.offlineServices) / stats.totalServices) * 100)
        : 0;

    return (
        <div className="space-y-6">
            {/* Status Overview */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-lg overflow-hidden transition-colors">
                <div className="p-6 pb-0">
                    <h2 className="text-xl font-bold text-gray-800 dark:text-gray-100 mb-2">System Status</h2>
                    <p className="text-sm text-gray-600 dark:text-gray-400">
                        Last updated: {initialData.last_update
                        ? new Date(initialData.last_update).toLocaleString()
                        : 'N/A'}
                    </p>
                </div>

                {/* Health Status Bar */}
                <div className="p-6 pt-4">
                    <div className="flex items-center justify-between mb-2">
                        <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Overall Health</span>
                        <span className={`text-sm font-medium ${healthPercentage > 80 ? 'text-green-600 dark:text-green-400' : healthPercentage > 50 ? 'text-yellow-600 dark:text-yellow-400' : 'text-red-600 dark:text-red-400'}`}>
                            {healthPercentage}%
                        </span>
                    </div>
                    <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2.5">
                        <div
                            className={`h-2.5 rounded-full ${healthPercentage > 80 ? 'bg-green-500' : healthPercentage > 50 ? 'bg-yellow-500' : 'bg-red-500'}`}
                            style={{ width: `${healthPercentage}%` }}
                        ></div>
                    </div>
                </div>
            </div>

            {/* Node & Service Stats Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                {/* Card 1 - Total Nodes with navigation */}
                <div
                    onClick={navigateToNodes}
                    className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors flex items-center cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700 group"
                >
                    <div className="p-3 rounded-full bg-blue-100 dark:bg-blue-900 mr-4">
                        <Server className="h-6 w-6 text-blue-600 dark:text-blue-300" />
                    </div>
                    <div className="flex-1">
                        <h3 className="font-bold text-gray-800 dark:text-gray-100">
                            Total Nodes
                        </h3>
                        <div className="flex items-center">
                            <p className="text-2xl font-bold text-gray-700 dark:text-gray-100 mr-2">
                                {initialData.total_nodes || 0}
                            </p>
                            <ArrowRight className="h-4 w-4 text-gray-400 dark:text-gray-500 group-hover:transform group-hover:translate-x-1 transition-transform" />
                        </div>
                        <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                            {initialData.healthy_nodes || 0} healthy
                        </p>
                    </div>
                </div>

                {/* Card 2 - Services Status */}
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors flex items-center">
                    <div className="p-3 rounded-full bg-purple-100 dark:bg-purple-900 mr-4">
                        <Activity className="h-6 w-6 text-purple-600 dark:text-purple-300" />
                    </div>
                    <div>
                        <h3 className="font-bold text-gray-800 dark:text-gray-100">
                            Services
                        </h3>
                        <p className="text-2xl font-bold text-gray-700 dark:text-gray-100">
                            {stats.totalServices || 0}
                        </p>
                        <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                            {stats.offlineServices || 0} offline
                        </p>
                    </div>
                </div>

                {/* Card 3 - Last Update */}
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors flex items-center">
                    <div className="p-3 rounded-full bg-green-100 dark:bg-green-900 mr-4">
                        <Rss className="h-6 w-6 text-green-600 dark:text-green-300" />
                    </div>
                    <div>
                        <h3 className="font-bold text-gray-800 dark:text-gray-100">
                            Response Time
                        </h3>
                        <p className="text-2xl font-bold text-gray-700 dark:text-gray-100">
                            {stats.responseTime ? `${(stats.responseTime / 1000000).toFixed(2)}ms` : 'N/A'}
                        </p>
                        <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                            Average across nodes
                        </p>
                    </div>
                </div>
            </div>

            {/* Quick Access Links */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">Quick Actions</h3>
                <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                    <Link href="/nodes">
                        <div className="p-4 bg-gray-50 dark:bg-gray-700 rounded-lg flex flex-col items-center justify-center text-center hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer">
                            <Monitor className="h-6 w-6 text-blue-500 dark:text-blue-400 mb-2" />
                            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">View All Nodes</span>
                        </div>
                    </Link>

                    <Link href="/nodes">
                        <div className="p-4 bg-gray-50 dark:bg-gray-700 rounded-lg flex flex-col items-center justify-center text-center hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer">
                            <CircleDot className="h-6 w-6 text-red-500 dark:text-red-400 mb-2" />
                            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Alert Status</span>
                        </div>
                    </Link>

                    <Link href="/nodes">
                        <div className="p-4 bg-gray-50 dark:bg-gray-700 rounded-lg flex flex-col items-center justify-center text-center hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer">
                            <Activity className="h-6 w-6 text-green-500 dark:text-green-400 mb-2" />
                            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Network Status</span>
                        </div>
                    </Link>

                    <Link href="/nodes">
                        <div className="p-4 bg-gray-50 dark:bg-gray-700 rounded-lg flex flex-col items-center justify-center text-center hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors cursor-pointer">
                            <Clock className="h-6 w-6 text-purple-500 dark:text-purple-400 mb-2" />
                            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Recent Updates</span>
                        </div>
                    </Link>
                </div>
            </div>
        </div>
    );
}

export default Dashboard;