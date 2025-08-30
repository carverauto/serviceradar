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

interface RoleGuardProps {
  children: React.ReactNode;
  requiredRoles?: string[];
  requiredPermissions?: string[];
  fallback?: React.ReactNode;
}

export default function RoleGuard({ 
  children, 
  requiredRoles = [], 
  requiredPermissions = [],
  fallback 
}: RoleGuardProps) {
  const [hasAccess, setHasAccess] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(true);
  const [userRoles, setUserRoles] = useState<string[]>([]);

  useEffect(() => {
    checkAccess();
    // Only run once on mount and when required roles/permissions actually change
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(requiredRoles), JSON.stringify(requiredPermissions)]);

  const checkAccess = async () => {
    try {
      // Get token from cookie instead of localStorage
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      
      if (!token) {
        setHasAccess(false);
        setLoading(false);
        return;
      }

      // Parse JWT to get roles
      try {
        const payload = JSON.parse(atob(token.split('.')[1]));
        const currentTime = Date.now() / 1000;
        
        if (payload.exp && payload.exp > currentTime) {
          const roles = payload.roles || [];
          setUserRoles(roles);
          
          // Check if user has any of the required roles
          let roleAccess = true;
          if (requiredRoles.length > 0) {
            roleAccess = requiredRoles.some(role => roles.includes(role));
          }
          
          // For now, we'll only check roles. Permissions would require 
          // an API call to get the full permission set
          setHasAccess(roleAccess);
          
          // Only log once, not repeatedly
          if (!roleAccess && !hasAccess) {
            console.log('Access denied. User roles:', roles, 'Required:', requiredRoles);
          }
        } else {
          // Token is expired
          setHasAccess(false);
          localStorage.removeItem('token');
        }
      } catch (parseError) {
        // Invalid token format
        console.error('Invalid token format:', parseError);
        setHasAccess(false);
        localStorage.removeItem('token');
      }
    } catch (error) {
      console.error('Access check failed:', error);
      setHasAccess(false);
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

  if (!hasAccess) {
    if (fallback) {
      return <>{fallback}</>;
    }
    
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-center">
          <AlertCircle className="h-12 w-12 mx-auto mb-4 text-red-500" />
          <h2 className="text-xl font-semibold mb-2">Access Denied</h2>
          <p className="text-gray-600 dark:text-gray-400 mb-2">
            You don't have permission to access this section.
          </p>
          {requiredRoles.length > 0 && (
            <p className="text-sm text-gray-500 dark:text-gray-500">
              Required roles: {requiredRoles.join(', ')}
            </p>
          )}
          {userRoles.length > 0 && (
            <p className="text-sm text-gray-500 dark:text-gray-500 mt-1">
              Your roles: {userRoles.join(', ')}
            </p>
          )}
        </div>
      </div>
    );
  }

  return <>{children}</>;
}