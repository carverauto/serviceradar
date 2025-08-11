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

import { pollersService } from './pollersService';

interface SysmonData {
    pollerId: string;
    cpuData: unknown[];
    memoryData: unknown[];
    diskData: unknown[];
}

interface CachedSysmonData {
    data: SysmonData[];
    timestamp: number;
    promise?: Promise<SysmonData[]>;
}

class SysmonService {
    private cache: CachedSysmonData | null = null;
    private readonly CACHE_DURATION = 30000; // 30 seconds cache
    private subscribers: Set<() => void> = new Set();

    async getSysmonData(token?: string): Promise<SysmonData[]> {
        const now = Date.now();
        
        // Return cached data if still valid
        if (this.cache && (now - this.cache.timestamp) < this.CACHE_DURATION) {
            return this.cache.data;
        }
        
        // If there's already a request in flight, wait for it
        if (this.cache?.promise) {
            return this.cache.promise;
        }
        
        // Start new request
        const promise = this.fetchSysmonData(token);
        
        // Store the promise to prevent duplicate requests
        if (this.cache) {
            this.cache.promise = promise;
        } else {
            this.cache = {
                data: [],
                timestamp: 0,
                promise
            };
        }
        
        try {
            const data = await promise;
            
            // Update cache with successful result
            this.cache = {
                data,
                timestamp: now,
                promise: undefined
            };
            
            // Notify all subscribers
            this.notifySubscribers();
            
            return data;
        } catch (error) {
            // Clear the promise on error so retry can work
            if (this.cache) {
                this.cache.promise = undefined;
            }
            throw error;
        }
    }

    private async fetchSysmonData(token?: string): Promise<SysmonData[]> {
        // Get all pollers using shared service (with caching and retry logic)
        const pollers = await pollersService.getPollers(token);
        
        // For each poller, fetch sysmon data
        const endTime = new Date();
        const startTime = new Date(endTime.getTime() - 5 * 60 * 1000); // Last 5 minutes for more recent data
        
        const sysmonPromises = pollers.map(async (poller: { poller_id: string }) => {
            const headers = {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            };

            try {
                const [cpuResponse, memoryResponse, diskResponse] = await Promise.all([
                    fetch(`/api/pollers/${poller.poller_id}/sysmon/cpu?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, { headers }),
                    fetch(`/api/pollers/${poller.poller_id}/sysmon/memory?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, { headers }),
                    fetch(`/api/pollers/${poller.poller_id}/sysmon/disk?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, { headers })
                ]);
                
                const cpuData = cpuResponse.ok ? await cpuResponse.json() : [];
                const memoryData = memoryResponse.ok ? await memoryResponse.json() : [];
                const diskData = diskResponse.ok ? await diskResponse.json() : [];
                
                return { pollerId: poller.poller_id, cpuData, memoryData, diskData };
            } catch (error) {
                console.warn(`Failed to fetch sysmon data for poller ${poller.poller_id}:`, error);
                return { pollerId: poller.poller_id, cpuData: [], memoryData: [], diskData: [] };
            }
        });
        
        return Promise.all(sysmonPromises);
    }

    // Subscription system for real-time updates
    subscribe(callback: () => void): () => void {
        this.subscribers.add(callback);
        return () => this.subscribers.delete(callback);
    }

    private notifySubscribers(): void {
        this.subscribers.forEach(callback => callback());
    }

    // Method to force refresh
    refresh(token?: string): Promise<SysmonData[]> {
        this.cache = null;
        return this.getSysmonData(token);
    }

    // Check if cache is valid
    isCacheValid(): boolean {
        if (!this.cache) return false;
        const now = Date.now();
        return (now - this.cache.timestamp) < this.CACHE_DURATION;
    }
}

// Export singleton instance
export const sysmonService = new SysmonService();