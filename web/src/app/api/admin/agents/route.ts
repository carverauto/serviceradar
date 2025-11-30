/*
 * Copyright 2025 Carver Automation.
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
import { cookies } from 'next/headers';

import { getApiKey, getInternalApiUrl } from '@/lib/config';
import { resolveAuthHeader } from '@/app/api/admin/edge-packages/helpers';

export async function GET(request: NextRequest) {
  try {
    const cookieStore = await cookies();
    const cookieToken = cookieStore.get('accessToken')?.value;
    const authHeader = resolveAuthHeader(request) || (cookieToken ? `Bearer ${cookieToken}` : '');

    if (!authHeader) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const response = await fetch(`${getInternalApiUrl()}/api/admin/agents`, {
      headers: {
        Authorization: authHeader,
        'Content-Type': 'application/json',
        'X-API-Key': getApiKey(),
      },
      cache: 'no-store',
    });

    if (!response.ok) {
      const errorText = await response.text();
      return NextResponse.json({ error: errorText || 'Failed to fetch agents' }, { status: response.status });
    }

    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error('Error fetching agents:', error);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
