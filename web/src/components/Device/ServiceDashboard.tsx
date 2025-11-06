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

"use client";

import React, { useState } from "react";
import { ChevronLeft, Network, BarChart3, Database } from "lucide-react";
import Link from "next/link";
import { useAuth } from "@/components/AuthProvider";

export interface RegistryDetails {
  device_id: string;
  device_type: string;
  registration_source?: string;
  first_registered?: string;
  first_seen?: string;
  last_seen?: string;
  status?: string;
  spiffe_identity?: string;
  metadata?: Record<string, string>;
  parent_id?: string;
  component_id?: string;
  checker_kind?: string;
}

export type ServiceDashboardData = RegistryDetails | unknown[] | null;

interface DeviceServiceDashboardProps {
  deviceId: string;
  serviceName: string;
  initialData: ServiceDashboardData;
  initialError: string | null;
  initialTimeRange: string;
}

const DeviceServiceDashboard: React.FC<DeviceServiceDashboardProps> = ({
  deviceId,
  serviceName,
  initialData,
  initialError,
  initialTimeRange,
}) => {
  const { token } = useAuth();
  const [data, setData] = useState<ServiceDashboardData>(initialData);
  const [error, setError] = useState(initialError);
  const [timeRange, setTimeRange] = useState(initialTimeRange);
  const [loading, setLoading] = useState(false);

  const isRegistryService = serviceName.toLowerCase() === "registry";

  const getRegistryInfo = () => {
    if (!isRegistryService || !data || Array.isArray(data)) {
      return null;
    }
    return data as RegistryDetails;
  };

  const registryInfo = getRegistryInfo();

  const getServiceIcon = () => {
    switch (serviceName.toLowerCase()) {
      case "snmp":
        return <Network className="h-6 w-6" />;
      case "sysmon":
        return <BarChart3 className="h-6 w-6" />;
      case "registry":
        return <Database className="h-6 w-6" />;
      default:
        return <BarChart3 className="h-6 w-6" />;
    }
  };

  const getServiceTitle = () => {
    switch (serviceName.toLowerCase()) {
      case "snmp":
        return "Network Metrics (SNMP)";
      case "sysmon":
        return "System Metrics (Sysmon)";
      case "registry":
        return "Service Registry Details";
      default:
        return `${serviceName} Metrics`;
    }
  };

  const fetchData = async (newTimeRange: string) => {
    if (isRegistryService) {
      return;
    }

    setLoading(true);
    try {
      const hours = newTimeRange.replace("h", "");
      const endTime = new Date();
      const startTime = new Date(
        endTime.getTime() - parseInt(hours) * 60 * 60 * 1000,
      );

      const response = await fetch(
        `/api/devices/${deviceId}/metrics?type=${serviceName.toLowerCase()}&start=${startTime.toISOString()}&end=${endTime.toISOString()}`,
        {
          headers: {
            "Content-Type": "application/json",
            ...(token && { Authorization: `Bearer ${token}` }),
          },
        },
      );

      if (response.ok) {
        const newData = await response.json();
        setData(Array.isArray(newData) ? newData : []);
        setError(null);
      } else {
        const errorText = await response.text();
        setError(`Failed to fetch data: ${response.status} - ${errorText}`);
      }
    } catch (err) {
      setError(`Error fetching data: ${(err as Error).message}`);
    } finally {
      setLoading(false);
    }
  };

  const handleTimeRangeChange = (newTimeRange: string) => {
    setTimeRange(newTimeRange);
    fetchData(newTimeRange);
  };

  const formatTimestamp = (value?: string) => {
    if (!value) {
      return "—";
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return value;
    }
    return date.toLocaleString();
  };

  if (error) {
    return (
      <div className="min-h-screen bg-gray-900 text-white">
        <div className="container mx-auto px-4 py-8">
          <div className="flex items-center mb-6">
            <Link
              href="/devices"
              className="mr-4 p-2 rounded-lg hover:bg-gray-800"
            >
              <ChevronLeft className="h-5 w-5" />
            </Link>
            <div className="flex items-center space-x-3">
              {getServiceIcon()}
              <h1 className="text-2xl font-bold">{getServiceTitle()}</h1>
            </div>
          </div>

          <div className="bg-red-900/20 border border-red-500 rounded-lg p-6">
            <h2 className="text-xl font-semibold text-red-400 mb-2">
              Error Loading Service Data
            </h2>
            <p className="text-red-300">{error}</p>
            <div className="mt-4 text-sm text-gray-400">
              <p>Device ID: {deviceId}</p>
              <p>Service: {serviceName}</p>
            </div>
          </div>
        </div>
      </div>
    );
  }

  const renderRegistryDetails = () => {
    if (!registryInfo) {
      return (
        <div className="bg-gray-800 rounded-lg p-6 text-center text-gray-300">
          <p>No registry details are available for this device.</p>
        </div>
      );
    }

    return (
      <div className="space-y-6">
        <div className="bg-gray-800 rounded-lg p-6 grid gap-4 md:grid-cols-2">
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              Component
            </h3>
            <p className="text-lg font-semibold text-white">
              {registryInfo.device_type || "Unknown"}
            </p>
          </div>
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              Status
            </h3>
            <p className="text-lg font-semibold text-white">
              {registryInfo.status || "Unknown"}
            </p>
          </div>
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              Registration Source
            </h3>
            <p className="text-white">
              {registryInfo.registration_source || "Unavailable"}
            </p>
          </div>
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              SPIFFE Identity
            </h3>
            <p className="text-white break-all">
              {registryInfo.spiffe_identity || "—"}
            </p>
          </div>
          {registryInfo.parent_id && (
            <div>
              <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
                Parent ID
              </h3>
              <p className="text-white break-all">{registryInfo.parent_id}</p>
            </div>
          )}
          {registryInfo.component_id && (
            <div>
              <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
                Component ID
              </h3>
              <p className="text-white break-all">
                {registryInfo.component_id}
              </p>
            </div>
          )}
        </div>

        <div className="bg-gray-800 rounded-lg p-6 grid gap-4 md:grid-cols-3">
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              First Registered
            </h3>
            <p className="text-white">
              {formatTimestamp(registryInfo.first_registered)}
            </p>
          </div>
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              First Seen
            </h3>
            <p className="text-white">
              {formatTimestamp(registryInfo.first_seen)}
            </p>
          </div>
          <div>
            <h3 className="text-sm uppercase tracking-wide text-gray-400 mb-2">
              Last Seen
            </h3>
            <p className="text-white">
              {formatTimestamp(registryInfo.last_seen)}
            </p>
          </div>
        </div>

        {registryInfo.metadata &&
          Object.keys(registryInfo.metadata).length > 0 && (
            <div className="bg-gray-800 rounded-lg p-6">
              <h3 className="text-lg font-semibold text-white mb-4">
                Metadata
              </h3>
              <dl className="grid gap-3 md:grid-cols-2">
                {Object.entries(registryInfo.metadata)
                  .sort(([a], [b]) => a.localeCompare(b))
                  .map(([key, value]) => (
                    <div
                      key={key}
                      className="border border-gray-700 rounded-lg p-4"
                    >
                      <dt className="text-sm text-gray-400 uppercase tracking-wide">
                        {key}
                      </dt>
                      <dd className="mt-1 text-white break-all">
                        {value || "—"}
                      </dd>
                    </div>
                  ))}
              </dl>
            </div>
          )}
      </div>
    );
  };

  return (
    <div className="min-h-screen bg-gray-900 text-white">
      <div className="container mx-auto px-4 py-8">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center">
            <Link
              href="/devices"
              className="mr-4 p-2 rounded-lg hover:bg-gray-800"
            >
              <ChevronLeft className="h-5 w-5" />
            </Link>
            <div className="flex items-center space-x-3">
              {getServiceIcon()}
              <div>
                <h1 className="text-2xl font-bold">{getServiceTitle()}</h1>
                <p className="text-gray-400">Device: {deviceId}</p>
              </div>
            </div>
          </div>

          {!isRegistryService && (
            <div className="flex items-center space-x-4">
              <select
                value={timeRange}
                onChange={(e) => handleTimeRangeChange(e.target.value)}
                className="bg-gray-800 border border-gray-600 rounded-lg px-3 py-2 text-white"
                disabled={loading}
              >
                <option value="1h">Last 1 Hour</option>
                <option value="6h">Last 6 Hours</option>
                <option value="24h">Last 24 Hours</option>
                <option value="7d">Last 7 Days</option>
              </select>
            </div>
          )}
        </div>

        <div className="grid gap-6">
          {isRegistryService ? (
            loading ? (
              <div className="bg-gray-800 rounded-lg p-6 text-center">
                <div className="animate-spin inline-block w-6 h-6 border-2 border-white border-t-transparent rounded-full"></div>
                <p className="mt-2 text-gray-400">
                  Loading registry details...
                </p>
              </div>
            ) : (
              renderRegistryDetails()
            )
          ) : loading ? (
            <div className="bg-gray-800 rounded-lg p-6 text-center">
              <div className="animate-spin inline-block w-6 h-6 border-2 border-white border-t-transparent rounded-full"></div>
              <p className="mt-2 text-gray-400">
                Loading {serviceName} data...
              </p>
            </div>
          ) : Array.isArray(data) && data.length > 0 ? (
            <div className="bg-gray-800 rounded-lg p-6">
              <h2 className="text-xl font-semibold mb-4">Metrics Data</h2>
              <div className="text-sm text-gray-400 mb-4">
                Found {data.length} metric records
              </div>
              <div className="max-h-96 overflow-y-auto">
                <pre className="text-sm text-gray-300 whitespace-pre-wrap">
                  {JSON.stringify(data, null, 2)}
                </pre>
              </div>
            </div>
          ) : (
            <div className="bg-gray-800 rounded-lg p-6 text-center">
              <div className="text-gray-400">
                <div className="mb-2">{getServiceIcon()}</div>
                <h3 className="text-lg font-medium text-white mb-2">
                  No {serviceName} Data Available
                </h3>
                <p>
                  No metrics found for this device in the selected time range.
                </p>
                <p className="text-sm mt-2">Device ID: {deviceId}</p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default DeviceServiceDashboard;
