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
import { sysmonService, SysmonAgentSummary } from '@/services/sysmonService';
import { useAuth } from '@/components/AuthProvider';

interface SysmonContextType {
    data: SysmonAgentSummary[] | null;
    loading: boolean;
    error: string | null;
    refresh: () => Promise<void>;
}

const SysmonContext = createContext<SysmonContextType | null>(null);

export const SysmonProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
    const { token } = useAuth();
    const [data, setData] = useState<SysmonAgentSummary[] | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const fetchData = useCallback(async () => {
        try {
            setError(null);
            const sysmonData = await sysmonService.getSysmonData(token ?? undefined);
            setData(sysmonData);
        } catch (err) {
            console.error('Failed to fetch sysmon data:', err);
            setError(err instanceof Error ? err.message : 'Failed to fetch sysmon data');
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
        const unsubscribe = sysmonService.subscribe(() => {
            fetchData();
        });

        return () => {
            clearInterval(interval);
            unsubscribe();
        };
    }, [fetchData]);

    return (
        <SysmonContext.Provider value={{ data, loading, error, refresh }}>
            {children}
        </SysmonContext.Provider>
    );
};

export const useSysmon = (): SysmonContextType => {
    const context = useContext(SysmonContext);
    if (!context) {
        throw new Error('useSysmon must be used within a SysmonProvider');
    }
    return context;
};
