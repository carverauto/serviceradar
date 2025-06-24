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
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Cell, Tooltip } from 'recharts';
import { Monitor, AlertTriangle, ShieldOff, Bell, Plus, MoreHorizontal, Info, ChevronDown } from 'lucide-react';

// Reusable component for the top statistic cards
const StatCard = ({ icon, title, value, subValue, alert = false, dropdown = false }) => (
    <div className={`bg-[#25252e] border border-gray-700/80 p-4 rounded-lg flex items-center gap-4`}>
        <div className={`p-3 rounded-md ${
            alert ? 'bg-red-900/50 text-red-400'
                : title.includes('Threat') ? 'bg-yellow-900/50 text-yellow-400'
                    : title.includes('Unhandled') ? 'bg-violet-900/50 text-violet-400'
                        : 'bg-blue-900/50 text-blue-400'
        }`}>
            {React.cloneElement(icon, { className: 'h-6 w-6' })}
        </div>
        <div className="flex items-baseline gap-x-2">
            <p className="text-2xl font-bold text-white">{value}</p>
            <p className="text-sm text-gray-400">{title}</p>
            {subValue && <p className="text-sm text-gray-500">| {subValue}</p>}
        </div>
        {dropdown && <ChevronDown className="h-4 w-4 text-gray-400 ml-auto" />}
    </div>
);

// Reusable component for the chart widgets
const ChartWidget = ({ title, subTitle, children, pagination, moreOptions = true }) => (
    <div className="bg-[#25252e] border border-gray-700/80 rounded-lg p-4 flex flex-col h-[320px]">
        <div className="flex justify-between items-start mb-4">
            <div>
                <h3 className="font-semibold text-white">{title}</h3>
                <p className="text-sm text-gray-400">{subTitle}</p>
            </div>
            <div className="flex items-center gap-x-2">
                {pagination && <div className="text-xs text-gray-400">{pagination}</div>}
                {moreOptions && <button className="text-gray-400 hover:text-white"><MoreHorizontal size={20} /></button>}
            </div>
        </div>
        <div className="flex-1">{children}</div>
    </div>
);

// "No Data to Show" component for the first chart
const NoData = () => (
    <div className="flex flex-col items-center justify-center h-full text-center text-gray-500">
        <div className="w-16 h-12 relative mb-2">
            <div className="absolute top-0 left-0 w-8 h-12 bg-gray-600 transform -skew-x-12"></div>
            <div className="absolute top-0 left-8 w-8 h-12 bg-violet-600 transform -skew-x-12"></div>
        </div>
        <p>No data to show</p>
    </div>
);

// Bar Chart component for reuse
const SimpleBarChart = ({ data, yAxisFormatter, yDomain }) => (
    <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} margin={{ top: 10, right: 10, left: -10, bottom: 5 }}>
            <XAxis dataKey="name" tick={{ fill: '#9ca3af', fontSize: 12 }} axisLine={false} tickLine={false} interval={0} />
            <YAxis
                tickFormatter={yAxisFormatter}
                tick={{ fill: '#9ca3af', fontSize: 12 }}
                domain={yDomain}
                axisLine={false}
                tickLine={false}
            />
            <Tooltip
                cursor={{ fill: 'rgba(100, 116, 139, 0.1)' }}
                contentStyle={{ backgroundColor: '#16151c', border: '1px solid #4b5563', borderRadius: '0.5rem' }}
                labelStyle={{ color: '#d1d5db' }}
            />
            <Bar dataKey="value" name="Count" radius={[4, 4, 0, 0]}>
                {data.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={entry.color} />
                ))}
            </Bar>
        </BarChart>
    </ResponsiveContainer>
);

// Mock data for the charts
const devicesNotScannedData = [
    { name: 'Computers', value: 89800, color: '#3b82f6' },
    { name: 'Handhelds', value: 16700, color: '#8b5cf6' },
    { name: 'Communications', value: 16000, color: '#60a5fa' },
    { name: 'Network Equip...', value: 7525, color: '#60a5fa' },
    { name: 'Imaging', value: 3536, color: '#a78bfa' },
    { name: 'Multimedia', value: 961, color: '#a78bfa' },
    { name: 'Automations', value: 560, color: '#a78bfa' },
];

const highRiskNotScannedData = [
    { name: 'Computers', value: 673, color: '#3b82f6'},
    { name: 'Handhelds', value: 525, color: '#8b5cf6'}
];

const criticalVulnsNoScanData = [
    { name: 'Workstation', value: 3424, color: '#3b82f6'}
];

export default function HomePage() {
    return (
        <div className="space-y-6">
            {/* Top Stat Cards Section */}
            <div className="p-4 bg-[#25252e] border border-gray-700/80 rounded-lg">
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
                    <StatCard icon={<Monitor />} title="Devices" value="140k" subValue="4,171 new" />
                    <StatCard icon={<AlertTriangle />} title="Critical risk devices" value="13.7k" alert />
                    <StatCard icon={<ShieldOff />} title="Threat activities" value="0" />
                    <StatCard icon={<Bell />} title="Unhandled alerts" value="0" dropdown />
                </div>
            </div>

            {/* Vulnerabilities Section */}
            <div>
                <div className="flex justify-between items-center mb-4">
                    <div className="flex items-center gap-2">
                        <h2 className="text-xl font-bold text-white">Vulnerabilities</h2>
                        <button className="text-gray-400 hover:text-white"><Info size={16} /></button>
                        <button className="text-gray-400 hover:text-white"><ChevronDown size={16} /></button>
                    </div>
                    <div className="flex items-center gap-2">
                        <button className="p-2 bg-violet-600 rounded-md hover:bg-violet-700">
                            <Plus className="h-5 w-5 text-white" />
                        </button>
                        <button className="p-2 text-gray-400 hover:text-white hover:bg-gray-700/50 rounded-md">
                            <MoreHorizontal className="h-5 w-5" />
                        </button>
                    </div>
                </div>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                    <ChartWidget title="Devices Scanned by Vulnerability Scanner" subTitle="Devices by Device Category">
                        <NoData />
                    </ChartWidget>
                    <ChartWidget title="Devices Not Scanned by Vulnerability Scanner" subTitle="Devices by Device Category" pagination="< 1 - 7 of 12 >">
                        <SimpleBarChart
                            data={devicesNotScannedData}
                            yAxisFormatter={(value) => value > 0 ? `${value / 1000}k` : '0'}
                            yDomain={[0, 100000]}
                        />
                    </ChartWidget>
                    <ChartWidget title="High Risk Devices Not Scanned in Last 30 Days" subTitle="Devices by Device Category">
                        <SimpleBarChart
                            data={highRiskNotScannedData}
                            yAxisFormatter={(value) => value}
                            yDomain={[0, 750]}
                        />
                    </ChartWidget>
                    <ChartWidget title="Devices with Confirmed High or Critical Vulnerabilities and No Scan in Last 30 Days" subTitle="Devices by Device Type">
                        <SimpleBarChart
                            data={criticalVulnsNoScanData}
                            yAxisFormatter={(value) => value > 0 ? `${value / 1000}`.replace('.', ',') + ',000' : '2,000'}
                            yDomain={[2000, 4000]}
                        />
                    </ChartWidget>
                </div>
            </div>
        </div>
    );
}