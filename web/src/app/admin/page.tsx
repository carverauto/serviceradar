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
import { Database, Settings2, RefreshCw } from 'lucide-react';
import ConfigEditor from '@/components/Admin/ConfigEditor';
import ServicesTreeNavigation, { SelectedServiceInfo } from '@/components/Admin/ServicesTreeNavigation';
import RoleGuard from '@/components/Auth/RoleGuard';

import type { ServiceTreePoller } from '@/components/Admin/ServicesTreeNavigation';

export default function AdminPage() {
  const [pollers, setPollers] = useState<ServiceTreePoller[]>([]);
  const [selectedService, setSelectedService] = useState<SelectedServiceInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [filterPoller, setFilterPoller] = useState('');
  const [filterAgent, setFilterAgent] = useState('');
  const [filterService, setFilterService] = useState('');

  useEffect(() => {
    fetchServicesTree();
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
    } catch (err) {
      console.error('Error fetching services tree:', err);
      setPollers([]);
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
      <div className="flex h-full">
        <div className="w-80 border-r border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 overflow-y-auto">
          <div className="p-4 border-b border-gray-200 dark:border-gray-700">
            <h2 className="text-lg font-semibold flex items-center gap-2 mb-3">
              <Database className="h-5 w-5" />
              Configuration Management
            </h2>
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
          </div>
          
          <ServicesTreeNavigation pollers={pollers} onSelect={handleSelect} selected={selectedService} filterPoller={filterPoller} filterAgent={filterAgent} filterService={filterService} />
        </div>

        <div className="flex-1 overflow-y-auto">
          {selectedService ? (
            <ConfigEditor 
              service={selectedService}
              kvStore={selectedService.kvStore || ''}
              onSave={() => fetchServicesTree()}
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
