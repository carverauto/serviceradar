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

// src/components/AuthProvider.tsx
'use client';

import React, { createContext, useContext, useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';

interface AuthContextType {
    token: string | null;
    user: { id: string; email: string; provider: string } | null;
    login: (username: string, password: string) => Promise<void>;
    logout: () => void;
    refreshToken: () => Promise<void>;
    isAuthenticated: boolean;
    isAuthEnabled: boolean;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
    const [token, setToken] = useState<string | null>(null);
    const [user, setUser] = useState<{ id: string; email: string; provider: string } | null>(null);
    const [isAuthenticated, setIsAuthenticated] = useState(false);
    const [isAuthEnabled, setIsAuthEnabled] = useState(false); // Toggle for auth requirement
    const router = useRouter();

    useEffect(() => {
        // Check if auth is enabled via environment variable or config
        const authEnabled = process.env.NEXT_PUBLIC_AUTH_ENABLED === 'true';
        setIsAuthEnabled(authEnabled);

        if (!authEnabled) return;

        const storedToken = localStorage.getItem('accessToken');
        if (storedToken) {
            verifyToken(storedToken)
                .then((verifiedUser) => {
                    setToken(storedToken);
                    setUser(verifiedUser);
                    setIsAuthenticated(true);
                    refreshToken().catch(() => logout()); // Refresh on load
                })
                .catch(() => {
                    localStorage.removeItem('accessToken');
                    localStorage.removeItem('refreshToken');
                    setIsAuthenticated(false);
                    router.push('/login');
                });
        }
    }, []);

    const login = async (username: string, password: string) => {
        try {
            const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/auth/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ username, password }),
            });

            if (!response.ok) throw new Error('Login failed');

            const data = await response.json();
            localStorage.setItem('accessToken', data.accessToken);
            localStorage.setItem('refreshToken', data.refreshToken);
            setToken(data.accessToken);
            const verifiedUser = await verifyToken(data.accessToken);
            setUser(verifiedUser);
            setIsAuthenticated(true);
            router.push('/nodes');
        } catch (error) {
            console.error('Login error:', error);
            throw error;
        }
    };

    const logout = () => {
        localStorage.removeItem('accessToken');
        localStorage.removeItem('refreshToken');
        setToken(null);
        setUser(null);
        setIsAuthenticated(false);
        router.push('/login');
    };

    const refreshToken = async () => {
        const refreshToken = localStorage.getItem('refreshToken');
        if (!refreshToken) {
            logout();
            return;
        }

        const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/auth/refresh`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ refreshToken }),
        });

        if (!response.ok) {
            logout();
            throw new Error('Token refresh failed');
        }

        const data = await response.json();
        localStorage.setItem('accessToken', data.accessToken);
        localStorage.setItem('refreshToken', data.refreshToken);
        setToken(data.accessToken);
        const verifiedUser = await verifyToken(data.accessToken);
        setUser(verifiedUser);
        setIsAuthenticated(true);
    };

    const verifyToken = async (token: string) => {
        const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/api/status`, {
            headers: { Authorization: `Bearer ${token}` },
        });

        if (!response.ok) throw new Error('Token verification failed');

        // Decode token client-side (simplified, assumes JWT structure)
        const base64Url = token.split('.')[1];
        const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
        const jsonPayload = decodeURIComponent(
            atob(base64)
                .split('')
                .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
                .join('')
        );
        return JSON.parse(jsonPayload);
    };

    return (
        <AuthContext.Provider value={{ token, user, login, logout, refreshToken, isAuthenticated, isAuthEnabled }}>
            {children}
        </AuthContext.Provider>
    );
};

export const useAuth = () => {
    const context = useContext(AuthContext);
    if (!context) throw new Error('useAuth must be used within an AuthProvider');
    return context;
};