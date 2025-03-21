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

// src/hooks/useAuthFlag.ts
'use client';

import { useState, useEffect } from 'react';
import { getAuthEnabled } from '@/actions/auth';

export function useAuthFlag() {
    const [isAuthEnabled, setIsAuthEnabled] = useState<boolean | null>(null);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const fetchAuthFlag = async () => {
            try {
                const { authEnabled } = await getAuthEnabled();
                setIsAuthEnabled(authEnabled);
            } catch (err) {
                console.error('Failed to fetch AUTH_ENABLED:', err);
                setError('Failed to load authentication status');
            }
        };

        fetchAuthFlag();
    }, []);

    return { isAuthEnabled, error };
}
