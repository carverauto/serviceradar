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
    // Get pollers from the database to understand service distribution
    const pollersResponse = await fetch(`${apiUrl}/pollers`, {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        "Authorization": req.headers.get("Authorization") || "",
      },
    });

    let pollers = [];
    if (pollersResponse.ok) {
      pollers = await pollersResponse.json();
    }

    // Create a default KV store structure
    // In the future, this should query actual KV stores via NATS
    const kvStores = [
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
            status: "active"
          },
          {
            id: "sync-service", 
            name: "Sync Service",
            type: "sync",
            kvStore: "local",
            status: "active"
          },
          // Add services based on active pollers
          ...pollers.map((poller: any) => [
            {
              id: `poller-${poller.poller_id}`,
              name: `Poller: ${poller.poller_id}`,
              type: "poller",
              kvStore: poller.kv_store_id || "local",
              status: poller.is_healthy ? "active" : "inactive"
            },
            {
              id: `agent-${poller.agent_id || poller.poller_id}`,
              name: `Agent: ${poller.agent_id || poller.poller_id}`, 
              type: "agent",
              kvStore: poller.kv_store_id || "local",
              status: poller.is_healthy ? "active" : "inactive"
            }
          ]).flat()
        ]
      }
    ];

    // Group services by KV store if multiple exist
    const kvStoreMap = new Map();
    kvStores.forEach(store => {
      if (!kvStoreMap.has(store.id)) {
        kvStoreMap.set(store.id, {
          id: store.id,
          name: store.name,
          type: store.type,
          services: []
        });
      }
      kvStoreMap.get(store.id).services.push(...store.services);
    });

    return NextResponse.json(Array.from(kvStoreMap.values()));
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