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
"use client";

import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
} from "react";
import { useRouter } from "next/navigation";

interface AuthContextType {
  token: string | null;
  user: { id: string; email: string; provider: string } | null;
  login: (username: string, password: string) => Promise<void>;
  logout: () => void;
  refreshToken: () => Promise<void>;
  isAuthenticated: boolean;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({
  children,
}) => {
  const [token, setToken] = useState<string | null>(null);
  const [user, setUser] = useState<{
    id: string;
    email: string;
    provider: string;
  } | null>(null);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const router = useRouter();

  const logout = useCallback(() => {
    document.cookie = "accessToken=; Max-Age=0; path=/";
    document.cookie = "refreshToken=; Max-Age=0; path=/";
    setToken(null);
    setUser(null);
    setIsAuthenticated(false);
    router.push("/login");
  }, [router]);

  const refreshToken = useCallback(async () => {
    const refreshTokenValue = document.cookie
      .split("; ")
      .find((row) => row.startsWith("refreshToken="))
      ?.split("=")[1];

    if (!refreshTokenValue) {
      logout();
      return;
    }

    const response = await fetch(
      `${process.env.NEXT_PUBLIC_API_URL}/auth/refresh`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refreshToken: refreshTokenValue }),
      },
    );

    if (!response.ok) {
      logout();
      throw new Error("Token refresh failed");
    }

    const data = await response.json();
    document.cookie = `accessToken=${data.accessToken}; path=/; max-age=${24 * 60 * 60}`;
    document.cookie = `refreshToken=${data.refreshToken}; path=/; max-age=${7 * 24 * 60 * 60}`;
    setToken(data.accessToken);
    const verifiedUser = await verifyToken(data.accessToken);
    setUser(verifiedUser);
    setIsAuthenticated(true);
  }, [logout]);

  const verifyToken = async (token: string) => {
    const response = await fetch(
      `${process.env.NEXT_PUBLIC_API_URL}/api/status`,
      {
        headers: { Authorization: `Bearer ${token}` },
      },
    );

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
  };

  useEffect(() => {
    const storedToken = document.cookie
      .split("; ")
      .find((row) => row.startsWith("accessToken="))
      ?.split("=")[1];

    if (storedToken) {
      verifyToken(storedToken)
        .then((verifiedUser) => {
          setToken(storedToken);
          setUser(verifiedUser);
          setIsAuthenticated(true);
          refreshToken().catch(() => logout());
        })
        .catch(() => {
          document.cookie = "accessToken=; Max-Age=0; path=/";
          document.cookie = "refreshToken=; Max-Age=0; path=/";
          setIsAuthenticated(false);
          router.push("/login");
        });
    }
  }, [router, refreshToken, logout]);

  const login = async (username: string, password: string) => {
    try {
      const response = await fetch(`/auth/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });

      if (!response.ok) throw new Error("Login failed");

      const data = await response.json();
      document.cookie = `accessToken=${data.accessToken}; path=/; max-age=${24 * 60 * 60}`;
      document.cookie = `refreshToken=${data.refreshToken}; path=/; max-age=${7 * 24 * 60 * 60}`;
      setToken(data.accessToken);
      const verifiedUser = await verifyToken(data.accessToken);
      setUser(verifiedUser);
      setIsAuthenticated(true);
      router.push("/nodes");
    } catch (error) {
      console.error("Login error:", error);
      throw error;
    }
  };

  return (
    <AuthContext.Provider
      value={{ token, user, login, logout, refreshToken, isAuthenticated }}
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
