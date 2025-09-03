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

import React, { useState, useEffect } from 'react';
import { Shield, AlertCircle } from 'lucide-react';

interface AdminGuardProps {
  children: React.ReactNode;
}

export default function AdminGuard({ children }: AdminGuardProps) {
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    checkAdminAccess();
  }, []);

  const checkAdminAccess = async () => {
    try {
      // Get token from cookie instead of localStorage
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
        
      if (!token) {
        setIsAdmin(false);
        setLoading(false);
        return;
      }

      // Simple token validation - check if it's a valid JWT format and not expired
      try {
        const payload = JSON.parse(atob(token.split('.')[1]));
        const currentTime = Date.now() / 1000;
        
        if (payload.exp && payload.exp > currentTime) {
          // Token is valid and not expired, check if user has admin role
          const hasAdminRole = payload.roles && payload.roles.includes('admin');
          setIsAdmin(hasAdminRole);
          
          if (!hasAdminRole) {
            console.log('User does not have admin role:', payload.roles);
          }
        } else {
          // Token is expired - clear cookies
          setIsAdmin(false);
          const cookieFlags = '; path=/; SameSite=Strict';
          document.cookie = `accessToken=${cookieFlags}; Max-Age=0`;
          document.cookie = `refreshToken=${cookieFlags}; Max-Age=0`;
        }
      } catch {
        // Invalid token format - clear cookies
        setIsAdmin(false);
        const cookieFlags = '; path=/; SameSite=Strict';
        document.cookie = `accessToken=${cookieFlags}; Max-Age=0`;
        document.cookie = `refreshToken=${cookieFlags}; Max-Age=0`;
      }
    } catch (error) {
      console.error('Admin access check failed:', error);
      setIsAdmin(false);
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="flex items-center space-x-2">
          <Shield className="h-5 w-5 animate-pulse" />
          <span>Checking permissions...</span>
        </div>
      </div>
    );
  }

  if (!isAdmin) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-center">
          <AlertCircle className="h-12 w-12 mx-auto mb-4 text-red-500" />
          <h2 className="text-xl font-semibold mb-2">Access Denied</h2>
          <p className="text-gray-600 dark:text-gray-400">
            You need administrator privileges to access this section.
          </p>
        </div>
      </div>
    );
  }

  return <>{children}</>;
}