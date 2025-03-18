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
