/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
"use client";
import React, { useState, useEffect, useCallback, useRef } from "react";
import { useAuth } from "@/components/AuthProvider";
import { Device, Pagination, DevicesApiResponse } from "@/types/devices";
import { cachedQuery } from "@/lib/cached-query";
import { escapeSrqlValue } from "@/lib/srql";
import {
  Server,
  Search,
  Loader2,
  AlertTriangle,
  CheckCircle,
  XCircle,
  Share2,
} from "lucide-react";
import DeviceTable from "./DeviceTable";
import { useDebounce } from "use-debounce";
import { useSrqlQuery, DEFAULT_SRQL_QUERY } from "@/contexts/SrqlQueryContext";
import { usePathname } from "next/navigation";
import selectDevicesQuery from "./deviceQueryUtils";
type SortableKeys =
  | "ip"
  | "hostname"
  | "last_seen"
  | "first_seen"
  | "poller_id";

type FilterStatus = "all" | "online" | "offline" | "collectors";

const StatCard = ({
  title,
  value,
  icon,
  isLoading,
  colorScheme = "blue",
  onClick,
  isActive = false,
}: {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  isLoading: boolean;
  colorScheme?: "blue" | "green" | "red" | "purple";
  onClick?: () => void;
  isActive?: boolean;
}) => {
  const bgColors = {
    blue: "bg-blue-50 dark:bg-blue-900/30",
    green: "bg-green-50 dark:bg-green-900/30",
    red: "bg-red-50 dark:bg-red-900/30",
    purple: "bg-purple-50 dark:bg-purple-900/30",
  };
  const ringColors = {
    blue: "focus:ring-blue-500",
    green: "focus:ring-green-500",
    red: "focus:ring-red-500",
    purple: "focus:ring-purple-500",
  };
  const Component = onClick ? "button" : "div";

  return (
    <Component
      type={onClick ? "button" : undefined}
      onClick={onClick}
      aria-pressed={isActive}
      className={`bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg ${onClick ? "text-left transition hover:border-gray-400 dark:hover:border-gray-600 focus:outline-none focus:ring-2 focus:ring-offset-2 dark:focus:ring-offset-gray-900 " + ringColors[colorScheme] : ""} ${isActive ? "border-blue-500 dark:border-blue-400" : ""}`}
    >
      <div className="flex items-center">
        <div className={`p-3 ${bgColors[colorScheme]} rounded-lg mr-4`}>
          {icon}
        </div>
        <div>
          <p className="text-sm text-gray-600 dark:text-gray-400">{title}</p>
          {isLoading ? (
            <div className="h-7 w-20 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse mt-1"></div>
          ) : (
            <p className="text-2xl font-bold text-gray-900 dark:text-white">
              {value}
            </p>
          )}
        </div>
      </div>
    </Component>
  );
};
const Dashboard = () => {
  const { token } = useAuth();
  const {
    query: activeSrqlQuery,
    viewId: activeViewId,
    setQuery: setSrqlQuery,
  } = useSrqlQuery();
  const pathname = usePathname();
  const [devices, setDevices] = useState<Device[]>([]);
  const [pagination, setPagination] = useState<Pagination | null>(null);
  const [stats, setStats] = useState({
    total: 0,
    online: 0,
    offline: 0,
    collectors: 0,
  });
  const [statsLoading, setStatsLoading] = useState(true);
  const [devicesLoading, setDevicesLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [searchTerm, setSearchTerm] = useState("");
  const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
  const [filterStatus, setFilterStatus] = useState<FilterStatus>("all");
  const [sortBy, setSortBy] = useState<SortableKeys>("last_seen");
  const [sortOrder, setSortOrder] = useState<"asc" | "desc">("desc");
  const pendingFilterRef = useRef<FilterStatus | null>(null);
  const buildQuery = useCallback(
    (
      status: FilterStatus,
      searchValue: string,
      sort: SortableKeys,
      order: "asc" | "desc",
    ): string => {
      const queryParts = [
        "in:devices",
        "time:last_7d",
        `sort:${sort}:${order}`,
        "limit:20",
      ];

      if (status === "online") {
        queryParts.push("is_available:true");
      } else if (status === "offline") {
        queryParts.push("is_available:false");
      } else if (status === "collectors") {
        queryParts.push("metadata._alias_last_seen_service_id:*");
      }

      const trimmedSearch = searchValue.trim();
      if (trimmedSearch) {
        const escapedTerm = escapeSrqlValue(trimmedSearch);
        queryParts.push(`search:"${escapedTerm}"`);
      }

      return queryParts.join(" ");
    },
    [],
  );

  const postQuery = useCallback(
    async <T,>(
      query: string,
      cursor?: string,
      direction?: "next" | "prev",
    ): Promise<T> => {
      const body: Record<string, unknown> = {
        query,
        limit: 20,
      };
      if (cursor) body.cursor = cursor;
      if (direction) body.direction = direction;

      const response = await fetch("/api/query", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token && { Authorization: `Bearer ${token}` }),
        },
        body: JSON.stringify(body),
        cache: "no-store",
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || "Failed to execute query");
      }
      return response.json();
    },
    [token],
  );

  const fetchStats = useCallback(async () => {
    setStatsLoading(true);
    try {
      const baseQuery = 'in:devices time:last_7d stats:"count() as total"';

      const runCount = async (query: string): Promise<number> => {
        try {
          const response = await cachedQuery<{
            results: Array<{ total: number }>;
          }>(query, token || undefined, 30000);
          return response.results?.[0]?.total ?? 0;
        } catch (queryError) {
          console.error(`Failed to execute count query: ${query}`, queryError);
          return 0;
        }
      };

      const [total, online, offline] = await Promise.all([
        runCount(baseQuery),
        runCount(`${baseQuery} is_available:true`),
        runCount(`${baseQuery} is_available:false`),
      ]);

      let collectors = await runCount(
        `${baseQuery} metadata._alias_last_seen_service_id:*`,
      );
      if (collectors === 0) {
        collectors = await runCount(
          `${baseQuery} collector_capabilities.has_collector:true`,
        );
      }

      setStats({
        total,
        online,
        offline,
        collectors,
      });
    } catch (error) {
      console.error("Failed to fetch device stats:", error);
    } finally {
      setStatsLoading(false);
    }
  }, [token]);

  const viewPath = pathname ?? "/devices";

  const normalizeQuery = useCallback(
    (value: string): string => value.replace(/\s+/g, " ").trim(),
    [],
  );

  const [currentQuery, setCurrentQuery] = useState(DEFAULT_SRQL_QUERY);
  const suppressStateSyncRef = useRef(false);

  const runDevicesQuery = useCallback(
    async (
      query: string,
      options?: {
        cursor?: string;
        direction?: "next" | "prev";
        syncContext?: boolean;
      },
    ) => {
      setDevicesLoading(true);
      setError(null);
      try {
        const data = await postQuery<DevicesApiResponse>(
          query,
          options?.cursor,
          options?.direction,
        );
        setDevices(data.results || []);
        setPagination(data.pagination || null);
        setCurrentQuery(query);

        if (options?.syncContext !== false) {
          setSrqlQuery(query, {
            origin: "view",
            viewPath,
            viewId: "devices:inventory",
          });
        }
      } catch (e) {
        setError(e instanceof Error ? e.message : "An unknown error occurred.");
        setDevices([]);
        setPagination(null);
      } finally {
        setDevicesLoading(false);
      }
    },
    [postQuery, setSrqlQuery, viewPath],
  );

  const buildQueryFromState = useCallback(
    () => buildQuery(filterStatus, debouncedSearchTerm, sortBy, sortOrder),
    [buildQuery, filterStatus, debouncedSearchTerm, sortBy, sortOrder],
  );

  const fetchDevicesFromState = useCallback(
    (cursor?: string, direction?: "next" | "prev") => {
      if (suppressStateSyncRef.current) {
        suppressStateSyncRef.current = false;
        return;
      }
      const query = buildQueryFromState();
      void runDevicesQuery(query, { cursor, direction });
    },
    [buildQueryFromState, runDevicesQuery],
  );

  const handlePageChange = useCallback(
    (cursor?: string, direction?: "next" | "prev") => {
      if (!cursor) {
        return;
      }
      void runDevicesQuery(currentQuery, {
        cursor,
        direction,
        syncContext: false,
      });
    },
    [currentQuery, runDevicesQuery],
  );

  useEffect(() => {
    if (activeViewId === "devices:inventory") {
      const normalizedIncoming = normalizeQuery(activeSrqlQuery);
      const normalizedStateQuery = normalizeQuery(buildQueryFromState());

      if (
        normalizedIncoming &&
        normalizedIncoming !== normalizedStateQuery &&
        pendingFilterRef.current === null
      ) {
        suppressStateSyncRef.current = true;
        void runDevicesQuery(normalizedIncoming, { syncContext: false });
        return;
      }

      fetchDevicesFromState();
      return;
    }

    if (!viewPath || !viewPath.startsWith("/devices")) {
      return;
    }

    const normalizedIncoming = normalizeQuery(activeSrqlQuery);
    const nextQuery = selectDevicesQuery(
      normalizedIncoming,
      buildQueryFromState(),
    );

    suppressStateSyncRef.current = true;
    setSrqlQuery(nextQuery, {
      origin: "view",
      viewPath,
      viewId: "devices:inventory",
    });
    void runDevicesQuery(nextQuery, { syncContext: false });
  }, [
    activeSrqlQuery,
    activeViewId,
    buildQueryFromState,
    fetchDevicesFromState,
    normalizeQuery,
    runDevicesQuery,
    setSrqlQuery,
    viewPath,
  ]);

  useEffect(() => {
    if (activeViewId !== "devices:inventory") {
      return;
    }

    const normalizedIncoming = normalizeQuery(activeSrqlQuery);
    if (!normalizedIncoming) {
      return;
    }

    const normalizedCurrent = normalizeQuery(currentQuery);
    if (normalizedIncoming === normalizedCurrent) {
      return;
    }

    suppressStateSyncRef.current = true;
    void runDevicesQuery(activeSrqlQuery, { syncContext: false });
  }, [
    activeSrqlQuery,
    activeViewId,
    currentQuery,
    normalizeQuery,
    runDevicesQuery,
  ]);

  useEffect(() => {
    if (activeViewId !== "devices:inventory") {
      return;
    }

    const normalized = normalizeQuery(activeSrqlQuery).toLowerCase();
    const hasOnline = normalized.includes("is_available:true");
    const hasOffline = normalized.includes("is_available:false");
    const hasCollectors = normalized.includes(
      "metadata._alias_last_seen_service_id:*",
    );
    const pending = pendingFilterRef.current;

    if (pending) {
      const matchesPending =
        (pending === "online" && hasOnline) ||
        (pending === "offline" && hasOffline) ||
        (pending === "collectors" && hasCollectors) ||
        (pending === "all" && !hasOnline && !hasOffline && !hasCollectors);

      if (matchesPending) {
        pendingFilterRef.current = null;
      } else {
        return;
      }
    }

    if (hasCollectors) {
      if (filterStatus !== "collectors") {
        setFilterStatus("collectors");
      }
      return;
    }

    if (hasOnline) {
      if (filterStatus !== "online") {
        setFilterStatus("online");
      }
      return;
    }

    if (hasOffline) {
      if (filterStatus !== "offline") {
        setFilterStatus("offline");
      }
      return;
    }

    if (filterStatus !== "all") {
      setFilterStatus("all");
    }
  }, [activeSrqlQuery, activeViewId, filterStatus, normalizeQuery]);

  useEffect(() => {
    fetchStats();
  }, [fetchStats]);

  const handleSort = (key: SortableKeys) => {
    if (sortBy === key) {
      setSortOrder(sortOrder === "asc" ? "desc" : "asc");
    } else {
      setSortBy(key);
      setSortOrder("desc");
    }
  };

  const handleStatCardFilter = useCallback(
    (status: FilterStatus) => {
      if (filterStatus === status) {
        suppressStateSyncRef.current = false;
        fetchDevicesFromState();
        return;
      }

      pendingFilterRef.current = status;
      const nextQuery = buildQuery(
        status,
        debouncedSearchTerm,
        sortBy,
        sortOrder,
      );
      suppressStateSyncRef.current = true;
      setFilterStatus(status);
      void runDevicesQuery(nextQuery);
    },
    [
      buildQuery,
      debouncedSearchTerm,
      fetchDevicesFromState,
      filterStatus,
      runDevicesQuery,
      sortBy,
      sortOrder,
    ],
  );

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <StatCard
          title="Total Devices"
          value={stats.total.toLocaleString()}
          icon={<Server className="h-6 w-6 text-blue-600 dark:text-blue-400" />}
          isLoading={statsLoading}
          colorScheme="blue"
          onClick={() => handleStatCardFilter("all")}
          isActive={filterStatus === "all"}
        />
        <StatCard
          title="Online"
          value={stats.online.toLocaleString()}
          icon={
            <CheckCircle className="h-6 w-6 text-green-600 dark:text-green-400" />
          }
          isLoading={statsLoading}
          colorScheme="green"
          onClick={() => handleStatCardFilter("online")}
          isActive={filterStatus === "online"}
        />
        <StatCard
          title="Offline"
          value={stats.offline.toLocaleString()}
          icon={<XCircle className="h-6 w-6 text-red-600 dark:text-red-400" />}
          isLoading={statsLoading}
          colorScheme="red"
          onClick={() => handleStatCardFilter("offline")}
          isActive={filterStatus === "offline"}
        />
        <StatCard
          title="Devices with Collectors"
          value={stats.collectors.toLocaleString()}
          icon={
            <Share2 className="h-6 w-6 text-purple-600 dark:text-purple-400" />
          }
          isLoading={statsLoading}
          colorScheme="purple"
          onClick={() => handleStatCardFilter("collectors")}
          isActive={filterStatus === "collectors"}
        />
      </div>

      <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
        <div className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-700">
          <div className="relative w-full md:w-1/3">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
            <input
              type="text"
              placeholder="Search by IP, hostname, or ID..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
            />
          </div>
          <div className="flex items-center gap-4">
            <label
              htmlFor="statusFilter"
              className="text-sm text-gray-600 dark:text-gray-300"
            >
              Status:
            </label>
            <select
              id="statusFilter"
              value={filterStatus}
              onChange={(e) => {
                const nextStatus = e.target.value as
                  | "all"
                  | "online"
                  | "offline"
                  | "collectors";
                pendingFilterRef.current = nextStatus;
                setFilterStatus(nextStatus);
              }}
              className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
            >
              <option value="all">All</option>
              <option value="online">Online</option>
              <option value="offline">Offline</option>
              <option value="collectors">Collectors</option>
            </select>
          </div>
        </div>

        {devicesLoading ? (
          <div className="text-center p-8">
            <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
          </div>
        ) : error ? (
          <div className="text-center p-8 text-red-400">
            <AlertTriangle className="mx-auto h-6 w-6 mb-2" />
            {error}
          </div>
        ) : (
          <DeviceTable
            devices={devices}
            onSort={handleSort}
            sortBy={sortBy}
            sortOrder={sortOrder}
          />
        )}

        {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
          <div className="p-4 flex items-center justify-between border-t border-gray-700">
            <button
              onClick={() => handlePageChange(pagination.prev_cursor, "prev")}
              disabled={!pagination.prev_cursor || devicesLoading}
              className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Previous
            </button>
            <button
              onClick={() => handlePageChange(pagination.next_cursor, "next")}
              disabled={!pagination.next_cursor || devicesLoading}
              className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Next
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

export default Dashboard;
