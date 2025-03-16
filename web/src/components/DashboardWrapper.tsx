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

// src/components/DashboardWrapper.tsx (client-side)
'use client';

import { useEffect, useState } from 'react';
import { useAuth } from './AuthProvider';
import Dashboard from './Dashboard';
import { fetchWithCache } from '@/lib/client-api';
import { SystemStatus } from '@/types';

export default function DashboardWrapper({ initialData }: { initialData: SystemStatus | null }) {
    const { token, isAuthEnabled } = useAuth();
    const [data, setData] = useState<SystemStatus | null>(initialData);

    useEffect(() => {
        if (isAuthEnabled && token) {
            // Refetch with token if auth is enabled
            fetchWithCache('/status', { headers: { Authorization: `Bearer ${token}` } })
                .then(updatedData => {
                    if (updatedData) setData(updatedData);
                })
                .catch(err => console.error('Error refetching with token:', err));
        }
    }, [token, isAuthEnabled]);

    return <Dashboard initialData={data} />;
}