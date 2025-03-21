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

import React, {createContext, useContext, useState, useEffect, useCallback} from 'react';
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
  const [isAuthEnabled, setIsAuthEnabled] = useState(true);
  const router = useRouter();

  useEffect(() => {
    fetch("/api/auth/status")
        .then((res) => res.json())
        .then((data) => setIsAuthEnabled(data.authEnabled))
        .catch((err) => console.error("Failed to fetch auth status:", err));

    const storedToken = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];

    if (storedToken && isAuthEnabled) {
      verifyToken(storedToken)
          .then((verifiedUser) => {
            setToken(storedToken);
            setUser(verifiedUser);
            setIsAuthenticated(true);
            router.push("/");
          })
          .catch(() => {
            document.cookie = "accessToken=; Max-Age=0; path=/";
            document.cookie = "refreshToken=; Max-Age=0; path=/";
            router.push("/login");
          });
    }
  }, [router, isAuthEnabled]);

  const login = async (username: string, password: string) => {
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
      const refreshToken = data.refresh_token || data.refreshToken;
      if (!accessToken || !refreshToken) {
        throw new Error("Invalid token format received from server");
      }

      document.cookie = `accessToken=${accessToken}; path=/; max-age=${24 * 60 * 60}; Secure; SameSite=Strict`;
      document.cookie = `refreshToken=${refreshToken}; path=/; max-age=${7 * 24 * 60 * 60}; Secure; SameSite=Strict`;
      setToken(accessToken);

      const verifiedUser = await verifyToken(accessToken);
      setUser(verifiedUser);
      setIsAuthenticated(true);
      // Let LoginPage handle the redirect
    } catch (error) {
      console.error("Login error:", error);
      throw error;
    }
  };

  const logout = () => {
    document.cookie = "accessToken=; Max-Age=0; path=/";
    document.cookie = "refreshToken=; Max-Age=0; path=/";
    setToken(null);
    setUser(null);
    setIsAuthenticated(false);
    router.push("/login");
  };

  const refreshToken = useCallback(async () => {
    const refreshTokenValue = document.cookie
        .split("; ")
        .find((row) => row.startsWith("refreshToken="))
        ?.split("=")[1];

    if (!refreshTokenValue) {
      logout();
      return;
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


      document.cookie = `accessToken=${accessToken}; path=/; max-age=${24 * 60 * 60}; Secure; SameSite=Strict`;
      document.cookie = `refreshToken=${newRefreshToken}; path=/; max-age=${7 * 24 * 60 * 60}; Secure; SameSite=Strict`;

      setToken(accessToken);
      const verifiedUser = await verifyToken(accessToken);
      setUser(verifiedUser);
      setIsAuthenticated(true);
    } catch (error) {
      console.error("Error refreshing token:", error);
      logout();
    }
  }, [logout]);

  const verifyToken = async (token: string) => {
    try {
      const response = await fetch("/api/auth/verify", {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!response.ok) throw new Error("Token verification failed");
      const base64Url = token.split(".")[1];
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

  return (
      <AuthContext.Provider
          value={{ token, user, login, logout, refreshToken, isAuthenticated, isAuthEnabled }}
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