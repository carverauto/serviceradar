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

import React, { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { rperfService } from '@/services/rperfService';
import { useAuth } from '@/components/AuthProvider';
import { RperfMetric } from '@/types/rperf';

interface RperfData {
    pollerId: string;
    rperfMetrics: RperfMetric[];
}

interface RperfContextType {
    data: RperfData[] | null;
    loading: boolean;
    error: string | null;
    refresh: () => Promise<void>;
}

const RperfContext = createContext<RperfContextType | null>(null);

export const RperfProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
    const { token } = useAuth();
    const [data, setData] = useState<RperfData[] | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const fetchData = useCallback(async () => {
        try {
            setError(null);
            const rperfData = await rperfService.getRperfData(token ?? undefined);
            setData(rperfData);
        } catch (err) {
            console.error('Failed to fetch rperf data:', err);
            setError(err instanceof Error ? err.message : 'Failed to fetch rperf data');
        } finally {
            setLoading(false);
        }
    }, [token]);

    const refresh = useCallback(async () => {
        setLoading(true);
        await fetchData();
    }, [fetchData]);

    useEffect(() => {
        fetchData();
        
        // Set up refresh interval - every 60 seconds
        const interval = setInterval(fetchData, 60000);
        
        // Subscribe to service updates
        const unsubscribe = rperfService.subscribe(() => {
            fetchData();
        });

        return () => {
            clearInterval(interval);
            unsubscribe();
        };
    }, [fetchData]);

    return (
        <RperfContext.Provider value={{ data, loading, error, refresh }}>
            {children}
        </RperfContext.Provider>
    );
};

export const useRperf = (): RperfContextType => {
    const context = useContext(RperfContext);
    if (!context) {
        throw new Error('useRperf must be used within a RperfProvider');
    }
    return context;
};