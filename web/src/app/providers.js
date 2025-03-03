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

import { createContext, useState, useEffect, useContext } from 'react';
import Navbar from '../components/Navbar';

// Create context for theme management
export const ThemeContext = createContext({
    darkMode: false,
    setDarkMode: () => {},
});

export function Providers({ children }) {
    const [darkMode, setDarkMode] = useState(false);
    const [mounted, setMounted] = useState(false);

    // Effect for initial load of dark mode preference
    useEffect(() => {
        const savedMode = localStorage.getItem('darkMode');
        setDarkMode(savedMode === 'true');
        setMounted(true);
    }, []);

    // Effect to save dark mode preference when it changes
    useEffect(() => {
        if (mounted) {
            localStorage.setItem('darkMode', darkMode);
            document.documentElement.classList.toggle('dark', darkMode);
        }
    }, [darkMode, mounted]);

    // Prevent flash of incorrect theme
    if (!mounted) {
        return null;
    }

    return (
        <ThemeContext.Provider value={{ darkMode, setDarkMode }}>
            <div className={darkMode ? 'dark' : ''}>
                <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
                    <Navbar />
                    <main className="container mx-auto px-4 py-8">
                        {children}
                    </main>
                </div>
            </div>
        </ThemeContext.Provider>
    );
}

// Custom hook to use the theme context
export function useTheme() {
    return useContext(ThemeContext);
}