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

import React, { useState, useEffect } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Search, Settings, ChevronDown, Send, ExternalLink, Sun, Moon, User, LogOut } from 'lucide-react';
import { useAuth } from './AuthProvider';
import { useTheme } from '@/app/providers';
import { cachedQuery } from '@/lib/cached-query';

interface Poller {
    poller_id: string;
}

interface Partition {
    partition: string;
}

export default function Header() {
    const [query, setQuery] = useState('show devices');
    const [selectedPoller, setSelectedPoller] = useState<string | null>(null);
    const [selectedPartition, setSelectedPartition] = useState<string | null>(null);
    const [pollers, setPollers] = useState<Poller[]>([]);
    const [partitions, setPartitions] = useState<Partition[]>([]);
    const [showPollers, setShowPollers] = useState(false);
    const [showPartitions, setShowPartitions] = useState(false);
    const [showSettings, setShowSettings] = useState(false);
    const [showProfile, setShowProfile] = useState(false);
    const router = useRouter();
    const searchParams = useSearchParams();
    const { token, user, logout } = useAuth();
    const { darkMode, setDarkMode } = useTheme();

    useEffect(() => {
        const fetchPollers = async () => {
            try {
                const data = await cachedQuery<{ results: { poller_id: string }[] }>(
                    'show pollers',
                    token || undefined
                );
                const rawResults = Array.isArray(data.results) ? data.results as { poller_id: string }[] : [];
                const uniquePollerIds = new Set<string>();
                const processedPollers: Poller[] = [];

                rawResults.forEach((item: { poller_id: string }) => {
                    if (item && typeof item === 'object' && typeof item.poller_id === 'string') {
                        const trimmedId = item.poller_id.trim();
                        if (trimmedId !== '' && !uniquePollerIds.has(trimmedId)) {
                            uniquePollerIds.add(trimmedId);
                            processedPollers.push({ poller_id: trimmedId });
                        }
                    }
                });
                setPollers(processedPollers);
            } catch (error) {
                console.error('Failed to fetch pollers:', error);
            }
        };

        const fetchPartitions = async () => {
            try {
                const data = await cachedQuery<{ results: { partition: string }[] }>(
                    'SHOW SWEEP_RESULTS',
                    token || undefined
                );
                
                // Ensure data.results exists and is an array before processing
                if (data && data.results && Array.isArray(data.results)) {
                    const uniquePartitions = Array.from(new Set(data.results.map((p: Partition) => p.partition)))
                        .map((p: string) => ({ partition: p }));
                    setPartitions(uniquePartitions);
                } else {
                    console.warn('No partition results found or invalid data structure');
                    setPartitions([]);
                }
            } catch (error) {
                console.error('Failed to fetch partitions:', error);
                setPartitions([]);
            }
        };

        fetchPollers();
        fetchPartitions();
    }, [token]);

    // Sync query input with URL parameters
    useEffect(() => {
        const queryParam = searchParams.get('q');
        if (queryParam) {
            setQuery(queryParam);
        }
    }, [searchParams]);

    useEffect(() => {
        let newQuery = 'show devices';
        if (selectedPoller) {
            newQuery += ` | where poller_id = '${selectedPoller}'`;
        }
        if (selectedPartition) {
            newQuery += ` | where partition = '${selectedPartition}'`;
        }
        setQuery(newQuery);
    }, [selectedPoller, selectedPartition]);

    // Close dropdowns when clicking outside
    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            const target = event.target as Element;
            if (!target.closest('.dropdown-container')) {
                setShowPollers(false);
                setShowPartitions(false);
                setShowSettings(false);
                setShowProfile(false);
            }
        };

        document.addEventListener('mousedown', handleClickOutside);
        return () => document.removeEventListener('mousedown', handleClickOutside);
    }, []);

    const handlePollerSelect = (pollerId: string | null) => {
        setSelectedPoller(pollerId);
        setShowPollers(false);
    };

    const handlePartitionSelect = (partition: string | null) => {
        setSelectedPartition(partition);
        setShowPartitions(false);
    };

    const handleSearch = (e: React.FormEvent) => {
        e.preventDefault();
        if (query.trim()) {
            router.push(`/query?q=${encodeURIComponent(query)}`);
        }
    };

    // Get user initials for profile icon
    const getUserInitials = (email: string) => {
        return email.split('@')[0].substring(0, 2).toUpperCase();
    };

    // Handle dark mode toggle
    const handleThemeToggle = () => {
        setDarkMode(!darkMode);
        setShowSettings(false);
    };

    // Handle logout
    const handleLogout = () => {
        logout();
        setShowProfile(false);
    };

    return (
        <header className="h-16 flex-shrink-0 bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 flex items-center justify-between px-6 text-gray-600 dark:text-gray-300">
            <div className="flex-1 flex items-center gap-4 mx-4">
                <form onSubmit={handleSearch} className="relative flex-1 flex">
                    <div className="relative flex-1">
                        <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                            <Search className="h-5 w-5 text-gray-400" />
                        </div>
                        <input
                            type="text"
                            placeholder="Search using SRQL query"
                            className="w-full bg-gray-50 dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded-l-md py-2 pl-10 pr-4 text-gray-900 dark:text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                        />
                    </div>
                    <button
                        type="submit"
                        className="px-4 py-2 bg-blue-500 text-white border border-blue-500 rounded-r-md hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500 flex items-center gap-2"
                        title="Execute Query"
                    >
                        <Send className="h-4 w-4" />
                        <span className="hidden sm:inline">Search</span>
                    </button>
                </form>

                <div className="relative dropdown-container">
                    <button onClick={() => setShowPollers(!showPollers)} className="flex items-center gap-2 px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-md text-sm hover:bg-gray-100 dark:hover:bg-gray-700">
                        {selectedPoller ? selectedPoller : 'All Pollers'}
                        <ChevronDown className="h-4 w-4" />
                    </button>
                    {showPollers && (
                        <div className="absolute right-0 mt-2 w-56 rounded-md shadow-lg bg-white dark:bg-gray-800 ring-1 ring-black ring-opacity-5 z-10">
                            <div className="py-1" role="menu" aria-orientation="vertical" aria-labelledby="options-menu">
                                <a href="#" onClick={() => handlePollerSelect(null)} className="block px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">All Pollers</a>
                                {pollers.map((poller) => (
                                    <a href="#" key={poller.poller_id} onClick={() => handlePollerSelect(poller.poller_id)} className="block px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">{poller.poller_id}</a>
                                ))}
                            </div>
                        </div>
                    )}
                </div>
                <div className="relative dropdown-container">
                    <button onClick={() => setShowPartitions(!showPartitions)} className="flex items-center gap-2 px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-md text-sm hover:bg-gray-100 dark:hover:bg-gray-700">
                        {selectedPartition ? selectedPartition : 'All Partitions'}
                        <ChevronDown className="h-4 w-4" />
                    </button>
                    {showPartitions && (
                        <div className="absolute right-0 mt-2 w-56 rounded-md shadow-lg bg-white dark:bg-gray-800 ring-1 ring-black ring-opacity-5 z-10">
                            <div className="py-1" role="menu" aria-orientation="vertical" aria-labelledby="options-menu">
                                <a href="#" onClick={() => handlePartitionSelect(null)} className="block px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">All Partitions</a>
                                {partitions.map((partition, index) => (
                                    <a href="#" key={`${partition.partition}-${index}`} onClick={() => handlePartitionSelect(partition.partition)} className="block px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">{partition.partition}</a>
                                ))}
                            </div>
                        </div>
                    )}
                </div>
            </div>

            <div className="flex items-center gap-4">
                <button className="flex items-center gap-2 px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-md text-sm hover:bg-gray-100 dark:hover:bg-gray-700">
                    Last 7 Days
                    <ChevronDown className="h-4 w-4" />
                </button>
                
                {/* Settings Dropdown */}
                <div className="relative dropdown-container">
                    <button 
                        onClick={() => setShowSettings(!showSettings)}
                        className="p-2 rounded-full hover:bg-gray-100 dark:hover:bg-gray-700"
                    >
                        <Settings className="h-5 w-5" />
                    </button>
                    {showSettings && (
                        <div className="absolute right-0 mt-2 w-56 rounded-md shadow-lg bg-white dark:bg-gray-800 ring-1 ring-black ring-opacity-5 z-10">
                            <div className="py-1" role="menu">
                                <a 
                                    href="https://docs.serviceradar.cloud" 
                                    target="_blank" 
                                    rel="noopener noreferrer"
                                    className="flex items-center gap-2 px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700"
                                    role="menuitem"
                                >
                                    <ExternalLink className="h-4 w-4" />
                                    Documentation
                                </a>
                                <button
                                    onClick={handleThemeToggle}
                                    className="flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700"
                                    role="menuitem"
                                >
                                    {darkMode ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
                                    {darkMode ? 'Light Mode' : 'Dark Mode'}
                                </button>
                            </div>
                        </div>
                    )}
                </div>

                {/* Profile Dropdown */}
                <div className="relative dropdown-container">
                    <button 
                        onClick={() => setShowProfile(!showProfile)}
                        className="w-9 h-9 flex items-center justify-center bg-blue-600 hover:bg-blue-700 rounded-full text-white font-bold text-sm transition-colors"
                    >
                        {user?.email ? getUserInitials(user.email) : <User className="h-5 w-5" />}
                    </button>
                    {showProfile && (
                        <div className="absolute right-0 mt-2 w-64 rounded-md shadow-lg bg-white dark:bg-gray-800 ring-1 ring-black ring-opacity-5 z-10">
                            <div className="py-1" role="menu">
                                {user && (
                                    <div className="px-4 py-3 border-b border-gray-100 dark:border-gray-700">
                                        <p className="text-sm font-medium text-gray-900 dark:text-white">{user.email}</p>
                                        <p className="text-xs text-gray-500 dark:text-gray-400">Provider: {user.provider}</p>
                                    </div>
                                )}
                                <button
                                    onClick={handleLogout}
                                    className="flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700"
                                    role="menuitem"
                                >
                                    <LogOut className="h-4 w-4" />
                                    Sign Out
                                </button>
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </header>
    );
}