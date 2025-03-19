// src/components/AuthProvider.tsx
'use client';

import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { useAuthFlag } from '@/hooks/useAuthFlag';

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
    const { isAuthEnabled, error: authFlagError } = useAuthFlag();
    const router = useRouter();

    const logout = useCallback(() => {
        localStorage.removeItem('accessToken');
        localStorage.removeItem('refreshToken');
        setToken(null);
        setUser(null);
        setIsAuthenticated(false);
        router.push('/login');
    }, [router]);

    const refreshToken = useCallback(async () => {
        const refreshTokenValue = localStorage.getItem('refreshToken');
        if (!refreshTokenValue) {
            logout();
            return;
        }

        const response = await fetch('/auth/refresh', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ refreshToken: refreshTokenValue }),
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
    }, [logout]);

    const verifyToken = async (token: string) => {
        const response = await fetch('/api/status', {
            headers: { Authorization: `Bearer ${token}` },
        });

        if (!response.ok) throw new Error('Token verification failed');

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

    useEffect(() => {
        if (isAuthEnabled === null) return;

        if (!isAuthEnabled) {
            setIsAuthenticated(true);
            return;
        }

        const storedToken = localStorage.getItem('accessToken');
        if (storedToken) {
            verifyToken(storedToken)
                .then((verifiedUser) => {
                    setToken(storedToken);
                    setUser(verifiedUser);
                    setIsAuthenticated(true);
                    refreshToken().catch(() => logout());
                })
                .catch(() => {
                    localStorage.removeItem('accessToken');
                    localStorage.removeItem('refreshToken');
                    setIsAuthenticated(false);
                    router.push('/login');
                });
        }
    }, [router, refreshToken, logout, isAuthEnabled]);

    const login = async (username: string, password: string) => {
        try {
            const response = await fetch('/auth/login', {
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

    if (authFlagError) {
        return <div>Error loading authentication status: {authFlagError}</div>;
    }

    if (isAuthEnabled === null) {
        return <div>Loading authentication status...</div>;
    }

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