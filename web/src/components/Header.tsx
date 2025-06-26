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
import { useRouter } from 'next/navigation';
import { Search, Settings, ChevronDown, Send } from 'lucide-react';
import { useAuth } from './AuthProvider';
import { fetchAPI } from '@/lib/client-api';

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
    const router = useRouter();
    const { token } = useAuth();

    useEffect(() => {
        const fetchPollers = async () => {
            try {
                const data = await fetchAPI<{ results: { poller_id: string }[] }>('/query', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` }),
                    },
                    body: JSON.stringify({ query: 'show pollers' }),
                });
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
                console.log('Raw pollers data:', data.results);
                setPollers(processedPollers);
            } catch (error) {
                console.error('Failed to fetch pollers:', error);
            }
        };

        const fetchPartitions = async () => {
            try {
                const data = await fetchAPI<{ results: { partition: string }[] }>('/query', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` }),
                    },
                    body: JSON.stringify({ query: 'show sweep_results | distinct partition' }),
                });
                setPartitions(Array.from(new Set(data.results.map((p: Partition) => p.partition))).map((p: string) => ({ partition: p })) || []);
            } catch (error) {
                console.error('Failed to fetch partitions:', error);
            }
        };

        fetchPollers();
        fetchPartitions();
    }, [token]);

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

                <div className="relative">
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
                <div className="relative">
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
                <button className="p-2 rounded-full hover:bg-gray-100 dark:hover:bg-gray-700"><Settings className="h-5 w-5" /></button>
                <button className="w-9 h-9 flex items-center justify-center bg-blue-600 rounded-full text-white font-bold text-sm">M</button>
            </div>
        </header>
    );
}