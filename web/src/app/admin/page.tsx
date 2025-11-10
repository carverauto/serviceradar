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

import Link from 'next/link';
import React, { useState, useEffect } from 'react';
import { Database, Settings2, RefreshCw, ShieldPlus } from 'lucide-react';
import ConfigEditor from '@/components/Admin/ConfigEditor';
import ServicesTreeNavigation, { SelectedServiceInfo } from '@/components/Admin/ServicesTreeNavigation';
import RoleGuard from '@/components/Auth/RoleGuard';
import WatcherTelemetryPanel from '@/components/Admin/WatcherTelemetryPanel';
import type { ConfigDescriptor } from '@/components/Admin/types';

import type { ServiceTreePoller } from '@/components/Admin/ServicesTreeNavigation';

const deriveKvStoreHints = (nodes: ServiceTreePoller[] = []): string[] => {
  const ids = new Set<string>();
  nodes.forEach((poller) => {
    poller.kv_store_ids?.forEach((id) => {
      if (id) {
        ids.add(id);
      }
    });
    poller.agents?.forEach((agent) => {
      agent.kv_store_ids?.forEach((id) => {
        if (id) {
          ids.add(id);
        }
      });
      agent.services?.forEach((service) => {
        if (service?.kv_store_id) {
          ids.add(service.kv_store_id);
        }
      });
    });
  });
  return Array.from(ids).sort();
};

export default function AdminPage() {
  const [pollers, setPollers] = useState<ServiceTreePoller[]>([]);
  const [selectedService, setSelectedService] = useState<SelectedServiceInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [filterPoller, setFilterPoller] = useState('');
  const [filterAgent, setFilterAgent] = useState('');
  const [filterService, setFilterService] = useState('');
  const [configDescriptors, setConfigDescriptors] = useState<ConfigDescriptor[]>([]);
  const [descriptorError, setDescriptorError] = useState<string | null>(null);
  const [kvStoreHints, setKvStoreHints] = useState<string[]>([]);

  useEffect(() => {
    fetchServicesTree();
  }, []);

  useEffect(() => {
    const fetchDescriptors = async () => {
      try {
        const token = document.cookie
          .split("; ")
          .find((row) => row.startsWith("accessToken="))
          ?.split("=")[1];
        const resp = await fetch('/api/admin/config', {
          headers: token ? { 'Authorization': `Bearer ${token}` } : {},
        });
        if (!resp.ok) {
          throw new Error('Failed to fetch config descriptors');
        }
        const data = await resp.json();
        setConfigDescriptors(Array.isArray(data) ? data : []);
        setDescriptorError(null);
      } catch (err) {
        console.error('Error fetching config descriptors:', err);
        setConfigDescriptors([]);
        setDescriptorError('Configuration metadata unavailable; showing cached services only.');
      }
    };
    fetchDescriptors();
  }, []);

  const fetchServicesTree = async () => {
    try {
      setLoading(true);
      // Prefer cookie-based token used across the app
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      const response = await fetch('/api/services/tree', {
        headers: token ? { 'Authorization': `Bearer ${token}` } : {},
      });

      if (!response.ok) {
        throw new Error('Failed to fetch services tree');
      }

      const data = await response.json();
      setPollers(data || []);
      setKvStoreHints(deriveKvStoreHints(data || []));
    } catch (err) {
      console.error('Error fetching services tree:', err);
      setPollers([]);
      setKvStoreHints([]);
    } finally {
      setLoading(false);
    }
  };

  const handleSelect = (sel: SelectedServiceInfo) => setSelectedService(sel);

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
      <div className="relative h-full">
        <div className="flex h-full">
          <div className="w-80 border-r border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 overflow-y-auto">
            <div className="p-4 border-b border-gray-200 dark:border-gray-700">
              <div className="flex items-start justify-between gap-3 mb-3">
                <h2 className="text-lg font-semibold flex items-center gap-2">
                  <Database className="h-5 w-5" />
                  Configuration Management
                </h2>
                <Link
                  href="/admin/edge-packages"
                  className="inline-flex items-center gap-1 rounded-md border border-blue-200 bg-blue-50 px-2.5 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:border-blue-900/40 dark:bg-blue-900/20 dark:text-blue-100"
                >
                  <ShieldPlus className="h-3.5 w-3.5" />
                  Edge onboarding
                </Link>
              </div>
              <div className="flex gap-2">
                <input
                  placeholder="Filter poller…"
                  className="w-1/2 px-2 py-1 text-sm border rounded bg-white dark:bg-gray-900"
                  value={filterPoller}
                  onChange={(e) => setFilterPoller(e.target.value)}
                />
                <input
                  placeholder="Filter agent…"
                  className="w-1/2 px-2 py-1 text-sm border rounded bg-white dark:bg-gray-900"
                  value={filterAgent}
                  onChange={(e) => setFilterAgent(e.target.value)}
                />
            </div>
            <div className="mt-2">
              <input
                placeholder="Filter service…"
                className="w-full px-2 py-1 text-sm border rounded bg-white dark:bg-gray-900"
                value={filterService}
                onChange={(e) => setFilterService(e.target.value)}
              />
            </div>
            {descriptorError && (
              <p className="mt-2 text-xs text-yellow-700 dark:text-yellow-300">{descriptorError}</p>
            )}
          </div>
            
            <ServicesTreeNavigation
              pollers={pollers}
              onSelect={handleSelect}
              selected={selectedService}
              filterPoller={filterPoller}
              filterAgent={filterAgent}
              filterService={filterService}
              configDescriptors={configDescriptors}
            />
          </div>

          <div className="flex-1 flex flex-col overflow-hidden bg-gray-50 dark:bg-gray-900/30">
            <WatcherTelemetryPanel kvStoreHints={kvStoreHints} />
            <div className="flex-1 overflow-hidden">
              {selectedService ? (
                <div className="flex h-full items-center justify-center text-gray-500">
                  <div className="text-center text-sm">
                    <Settings2 className="h-10 w-10 mx-auto mb-3 text-gray-400" />
                    <p>Editing {selectedService.name}</p>
                    <p className="mt-1 text-gray-400">Close the editor to return to this view.</p>
                  </div>
                </div>
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
        </div>

        {selectedService && (
          <div className="absolute inset-0 z-20 bg-gray-950/70 backdrop-blur-sm">
            <div className="flex h-full w-full">
              <div className="flex-1 bg-white dark:bg-gray-950 shadow-2xl flex flex-col overflow-hidden">
                <ConfigEditor
                  service={selectedService}
                  kvStore={selectedService.kvStore || ''}
                  onSave={() => fetchServicesTree()}
                  onClose={() => setSelectedService(null)}
                />
              </div>
            </div>
          </div>
        )}
      </div>
    </RoleGuard>
  );
}
