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

import React, { createContext, useContext, useState, useEffect, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';

interface AuthContextType {
  token: string | null;
  user: { id: string; email: string; provider: string } | null;
  login: (username: string, password: string) => Promise<boolean>;
  logout: () => void;
  refreshToken: () => Promise<boolean>;
  isAuthenticated: boolean;
  isAuthEnabled: boolean;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [token, setToken] = useState<string | null>(null);
  const [user, setUser] = useState<{ id: string; email: string; provider: string } | null>(null);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isAuthEnabled, setIsAuthEnabled] = useState(true);
  const [isInitializing, setIsInitializing] = useState(true);
  const refreshTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const router = useRouter();

  // Helper function to get cookie flags based on environment
  const getCookieFlags = () => {
    const isHttps = typeof window !== 'undefined' && window.location.protocol === 'https:';
    const secureFlag = isHttps ? '; Secure' : '';
    return `; path=/; SameSite=Strict${secureFlag}`;
  };

  // Extract expiration from JWT
  const getTokenExpiration = (tokenStr: string): number => {
    try {
      const base64Url = tokenStr.split('.')[1];
      const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
      const payload = JSON.parse(atob(base64));
      return payload.exp || 0;
    } catch (error) {
      console.error('Failed to parse token expiration', error);
      return 0;
    }
  };

  // Verify token function
  const verifyToken = async (tokenStr: string) => {
    try {
      const response = await fetch("/api/auth/verify", {
        headers: { Authorization: `Bearer ${tokenStr}` },
      });

      if (!response.ok) throw new Error("Token verification failed");

      const base64Url = tokenStr.split(".")[1];
      const base64 = base64Url.replace(/-/g, "+").replace(/_/g, "/");
      const jsonPayload = decodeURIComponent(
          atob(base64)
              .split("")
              .map((c) => "%" + ("00" + c.charCodeAt(0).toString(16)).slice(-2))
              .join(""),
      );

      return JSON.parse(jsonPayload);
    } catch (error) {
      console.error("Token verification error:", error);
      throw error;
    }
  };

  // Cleanup function for refresh timers
  const clearRefreshTimeout = () => {
    if (refreshTimeoutRef.current) {
      clearTimeout(refreshTimeoutRef.current);
      refreshTimeoutRef.current = null;
    }
  };

  const logout = useCallback(() => {
    clearRefreshTimeout();
    const cookieFlags = getCookieFlags();
    document.cookie = `accessToken=${cookieFlags}; Max-Age=0`;
    document.cookie = `refreshToken=${cookieFlags}; Max-Age=0`;
    setToken(null);
    setUser(null);
    setIsAuthenticated(false);
    router.push("/login");
  }, [router]);

  // To break the circular dependency, we declare refreshToken using useState
  // This technique lets us define functions that reference each other
  const [refreshToken] = useState(() => async (): Promise<boolean> => {
    const refreshTokenValue = document.cookie
        .split("; ")
        .find((row) => row.startsWith("refreshToken="))
        ?.split("=")[1];

    if (!refreshTokenValue) {
      logout();
      return false;
    }

    try {
      const response = await fetch("/api/auth/refresh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: refreshTokenValue }),
      });

      if (!response.ok) {
        throw new Error("Token refresh failed");
      }

      const data = await response.json();
      const accessToken = data.access_token || data.accessToken;
      const newRefreshToken = data.refresh_token || data.refreshToken;

      // Set cookies with secure flags
      const cookieFlags = getCookieFlags();
      document.cookie = `accessToken=${accessToken}${cookieFlags}; max-age=${24 * 60 * 60}`;
      document.cookie = `refreshToken=${newRefreshToken}${cookieFlags}; max-age=${7 * 24 * 60 * 60}`;

      setToken(accessToken);

      const verifiedUser = await verifyToken(accessToken);
      setUser(verifiedUser);
      setIsAuthenticated(true);

      // Set up new refresh timer
      const tokenExp = getTokenExpiration(accessToken);
      if (tokenExp) {
        scheduleTokenRefresh(tokenExp);
      }

      return true;
    } catch (error) {
      console.error("Error refreshing token:", error);
      logout();
      return false;
    }
  });

  // Schedule token refresh
  const scheduleTokenRefresh = useCallback((tokenExp: number) => {
    clearRefreshTimeout();

    // Calculate when to refresh - 1 minute before expiry
    const currentTime = Math.floor(Date.now() / 1000);
    const timeUntilRefresh = Math.max(0, tokenExp - currentTime - 60) * 1000;

    refreshTimeoutRef.current = setTimeout(() => {
      refreshToken();
    }, timeUntilRefresh);
  }, [refreshToken]);

  // Login function
  const login = async (username: string, password: string): Promise<boolean> => {
    try {
      const response = await fetch("/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Login failed: ${response.status} - ${errorText}`);
      }

      const data = await response.json();

      const accessToken = data.access_token || data.accessToken;
      const refreshTokenValue = data.refresh_token || data.refreshToken;

      if (!accessToken || !refreshTokenValue) {
        throw new Error("Invalid token format received from server");
      }

      // Set cookies with secure flags
      const cookieFlags = getCookieFlags();
      document.cookie = `accessToken=${accessToken}${cookieFlags}; max-age=${24 * 60 * 60}`;
      document.cookie = `refreshToken=${refreshTokenValue}${cookieFlags}; max-age=${7 * 24 * 60 * 60}`;

      setToken(accessToken);

      const verifiedUser = await verifyToken(accessToken);
      setUser(verifiedUser);
      setIsAuthenticated(true);

      // Set up refresh timer
      const tokenExp = getTokenExpiration(accessToken);
      if (tokenExp) {
        scheduleTokenRefresh(tokenExp);
      }

      return true;
    } catch (error) {
      console.error("Login error:", error);
      throw error;
    }
  };

  // Initialize auth on page load
  useEffect(() => {
    const initializeAuth = async () => {
      try {
        // Check if auth is enabled
        const res = await fetch("/api/auth/status");
        const data = await res.json();
        setIsAuthEnabled(data.authEnabled);

        if (!data.authEnabled) {
          setIsInitializing(false);
          return;
        }

        // Check for stored token
        const storedToken = document.cookie
            .split("; ")
            .find((row) => row.startsWith("accessToken="))
            ?.split("=")[1];

        if (storedToken) {
          try {
            const verifiedUser = await verifyToken(storedToken);
            setToken(storedToken);
            setUser(verifiedUser);
            setIsAuthenticated(true);

            // Set up automatic refresh
            const tokenExp = getTokenExpiration(storedToken);
            if (tokenExp) {
              scheduleTokenRefresh(tokenExp);
            }
          } catch (error) {
            console.error("Token verification failed:", error);
            // Try to refresh the token
            try {
              await refreshToken();
            } catch (refreshError) {
              console.error("Token refresh failed:", refreshError);
              // Clear invalid credentials and redirect to login
              const cookieFlags = getCookieFlags();
              document.cookie = `accessToken=${cookieFlags}; Max-Age=0`;
              document.cookie = `refreshToken=${cookieFlags}; Max-Age=0`;
              router.push("/login");
            }
          }
        }
      } catch (error) {
        console.error("Auth initialization error:", error);
      } finally {
        setIsInitializing(false);
      }
    };

    initializeAuth();

    return () => {
      clearRefreshTimeout();
    };
  }, [router, scheduleTokenRefresh, refreshToken]);

  // Show loading state during initialization
  if (isInitializing) {
    return <div className="flex items-center justify-center min-h-screen">Loading...</div>;
  }

  return (
      <AuthContext.Provider
          value={{
            token,
            user,
            login,
            logout,
            refreshToken,
            isAuthenticated,
            isAuthEnabled
          }}
      >
        {children}
      </AuthContext.Provider>
  );
};

export const useAuth = () => {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used within an AuthProvider");
  return context;
};