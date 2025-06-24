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
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import {
    BarChart3,
    Server,
    MessageSquareCode,
    Package,
    MessageCircleQuestion,
    Globe,
    Layers
} from 'lucide-react';

const navItems = [
    { href: '/analytics', label: 'Analytics', icon: BarChart3 },
    { href: '/devices', label: 'Devices', icon: Server },
    { href: '/network', label: 'Network', icon: Globe },
    { href: '/security', label: 'Events', icon: MessageSquareCode},
];

export default function Sidebar() {
    const pathname = usePathname();

    return (
        <aside className="w-60 flex-shrink-0 bg-[#16151c] text-gray-300 flex flex-col border-r border-gray-700">
            <div className="h-16 flex items-center px-4 border-b border-gray-700">
                <span className="text-xl font-bold text-white">ServiceRadar</span>
                <span className="ml-1 text-[10px] align-top font-semibold bg-blue-500 text-white px-1 py-0.5 rounded">TM</span>
            </div>
            <nav className="flex-1 px-3 py-4 space-y-1">
                {navItems.map((item) => {
                    const isActive = pathname.startsWith(item.href);
                    return (
                        <Link key={item.href} href={item.href} className={`flex items-center gap-x-3 px-3 py-2.5 rounded-md text-sm font-medium transition-colors ${isActive ? 'bg-violet-600 text-white' : 'hover:bg-gray-700/50 hover:text-white'}`}>
                            <item.icon className="h-5 w-5" />
                            <span>{item.label}</span>
                        </Link>
                    );
                })}
            </nav>
            <div className="mt-auto p-4 border-t border-gray-700"><button className="w-full flex items-center justify-center py-2.5 rounded-md text-sm font-medium transition-colors hover:bg-gray-700/50 hover:text-white relative"><MessageCircleQuestion className="h-5 w-5" /><span className="absolute top-1 right-1 flex h-5 w-5 items-center justify-center rounded-full bg-red-500 text-xs text-white">14</span></button></div>
        </aside>
    );
}