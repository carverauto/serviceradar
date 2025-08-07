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

import { fetchWithRetry } from '@/utils/fetchWithRetry';

interface Poller {
  poller_id: string;
  [key: string]: unknown;
}

interface CachedPollersData {
  data: Poller[];
  timestamp: number;
  promise?: Promise<Poller[]>;
}

class PollersService {
  private cache: CachedPollersData | null = null;
  private readonly CACHE_DURATION = 5000; // 5 seconds cache

  async getPollers(token?: string): Promise<Poller[]> {
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
    const promise = this.fetchPollers(token);
    
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
      
      return data;
    } catch (error) {
      // Clear the promise on error so retry can work
      if (this.cache) {
        this.cache.promise = undefined;
      }
      throw error;
    }
  }
  
  private async fetchPollers(token?: string): Promise<Poller[]> {
    const response = await fetchWithRetry('/api/pollers', {
      headers: {
        'Content-Type': 'application/json',
        ...(token && { Authorization: `Bearer ${token}` }),
      },
      maxRetries: 3,
      retryDelay: 1000,
      timeout: 10000,
    });
    
    if (!response.ok) {
      let errorMessage = 'Failed to fetch pollers';
      try {
        const errorData = await response.json();
        errorMessage = errorData.detail || errorData.error || errorMessage;
      } catch {
        errorMessage = `Failed to fetch pollers (HTTP ${response.status})`;
      }
      throw new Error(errorMessage);
    }
    
    return response.json();
  }
  
  // Method to clear cache and force refresh
  clearCache(): void {
    this.cache = null;
  }
  
  // Method to check if cache is valid
  isCacheValid(): boolean {
    if (!this.cache) return false;
    const now = Date.now();
    return (now - this.cache.timestamp) < this.CACHE_DURATION;
  }
}

// Export singleton instance
export const pollersService = new PollersService();