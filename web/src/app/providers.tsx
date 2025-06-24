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

interface ThemeContextType {
    darkMode: boolean;
    setDarkMode: (dark: boolean) => void;
}

// Create context for theme management
export const ThemeContext = createContext<ThemeContextType>({
    darkMode: false,
    setDarkMode: () => {},
});

export function Providers({ children }: { children: ReactNode }) {
    const [darkMode, setDarkMode] = useState(true); // Default to dark
    const [mounted, setMounted] = useState(false);

    // Effect for initial load of dark mode preference
    useEffect(() => {
        const savedMode = localStorage.getItem('darkMode');
        // Set dark mode based on saved preference, or default to true
        setDarkMode(savedMode !== null ? savedMode === 'true' : true);
        setMounted(true);
    }, []);

    // Effect to save dark mode preference when it changes
    useEffect(() => {
        if (mounted) {
            localStorage.setItem('darkMode', String(darkMode));
            document.documentElement.classList.toggle('dark', darkMode);
        }
    }, [darkMode, mounted]);

    // Prevents a flash of the incorrect theme on page load
    if (!mounted) {
        return null;
    }

    return (
        <ThemeContext.Provider value={{ darkMode, setDarkMode }}>
            {children}
        </ThemeContext.Provider>
    );
}

// Custom hook to use the theme context
export function useTheme() {
    return useContext(ThemeContext);
}