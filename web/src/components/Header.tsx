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

import React from 'react';
import { Search, Settings, ChevronDown } from 'lucide-react';

export default function Header() {

    return (
        <header className="h-16 flex-shrink-0 bg-[#1C1B22] border-b border-gray-700 flex items-center justify-between px-6 text-gray-300">
            <div className="flex-1 max-w-xl mx-4">
                <div className="relative">
                    <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                        <Search className="h-5 w-5 text-gray-400" />
                    </div>
                    <input
                        type="text"
                        placeholder="Search using SRQL query"
                        className="w-full bg-[#25252e] border border-gray-600 rounded-md py-2 pl-10 pr-4 text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-violet-500"
                    />
                </div>
            </div>

            <div className="flex items-center gap-4">
                <button className="flex items-center gap-2 px-3 py-1.5 border border-gray-600 rounded-md text-sm hover:bg-gray-700/50">
                    All Pollers
                    <ChevronDown className="h-4 w-4" />
                </button>
                <button className="flex items-center gap-2 px-3 py-1.5 border border-gray-600 rounded-md text-sm hover:bg-gray-700/50">
                    All Partitions
                    <ChevronDown className="h-4 w-4" />
                </button>
                <button className="flex items-center gap-2 px-3 py-1.5 border border-gray-600 rounded-md text-sm hover:bg-gray-700/50">
                    Last 7 Days
                    <ChevronDown className="h-4 w-4" />
                </button>
                <button className="p-2 rounded-full hover:bg-gray-700/50"><Settings className="h-5 w-5" /></button>
                <button className="w-9 h-9 flex items-center justify-center bg-violet-600 rounded-full text-white font-bold text-sm">M</button>
            </div>
        </header>
    );
}