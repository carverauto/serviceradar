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

import { NextRequest, NextResponse } from 'next/server';
import { getInternalApiUrl, getApiKey } from '@/lib/config';

interface UserInfo {
  username: string;
  roles: string[];
  permissions: string[];
}

export async function checkAdminAccess(req: NextRequest): Promise<UserInfo | null> {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return null;
  }

  const token = authHeader.substring(7);
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    // Use the existing auth/verify endpoint
    const response = await fetch(`${apiUrl}/auth/verify`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
        'Authorization': authHeader,
      },
      body: JSON.stringify({ token }),
    });

    if (!response.ok) {
      return null;
    }

    const data = await response.json();
    
    // For now, all authenticated users are admins since you only have one user
    // This is simpler and matches your current setup
    return {
      username: data.email || data.username || 'admin',
      roles: ['admin'],
      permissions: ['config:read', 'config:write', 'config:delete']
    };
  } catch (error) {
    console.error('RBAC check error:', error);
    return null;
  }
}

export function requireAdmin() {
  return async (req: NextRequest) => {
    const userInfo = await checkAdminAccess(req);
    
    if (!userInfo || !userInfo.roles.includes('admin')) {
      return NextResponse.json(
        { error: 'Forbidden: Admin access required' },
        { status: 403 }
      );
    }

    return null; // Allow request to proceed
  };
}

export function requirePermission(permission: string) {
  return async (req: NextRequest) => {
    const userInfo = await checkAdminAccess(req);
    
    if (!userInfo || !userInfo.permissions.includes(permission)) {
      return NextResponse.json(
        { error: `Forbidden: ${permission} permission required` },
        { status: 403 }
      );
    }

    return null; // Allow request to proceed
  };
}