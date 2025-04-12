// EnvMetricsDemo.jsx
import React, { useState } from 'react';
import EnvironmentMetrics from './environment-metrics';

const EnvMetricsDemo = () => {
    const [selectedPoller, setSelectedPoller] = useState('poller-01');

    // Sample pollers from your dashboard
    const pollers = [
        'poller-01',
        'proxmox-1',
        'proxmox-2',
        'proxmox-3',
        'proxmox-4',
        'proxmox-5',
        'proxmox-6',
        'proxmox-7'
    ];

    return (
        <div className="p-4 space-y-4">
            <div className="flex items-center space-x-2 mb-4">
                <label htmlFor="poller-select" className="text-sm font-medium text-gray-200">
                    Select Poller:
                </label>
                <select
                    id="poller-select"
                    value={selectedPoller}
                    onChange={(e) => setSelectedPoller(e.target.value)}
                    className="bg-gray-800 border border-gray-700 text-gray-200 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 p-2"
                >
                    {pollers.map(poller => (
                        <option key={poller} value={poller}>{poller}</option>
                    ))}
                </select>
            </div>

            <EnvironmentMetrics pollerId={selectedPoller} />
        </div>
    );
};

export default EnvMetricsDemo;