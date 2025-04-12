// src/components/Metrics/metric-components.jsx
import React from 'react';
import { Thermometer, Cpu, HardDrive, BarChart3 } from 'lucide-react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer, AreaChart, Area, BarChart, Bar } from 'recharts';
import { MetricCard, CustomTooltip, ProgressBar } from './shared-components';

// Temperature Components
export const TemperatureCard = ({ data }) => {
    return (
        <MetricCard
            title="Temperature"
            current={data.current}
            unit={data.unit}
            warning={data.warning}
            critical={data.critical}
            change={data.change}
            icon={<Thermometer size={16} className="mr-2 text-blue-400" />}
        />
    );
};

export const TemperatureChart = ({ data }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-2">Temperature Trend</h3>
            <div style={{ height: "180px" }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, data.max]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#3B82F6" fill="#3B82F6" fillOpacity={0.2} name={`Temperature (${data.unit})`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const TemperatureDetails = ({ data }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-3">Temperature Details</h3>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="p-3 bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-400">Current</div>
                    <div className="text-lg font-bold text-blue-400">{data.current}{data.unit}</div>
                </div>
                <div className="p-3 bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-400">Warning Threshold</div>
                    <div className="text-lg font-bold text-yellow-400">{data.warning}{data.unit}</div>
                </div>
                <div className="p-3 bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-400">Critical Threshold</div>
                    <div className="text-lg font-bold text-red-400">{data.critical}{data.unit}</div>
                </div>
            </div>
        </div>
    );
};

// CPU Components
export const CpuCard = ({ data }) => {
    return (
        <MetricCard
            title="CPU Usage"
            current={data.current}
            unit={data.unit}
            warning={data.warning}
            critical={data.critical}
            change={data.change}
            icon={<Cpu size={16} className="mr-2 text-purple-400" />}
        />
    );
};

export const CpuChart = ({ data }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-2">CPU Usage Trend</h3>
            <div style={{ height: "180px" }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, 100]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#8B5CF6" fill="#8B5CF6" fillOpacity={0.2} name={`CPU Usage (${data.unit})`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const CpuCoresChart = ({ cores }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-3">CPU Cores Usage</h3>
            <div style={{ height: "180px" }}>
                <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={cores} margin={{ top: 5, right: 30, left: 20, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                        <XAxis dataKey="name" stroke="#6B7280" />
                        <YAxis domain={[0, 100]} stroke="#6B7280" />
                        <Tooltip />
                        <Bar dataKey="value" name="Usage (%)" fill="#8B5CF6" />
                    </BarChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

// Memory Components
export const MemoryCard = ({ data }) => {
    return (
        <MetricCard
            title="Memory Usage"
            current={data.current}
            unit={data.unit}
            warning={data.warning}
            critical={data.critical}
            change={data.change}
            icon={<BarChart3 size={16} className="mr-2 text-pink-400" />}
        />
    );
};

export const MemoryChart = ({ data }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-2">Memory Usage Trend</h3>
            <div style={{ height: "180px" }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, 100]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#EC4899" fill="#EC4899" fillOpacity={0.2} name={`Memory Usage (${data.unit})`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const MemoryDetails = ({ data }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-3">Memory Details</h3>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="p-3 bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-400">Total Memory</div>
                    <div className="text-lg font-bold text-pink-400">{data.total} GB</div>
                </div>
                <div className="p-3 bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-400">Used Memory</div>
                    <div className="text-lg font-bold text-pink-400">{data.used} GB</div>
                </div>
                <div className="p-3 bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-400">Free Memory</div>
                    <div className="text-lg font-bold text-pink-400">{(data.total - data.used).toFixed(1)} GB</div>
                </div>
            </div>
        </div>
    );
};

// Filesystem Components
export const FilesystemCard = ({ data }) => {
    const avgUsage = data.drives.reduce((sum, drive) => sum + drive.usedPercent, 0) / data.drives.length;

    return (
        <MetricCard
            title="Disk Usage"
            current={avgUsage.toFixed(1)}
            unit="%"
            warning={data.warning}
            critical={data.critical}
            icon={<HardDrive size={16} className="mr-2 text-green-400" />}
        >
            <div className="text-xs text-gray-400 mt-1">
                {data.drives.length} volumes monitored
            </div>
        </MetricCard>
    );
};

export const FilesystemChart = ({ data }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-2">Disk Usage Trend</h3>
            <div style={{ height: "180px" }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, 100]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#10B981" fill="#10B981" fillOpacity={0.2} name={`Disk Usage (%)`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const FilesystemDetails = ({ drives }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-4">
            <h3 className="text-sm font-medium text-gray-300 mb-3">Filesystem Details</h3>
            <div className="space-y-4">
                {drives.map((drive, index) => (
                    <div key={index} className="bg-gray-700 rounded-lg p-3">
                        <div className="flex justify-between items-center mb-1">
                            <span className="font-medium text-gray-200">{drive.name}</span>
                            <span className="text-sm">
                {drive.used} GB / {drive.size} GB
              </span>
                        </div>
                        <ProgressBar
                            value={drive.usedPercent}
                            warning={drive.warning}
                            critical={drive.critical}
                        />
                        <div className="text-right text-xs text-gray-400 mt-1">
                            {drive.usedPercent}% used
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );
};

// Add missing ReferenceLine component import
import { ReferenceLine } from 'recharts';