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

import { useState, useEffect } from 'react';

interface RBACState {
  roles: string[];
  permissions: string[];
  isAuthenticated: boolean;
  loading: boolean;
}

export function useRBAC() {
  const [state, setState] = useState<RBACState>({
    roles: [],
    permissions: [],
    isAuthenticated: false,
    loading: true
  });

  useEffect(() => {
    checkAuth();
  }, []);

  const checkAuth = () => {
    try {
      // Get token from cookie instead of localStorage
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
        
      if (!token) {
        setState({
          roles: [],
          permissions: [],
          isAuthenticated: false,
          loading: false
        });
        return;
      }

      const payload = JSON.parse(atob(token.split('.')[1]));
      const currentTime = Date.now() / 1000;
      
      if (payload.exp && payload.exp > currentTime) {
        setState({
          roles: payload.roles || [],
          permissions: payload.permissions || [],
          isAuthenticated: true,
          loading: false
        });
      } else {
        // Token expired
        localStorage.removeItem('token');
        setState({
          roles: [],
          permissions: [],
          isAuthenticated: false,
          loading: false
        });
      }
    } catch (error) {
      console.error('Auth check failed:', error);
      setState({
        roles: [],
        permissions: [],
        isAuthenticated: false,
        loading: false
      });
    }
  };

  const hasRole = (role: string): boolean => {
    return state.roles.includes(role);
  };

  const hasAnyRole = (roles: string[]): boolean => {
    return roles.some(role => state.roles.includes(role));
  };

  const hasAllRoles = (roles: string[]): boolean => {
    return roles.every(role => state.roles.includes(role));
  };

  const hasPermission = (permission: string): boolean => {
    // Check for wildcard permissions
    if (state.permissions.includes('*')) return true;
    
    // Check for exact permission
    if (state.permissions.includes(permission)) return true;
    
    // Check for wildcard in permission category (e.g., "config:*" matches "config:read")
    const [category] = permission.split(':');
    if (state.permissions.includes(`${category}:*`)) return true;
    
    return false;
  };

  const hasAnyPermission = (permissions: string[]): boolean => {
    return permissions.some(perm => hasPermission(perm));
  };

  const hasAllPermissions = (permissions: string[]): boolean => {
    return permissions.every(perm => hasPermission(perm));
  };

  return {
    ...state,
    hasRole,
    hasAnyRole,
    hasAllRoles,
    hasPermission,
    hasAnyPermission,
    hasAllPermissions,
    refresh: checkAuth
  };
}