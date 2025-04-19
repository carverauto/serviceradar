// src/components/Metrics/data-service.js
import { fetchFromAPI } from '@/lib/api';

// Helper function to convert bytes to GB
const bytesToGB = (bytes) => (bytes / 1024 / 1024 / 1024).toFixed(1);

// Safe property access helper
const safeGet = (obj, path, defaultValue = null) => {
    try {
        return path.split('.').reduce((o, key) =>
            (o && o[key] !== undefined) ? o[key] : undefined, obj) || defaultValue;
    } catch (e) {
        console.warn(`Error accessing property path: ${path}`, e);
        return defaultValue;
    }
};

export const fetchSystemData = async (pollerId, timeRange = '1h') => {
    return new Promise(async (resolve, reject) => {
        try {
            const end = new Date();
            const start = new Date();
            switch (timeRange) {
                case '6h':
                    start.setHours(end.getHours() - 6);
                    break;
                case '24h':
                    start.setHours(end.getHours() - 24);
                    break;
                default:
                    start.setHours(end.getHours() - 1);
            }

            const queryParams = `?start=${encodeURIComponent(start.toISOString())}&end=${encodeURIComponent(end.toISOString())}`;
            console.log(`Fetching Sysmon data for poller ${pollerId} with params: ${queryParams}`);

            try {
                // Use Promise.allSettled to handle partial failures
                const results = await Promise.allSettled([
                    fetchFromAPI(`/pollers/${pollerId}/sysmon/cpu${queryParams}`),
                    fetchFromAPI(`/pollers/${pollerId}/sysmon/disk${queryParams}`),
                    fetchFromAPI(`/pollers/${pollerId}/sysmon/memory${queryParams}`),
                ]);

                console.log("API request results:", results);

                // Extract values or use defaults
                const cpuData = results[0].status === 'fulfilled' && results[0].value ?
                    results[0].value : { cpus: [], timestamp: end.toISOString() };

                const diskData = results[1].status === 'fulfilled' && results[1].value ?
                    results[1].value : { disks: [], timestamp: end.toISOString() };

                const memoryData = results[2].status === 'fulfilled' && results[2].value ?
                    results[2].value : { memory: { used_bytes: 0, total_bytes: 1 }, timestamp: end.toISOString() };

                console.log("Received API data:", { cpuData, diskData, memoryData });

                // Process CPU data with proper error handling
                const cpuCores = Array.isArray(safeGet(cpuData, 'cpus')) ? cpuData.cpus : [];
                const cpuUsage = cpuCores.length > 0
                    ? cpuCores.reduce((sum, core) => sum + safeGet(core, 'usage_percent', 0), 0) / cpuCores.length
                    : 0;

                const cpu = {
                    current: parseFloat(cpuUsage.toFixed(1)),
                    warning: 70,
                    critical: 90,
                    data: [{
                        timestamp: safeGet(cpuData, 'timestamp', end.toISOString()),
                        formattedTime: new Date(safeGet(cpuData, 'timestamp', end)).toLocaleTimeString(),
                        value: parseFloat(cpuUsage.toFixed(1))
                    }],
                    unit: '%',
                    min: 0,
                    max: 100,
                    cores: cpuCores.map(core => ({
                        name: `Core ${safeGet(core, 'core_id', 'Unknown')}`,
                        value: safeGet(core, 'usage_percent', 0)
                    })),
                };

                // Process memory data with proper error handling
                const memTotal = safeGet(memoryData, 'memory.total_bytes', 1);
                const memUsed = safeGet(memoryData, 'memory.used_bytes', 0);
                const memPercent = memTotal > 0 ? (memUsed / memTotal) * 100 : 0;

                const memory = {
                    current: parseFloat(memPercent.toFixed(1)),
                    warning: 85,
                    critical: 95,
                    total: parseFloat(bytesToGB(memTotal)),
                    used: parseFloat(bytesToGB(memUsed)),
                    data: [{
                        timestamp: safeGet(memoryData, 'timestamp', end.toISOString()),
                        formattedTime: new Date(safeGet(memoryData, 'timestamp', end)).toLocaleTimeString(),
                        value: parseFloat(memPercent.toFixed(1))
                    }],
                    unit: '%',
                    min: 0,
                    max: 100,
                };

                // Process disk data with proper error handling
                const disks = Array.isArray(safeGet(diskData, 'disks')) ? diskData.disks : [];
                console.log("Disk data:", disks);

                const disk = {
                    drives: disks.map(disk => {
                        const totalBytes = safeGet(disk, 'total_bytes', 1);
                        const usedBytes = safeGet(disk, 'used_bytes', 0);
                        const usedPercent = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0;

                        return {
                            name: safeGet(disk, 'mount_point', 'Unknown'),
                            used: parseFloat(bytesToGB(usedBytes)),
                            size: parseFloat(bytesToGB(totalBytes)),
                            usedPercent: parseFloat(usedPercent.toFixed(1)),
                            warning: 75,
                            critical: 90,
                        };
                    }),
                    data: [{
                        timestamp: safeGet(diskData, 'timestamp', end.toISOString()),
                        formattedTime: new Date(safeGet(diskData, 'timestamp', end)).toLocaleTimeString(),
                        value: disks.length > 0
                            ? parseFloat((disks.reduce((sum, disk) => {
                                const total = safeGet(disk, 'total_bytes', 1);
                                const used = safeGet(disk, 'used_bytes', 0);
                                return sum + (total > 0 ? (used / total) * 100 : 0);
                            }, 0) / disks.length).toFixed(1))
                            : 0
                    }],
                    unit: '%',
                    warning: 75,
                    critical: 90,
                    min: 0,
                    max: 100,
                };

                // Calculate change rates (placeholder, as we only have one data point per endpoint)
                cpu.change = 0;
                memory.change = 0;
                disk.change = 0;

                const result = {
                    cpu,
                    memory,
                    disk,
                };

                console.log("Processed system data:", result);
                resolve(result);
            } catch (error) {
                console.error('API fetch error:', error);
                reject(error);
            }
        } catch (error) {
            console.error('Error fetching Sysmon data:', error);
            reject(error);
        }
    });
};

export const getCombinedChartData = (data) => {
    if (!data) return [];

    const combinedData = [];
    const keys = ['cpu', 'memory', 'disk'];

    if (data.cpu && data.cpu.data) {
        const cpuData = data.cpu.data;

        cpuData.forEach((point, index) => {
            const dataPoint = {
                timestamp: point.timestamp,
                formattedTime: point.formattedTime,
            };

            keys.forEach((key) => {
                if (data[key] && data[key].data && data[key].data[index]) {
                    dataPoint[key] = data[key].data[index].value;
                }
            });

            combinedData.push(dataPoint);
        });
    }

    return combinedData;
};