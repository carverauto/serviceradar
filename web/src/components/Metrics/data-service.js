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

// src/components/Metrics/data-service.js - Add getCombinedChartData function

import { fetchAPI } from '@/lib/client-api';

// Cache store for metrics data
const metricsCache = new Map();
const pendingRequests = new Map();

// Cache configuration
const CACHE_TTL = 10000; // 10 seconds cache TTL
const MIN_FETCH_INTERVAL = 1000; // Minimum 1 second between fetches for the same key

// Helper function to convert bytes to GB, handling string inputs
const bytesToGB = (bytes) => {
    const parsedBytes = parseInt(bytes);
    return isNaN(parsedBytes) ? 0 : (parsedBytes / 1024 / 1024 / 1024).toFixed(1);
};

const hzToGHz = (hz) => {
    const value = Number(hz);
    if (!Number.isFinite(value) || value <= 0) {
        return null;
    }

    return value / 1_000_000_000;
};

const average = (values) => {
    if (!Array.isArray(values) || values.length === 0) {
        return null;
    }

    const total = values.reduce((sum, val) => sum + val, 0);
    return total / values.length;
};

const toNumberOrNull = (value) => {
    const asNumber = Number(value);
    return Number.isFinite(asNumber) ? asNumber : null;
};

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

const buildClusterSummaries = (cores) => {
    if (!Array.isArray(cores) || cores.length === 0) {
        return [];
    }

    const deriveClusterName = (core) => {
        const rawCluster = safeGet(core, 'cluster', null);
        if (rawCluster && typeof rawCluster === 'string' && rawCluster.trim().length > 0) {
            return rawCluster.trim();
        }

        const label = safeGet(core, 'label', null);
        if (typeof label === 'string' && label.trim().length > 0) {
            const match = label.trim().match(/^[A-Za-z]+/);
            if (match && match[0]) {
                return match[0];
            }
        }

        const name = safeGet(core, 'name', null);
        if (typeof name === 'string' && name.trim().length > 0) {
            const match = name.trim().match(/^[A-Za-z]+/);
            if (match && match[0]) {
                return match[0];
            }
        }

        return 'Unassigned';
    };

    const clusterMap = new Map();

    cores.forEach((core) => {
        if (!core) {
            return;
        }

        const clusterName = deriveClusterName(core);
        if (!clusterMap.has(clusterName)) {
            clusterMap.set(clusterName, {
                name: clusterName,
                cores: 0,
                usageSum: 0,
                frequencySum: 0,
                frequencySamples: 0,
            });
        }

        const entry = clusterMap.get(clusterName);
        entry.cores += 1;

        const usage = toNumberOrNull(core.usage_percent);
        if (usage !== null) {
            entry.usageSum += usage;
        }

        const freq = toNumberOrNull(core.frequency_hz);
        if (freq !== null) {
            entry.frequencySum += freq;
            entry.frequencySamples += 1;
        }
    });

    return Array.from(clusterMap.values()).map((entry) => ({
        name: entry.name,
        cores: entry.cores,
        averageUsage: entry.cores > 0 ? entry.usageSum / entry.cores : 0,
        averageFrequencyHz: entry.frequencySamples > 0
            ? entry.frequencySum / entry.frequencySamples
            : null,
    }));
};

const extractSysmonMetadata = (sample) => {
    if (!sample || typeof sample !== 'object') {
        return null;
    }

    const metadataSource = sample.status || {};
    const coreSample = Array.isArray(sample.cpus) ? sample.cpus.find(Boolean) : null;

    const hostId = coreSample?.host_id || metadataSource.host_id || null;
    const hostIp = coreSample?.host_ip || metadataSource.host_ip || null;
    const agentId = coreSample?.agent_id || metadataSource.agent_id || null;
    const responseTimeNs = toNumberOrNull(sample.response_time || metadataSource.response_time);
    const timestamp = sample.timestamp || metadataSource.timestamp || null;

    if (!hostId && !hostIp && !agentId && !timestamp) {
        return null;
    }

    return {
        hostId,
        hostIp,
        agentId,
        responseTimeNs,
        timestamp,
    };
};

// Fetch system data from API
export const fetchSystemData = async (targetId, timeRange = '1h', idType = 'poller') => {
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
        const endpoint = idType === 'device' ? 'devices' : 'pollers';
        console.log(`Fetching Sysmon data for ${idType} ${targetId} with params: ${queryParams}`);

        // Improved error handling with individual try/catch blocks for each API call
        const cpuPromise = fetchWithTimeout(`/api/${endpoint}/${targetId}/sysmon/cpu${queryParams}`, 5000)
            .catch(err => {
                if (err.message === 'No metrics found') {
                    console.log(`CPU metrics: No data available for ${idType} ${targetId}`);
                } else {
                    console.warn(`CPU metrics failed: ${err.message}`);
                }
                return null;
            });

        const diskPromise = fetchWithTimeout(`/api/${endpoint}/${targetId}/sysmon/disk${queryParams}`, 5000)
            .catch(err => {
                if (err.message === 'No metrics found') {
                    console.log(`Disk metrics: No data available for ${idType} ${targetId}`);
                } else {
                    console.warn(`Disk metrics failed: ${err.message}`);
                }
                return null;
            });

        const memoryPromise = fetchWithTimeout(`/api/${endpoint}/${targetId}/sysmon/memory${queryParams}`, 5000)
            .catch(err => {
                if (err.message === 'No metrics found') {
                    console.log(`Memory metrics: No data available for ${idType} ${targetId}`);
                } else {
                    console.warn(`Memory metrics failed: ${err.message}`);
                }
                return null;
            });

        const processPromise = fetchWithTimeout(`/api/${endpoint}/${targetId}/sysmon/processes${queryParams}`, 5000)
            .catch(err => {
                if (err.message === 'No metrics found') {
                    console.log(`Process metrics: No data available for ${idType} ${targetId}`);
                } else {
                    console.warn(`Process metrics failed: ${err.message}`);
                }
                return null;
            });

        const results = await Promise.all([cpuPromise, diskPromise, memoryPromise, processPromise]);

        console.log('API request results:', results.map(r => r ?
            { status: 'success', dataSize: JSON.stringify(r).length } :
            { status: 'failed' }));

        const cpuResponse = results[0];
        const diskResponse = results[1];
        const memoryResponse = results[2];
        const processResponse = results[3];

        // Process CPU metrics with proper null checks
        let cpuDataPoints = [];
        let currentCpuValue = 0;
        let cpuCores = [];
        let cpuFrequencyDataPoints = [];
        let currentCpuFrequency = null;
        let cpuFrequencyCores = [];
        let cpuClusters = [];
        let cpuMetadata = null;

        if (cpuResponse) {
            try {
                if (Array.isArray(cpuResponse)) {
                    const latestSample = cpuResponse.length > 0 ? cpuResponse[0] : null;
                    cpuDataPoints = cpuResponse.map(point => {
                        const cores = safeGet(point, 'cpus', []);
                        const avgUsage = cores.length > 0
                            ? cores.reduce((sum, core) => sum + safeGet(core, 'usage_percent', 0), 0) / cores.length
                            : 0;
                        return {
                            timestamp: safeGet(point, 'timestamp', new Date().toISOString()),
                            formattedTime: new Date(safeGet(point, 'timestamp', new Date())).toLocaleTimeString(),
                            value: parseFloat(avgUsage.toFixed(1)),
                        };
                    });
                    const latestCores = safeGet(latestSample, 'cpus', []);
                    cpuMetadata = extractSysmonMetadata(latestSample);
                    cpuClusters = buildClusterSummaries(latestCores);
                    cpuCores = latestCores;
                    cpuFrequencyDataPoints = cpuResponse.map(point => {
                        const rawTimestamp = safeGet(point, 'timestamp', new Date().toISOString());
                        const cores = safeGet(point, 'cpus', []);
                        const frequencies = cores
                            .map(core => hzToGHz(safeGet(core, 'frequency_hz', null)))
                            .filter(value => value !== null);
                        const avgFreq = average(frequencies);

                        return {
                            timestamp: rawTimestamp,
                            formattedTime: new Date(rawTimestamp).toLocaleTimeString(),
                            value: avgFreq !== null ? parseFloat(avgFreq.toFixed(3)) : null,
                        };
                    });
                    currentCpuValue = cpuCores.length > 0
                        ? cpuCores.reduce((sum, core) => sum + safeGet(core, 'usage_percent', 0), 0) / cpuCores.length
                        : 0;

                    const latestFrequencyPoint = cpuFrequencyDataPoints.find(point => point.value !== null);
                    if (latestFrequencyPoint) {
                        currentCpuFrequency = latestFrequencyPoint.value;
                    }
                } else {
                    cpuCores = safeGet(cpuResponse, 'cpus', []);
                    cpuMetadata = extractSysmonMetadata(cpuResponse);
                    cpuClusters = buildClusterSummaries(cpuCores);
                    currentCpuValue = cpuCores.length > 0
                        ? cpuCores.reduce((sum, core) => sum + safeGet(core, 'usage_percent', 0), 0) / cpuCores.length
                        : 0;
                    cpuDataPoints = [{
                        timestamp: safeGet(cpuResponse, 'timestamp', new Date().toISOString()),
                        formattedTime: new Date(safeGet(cpuResponse, 'timestamp', new Date())).toLocaleTimeString(),
                        value: parseFloat(currentCpuValue.toFixed(1)),
                    }];

                    const frequencies = cpuCores
                        .map(core => hzToGHz(safeGet(core, 'frequency_hz', null)))
                        .filter(value => value !== null);
                    const avgFreq = average(frequencies);
                    const rawTimestamp = safeGet(cpuResponse, 'timestamp', new Date().toISOString());
                    cpuFrequencyDataPoints = [{
                        timestamp: rawTimestamp,
                        formattedTime: new Date(rawTimestamp).toLocaleTimeString(),
                        value: avgFreq !== null ? parseFloat(avgFreq.toFixed(3)) : null,
                    }];

                    if (avgFreq !== null) {
                        currentCpuFrequency = parseFloat(avgFreq.toFixed(3));
                    }
                }
            } catch (err) {
                console.error('Error processing CPU data:', err);
            }
        }

        if (cpuCores.length > 0) {
            cpuFrequencyCores = cpuCores
                .map(core => {
                    const frequency = hzToGHz(safeGet(core, 'frequency_hz', null));
                    return {
                        cluster: safeGet(core, 'cluster', null),
                        name: safeGet(core, 'label', null) || `Core ${safeGet(core, 'core_id', 'Unknown')}`,
                        value: frequency !== null ? parseFloat(frequency.toFixed(3)) : null,
                    };
                })
                .filter(core => core.value !== null);
        }

        // Process memory metrics with proper null checks
        let memoryDataPoints = [];
        let memTotal = 1;
        let memUsed = 0;
        let memPercent = 0;

        if (memoryResponse) {
            try {
                if (Array.isArray(memoryResponse)) {
                    memoryDataPoints = memoryResponse.map(point => {
                        const total = parseInt(safeGet(point, 'memory.total_bytes', '1'));
                        const used = parseInt(safeGet(point, 'memory.used_bytes', '0'));
                        const percent = total > 0 ? (used / total) * 100 : 0;
                        return {
                            timestamp: safeGet(point, 'timestamp', new Date().toISOString()),
                            formattedTime: new Date(safeGet(point, 'timestamp', new Date())).toLocaleTimeString(),
                            value: parseFloat(percent.toFixed(1)),
                        };
                    });
                    memTotal = parseInt(safeGet(memoryResponse[0], 'memory.total_bytes', '1'));
                    memUsed = parseInt(safeGet(memoryResponse[0], 'memory.used_bytes', '0'));
                    memPercent = memTotal > 0 ? (memUsed / memTotal) * 100 : 0;
                } else {
                    memTotal = parseInt(safeGet(memoryResponse, 'memory.total_bytes', '1'));
                    memUsed = parseInt(safeGet(memoryResponse, 'memory.used_bytes', '0'));
                    memPercent = memTotal > 0 ? (memUsed / memTotal) * 100 : 0;
                    memoryDataPoints = [{
                        timestamp: safeGet(memoryResponse, 'timestamp', new Date().toISOString()),
                        formattedTime: new Date(safeGet(memoryResponse, 'timestamp', new Date())).toLocaleTimeString(),
                        value: parseFloat(memPercent.toFixed(1)),
                    }];
                }
            } catch (err) {
                console.error('Error processing memory data:', err);
            }
        }

        // Process disk metrics with proper null checks
        let diskDataPoints = [];
        let disks = [];
        let avgDiskUsage = 0;

        if (diskResponse) {
            try {
                if (Array.isArray(diskResponse)) {
                    diskDataPoints = diskResponse.map(point => {
                        const disksInPoint = safeGet(point, 'disks', []);
                        const avgUsage = disksInPoint.length > 0
                            ? disksInPoint.reduce((sum, disk) => {
                            const total = parseInt(safeGet(disk, 'total_bytes', '1'));
                            const used = parseInt(safeGet(disk, 'used_bytes', '0'));
                            return sum + (total > 0 ? (used / total) * 100 : 0);
                        }, 0) / disksInPoint.length
                            : 0;
                        return {
                            timestamp: safeGet(point, 'timestamp', new Date().toISOString()),
                            formattedTime: new Date(safeGet(point, 'timestamp', new Date())).toLocaleTimeString(),
                            value: parseFloat(avgUsage.toFixed(1)),
                        };
                    });
                    disks = safeGet(diskResponse[0], 'disks', []);
                    avgDiskUsage = disks.length > 0
                        ? disks.reduce((sum, disk) => {
                        const total = parseInt(safeGet(disk, 'total_bytes', '1'));
                        const used = parseInt(safeGet(disk, 'used_bytes', '0'));
                        return sum + (total > 0 ? (used / total) * 100 : 0);
                    }, 0) / disks.length
                        : 0;
                } else {
                    disks = safeGet(diskResponse, 'disks', []);
                    avgDiskUsage = disks.length > 0
                        ? disks.reduce((sum, disk) => {
                        const total = parseInt(safeGet(disk, 'total_bytes', '1'));
                        const used = parseInt(safeGet(disk, 'used_bytes', '0'));
                        return sum + (total > 0 ? (used / total) * 100 : 0);
                    }, 0) / disks.length
                        : 0;
                    diskDataPoints = [{
                        timestamp: safeGet(diskResponse, 'timestamp', new Date().toISOString()),
                        formattedTime: new Date(safeGet(diskResponse, 'timestamp', new Date())).toLocaleTimeString(),
                        value: parseFloat(avgDiskUsage.toFixed(1)),
                    }];
                }
            } catch (err) {
                console.error('Error processing disk data:', err);
            }
        }

        // Process process metrics with proper null checks
        let processDataPoints = [];
        let processes = [];
        let processCount = 0;
        let avgCpuUsage = 0;
        let totalMemoryUsage = 0;

        if (processResponse) {
            try {
                if (Array.isArray(processResponse)) {
                    processDataPoints = processResponse.map(point => {
                        const processesInPoint = safeGet(point, 'processes', []);
                        const count = processesInPoint.length;
                        const avgCpu = processesInPoint.length > 0
                            ? processesInPoint.reduce((sum, proc) => sum + safeGet(proc, 'cpu_usage', 0), 0) / processesInPoint.length
                            : 0;
                        return {
                            timestamp: safeGet(point, 'timestamp', new Date().toISOString()),
                            formattedTime: new Date(safeGet(point, 'timestamp', new Date())).toLocaleTimeString(),
                            value: count,
                            avgCpu: parseFloat(avgCpu.toFixed(1)),
                        };
                    });
                    processes = safeGet(processResponse[0], 'processes', []);
                    processCount = processes.length;
                    avgCpuUsage = processes.length > 0
                        ? processes.reduce((sum, proc) => sum + safeGet(proc, 'cpu_usage', 0), 0) / processes.length
                        : 0;
                    totalMemoryUsage = processes.reduce((sum, proc) => sum + parseInt(safeGet(proc, 'memory_usage', '0')), 0);
                } else {
                    processes = safeGet(processResponse, 'processes', []);
                    processCount = processes.length;
                    avgCpuUsage = processes.length > 0
                        ? processes.reduce((sum, proc) => sum + safeGet(proc, 'cpu_usage', 0), 0) / processes.length
                        : 0;
                    totalMemoryUsage = processes.reduce((sum, proc) => sum + parseInt(safeGet(proc, 'memory_usage', '0')), 0);
                    processDataPoints = [{
                        timestamp: safeGet(processResponse, 'timestamp', new Date().toISOString()),
                        formattedTime: new Date(safeGet(processResponse, 'timestamp', new Date())).toLocaleTimeString(),
                        value: processCount,
                        avgCpu: parseFloat(avgCpuUsage.toFixed(1)),
                    }];
                }
            } catch (err) {
                console.error('Error processing process data:', err);
            }
        }

        // Build result with default values if data is missing
        const cpu = {
            current: parseFloat(currentCpuValue.toFixed(1)),
            warning: 70,
            critical: 90,
            data: cpuDataPoints.length > 0 ? cpuDataPoints : generateDefaultDataPoints(),
            unit: '%',
            min: 0,
            max: 100,
            cores: cpuCores.map(core => {
        const label = safeGet(core, 'label', null);
        const coreId = safeGet(core, 'core_id', 'Unknown');
        const rawCluster = safeGet(core, 'cluster', null);
        const cluster = (() => {
            if (rawCluster && typeof rawCluster === 'string' && rawCluster.trim().length > 0) {
                return rawCluster.trim();
            }
            if (typeof label === 'string' && label.trim().length > 0) {
                const match = label.trim().match(/^[A-Za-z]+/);
                if (match && match[0]) {
                    return match[0];
                }
            }
            return null;
        })();
        const baseName = label || `Core ${coreId}`;
        const includeCluster = cluster && !String(baseName).toLowerCase().includes(String(cluster).toLowerCase());
        const displayName = includeCluster ? `${baseName} (${cluster})` : baseName;
        const usagePercent = safeGet(core, 'usage_percent', 0);
        const frequencyHz = toNumberOrNull(safeGet(core, 'frequency_hz', null));
                const frequencyGHz = Number.isFinite(frequencyHz) && frequencyHz > 0 ? hzToGHz(frequencyHz) : null;

                return {
                    name: displayName,
                    rawLabel: baseName,
                    coreId,
                    value: usagePercent,
                    cluster,
                    frequencyHz,
                    frequencyGHz,
                };
            }),
            change: 0,
            clusters: cpuClusters,
            metadata: cpuMetadata,
        };

        let cpuFrequency = null;
        const nonNullFrequencyPoints = cpuFrequencyDataPoints.filter(point => point && point.value !== null);
        if (nonNullFrequencyPoints.length > 0) {
            const latestFrequency = currentCpuFrequency ?? nonNullFrequencyPoints[0].value;
            const frequencyValues = nonNullFrequencyPoints.map(point => point.value);
            const maxFrequency = Math.max(...frequencyValues);

            cpuFrequency = {
                current: parseFloat(latestFrequency.toFixed(3)),
                unit: 'GHz',
                min: 0,
                max: parseFloat(maxFrequency.toFixed(3)),
                data: cpuFrequencyDataPoints,
                change: 0,
                cores: cpuFrequencyCores,
                clusters: cpuClusters,
                metadata: cpuMetadata,
            };
        }

        const memory = {
            current: parseFloat(memPercent.toFixed(1)),
            warning: 85,
            critical: 95,
            total: parseFloat(bytesToGB(memTotal)),
            used: parseFloat(bytesToGB(memUsed)),
            data: memoryDataPoints.length > 0 ? memoryDataPoints : generateDefaultDataPoints(),
            unit: '%',
            min: 0,
            max: 100,
            change: 0,
        };

        const disk = {
            drives: disks.map(disk => {
                const totalBytes = parseInt(safeGet(disk, 'total_bytes', '1'));
                const usedBytes = parseInt(safeGet(disk, 'used_bytes', '0'));
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
            data: diskDataPoints.length > 0 ? diskDataPoints : generateDefaultDataPoints(),
            unit: '%',
            warning: 75,
            critical: 90,
            min: 0,
            max: 100,
            change: 0,
        };

        const process = {
            count: processCount,
            avgCpuUsage: parseFloat(avgCpuUsage.toFixed(1)),
            totalMemoryUsage: parseFloat(bytesToGB(totalMemoryUsage)),
            data: processDataPoints.length > 0 ? processDataPoints : generateDefaultDataPoints(),
            processes: processes.map(proc => ({
                pid: safeGet(proc, 'pid', 0),
                name: safeGet(proc, 'name', 'Unknown'),
                cpuUsage: parseFloat(safeGet(proc, 'cpu_usage', 0).toFixed(1)),
                memoryUsage: parseFloat(bytesToGB(safeGet(proc, 'memory_usage', '0'))),
                status: safeGet(proc, 'status', 'Unknown'),
                startTime: safeGet(proc, 'start_time', ''),
            })).sort((a, b) => b.cpuUsage - a.cpuUsage), // Sort by CPU usage desc
            unit: 'processes',
            change: 0,
        };

        const result = { cpu, memory, disk, process };
        if (cpuFrequency) {
            result.cpuFrequency = cpuFrequency;
        }
        console.log('Processed data points:', {
            cpuPoints: cpuDataPoints.length,
            memoryPoints: memoryDataPoints.length,
            diskPoints: diskDataPoints.length,
            processPoints: processDataPoints.length,
        });

        // Check if we have any actual metric data
        const hasAnyData = cpuResponse || diskResponse || memoryResponse || processResponse;
        if (!hasAnyData) {
            console.log(`No sysmon data available for ${idType} ${targetId}`);
            // Return null to indicate no data available, which will trigger the EmptyState
            return null;
        }

        return result;
    } catch (error) {
        console.error('Error fetching Sysmon data:', error);
        throw error;
    }
};

// Custom fetch with timeout and caching
const fetchWithTimeout = async (url, timeout = 8000) => {
    const cacheKey = url;
    const now = Date.now();
    
    // Check if we have valid cached data
    const cached = metricsCache.get(cacheKey);
    if (cached && (now - cached.timestamp) < CACHE_TTL) {
        console.log(`[Cache Hit] Returning cached data for: ${url}`);
        return cached.data;
    }
    
    // Check if there's already a pending request for this URL
    if (pendingRequests.has(cacheKey)) {
        console.log(`[Request Dedup] Waiting for existing request: ${url}`);
        return pendingRequests.get(cacheKey);
    }
    
    // Create the fetch promise
    const fetchPromise = (async () => {
        try {
            // Check if we need to throttle requests
            if (cached && (now - cached.timestamp) < MIN_FETCH_INTERVAL) {
                console.log(`[Throttled] Using stale cache for: ${url}`);
                return cached.data;
            }
            
            console.log(`[Fetching] Making API request: ${url}`);
            
            // First try to get from API
            const apiPromise = fetchAPI(url);

            // Set up timeout
            const timeoutPromise = new Promise((_, reject) => {
                setTimeout(() => {
                    reject(new Error(`Request timed out after ${timeout}ms`));
                }, timeout);
            });

            // Race between fetch and timeout
            const data = await Promise.race([apiPromise, timeoutPromise]);
            
            // Cache the successful response
            metricsCache.set(cacheKey, {
                data,
                timestamp: now
            });
            
            // Clean up pending request
            pendingRequests.delete(cacheKey);
            
            return data;
        } catch (error) {
            // Clean up pending request on error
            pendingRequests.delete(cacheKey);
            
            // If we have stale cached data, return it instead of failing
            if (cached) {
                console.warn(`[Fallback] Using stale cache due to error: ${error.message}`);
                return cached.data;
            }
            
            throw error;
        }
    })();
    
    // Store the pending request
    pendingRequests.set(cacheKey, fetchPromise);
    
    return fetchPromise;
};

// Cleanup old cache entries periodically
const cleanupCache = () => {
    const now = Date.now();
    const expiredKeys = [];
    
    metricsCache.forEach((value, key) => {
        if (now - value.timestamp > CACHE_TTL * 2) {
            expiredKeys.push(key);
        }
    });
    
    expiredKeys.forEach(key => {
        metricsCache.delete(key);
        console.log(`[Cache Cleanup] Removed expired entry: ${key}`);
    });
};

// Run cache cleanup every 30 seconds (only in browser environment)
if (typeof window !== 'undefined') {
    setInterval(cleanupCache, 30000);
}

// Generate default data points if API fails
const generateDefaultDataPoints = () => {
    const points = [];
    const now = new Date();

    for (let i = 0; i < 10; i++) {
        const time = new Date(now);
        time.setMinutes(now.getMinutes() - i * 5);

        points.push({
            timestamp: time.toISOString(),
            formattedTime: time.toLocaleTimeString(),
            value: 0,
        });
    }

    return points.reverse();
};

// Clear all cached metrics data
export const clearMetricsCache = () => {
    metricsCache.clear();
    pendingRequests.clear();
    console.log('[Cache] Cleared all metrics cache');
};

// Combines data from CPU, memory, and disk metrics for the combined chart
export const getCombinedChartData = (data) => {
    if (!data) return [];

    // Find the dataset with the most points to use as base
    let baseData = [];
    let baseKey = '';

    for (const key of ['cpu', 'memory', 'disk', 'process']) {
        if (data[key] && Array.isArray(data[key].data) && data[key].data.length > baseData.length) {
            baseData = data[key].data;
            baseKey = key;
        }
    }

    if (baseData.length === 0) {
        console.warn('No data available for combined chart');
        return [];
    }

    // Create combined dataset using timestamps from the base dataset
    return baseData.map(basePoint => {
        const result = {
            timestamp: basePoint.timestamp,
            formattedTime: basePoint.formattedTime,
        };

        // Add data points for each metric type (cpu, memory, disk, process)
        for (const key of ['cpu', 'memory', 'disk', 'process']) {
            if (key === baseKey) {
                // For the base dataset, use values directly
                result[key] = basePoint.value;
            } else if (data[key] && Array.isArray(data[key].data)) {
                // For other datasets, find matching timestamp or use null
                const matchingPoint = data[key].data.find(p => p.timestamp === basePoint.timestamp);
                result[key] = matchingPoint ? matchingPoint.value : null;
            } else {
                result[key] = null;
            }
        }

        return result;
    });
};
