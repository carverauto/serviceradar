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
import { ChevronRight, ChevronDown, Server, Database, Settings2, RefreshCw } from 'lucide-react';
import ConfigEditor from '@/components/Admin/ConfigEditor';
import KVTreeNavigation from '@/components/Admin/KVTreeNavigation';
import RoleGuard from '@/components/Auth/RoleGuard';

interface KVStore {
  id: string;
  name: string;
  type: 'hub' | 'leaf';
  services: ServiceInfo[];
}

interface ServiceInfo {
  id: string;
  name: string;
  type: 'core' | 'sync' | 'poller' | 'agent';
  kvStore: string;
  status: 'active' | 'inactive';
}

export default function AdminPage() {
  const [kvStores, setKvStores] = useState<KVStore[]>([]);
  const [selectedService, setSelectedService] = useState<ServiceInfo | null>(null);
  const [selectedKV, setSelectedKV] = useState<string>('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchKVStores();
  }, []);

  const fetchKVStores = async () => {
    try {
      setLoading(true);
      const response = await fetch('/api/config/kv', {
        headers: {
          'Authorization': `Bearer ${localStorage.getItem('token')}`,
        },
      });

      if (!response.ok) {
        throw new Error('Failed to fetch KV stores');
      }

      const data = await response.json();
      
      // If no KV stores are returned, create a default local one
      if (!data || data.length === 0) {
        setKvStores([{
          id: 'local',
          name: 'Local KV',
          type: 'hub',
          services: []
        }]);
      } else {
        setKvStores(data);
      }
    } catch (err) {
      console.error('Error fetching KV stores:', err);
      // Set default KV store on error
      setKvStores([{
        id: 'local',
        name: 'Local KV',
        type: 'hub',
        services: []
      }]);
    } finally {
      setLoading(false);
    }
  };

  const handleServiceSelect = (service: ServiceInfo, kvStore: string) => {
    setSelectedService(service);
    setSelectedKV(kvStore);
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="flex items-center space-x-2">
          <RefreshCw className="h-5 w-5 animate-spin" />
          <span>Loading configuration...</span>
        </div>
      </div>
    );
  }

  return (
    <RoleGuard requiredRoles={['admin']}>
      <div className="flex h-full">
        <div className="w-80 border-r border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 overflow-y-auto">
          <div className="p-4 border-b border-gray-200 dark:border-gray-700">
            <h2 className="text-lg font-semibold flex items-center gap-2">
              <Database className="h-5 w-5" />
              Configuration Management
            </h2>
          </div>
          
          <KVTreeNavigation 
            kvStores={kvStores}
            onServiceSelect={handleServiceSelect}
            selectedService={selectedService}
          />
        </div>

        <div className="flex-1 overflow-y-auto">
          {selectedService ? (
            <ConfigEditor 
              service={selectedService}
              kvStore={selectedKV}
              onSave={() => fetchKVStores()}
            />
          ) : (
            <div className="flex items-center justify-center h-full text-gray-500">
              <div className="text-center">
                <Settings2 className="h-12 w-12 mx-auto mb-4 text-gray-400" />
                <p className="text-lg">Select a service to configure</p>
                <p className="text-sm mt-2">Choose from the navigation tree on the left</p>
              </div>
            </div>
          )}
        </div>
      </div>
    </RoleGuard>
  );
}