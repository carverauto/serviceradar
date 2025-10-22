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

import { createContext, useState, useEffect, useContext, ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

interface ThemeContextType {
    darkMode: boolean;
    setDarkMode: (dark: boolean) => void;
}

// Create context for theme management
export const ThemeContext = createContext<ThemeContextType>({
    darkMode: false,
    setDarkMode: () => {},
});

// Create a client instance for React Query
const queryClient = new QueryClient({
    defaultOptions: {
        queries: {
            staleTime: 30000, // 30 seconds
            gcTime: 300000, // 5 minutes (was cacheTime in v4)
            refetchOnWindowFocus: false,
            retry: 1,
        },
    },
});

export function Providers({ children }: { children: ReactNode }) {
    const isBrowser = typeof window !== 'undefined';
    const [darkMode, setDarkMode] = useState<boolean>(() => {
        if (!isBrowser) {
            return true;
        }
        const savedMode = window.localStorage.getItem('darkMode');
        const preferred = savedMode !== null ? savedMode === 'true' : true;
        if (typeof document !== 'undefined') {
            document.documentElement.classList.toggle('dark', preferred);
        }
        return preferred;
    });

    useEffect(() => {
        if (!isBrowser) {
            return;
        }
        window.localStorage.setItem('darkMode', String(darkMode));
        document.documentElement.classList.toggle('dark', darkMode);
    }, [darkMode, isBrowser]);

    if (!isBrowser) {
        return null;
    }

    return (
        <QueryClientProvider client={queryClient}>
            <ThemeContext.Provider value={{ darkMode, setDarkMode }}>
                {children}
            </ThemeContext.Provider>
        </QueryClientProvider>
    );
}

// Custom hook to use the theme context
export function useTheme() {
    return useContext(ThemeContext);
}
