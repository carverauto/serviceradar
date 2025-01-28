import React from 'react';

// Helper functions for formatting
const formatResponseTime = (time) => {
    if (!time && time !== 0) return 'N/A';
    return `${(time / 1000000).toFixed(2)}ms`;
};

const formatPacketLoss = (loss) => {
    if (typeof loss !== 'number') return 'N/A';
    return `${loss.toFixed(1)}%`;
};

// Individual ping status component
const PingStatus = ({ details }) => {
    const getPingDetails = () => {
        try {
            return typeof details === 'string' ? JSON.parse(details) : details;
        } catch (e) {
            console.error('Error parsing ping details:', e);
            return null;
        }
    };

    const pingData = getPingDetails();

    if (!pingData) {
        return <div className="text-gray-500">No ping data available</div>;
    }

    return (
        <div className="grid grid-cols-2 gap-2 text-sm">
            <div className="font-medium text-gray-600">Response Time:</div>
            <div>{formatResponseTime(pingData.response_time)}</div>
            <div className="font-medium text-gray-600">Packet Loss:</div>
            <div>{formatPacketLoss(pingData.packet_loss)}</div>
            <div className="font-medium text-gray-600">Status:</div>
            <div className={`font-medium ${pingData.available ? 'text-green-600' : 'text-red-600'}`}>
                {pingData.available ? 'Available' : 'Unavailable'}
            </div>
        </div>
    );
};

// Summary component for multiple hosts
const ICMPSummary = ({ hosts }) => {
    if (!Array.isArray(hosts) || hosts.length === 0) {
        return <div className="text-gray-500">No ICMP data available</div>;
    }

    const respondingHosts = hosts.filter(h => h.available).length;
    const totalResponseTime = hosts.reduce((sum, host) => {
        if (host.available && host.response_time) {
            return sum + host.response_time;
        }
        return sum;
    }, 0);
    const avgResponseTime = respondingHosts > 0 ? totalResponseTime / respondingHosts : 0;

    return (
        <div className="bg-white rounded-lg shadow p-6">
            <div className="grid grid-cols-2 gap-4 text-sm">
                <div className="font-medium text-gray-600">ICMP Responding:</div>
                <div>{respondingHosts} hosts</div>
                <div className="font-medium text-gray-600">Average Response Time:</div>
                <div>{formatResponseTime(avgResponseTime)}</div>
            </div>
        </div>
    );
};

// Network sweep ICMP summary
const NetworkSweepICMP = ({ sweepData }) => {
    if (!sweepData || !sweepData.hosts) {
        return <div className="text-gray-500">No sweep data available</div>;
    }

    const hosts = sweepData.hosts.filter(host => host.icmp_status);
    const respondingHosts = hosts.filter(host => host.icmp_status.available).length;

    let avgResponseTime = 0;
    const respondingHostsWithTime = hosts.filter(host => {
        return host.icmp_status.available && host.icmp_status.round_trip;
    });

    if (respondingHostsWithTime.length > 0) {
        const totalTime = respondingHostsWithTime.reduce((sum, host) => {
            return sum + (host.icmp_status.round_trip || 0);
        }, 0);
        avgResponseTime = totalTime / respondingHostsWithTime.length;
    }

    return (
        <div className="space-y-4">
            <h3 className="text-lg font-medium">ICMP Status Summary</h3>
            <div className="bg-white rounded-lg shadow p-6">
                <div className="grid grid-cols-2 gap-4 text-sm">
                    <div className="font-medium text-gray-600">ICMP Responding:</div>
                    <div>{respondingHosts} hosts</div>
                    <div className="font-medium text-gray-600">Average Response Time:</div>
                    <div>{formatResponseTime(avgResponseTime)}</div>
                </div>
            </div>
        </div>
    );
};

export { PingStatus, ICMPSummary, NetworkSweepICMP };