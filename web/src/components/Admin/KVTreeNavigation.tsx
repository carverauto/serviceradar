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

import React, { useState } from 'react';
import { ChevronRight, ChevronDown, Server, Cpu, Database, Settings, Package } from 'lucide-react';

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

interface KVTreeNavigationProps {
  kvStores: KVStore[];
  onServiceSelect: (service: ServiceInfo, kvStore: string) => void;
  selectedService: ServiceInfo | null;
}

export default function KVTreeNavigation({ kvStores, onServiceSelect, selectedService }: KVTreeNavigationProps) {
  const [expandedKVs, setExpandedKVs] = useState<Set<string>>(new Set(['local']));
  const [expandedServices, setExpandedServices] = useState<Set<string>>(new Set());

  const toggleKV = (kvId: string) => {
    const newExpanded = new Set(expandedKVs);
    if (newExpanded.has(kvId)) {
      newExpanded.delete(kvId);
    } else {
      newExpanded.add(kvId);
    }
    setExpandedKVs(newExpanded);
  };

  const toggleServiceType = (serviceType: string) => {
    const newExpanded = new Set(expandedServices);
    if (newExpanded.has(serviceType)) {
      newExpanded.delete(serviceType);
    } else {
      newExpanded.add(serviceType);
    }
    setExpandedServices(newExpanded);
  };

  const getServiceIcon = (type: string) => {
    switch (type) {
      case 'core': return <Server className="h-4 w-4" />;
      case 'sync': return <Database className="h-4 w-4" />;
      case 'poller': return <Cpu className="h-4 w-4" />;
      case 'agent': return <Package className="h-4 w-4" />;
      default: return <Settings className="h-4 w-4" />;
    }
  };

  const serviceTypes = ['core', 'sync', 'poller', 'agent', 'otel', 'flowgger'];

  const createDefaultServices = (kvStore: string) => {
    return serviceTypes.map(type => ({
      id: `${kvStore}-${type}`,
      name: `${type.charAt(0).toUpperCase() + type.slice(1)} Configuration`,
      type: type as 'core' | 'sync' | 'poller' | 'agent',
      kvStore: kvStore,
      status: 'inactive' as const
    }));
  };

  return (
    <div className="p-2">
      {kvStores.map((kv) => {
        const services = kv.services.length > 0 ? kv.services : createDefaultServices(kv.id);
        const groupedServices = services.reduce((acc, service) => {
          if (!acc[service.type]) acc[service.type] = [];
          acc[service.type].push(service);
          return acc;
        }, {} as Record<string, ServiceInfo[]>);

        return (
          <div key={kv.id} className="mb-2">
            <div
              className="flex items-center gap-2 p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer"
              onClick={() => toggleKV(kv.id)}
            >
              {expandedKVs.has(kv.id) ? (
                <ChevronDown className="h-4 w-4" />
              ) : (
                <ChevronRight className="h-4 w-4" />
              )}
              <Database className="h-4 w-4" />
              <span className="font-medium">{kv.name}</span>
              {kv.type === 'leaf' && (
                <span className="text-xs bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 px-1.5 py-0.5 rounded">
                  Leaf
                </span>
              )}
            </div>

            {expandedKVs.has(kv.id) && (
              <div className="ml-4">
                {serviceTypes.map((type) => {
                  const servicesOfType = groupedServices[type] || [];
                  const hasServices = servicesOfType.length > 0;
                  
                  return (
                    <div key={type} className="mb-1">
                      <div
                        className="flex items-center gap-2 p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer"
                        onClick={() => hasServices ? toggleServiceType(`${kv.id}-${type}`) : null}
                      >
                        {hasServices ? (
                          expandedServices.has(`${kv.id}-${type}`) ? (
                            <ChevronDown className="h-3 w-3" />
                          ) : (
                            <ChevronRight className="h-3 w-3" />
                          )
                        ) : (
                          <span className="w-3" />
                        )}
                        {getServiceIcon(type)}
                        <span className="text-sm capitalize">{type}</span>
                        {hasServices && (
                          <span className="text-xs text-gray-500">({servicesOfType.length})</span>
                        )}
                      </div>

                      {expandedServices.has(`${kv.id}-${type}`) && (
                        <div className="ml-6">
                          {servicesOfType.map((service) => (
                            <div
                              key={service.id}
                              className={`flex items-center gap-2 p-1.5 text-sm hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer ${
                                selectedService?.id === service.id ? 'bg-blue-100 dark:bg-blue-900' : ''
                              }`}
                              onClick={() => onServiceSelect(service, kv.id)}
                            >
                              <span className="w-3" />
                              <span>{service.name}</span>
                              {service.status === 'active' && (
                                <span className="w-2 h-2 bg-green-500 rounded-full" />
                              )}
                            </div>
                          ))}
                        </div>
                      )}

                      {!hasServices && (
                        <div
                          className={`ml-9 flex items-center gap-2 p-1.5 text-sm hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer ${
                            selectedService?.type === type && selectedService?.kvStore === kv.id ? 'bg-blue-100 dark:bg-blue-900' : ''
                          }`}
                          onClick={() => onServiceSelect({
                            id: `${kv.id}-${type}`,
                            name: `${type.charAt(0).toUpperCase() + type.slice(1)} Configuration`,
                            type: type as 'core' | 'sync' | 'poller' | 'agent',
                            kvStore: kv.id,
                            status: 'inactive'
                          }, kv.id)}
                        >
                          <span className="text-gray-500">Configure {type}</span>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
