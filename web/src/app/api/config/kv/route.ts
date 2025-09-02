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

import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";
import { requirePermission } from "@/middleware/rbac";

// List all KV stores and their services
export async function GET(req: NextRequest) {
  // Simple auth check - verify token is present
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return NextResponse.json(
      { error: 'Unauthorized: Authentication required' },
      { status: 401 }
    );
  }

  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    // Get configured KV endpoints from core
    const epsResponse = await fetch(`${apiUrl}/api/kv/endpoints`, {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        "Authorization": req.headers.get("Authorization") || "",
      },
    });

    let eps = [] as any[];
    if (epsResponse.ok) {
      eps = await epsResponse.json();
    }
    // Transform to UI shape, include basic core/sync service placeholders under each KV
    const stores = (eps.length ? eps : [{ id: 'local', name: 'Local KV', type: 'hub' }]).map((ep: any) => ({
      id: ep.id,
      name: ep.name || ep.id,
      type: ep.type || 'hub',
      services: [
        { id: `core-${ep.id}`, name: 'Core Configuration', type: 'core', kvStore: ep.id, status: 'active' },
        { id: `sync-${ep.id}`, name: 'Sync Configuration', type: 'sync', kvStore: ep.id, status: 'active' },
        { id: `poller-${ep.id}`, name: 'Poller Configuration', type: 'poller', kvStore: ep.id, status: 'active' },
        { id: `agent-${ep.id}`, name: 'Agent Configuration', type: 'agent', kvStore: ep.id, status: 'active' },
        { id: `otel-${ep.id}`, name: 'OTEL Collector', type: 'otel', kvStore: ep.id, status: 'active' },
        { id: `flowgger-${ep.id}`, name: 'Flowgger', type: 'flowgger', kvStore: ep.id, status: 'active' },
      ]
    }));
    return NextResponse.json(stores);
  } catch (error) {
    console.error("KV stores fetch error:", error);
    
    // Return default structure on error
    return NextResponse.json([
      {
        id: "local",
        name: "Local KV Store", 
        type: "hub",
        services: [
          {
            id: "core-service",
            name: "Core API Service",
            type: "core",
            kvStore: "local",
            status: "inactive"
          },
          {
            id: "sync-service",
            name: "Sync Service", 
            type: "sync",
            kvStore: "local",
            status: "inactive"
          }
        ]
      }
    ]);
  }
}
