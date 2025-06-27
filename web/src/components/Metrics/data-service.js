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

import { fetchFromAPI } from '@/lib/api';

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

// Fetch system data from API
export const fetchSystemData = async (pollerId, timeRange = '1h') => {
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

        // Improved error handling with individual try/catch blocks for each API call
        const cpuPromise = fetchWithTimeout(`/pollers/${pollerId}/sysmon/cpu${queryParams}`, 5000)
            .catch(err => {
                console.warn(`CPU metrics failed: ${err.message}`);
                return null;
            });

        const diskPromise = fetchWithTimeout(`/pollers/${pollerId}/sysmon/disk${queryParams}`, 5000)
            .catch(err => {
                console.warn(`Disk metrics failed: ${err.message}`);
                return null;
            });

        const memoryPromise = fetchWithTimeout(`/pollers/${pollerId}/sysmon/memory${queryParams}`, 5000)
            .catch(err => {
                console.warn(`Memory metrics failed: ${err.message}`);
                return null;
            });

        const results = await Promise.all([cpuPromise, diskPromise, memoryPromise]);

        console.log('API request results:', results.map(r => r ?
            { status: 'success', dataSize: JSON.stringify(r).length } :
            { status: 'failed' }));

        const cpuResponse = results[0];
        const diskResponse = results[1];
        const memoryResponse = results[2];

        // Process CPU metrics with proper null checks
        let cpuDataPoints = [];
        let currentCpuValue = 0;
        let cpuCores = [];

        if (cpuResponse) {
            try {
                if (Array.isArray(cpuResponse)) {
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
                    cpuCores = safeGet(cpuResponse[0], 'cpus', []);
                    currentCpuValue = cpuCores.length > 0
                        ? cpuCores.reduce((sum, core) => sum + safeGet(core, 'usage_percent', 0), 0) / cpuCores.length
                        : 0;
                } else {
                    cpuCores = safeGet(cpuResponse, 'cpus', []);
                    currentCpuValue = cpuCores.length > 0
                        ? cpuCores.reduce((sum, core) => sum + safeGet(core, 'usage_percent', 0), 0) / cpuCores.length
                        : 0;
                    cpuDataPoints = [{
                        timestamp: safeGet(cpuResponse, 'timestamp', new Date().toISOString()),
                        formattedTime: new Date(safeGet(cpuResponse, 'timestamp', new Date())).toLocaleTimeString(),
                        value: parseFloat(currentCpuValue.toFixed(1)),
                    }];
                }
            } catch (err) {
                console.error('Error processing CPU data:', err);
            }
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

        // Build result with default values if data is missing
        const cpu = {
            current: parseFloat(currentCpuValue.toFixed(1)),
            warning: 70,
            critical: 90,
            data: cpuDataPoints.length > 0 ? cpuDataPoints : generateDefaultDataPoints(),
            unit: '%',
            min: 0,
            max: 100,
            cores: cpuCores.map(core => ({
                name: `Core ${safeGet(core, 'core_id', 'Unknown')}`,
                value: safeGet(core, 'usage_percent', 0),
            })),
            change: 0,
        };

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

        const result = { cpu, memory, disk };
        console.log('Processed data points:', {
            cpuPoints: cpuDataPoints.length,
            memoryPoints: memoryDataPoints.length,
            diskPoints: diskDataPoints.length,
        });

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
            const apiPromise = fetchFromAPI(url);

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

// Run cache cleanup every 30 seconds
setInterval(cleanupCache, 30000);

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

    for (const key of ['cpu', 'memory', 'disk']) {
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

        // Add data points for each metric type (cpu, memory, disk)
        for (const key of ['cpu', 'memory', 'disk']) {
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