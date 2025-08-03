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
import Image from 'next/image';
import { usePathname } from 'next/navigation';
import {
    BarChart3,
    Server,
    MessageSquareCode,
    Globe,
    Activity,
} from 'lucide-react';

const navItems = [
    { href: '/analytics', label: 'Analytics', icon: BarChart3 },
    { href: '/devices', label: 'Devices', icon: Server },
    { href: '/network', label: 'Network', icon: Globe },
    { href: '/events', label: 'Events', icon: MessageSquareCode },
    { href: '/observability', label: 'Observability', icon: Activity },
];

export default function Sidebar() {
    const pathname = usePathname();

    return (
        <aside className="w-60 flex-shrink-0 bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 flex flex-col border-r border-gray-200 dark:border-gray-700">
            <div className="h-16 flex items-center gap-2 px-4 border-b border-gray-200 dark:border-gray-700">
                <Image src="/serviceRadar.svg" alt="ServiceRadar Logo" width={36} height={36} />
                <Link href="/" className="text-xl font-bold text-gray-800 dark:text-white">
                    ServiceRadar
                </Link>
            </div>
            <nav className="flex-1 px-3 py-4 space-y-1">
                {navItems.map((item) => {
                    const isActive = pathname.startsWith(item.href);
                    return (
                        <Link key={item.href} href={item.href} className={`flex items-center gap-x-3 px-3 py-2.5 rounded-md text-sm font-medium transition-colors ${isActive ? 'bg-blue-600 text-white' : 'hover:bg-gray-100 dark:hover:bg-gray-700'}`}>
                            <item.icon className="h-5 w-5" />
                            <span>{item.label}</span>
                        </Link>
                    );
                })}
            </nav>
        </aside>
    );
}